/* fbegl.c — a wrapper libEGL.so.1 that presents to /dev/fb0.
 *
 * SDL resolves eglSwapBuffers by dlopen'ing libEGL.so.1 and dlsym'ing the
 * symbol, which bypasses an LD_PRELOAD interposer. So instead we BECOME
 * libEGL.so.1: this shim is placed first on LD_LIBRARY_PATH, exports its own
 * eglSwapBuffers (blit the finished frame to the Miyoo panel, then forward) and
 * eglGetProcAddress (hand back our eglSwapBuffers), and forwards every other
 * EGL entry point to the real Mesa EGL, shipped alongside as librealEGL.so
 * (same binary, soname patched) and pulled in as a NEEDED dependency.
 *
 * No GPU / compositor on the SSD202D: this readback+blit IS the display path.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include "fb.h"

#ifndef GL_FRAMEBUFFER_BINDING
#define GL_FRAMEBUFFER_BINDING 0x8CA6
#endif
#ifndef GL_IMPLEMENTATION_COLOR_READ_FORMAT
#define GL_IMPLEMENTATION_COLOR_READ_FORMAT 0x8B9B
#endif
#ifndef GL_IMPLEMENTATION_COLOR_READ_TYPE
#define GL_IMPLEMENTATION_COLOR_READ_TYPE   0x8B9A
#endif

/* --- present-path instrumentation (FBEGL_STATS=<frames per report>) ---------
 *
 * Phase 0 for any present-path optimization: find out what fraction of a frame
 * the readback and the blit actually are before making either faster.
 *
 * The decomposition only means anything with an explicit glFinish FIRST.
 * llvmpipe defers: nothing is rasterized until something forces a flush, and
 * that something is our glReadPixels. Timing glReadPixels alone therefore
 * charges the ENTIRE scene rasterization to "readback" and would make the
 * present path look like the bottleneck no matter what the truth is. Draining
 * the pipe separately splits "the renderer is slow" from "our copy is slow".
 */
static int    g_stats_n;          /* 0 = instrumentation off */
static int    g_stats_i;
static double a_finish, a_read, a_cursor, a_blit, a_swap, a_gap, a_map;
static double g_prev_end;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

static EGLBoolean (*real_swap)(EGLDisplay, EGLSurface);
static __eglMustCastToProperFunctionPointerType (*real_gpa)(const char *);
static EGLBoolean (*real_query)(EGLDisplay, EGLSurface, EGLint, EGLint *);

static fb_t          g_fb;
static int           g_fb_state = -1;
static unsigned char *g_buf;

/* Touch-mode cursor overlay.
 *
 * Pocket-Edition-era builds are driven by a virtual cursor injected into
 * game-window (see inject_miyoo_input.py, MCPE_INPUT=touch). The game has no
 * pointer of its own, so without this the cursor is invisible and unusable.
 * The injector publishes "x y down" to /tmp/mcpe_cursor; we stamp a crosshair
 * into the RGBA source buffer BEFORE the blit, so the existing scale + 180
 * rotation carries it to the panel for free. Costs one tiny read per frame and
 * is skipped entirely when the file does not exist (i.e. normal gamepad mode). */
static void draw_cursor(unsigned char *buf, int w, int h) {
    FILE *f = fopen("/tmp/mcpe_cursor", "r");
    if (!f) return;
    int cx = -1, cy = -1, down = 0;
    int got = fscanf(f, "%d %d %d", &cx, &cy, &down);
    fclose(f);
    if (got < 2 || cx < 0 || cy < 0 || cx >= w || cy >= h) return;
    /* glReadPixels hands us a BOTTOM-UP buffer (hence gl_bottom_up=1 in the
     * blit), but the injector publishes top-down screen coords. Flip y here or
     * the crosshair lands mirrored vertically from the actual touch point. */
    cy = h - 1 - cy;

    /* Filled while the finger is down, hollow while hovering. */
    const int arm = 5;
    for (int i = -arm; i <= arm; i++) {
        int px[2] = { cx + i, cx };
        int py[2] = { cy,     cy + i };
        for (int k = 0; k < 2; k++) {
            int x = px[k], y = py[k];
            if (x < 0 || y < 0 || x >= w || y >= h) continue;
            unsigned char *p = buf + ((size_t)y * w + x) * 4;
            int edge = (i <= -arm + 1 || i >= arm - 1);
            p[0] = down ? 255 : (edge ? 0 : 255);   /* R */
            p[1] = down ? 40  : (edge ? 0 : 255);   /* G */
            p[2] = down ? 40  : (edge ? 0 : 255);   /* B */
            p[3] = 255;
        }
    }
}
static int           g_bw, g_bh, g_frames, g_quiet;

/* --- async PBO present (FBEGL_PBO=1) ---------------------------------------
 *
 * WHY, measured in-world at 320x240 on 1.2.20.2:
 *
 *   main-thread work (app+submit 80.8 + blit 5.0 + readpx 1.0)  = 57.4% of frame
 *   rasterizer work  (glFinish 64.4)                            = 42.6% of frame
 *   llvmpipe-0 42.2% + llvmpipe-1 43.4% = 85.6%, against 85.2% predicted from
 *   that duty cycle -- i.e. the workers are saturated during glFinish and IDLE
 *   for the rest of the frame, while the main thread is the exact opposite.
 *
 * The two halves use disjoint resources and run strictly in sequence, because a
 * plain glReadPixels is a synchronous readback and drains the pipeline every
 * single frame. llvmpipe can otherwise keep several scenes in flight and build
 * the next while rasterizing the previous. A perfectly overlapped frame would
 * cost max(86.8, 64.4) ~= 87 ms instead of 151 -- about +74%.
 *
 * So: read back into a pixel-pack buffer (asynchronous, returns immediately)
 * and blit the PREVIOUS frame, which has had a whole frame to land. Costs one
 * frame of display latency.
 *
 * This was previously ranked last and priced at ~4%, by costing the readback
 * (1 ms) instead of the barrier the readback creates (up to 64 ms of lost
 * overlap). Do not re-derive that mistake.
 *
 * GLES3 entry points are resolved at RUNTIME rather than linked, so this object
 * still builds against the Buster GLES2 headers and degrades to the synchronous
 * path on any driver that lacks them. */
#define FBEGL_GL_PIXEL_PACK_BUFFER 0x88EB
#define FBEGL_GL_STREAM_READ       0x88E1
#define FBEGL_GL_MAP_READ_BIT      0x0001
#define FBEGL_GL_MAP_WRITE_BIT     0x0002

typedef void *(*fn_map_range)(GLenum, GLintptr, GLsizeiptr, GLbitfield);
typedef GLboolean (*fn_unmap)(GLenum);
static fn_map_range p_map_range;
static fn_unmap     p_unmap;

static int    g_pbo_want;              /* FBEGL_PBO=1 requested */
static int    g_pbo_on;                /* actually running the async path */
static GLuint g_pbo[2];
static int    g_pbo_cur, g_pbo_have_prev;
static size_t g_pbo_size;

static void *resolve_gl(const char *name) {
    void *f = dlsym(RTLD_DEFAULT, name);
    if (!f && real_gpa) f = (void *)real_gpa(name);
    return f;
}

/* Returns 1 if the async path is usable for this geometry. Any failure falls
 * back to the synchronous path and says so once -- a silent fallback here would
 * look exactly like "the optimization did nothing". */
static int pbo_setup(int w, int h) {
    size_t need = (size_t)w * h * 4;
    if (!g_pbo_want) return 0;
    if (g_pbo_on && g_pbo_size == need) return 1;

    if (!p_map_range) {
        p_map_range = (fn_map_range)resolve_gl("glMapBufferRange");
        p_unmap     = (fn_unmap)resolve_gl("glUnmapBuffer");
    }
    if (!p_map_range || !p_unmap) {
        fprintf(stderr, "[fbegl] PBO unavailable (no glMapBufferRange/glUnmapBuffer) "
                        "- staying on the synchronous path\n");
        g_pbo_want = 0;
        return 0;
    }

    if (g_pbo[0] || g_pbo[1]) { glDeleteBuffers(2, g_pbo); g_pbo[0] = g_pbo[1] = 0; }
    while (glGetError() != GL_NO_ERROR) { }
    glGenBuffers(2, g_pbo);
    for (int i = 0; i < 2; i++) {
        glBindBuffer(FBEGL_GL_PIXEL_PACK_BUFFER, g_pbo[i]);
        glBufferData(FBEGL_GL_PIXEL_PACK_BUFFER, (GLsizeiptr)need, NULL, FBEGL_GL_STREAM_READ);
    }
    glBindBuffer(FBEGL_GL_PIXEL_PACK_BUFFER, 0);
    if (glGetError() != GL_NO_ERROR || !g_pbo[0] || !g_pbo[1]) {
        fprintf(stderr, "[fbegl] PBO allocation failed (%zu bytes x2) "
                        "- staying on the synchronous path\n", need);
        g_pbo_want = 0; g_pbo_on = 0;
        return 0;
    }
    g_pbo_size = need; g_pbo_cur = 0; g_pbo_have_prev = 0; g_pbo_on = 1;
    fprintf(stderr, "[fbegl] async PBO present ENABLED (%dx%d, 2 x %zu bytes, "
                    "1 frame of latency)\n", w, h, need);
    return 1;
}

static void resolve(void) {
    real_swap  = (EGLBoolean (*)(EGLDisplay, EGLSurface))dlsym(RTLD_NEXT, "eglSwapBuffers");
    real_gpa   = (__eglMustCastToProperFunctionPointerType (*)(const char *))dlsym(RTLD_NEXT, "eglGetProcAddress");
    real_query = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLint, EGLint *))dlsym(RTLD_NEXT, "eglQuerySurface");
    if (!real_swap) {                                  /* fallback: explicit handle */
        void *h = dlopen("librealEGL.so", RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            real_swap  = (EGLBoolean (*)(EGLDisplay, EGLSurface))dlsym(h, "eglSwapBuffers");
            real_gpa   = (__eglMustCastToProperFunctionPointerType (*)(const char *))dlsym(h, "eglGetProcAddress");
            real_query = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLint, EGLint *))dlsym(h, "eglQuerySurface");
        }
    }
}

__attribute__((constructor))
static void fbegl_init(void) {
    const char *s = getenv("FBEGL_STATS");
    g_quiet = getenv("FBPRESENT_QUIET") != NULL;
    g_stats_n = s ? atoi(s) : 0;
    { const char *pb = getenv("FBEGL_PBO"); g_pbo_want = pb && atoi(pb) != 0; }
    if (g_stats_n < 0) g_stats_n = 0;
    resolve();
    fprintf(stderr, "[fbegl] wrapper init real_swap=%p real_gpa=%p real_query=%p stats=%d pbo=%d\n",
            (void *)real_swap, (void *)real_gpa, (void *)real_query, g_stats_n, g_pbo_want);
}

static void present(EGLDisplay dpy, EGLSurface surf) {
    if (!real_query) return;
    EGLint w = 0, h = 0;
    real_query(dpy, surf, EGL_WIDTH,  &w);
    real_query(dpy, surf, EGL_HEIGHT, &h);
    if (w <= 0 || h <= 0) return;

    if (g_fb_state < 0)
        g_fb_state = (fb_open(&g_fb, "/dev/fb0") == 0) ? 0 : 1;
    if (w != g_bw || h != g_bh) {
        free(g_buf);
        g_buf = (unsigned char *)malloc((size_t)w * h * 4);
        g_bw = w; g_bh = h;
        if (!g_quiet) fprintf(stderr, "[fbegl] surface %dx%d\n", w, h);
    }
    if (g_fb_state == 0 && g_buf) {
        GLint prev = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        /* Report what llvmpipe would rather hand us. If this is not
         * RGBA/UNSIGNED_BYTE we are paying a per-pixel swizzle inside Mesa's
         * readback on top of the one the blit already does. */
        if (g_stats_n && g_frames == 0) {
            GLint fmt = 0, typ = 0;
            glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT, &fmt);
            glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE, &typ);
            fprintf(stderr, "[fbegl] preferred read format=0x%04X type=0x%04X "
                            "(requesting GL_RGBA=0x1908 / GL_UNSIGNED_BYTE=0x1401)\n",
                    (unsigned)fmt, (unsigned)typ);
        }

        if (pbo_setup(w, h)) {
            /* ASYNC PATH. Deliberately NO glFinish, not even under FBEGL_STATS:
             * a pipeline drain is the exact thing this path exists to remove,
             * and instrumenting it back in would hide its own effect.
             *
             * Issue this frame's readback into one buffer (returns immediately)
             * and blit the PREVIOUS frame out of the other, which has had a
             * whole frame to land. Any residual stall shows up as "map" time --
             * that is the number to watch.  */
            int nxt = g_pbo_cur ^ 1;
            double t0 = now_ms();
            glBindBuffer(FBEGL_GL_PIXEL_PACK_BUFFER, g_pbo[g_pbo_cur]);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, (void *)0);
            double t1 = now_ms(), t2 = t1, t3 = t1;

            if (g_pbo_have_prev) {
                /* Only ask for write access when the cursor overlay will
                 * actually scribble on the mapping (touch builds). */
                GLbitfield acc = FBEGL_GL_MAP_READ_BIT;
                if (access("/tmp/mcpe_cursor", F_OK) == 0) acc |= FBEGL_GL_MAP_WRITE_BIT;
                glBindBuffer(FBEGL_GL_PIXEL_PACK_BUFFER, g_pbo[nxt]);
                void *p = p_map_range(FBEGL_GL_PIXEL_PACK_BUFFER, 0,
                                      (GLsizeiptr)g_pbo_size, acc);
                t2 = now_ms();
                if (p) {
                    if (acc & FBEGL_GL_MAP_WRITE_BIT) draw_cursor((unsigned char *)p, w, h);
                    fb_blit_rgba_scaled(&g_fb, (const uint8_t *)p, w, h, 1);
                    p_unmap(FBEGL_GL_PIXEL_PACK_BUFFER);
                }
                t3 = now_ms();
            }
            glBindBuffer(FBEGL_GL_PIXEL_PACK_BUFFER, 0);
            if (prev) glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev);
            g_pbo_cur = nxt;
            g_pbo_have_prev = 1;
            if (g_stats_n) { a_read += t1 - t0; a_map += t2 - t1; a_blit += t3 - t2; }

        } else if (g_stats_n) {
            double t0 = now_ms();
            glFinish();                 /* drain the rasterizer, charged separately */
            double t1 = now_ms();
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, g_buf);
            double t2 = now_ms();
            if (prev) glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev);
            draw_cursor(g_buf, w, h);
            double t3 = now_ms();
            fb_blit_rgba_scaled(&g_fb, g_buf, w, h, 1);
            double t4 = now_ms();
            a_finish += t1 - t0; a_read += t2 - t1;
            a_cursor += t3 - t2; a_blit += t4 - t3;
        } else {
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, g_buf);
            if (prev) glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev);
            draw_cursor(g_buf, w, h);
            fb_blit_rgba_scaled(&g_fb, g_buf, w, h, 1);
        }

        if (!g_quiet && (g_frames < 3 || g_frames % 30 == 0))
            fprintf(stderr, "[fbegl] presented frame %d (%dx%d)\n", g_frames, w, h);
        g_frames++;
    }
}

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    if (!g_stats_n) {
        present(dpy, surface);
        return real_swap ? real_swap(dpy, surface) : EGL_TRUE;
    }

    /* "gap" is everything that is NOT us: the game's own frame — simulation
     * plus the GL calls it issues — measured from the end of the previous swap
     * to the start of this one. It is the denominator the present cost has to
     * be judged against. */
    double t0 = now_ms();
    if (g_prev_end > 0.0) a_gap += t0 - g_prev_end;
    present(dpy, surface);
    double t1 = now_ms();
    EGLBoolean r = real_swap ? real_swap(dpy, surface) : EGL_TRUE;
    double t2 = now_ms();
    a_swap += t2 - t1;
    g_prev_end = t2;

    if (++g_stats_i >= g_stats_n) {
        double n = (double)g_stats_i;
        double total = a_gap + a_finish + a_read + a_cursor + a_blit + a_swap + a_map;
        if (g_pbo_on) {
            /* No glFinish on this path, so rasterization is no longer a separate
             * line -- it is overlapped with app+submit, which is the point. The
             * proof that overlap is happening is that the stage times STOP
             * summing to the old frame time: "total" here should fall well below
             * the synchronous path's app+submit + glFinish. "map" is the residual
             * stall -- if it is large, the readback is not completing in time and
             * the overlap is only partial. */
            fprintf(stderr,
                    "[fbegl] stats n=%d PBO ms/frame: app+submit %.1f | readpx-issue %.2f | "
                    "map %.1f | blit %.1f | eglSwap %.2f | total %.1f (%.2f fps)\n",
                    g_stats_i, a_gap / n, a_read / n, a_map / n, a_blit / n,
                    a_swap / n, total / n, total > 0.0 ? 1000.0 * n / total : 0.0);
        } else {
            fprintf(stderr,
                    "[fbegl] stats n=%d ms/frame: app+submit %.1f | glFinish %.1f | "
                    "readpx %.1f | cursor %.2f | blit %.1f | eglSwap %.2f | total %.1f "
                    "(%.2f fps) | present share %.0f%%\n",
                    g_stats_i, a_gap / n, a_finish / n, a_read / n, a_cursor / n,
                    a_blit / n, a_swap / n, total / n,
                    total > 0.0 ? 1000.0 * n / total : 0.0,
                    total > 0.0 ? 100.0 * (a_read + a_cursor + a_blit) / total : 0.0);
        }
        a_gap = a_finish = a_read = a_cursor = a_blit = a_swap = a_map = 0.0;
        g_stats_i = 0;
    }
    return r;
}

__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name) {
    if (name && strcmp(name, "eglSwapBuffers") == 0)
        return (__eglMustCastToProperFunctionPointerType)eglSwapBuffers;
    return real_gpa ? real_gpa(name) : NULL;
}
