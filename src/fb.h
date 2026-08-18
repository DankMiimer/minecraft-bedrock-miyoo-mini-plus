/* fb.h — minimal /dev/fb0 blit for the MM+ software-GL smoke test.
 *
 * The MM+ panel is BGRA 640x480x32 and physically rotated 180 degrees
 * (see docs/01-hardware.md). This header opens/mmaps the framebuffer and
 * blits an RGBA8 source into it as BGRA with a full 180-degree rotation.
 *
 * Orientation note: getting the image perfectly upright is NOT the goal of the
 * smoke test — FPS and RSS are. If the first frame looks mirrored/upside down,
 * flip GL_BOTTOM_UP at the call site (or the x/y inversion below); it does not
 * change the performance numbers.
 */
#ifndef SMOKE_FB_H
#define SMOKE_FB_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

typedef struct {
    int      fd;
    uint8_t *mem;
    size_t   size;
    int      w, h, bpp, line;
} fb_t;

static inline int fb_open(fb_t *fb, const char *dev) {
    memset(fb, 0, sizeof(*fb));
    fb->fd = open(dev ? dev : "/dev/fb0", O_RDWR);
    if (fb->fd < 0) { perror("open /dev/fb0"); return -1; }

    struct fb_var_screeninfo vi;
    struct fb_fix_screeninfo fi;
    if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &vi) < 0) { perror("VSCREENINFO"); return -1; }
    if (ioctl(fb->fd, FBIOGET_FSCREENINFO, &fi) < 0) { perror("FSCREENINFO"); return -1; }

    fb->w    = vi.xres;
    fb->h    = vi.yres;
    fb->bpp  = vi.bits_per_pixel;
    fb->line = fi.line_length ? (int)fi.line_length : fb->w * (fb->bpp / 8);
    fb->size = fi.smem_len ? fi.smem_len : (size_t)fb->line * fb->h;

    fb->mem = mmap(NULL, fb->size, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
    if (fb->mem == MAP_FAILED) { perror("mmap /dev/fb0"); return -1; }

    fprintf(stderr, "fb: %dx%d bpp=%d line=%d size=%zu pan=%u,%u\n",
            fb->w, fb->h, fb->bpp, fb->line, fb->size, vi.xoffset, vi.yoffset);

    /* The panel is DOUBLE-BUFFERED — fbset reports `640 480 640 960 32`, two
     * pages — and MainUI pans between them. Every blit in this header targets
     * page 0, so if the display was left panned to page 1 we render perfectly
     * into a page nobody can see. From the outside that is indistinguishable
     * from "the game will not start": the process is alive, presenting frames,
     * burning both cores, and the screen never changes.
     *
     * It is intermittent in exactly the worst way, because whether you get a
     * picture depends on which page MainUI happened to be showing when it was
     * SIGSTOPped. Observed live on 2026-08-17 with pan=0,480.
     *
     * Take page 0 on open. xvfbmirror already had to learn this same lesson;
     * see docs/13. Non-fatal if it fails — say so and carry on. */
    if (vi.xoffset != 0 || vi.yoffset != 0) {
        struct fb_var_screeninfo pan = vi;
        pan.xoffset = 0;
        pan.yoffset = 0;
        if (ioctl(fb->fd, FBIOPAN_DISPLAY, &pan) == 0)
            fprintf(stderr, "fb: panned display %u,%u -> 0,0 (page 0 is what we blit)\n",
                    vi.xoffset, vi.yoffset);
        else
            perror("fb: FBIOPAN_DISPLAY (screen may stay blank)");
    }
    return 0;
}

/* src: w*h RGBA8 in GL channel order (R,G,B,A).
 * gl_bottom_up != 0 means row 0 of src is the BOTTOM of the image
 * (glReadPixels / OSMesa default). */
static inline void fb_blit_rgba(fb_t *fb, const uint8_t *src,
                                int w, int h, int gl_bottom_up) {
    if (fb->bpp != 32) {
        fprintf(stderr, "fb: unexpected bpp=%d, skipping blit\n", fb->bpp);
        return;
    }
    int rows = h < fb->h ? h : fb->h;
    int cols = w < fb->w ? w : fb->w;
    for (int y = 0; y < rows; y++) {
        int sy = gl_bottom_up ? (h - 1 - y) : y;
        int dy = fb->h - 1 - y;                       /* 180 rotate, y */
        uint8_t       *drow = fb->mem + (size_t)dy * fb->line;
        const uint8_t *srow = src + (size_t)sy * w * 4;
        for (int x = 0; x < cols; x++) {
            int dx = fb->w - 1 - x;                    /* 180 rotate, x */
            const uint8_t *s = srow + x * 4;
            uint8_t       *d = drow + dx * 4;
            d[0] = s[2];  /* B */
            d[1] = s[1];  /* G */
            d[2] = s[0];  /* R */
            d[3] = 0xff;  /* A must be opaque or the pixel may not show */
        }
    }
}

/* Nearest-neighbour upscale of src(w*h RGBA8) to the full fb (BGRA), 180-rotated.
 * Lets the GL scene render at a low internal resolution (e.g. 320x240) that is
 * then scaled to the 640x480 panel — the standard trick to buy software-raster
 * fill-rate headroom. */
/* PERF (2026-08-15): this touches every one of the panel's 307,200 pixels on
 * EVERY frame regardless of the internal render size, so it is a FIXED per-frame
 * tax that lowering MCPE_W/MCPE_H does not reduce — which is why 200x150 did not
 * beat 320x240 in-world. The original inner loop cost two things per pixel:
 *   1. `fx * w / fb->w` — an integer divide, and Cortex-A7 divides are slow.
 *   2. four separate BYTE stores into the mmap'd framebuffer. That is uncached
 *      device memory, where each byte store can become its own bus transaction.
 * Both are hoisted away below: the source x/y mapping becomes two small
 * precomputed tables (rebuilt only when the geometry changes), and each pixel is
 * written as ONE aligned 32-bit word. Alignment holds because the source is
 * malloc'd with a row stride of w*4 and fb->line is a multiple of 4. */
#ifndef FB_MAXDIM
#define FB_MAXDIM 2048
#endif

static inline void fb_blit_rgba_scaled(fb_t *fb, const uint8_t *src,
                                       int w, int h, int gl_bottom_up) {
    if (fb->bpp != 32) return;

    if (fb->w <= FB_MAXDIM && fb->h <= FB_MAXDIM) {
        static int xmap[FB_MAXDIM], ymap[FB_MAXDIM];
        static int c_w, c_h, c_fw, c_fh, c_bu;      /* geometry the tables match */
        if (w != c_w || h != c_h || fb->w != c_fw || fb->h != c_fh || gl_bottom_up != c_bu) {
            for (int fx = 0; fx < fb->w; fx++) xmap[fx] = fx * w / fb->w;
            for (int fy = 0; fy < fb->h; fy++) {
                int sy0 = fy * h / fb->h;
                ymap[fy] = gl_bottom_up ? (h - 1 - sy0) : sy0;
            }
            c_w = w; c_h = h; c_fw = fb->w; c_fh = fb->h; c_bu = gl_bottom_up;
        }
        for (int fy = 0; fy < fb->h; fy++) {
            const uint32_t *srow = (const uint32_t *)(src + (size_t)ymap[fy] * w * 4);
            /* 180 rotate: the destination row runs bottom-up AND right-to-left,
             * so walk a pointer backwards rather than recomputing fb->w-1-fx. */
            uint32_t *d = (uint32_t *)(fb->mem + (size_t)(fb->h - 1 - fy) * fb->line)
                        + (fb->w - 1);
            for (int fx = 0; fx < fb->w; fx++) {
                uint32_t s = srow[xmap[fx]];   /* RGBA8 LE: R | G<<8 | B<<16 | A<<24 */
                *d-- = 0xFF000000u                      /* force opaque */
                     | (s & 0x0000FF00u)                /* G stays put */
                     | ((s & 0x00FF0000u) >> 16)        /* B -> low byte */
                     | ((s & 0x000000FFu) << 16);       /* R -> high byte */
            }
        }
        return;
    }

    /* Fallback for panels larger than the tables: correct, just slower. */
    for (int fy = 0; fy < fb->h; fy++) {
        int sy0 = fy * h / fb->h;
        int sy  = gl_bottom_up ? (h - 1 - sy0) : sy0;
        int dy  = fb->h - 1 - fy;                       /* 180 rotate, y */
        uint8_t       *drow = fb->mem + (size_t)dy * fb->line;
        const uint8_t *srow = src + (size_t)sy * w * 4;
        for (int fx = 0; fx < fb->w; fx++) {
            int sx = fx * w / fb->w;
            int dx = fb->w - 1 - fx;                     /* 180 rotate, x */
            const uint8_t *s = srow + sx * 4;
            uint8_t       *d = drow + dx * 4;
            d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = 0xff;
        }
    }
}

static inline void fb_close(fb_t *fb) {
    if (fb->mem && fb->mem != MAP_FAILED) munmap(fb->mem, fb->size);
    if (fb->fd >= 0) close(fb->fd);
}

#endif /* SMOKE_FB_H */
