# Minecraft on Miyoo Mini Plus (no GPU) — HANDOFF

**Playable. Default = Pocket Edition 1.1.5, llvmpipe, 320×240 — 7.58 FPS mean.**
The OnionOS shortcut (`App/MinecraftBedrock`) launches it. Six Minecraft versions
were benchmarked 3× each; full data in
[`../docs/13-older-minecraft-versions-plan.md`](../docs/13-older-minecraft-versions-plan.md).

Journey: 1.16.221.01 softpipe slideshow (~1–2 FPS, froze the device) → llvmpipe +
rewritten present blit + older engine + real controls → **7.58 FPS with a working
dual-stick-style control scheme**.

---

## SOLVED: `killall smbd` is what kills the OnionOS supervisor

It was **never the OOM killer**. `launch-mcpe.sh`'s own `MCPE_FREERAM=1` phase
has been destroying the device, deterministically, since it was written:

```sh
for svc in smbd smbd-notifyd smbd-cleanupd filebrowser; do
    killall -q "$svc" 2>/dev/null        # <-- SIGTERM to smbd = supervisor dead
done
```

**Everything on this device runs in ONE process group.** Measured on a fresh
boot — `pgrp` and `session` are identical for every userspace process that
matters:

```
runtime.sh   pid=780   pgrp=582  session=564  ppid=766
MainUI       pid=1079  pgrp=582  session=564  ppid=780
keymon       pid=1021  pgrp=582  session=564  ppid=780
batmon       pid=844   pgrp=582  session=564  ppid=780
smbd         pid=1112  pgrp=582  session=564  ppid=1
filebrowser  pid=1010  pgrp=582  session=564  ppid=1
audioserver  pid=825   pgrp=582  session=564  ppid=780
```

And OnionOS starts Samba as `smbd --no-process-group -D`, so smbd **never moved
into a process group of its own** — it is still sitting in the UI's group.
Samba's SIGTERM shutdown path signals its process group to reap its children, so
that broadcast lands on `runtime.sh`, `keymon` and `batmon`. `MainUI` survives
because it ignores SIGTERM, which is exactly why the surviving-MainUI-reparented-
to-PID-1 signature looked so confusing.

**Proof, three independent steps:**

1. **Bisect of the freeram phase**, one line at a time on a fresh boot, with a
   60-second do-nothing control first (they do *not* die on their own):
   `A control +60 s: all alive` → `B killall smbd/filebrowser: DEAD -> runtime.sh
   keymon batmon`.
2. **Narrowed to the single argument.** `pidof` and busybox `killall` share
   `find_pid_by_name()`, so `pidof` is a read-only preview of the kill list —
   and it is correct, no name mis-matching: `pidof smbd -> 1120 1118 1112`, all
   genuinely smbd. Killing just that one name reproduced the failure.
3. **SIGKILL is the control.** `killall -9 -q smbd` removes all three smbd
   processes and leaves **all four UI processes alive at +12 s and +30 s**.
   SIGKILL cannot be caught, so the only thing that changed is that smbd's own
   shutdown handler never ran.

**Consequences worth absorbing:**

- Every "runtime.sh dies sometimes" incident in these docs is most likely this.
  It is not intermittent and not memory-related — it fires within ~12 s, every
  time, on a completely idle machine with 43 MB free.
- **`oom_score_adj` was never going to help.** It has no bearing on an explicit
  SIGTERM. The `protect_ui` port is still worth keeping (it costs nothing and
  covers genuine OOM), but it was aimed at the wrong cause — and what actually
  cracked this was the *warning line* added alongside it.
- The earlier `drop_caches`/SIGBUS theory was **wrong**. It was a reasonable
  guess and the bisect killed it in one run; that is what the control was for.

**FIXED and verified end-to-end** (owner approved 2026-08-17). `launch-mcpe.sh`
now uses `killall -9 -q "$svc"`: SIGKILL cannot be caught, so no service runs a
shutdown handler and nothing is broadcast to the shared group. A full game
launch, which had never once survived this, now gives:

```
    before launch:                       all alive  [sup=780 ui=1079 km=1021 bm=844]
    20 s into launch (freeram has run):  all alive  [sup=780 ui=1079 km=1021 bm=844]
    60 s in, game rendering:             all alive  [sup=780 ui=1079 km=1021 bm=844]
    110 s in, past the 90 s watchdog:    all alive  [sup=780 ui=1079 km=1021 bm=844]
[oom] protected runtime.sh (780)      <- fires for the first time ever
```

Same PIDs throughout — nothing died, nothing had to be restarted. The `-9` is
load-bearing and there is a comment in the launcher saying so; do not tidy it
back to a plain `killall`.

**The fix costs no performance**, which was not obvious — `keymon` and `batmon`
now survive and consume CPU where they used to be dead. Measured: 13.8 fps at
320×240 with the UI intact against 13.76 fps in the thread probe taken while the
bug was still killing it. Indistinguishable, because those two daemons together
are under 1% of a core and `MainUI` is SIGSTOPped during play regardless. The fix
buys stability, not speed.

Worth knowing: the loop was of dubious value anyway. filebrowser's real `VmRSS`
is 68 kB (the huge `VSZ` is Go reserving address space) and smbd's saving has
never been measured, so if it ever causes trouble again, deleting the loop
outright costs almost nothing.

## Device state at the end of 2026-08-17

**Healthy.** All four UI processes alive after a full game launch, which is new.

**`reboot` is safe over telnet ONLY if the USB cable is unplugged.** Owner-
supplied and it explains a lost hour: *the MM+ boots, detects USB power, and
turns itself off again.* That is why one mid-session `reboot` never came back —
no ping, and a port-23 sweep of `192.168.1.0/24` found nothing, which looked
exactly like a hang or a DHCP change. It was neither. Check the cable before
blaming the network.

---

## START HERE — taking this over (written 2026-08-17)

**The job now: make Bedrock 1.2.20.2 faster. Nothing else.**

### The four leads are DONE. Read this before planning anything.

All four were worked on 2026-08-17. Summary of the verdicts, evidence below:

| lead | verdict |
| --- | --- |
| 1. re-baseline with telnet closed | **resolved, cause reattributed** — it was `mm.ps1`, not `telnetd`. Fixed at the source. |
| 2. re-test low `MCPE_W/H` | **FLIPPED — low resolution now helps a lot.** Biggest live lever. |
| 3. match `glReadPixels` to the native format | **dead.** Premise was right, payoff is ~1%. |
| 4. instrument the present path | **done. Present is 7% of the frame; rasterization is 79%.** |

**The headline: the present path is not the problem.** Optimizing `glReadPixels`
or `fb_blit_rgba_scaled` cannot buy more than ~7%, because together they are
5.9 ms of an 86 ms frame. What costs is llvmpipe rasterization, and the one
lever that reaches it is internal resolution.

### Lead 4 — the present path, measured (this is the Phase 0 that was missing)

`client/src/fbegl.c` now takes `FBEGL_STATS=<frames per report>` and prints a
per-stage breakdown. It is a no-op when the variable is unset, so the shipped
path is unchanged.

**The `glFinish` split is the whole point.** llvmpipe defers: nothing is
rasterized until something forces a flush, and that something was our
`glReadPixels`. Timing `glReadPixels` alone charges the entire scene
rasterization to "readback" and makes the present path look guilty no matter
what the truth is. Draining the pipe separately, and timing that separately, is
what separates "the renderer is slow" from "our copy is slow".

1.2.20.2, 320×240, steady-state main menu, 29 reports × 30 frames:

```
app+submit 11.8 | glFinish 68.6 | readpx 1.0 | cursor 0.06 | blit 4.9 | eglSwap 0.01
                                                       total 86.4 ms = 11.6 fps
```

- **present (readpx + cursor + blit) = 7%**; rasterization = 79%; the game's own
  frame (simulation + GL submission) = 14%.
- `eglSwap` is 0.01 ms — the real swap does nothing, as expected surfaceless.

**Lead 3 is dead on these numbers.** The query does confirm the mismatch —
`GL_IMPLEMENTATION_COLOR_READ_FORMAT` is `0x80E1` (`GL_BGRA_EXT`) and
`_TYPE` is `0x1401` (`GL_UNSIGNED_BYTE`) while we ask for `GL_RGBA`, so llvmpipe
really is swizzling every pixel — but the whole of `glReadPixels` is 1.0 ms of
86. Matching the format wins at most 1%. Do not spend a build on it.

### IN-WORLD, CONFIRMED — and the bottleneck is not what the menu said

Three arms, one script, operator standing still, world reloaded identically each
time (`App/mcpe/inworld-res.sh`; `kill -9` means the world never saves, so every
arm reloads at the same position, heading and time of day):

| arm | res | app+submit | glFinish | readpx | blit | total | fps | worst |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 320×240 | 84.3 | 66.8 | 0.98 | 5.09 | 157.2 | **6.36** | 184.6 |
| 2 | **160×120** | 82.5 | **39.3** | 0.31 | 4.83 | 127.0 | **7.87** | 151.2 |
| 3 | 320×240 | 80.6 | 64.4 | 0.91 | 5.03 | 151.0 | **6.62** | 173.0 |

Arms 1 and 3 differ by 4.1%, so baseline is **6.49 fps** and anything under ~4%
is noise. **160×120 is +21%.** Real, but the menu predicted **+92%**.

**Why the menu overpredicted, and it matters more than the win:** in-world
`app+submit` is **82 ms**, seven times its menu value, and it is **completely
resolution-independent** (84.3 / 82.5 / 80.6). It is 54% of the frame at 320×240
and 65% at 160×120. Resolution only ever attacked `glFinish`, which in a world is
the *smaller* half of the frame.

Fitting the two resolutions: in-world `glFinish` ≈ **30 ms fixed + 0.48 ms per
1000 px**. Driving resolution to zero therefore floors at 82 + 30 + 5 ≈ 117 ms ≈
**8.5 fps**, and 160×120 already banks 93% of that.

**So resolution is characterised and close to exhausted.** Do not sweep it again.
Intermediate sizes are strictly worse than 160×120 *and* scale badly to the
640×480 panel (only 320×240 = 2× and 160×120 = 4× are integer):

| res | predicted in-world | scale |
| --- | ---: | --- |
| 320×240 | 6.49 (measured) | clean 2× |
| 256×192 | ~7.0 | 2.5×, shimmers |
| 200×150 | ~7.2 | 3.2×, shimmers |
| 160×120 | 7.87 (measured) | clean 4× |
| (zero px) | 8.5 ceiling | — |

**The menu screen is a good screen and a bad extrapolator.** It ranked the lever
correctly — low resolution does help — and got the magnitude wrong by 4×, because
the menu has almost no geometry and therefore almost no `app+submit`. Use it to
decide *whether* to test something in-world, never to size the win.

### Bonus result: the "universal stall" really does look like an artifact

Worst 30-frame window across all three arms was 184.6 ms = 5.4 fps against a 6.36
mean — an 18% dip, not a stall. The docs record "~1 interval under 2 FPS, every
version, every run". **This run measured a window starting 60 s after world entry
and the stalls simply were not there.** That is what the artifact hypothesis
predicts: `bench.sh` measures a trailing 180 s window which catches the tail of
world loading, and every run loads a world exactly once. Anyone re-opening the
stall question should start by fixing the window, not by hunting the engine.

### Lead 2 — low internal resolution: the old conclusion HAS flipped

One variable (`MCPE_W`/`MCPE_H`), everything else held fixed, same menu scene:

| res | pixels | app+submit | glFinish | readpx | blit | total | fps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 320×240 | 76,800 | 11.8 | 68.6 | 1.01 | 4.91 | 86.4 | 11.58 |
| 256×192 | 49,152 | 11.7 | 49.7 | 0.60 | 4.86 | 66.9 | **14.94** |
| 200×150 | 30,000 | 11.8 | 33.5 | 0.40 | 4.81 | 50.6 | **19.75** |
| 160×120 | 19,200 | 11.2 | 28.7 | 0.30 | 4.79 | 45.1 | **22.20** |

`glFinish` fits **≈15 ms fixed + 0.69 ms per 1000 pixels** (that model predicts
49.4 at 256×192 against 49.7 measured, and 36.2 at 200×150 against 33.5). So
about **78% of the rasterization cost at 320×240 is fill-proportional** and low
resolution reaches it directly.

Two things this table also settles:

- **`blit` is 4.79–4.91 ms at every resolution.** The documented "fixed
  307,200-pixel tax" is exactly that, confirmed by direct measurement rather
  than inference.
- **`app+submit` is 11.2–11.8 ms at every resolution**, so the game's own
  per-frame work is genuinely resolution-independent.

**Two caveats, both load-bearing:**

1. **This is the MENU, not a world.** In-world there is far more geometry, so
   the fixed term will be larger and the *relative* win smaller. The per-pixel
   term is real either way, but the size of the win is unconfirmed.
2. **Scale quality.** The panel is 640×480 and the blit is nearest-neighbour, so
   only **320×240 (clean 2×)** and **160×120 (clean 4×)** resample cleanly.
   256×192 is 2.5× and 200×150 is 3.2× — both will shimmer, and 160×120 may well
   make the HUD unreadable. This is an owner call, not a benchmark call.

At 160×120 the fixed costs (11.2 app + 4.8 blit + ~15 ms `glFinish` floor) are
69% of the frame, so resolution is exhausted below roughly 200×150 — and at that
point the blit's 4.8 ms is 11% of the frame and *does* become worth attacking.

### Lead 1 — telnet contamination was real, but `telnetd` was not the culprit

`tools/mm.ps1` closed plink's stdin to signal end-of-input. That half-closes the
TCP connection, and busybox `telnetd` then spins in `select()` on a permanently
readable socket. Three 20-second idle windows on the same otherwise-idle machine,
measured as **deltas** (the old 1422-tick figure looks like a cumulative
since-boot read):

| condition | telnetd CPU / 20 s | system idle ticks / 20 s (of 4000) |
| --- | ---: | ---: |
| `mm.ps1` session, stdin closed | **1987 = 99.3% of one core** | 1746 |
| session held open, stdin never closed | **<1 tick** | 3500 |
| no telnet session at all | — | 3515 |

So an open telnet session costs nothing; a *half-closed* one costs half the
machine. **Fixed in `tools/mm.ps1`** — stdin is left open and the trailing `exit`
ends the session. Verified after the change: `telnetd` no longer appears in the
profile at all and idle matches the no-session case.

Consequence for the archive: any measurement taken while a **long-running**
`mm.ps1` call was in flight lost ~50% of the machine. Short detached launches
(`setsid … &`, which return in seconds) were never affected. This remains the
best candidate for the documented 5.17-vs-7.22 spread.

### Two things about the benchmark itself that the next person needs

**The game does NOT auto-enter a world.** Launched unattended and left 120 s, it
sits on the main menu — screenshotted, not inferred. `bench.sh` waits for a
world-entry marker, so **every in-world run needs a human to press Play**. Budget
for that, or add a scripted-input source to the client (the injected input in
`inject_miyoo_input.py` already has a `(code,value)` queue fed by a reader
thread; a second producer replaying a timed file would make runs unattended and
identical, and would remove operator behaviour as a variance source).

**The "1 stall per run, universal across every version" claim is probably an
artifact — worth checking before anyone hunts the stall again.** In
`bench-1.2.20.2-1.log` the frame counter goes 90 at t=499 and 120 at t=535: a
36-second gap immediately after the `IP_MULTICAST_TTL` marker. That is the world
*loading*. `bench.sh` measures a trailing 180 s window (`last - 180` = 520 here),
which catches the tail of that gap. Every version and every run loads a world
exactly once, which is exactly how often the "stall" appears. Not confirmed —
but if it holds, the open question "why do the stalls happen" partly dissolves,
and the fix is to start the window after world load rather than trailing the end.

### It is genuinely fill-bound, and the parallelism is already maxed out

`App/mcpe/thread-probe.sh`, steady-state menu, 320×240, per-thread CPU over a
20 s window plus the `FBEGL_STATS` figures:

| `LP_NUM_THREADS` | llvmpipe workers | main thread | glFinish | fps |
| --- | --- | ---: | ---: | ---: |
| 1 | 83.9% (one worker) | 15.2% | **105.8 ms** | 8.01 |
| auto (2) | 72.5% + 69.6% = **142%** | 24.3% | **55.0 ms** | 13.76 |
| 4 | 42.1 + 34.2 + 33.3 + 32.5 = **142%** | 24.4% | **54.9 ms** | 13.80 |

- **Real fragment work, not driver overhead.** 1→2 workers cuts `glFinish` by
  **1.92×** — near-linear. Overhead does not parallelise like that, so the
  resolution correlation in the sweep above is causal.
- **Two cores is the ceiling.** Four workers burn exactly the same total CPU as
  two (142% either way) for an identical `glFinish`. `LP_NUM_THREADS=auto` is
  already right — do not touch it, and do not re-run this A/B.
- The workers are saturated *during* `glFinish` and idle outside it: the duty
  cycle predicts 152% average, measured 142%.
- Total game CPU is ~167% of the 200% available.

So pixel count is the only lever that reaches the 79%. That is the same
conclusion the resolution sweep reached, arrived at independently.

### Dead levers — measured, do not retry these

Four arms in one script at 320×240, with a repeat of the baseline last as a
drift control (`App/mcpe/opts-ab.sh`):

| arm | `gfx_multithreaded_renderer` | `gfx_msaa` | app+submit | glFinish | total | fps |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| A baseline | 1 | 1 | 11.6 | 54.8 | 72.4 | 13.81 |
| B | **0** | 1 | 11.5 | 54.7 | 72.2 | **13.86** |
| C | 1 | **4** | **25.2** | 56.1 | 87.2 | **11.47** |
| D baseline repeat | 1 | 1 | 11.7 | 54.2 | 71.8 | 13.93 |

A vs D differ by **0.9%**, so the drift control holds and anything under ~1.2% is
noise.

- **`gfx_multithreaded_renderer:0` changes nothing** — 13.86 against a 13.87
  baseline mean. The value provably applied (checked in `options.txt` before and
  after every arm). The "a game render thread contends with llvmpipe's two
  workers" theory is dead.
- **`gfx_msaa` is already at its floor.** Raising it to 4 costs 20%, so the
  setting *is* honoured — but 1 means one sample, i.e. no multisampling, and
  there is nothing below it. `0` untested; there is no reason to expect anything
  beneath one sample.

**The useful finding here is where MSAA's cost landed.** Not in `glFinish`
(+1.3 ms, near noise) but in **app+submit, 11.6 → 25.2 ms**. That window is
"everything that is not us" — nominally game simulation plus GL submission — and
multisampling cannot affect game logic. So **llvmpipe is doing its triangle setup
and binning on the calling thread**, and more samples makes that setup dearer.

Consequence worth acting on: the baseline 11.6 ms of app+submit is **not** mostly
simulation, it is substantially driver work proportional to submitted geometry.
That makes draw-call and geometry reduction a real lever on a term previously
written off as fixed — and it is the first thing that points at the ~15 ms fixed
floor in the `glFinish` model.

### A cheap new way to measure: screen at the main menu

The menu is a fixed, self-animating scene, it needs no operator, and its
`glFinish` figure sits in a tight band (59–80 ms across 38 reports) — far better
signal than the in-world benchmark's ±1.5 fps. Every table above was produced
this way, unattended, one variable at a time.

**It is a screen, not a verdict.** Anything that wins at the menu still has to be
confirmed in a world before it goes in the docs as a speedup.

**Within a session it is extremely tight; across sessions it is not.** Both
halves measured, three identical 320×240 arms back to back
(`App/mcpe/rebaseline-320.sh`):

| run | glFinish | readpx | blit | total | fps |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 54.6 | 0.90 | 4.91 | 72.2 | 13.86 |
| 2 | 54.5 | 0.99 | 4.91 | 72.0 | 13.88 |
| 3 | 55.3 | 1.00 | 4.89 | 72.9 | 13.71 |

**A 1.2% spread with no drift trend over ~7 minutes.** For comparison the
in-world benchmark is ±1.5 fps on a 5.5 mean, i.e. ±27% — the menu screen is
roughly twenty times the signal, which is what makes unattended A/B screening
practical at all.

Across sessions it still moves: the resolution sweep read **68.6 ms / 11.58 fps**
at 320×240 where this reads **~55 ms / 13.8 fps**. Both were taken with the UI
processes dead, so the smbd bug is *not* the explanation, and the cause is
**unknown** — boot-to-boot state of some kind, bounded at roughly 20–25%. Do not
invent a mechanism for it; just obey the rule.

**The rule: every arm of a comparison goes in one run of one script.** The 1.2%
figure is what licenses the sweep table above — its four arms ran back to back
inside a single ~10-minute script, and drift across a comparable window is ~1%,
so the *ratios* there are sound even though the absolute numbers do not
reproduce.

### THE 82 ms IS COMPUTE, NOT SWAP — and the frame is fully serialised

In-world, 320×240, 120 s window (`App/mcpe/majflt2.sh`):

```
main thread          5771 ticks   48.1% of one core   <= MAIN
llvmpipe-1           5210 ticks   43.4%
llvmpipe-0           5064 ticks   42.2%
process minflt +2326   majflt +183       VmSwap 107496 kB
stats: app+submit 80.8  glFinish 64.4  blit 5.00  total 151.2 ms = 6.61 fps
PREDICTED main-thread CPU if app+submit is pure compute: 57.4%
```

**Verdict: compute.** Main thread measured 48.1% against a 57.4% compute
prediction — 84% of it. `majflt` is 183 in 120 s (1.5/s); even at a generous
10 ms per fault that is ~1.5% of wall time, about 2 ms of the ~14 ms/frame gap.
**Swap is not the bottleneck**, despite 107 MB of `VmSwap`. The 82 ms is the main
thread doing vertex processing and llvmpipe scene binning, which llvmpipe runs
**single-threaded on the calling thread** — which is also why the MSAA arm made
setup dearer without touching `glFinish`.

The calibration held: at the menu, main-thread CPU was 24.3% against 24.1%
predicted (101% — pure compute). In-world it is 84%, so a little genuine blocking
exists, but not enough to matter.

**A reproducibility note that corrects an earlier caution:** this run matched the
previous session's arm 3 to within **0.15%** (80.8 vs 80.6, 64.4 vs 64.4, 6.61 vs
6.62 fps) *across a reboot*. The in-world "touch nothing" protocol is extremely
repeatable. It was the MENU metric that drifted 25% between sessions, not
in-world measurement.

### THE BIG ONE: the frame is serialised across two half-idle resources

From the same numbers:

- `glFinish` is 64.4/151.2 = **42.6% of the frame**. Two workers busy for that
  fraction predicts 85.2% total; measured 43.4 + 42.2 = **85.6%**. The workers
  are saturated during `glFinish` and **idle the rest of the frame**.
- Main-thread work is (80.8 + 5.0 + 0.97 + 0.06)/151.2 = **57.4% of the frame**,
  and happens entirely **outside** `glFinish`.

**The two phases use disjoint resources and run strictly one after the other.**
The main thread computes while both rasterizer threads idle; then it blocks while
they rasterize. A perfectly pipelined frame would cost `max(86.8, 64.4) ≈ 87 ms`
instead of 151 — **≈11.5 fps, +74%**. That dwarfs the +21% from resolution.

**What serialises it is our own present path.** `glReadPixels` is a synchronous
readback, so every frame ends in a full pipeline drain. llvmpipe can normally
keep several scenes in flight and build the next while rasterizing the previous;
we prevent it, every frame.

**The fix is the PBO item previously ranked LAST and priced at ~4%.** That
estimate was wrong because it costed the readback (1 ms) instead of the barrier
the readback creates (up to 64 ms of lost overlap). Use a GLES3
`GL_PIXEL_PACK_BUFFER` async readback and present the PREVIOUS frame.

Confidence, stated plainly: **the resource split is measured; the +74% is a
projection from it.** Overlap is never perfect, llvmpipe's scene queue may bound
it, and it costs one frame of display latency. But even half of it beats
everything else on the board, and confirmation is cheap — once the two phases
overlap, `app+submit` and `glFinish` will stop summing to the frame time in the
existing `FBEGL_STATS` line.

### REFUTED: async PBO present buys nothing (2026-08-18)

Implemented and measured. **It does not work, and the reason is worth keeping.**

Clean A/B at the menu, both arms one script, fresh boot:

| arm | app+submit | total | fps | frames in run |
| --- | ---: | ---: | ---: | ---: |
| sync | 11.8 | 72.5 | 13.80 | 1140 |
| PBO  | 11.7 | 72.5 | 13.80 | 1140 |

Identical down to the frame count, with the async path confirmed active
(`[fbegl] async PBO present ENABLED`). Overlap should have been worth ~16% here.

**Why, from the stage split the PBO path prints:**

```
app+submit 11.7 | readpx-issue 55.8 | map 0.1 | blit 4.9 | total 72.5
```

`readpx-issue` is the call that was supposed to queue the readback and return
immediately. It takes **55.8 ms** -- exactly what `glFinish` costs on the
synchronous path (54.8 ms). `map` is **0.1 ms**, so the data has been ready
for ages by the time we consume it.

**`glReadPixels` into a pixel-pack buffer is NOT asynchronous on Mesa llvmpipe.**
It blocks for the full rasterization whatever the destination. That is the
correct behaviour for a software rasterizer: async PBO readback exists to
overlap a **GPU DMA transfer**, and there is no DMA engine here to defer to. The
PBO changes where the pixels land, not when the work happens.

**What was wrong with the +74% projection:** the resource-idleness measurement
behind it was sound -- main thread and rasterizer threads really are busy in
alternation. The error was attributing the serialization to a readback that was
synchronous *by choice*, when it is synchronous *by construction*. The
opportunity is real; this mechanism cannot reach it.

Not re-tested in-world on purpose: the failure is in the mechanism, not in the
size of the prize, so `readpx-issue` will block for rasterization in a world
exactly as it does at the menu. That is an inference, not a measurement.

**The code is kept, opt-in and OFF by default** (`FBEGL_PBO=1`). It costs
nothing when unset, it is the only way to re-check this if a future Mesa changes
the behaviour, and its stage split is what diagnosed the failure.

**If anyone attacks the overlap again**, the remaining idea is to
`glCopyTexImage2D` at swap N (a queued GL copy, no drain) and read that texture
at swap N+1, giving the rasterizer a whole frame to catch up. That defers the
drain rather than trying to make it asynchronous. Unproven, and it depends on
llvmpipe letting the app thread run ahead into a second scene.
### 160x120 IS FASTER BUT UNSHIPPABLE - the GUI overflows the panel (2026-08-18)

Set as the default, screenshotted, and **reverted the same session.** The +21%
is real; the picture is not acceptable.

Minecraft sizes its GUI relative to the framebuffer, so halving the render size
**doubles the GUI's share of the screen**. At 160x120 the main menu overflows:
`Sign In` clips to `n In`, the skin button clips to `2`, and Settings and
Store are pushed off the panel entirely. Blockiness was the expected cost;
unreachable buttons were not, and no benchmark could have shown it.

**`gfx_guiscale_offset` cannot rescue it.** The in-game debug overlay already
reads `Gui:1.00` at 320x240 -- the scale is at its floor -- so the offset is
saturated. Verified rather than assumed: offsets of **-3, -4 and -6 all render
identically to -2** at 160x120 (captured from /dev/fb0 for each).

So the resolution lever, despite being the only measured win of the session, is
**spent**. The choices are 320x240 (clean 2x, current default) or 160x120 (clean
4x, +21%, broken UI), and nothing in between is both faster and cleanly scaled:
256x192 (2.5x) and 200x150 (3.2x) shimmer under nearest-neighbour AND measure
slower than 160x120.

**If anyone wants the +21% back**, the UI is the thing to attack, not the
renderer -- e.g. rendering the GUI pass at panel resolution while the world
renders at 160x120. That is a real change to the present path (two render
targets at different sizes), not a config knob, and it is unexplored.
### The GUI-fit floor is 208x156, not 320x240 (2026-08-18)

160x120 breaks the menu, but 320x240 was never the real constraint. Captured
/dev/fb0 at seven surface sizes and read the menu off the pictures:

| surface | pixels | menu fps | GUI verdict |
| --- | ---: | ---: | --- |
| 320x240 | 76,800 | 13.8 | full margins (current default) |
| 288x216 | 62,208 | 15.7 | fits |
| 256x192 | 49,152 | 16.7 | fits |
| 224x168 | 37,632 | 19.1 | fits, tight |
| **208x156** | **32,448** | **20.4** | **FLOOR - bottom row still complete** |
| 192x144 | 27,648 | 21.7 | Settings/Store half cut off |
| 160x120 | 19,200 | 22.2 | Settings/Store gone entirely |

Extrapolating in-world from the measured `glFinish ~= 30 ms + 0.48 ms/1000 px`,
208x156 predicts **~7.5 fps, about +16%** on the 6.49 baseline -- most of
160x120's +21% with a menu you can actually use.

**Two caveats before anyone ships it.** 640/208 = 3.08x, so it is NON-INTEGER
scaling and will shimmer in motion under nearest-neighbour; a static screenshot
cannot show that. And the menu is a **proxy** for the in-world HUD -- the hotbar
may have its own threshold, so an in-world check is required, not optional.

**Why the config route is exhausted:** `mcpelauncher-client --help` offers only
`-ww`/`-wh`, and 1.2 predates Bedrock's render-scale setting entirely
(`grep -iE 'scale|resolution|render' options.txt` finds only dpad, guiscale and
VR knobs). Nothing in the engine or launcher decouples world resolution from GUI
resolution.

**Doing it properly** needs a wrapper `libGLESv2.so.2` -- the same
first-on-LD_LIBRARY_PATH trick as our libEGL -- that redirects world draws into a
small FBO, detects the world->GUI pass boundary, upscales the FBO into the real
framebuffer, then lets GUI draws land at full size. That means a blit shader,
complete GLES2 state save/restore around it, and a heuristic for the pass
boundary (depth-test disable / ortho switch) that will be fragile. Unstarted.
### The shortcut now has a RESOLUTION PICKER (2026-08-18)

`App/MinecraftBedrock12/launch.sh` opens Onion's own `prompt` dialog before
launching, so the frame-rate/clarity trade is chosen per session instead of
being baked in. Four options, last choice remembered in `App/mcpe/res-choice.txt`
and preselected; **B backs out without launching**.

`prompt` returns the chosen index as its EXIT CODE (255 = cancel) and needs
`LD_PRELOAD=libpadsp.so` like every Onion UI binary. Callers to copy from:
`.tmp_update/script/m3u_gen.sh` and `transfer_mgba_save.sh`.

The labels state fps, and mark which numbers are measured (320x240, 160x120) and
which are estimated from the `30 ms + 0.48 ms/1000 px` fit (256x192, 208x156).
160x120 is offered WITH a warning rather than hidden -- it is genuinely the
fastest and fine for exploring, it just loses Settings/Store off the edges.

**You cannot test `prompt` over telnet.** It renders through SDL's fbcon on an
active VT; over telnet it opens /dev/fb0 (it even pans it) but its pixels never
land there, so a framebuffer capture shows only stale MainUI content. Both a
detached run and an attached run were tried. The only faithful test is pressing
the shortcut, because the real path has MainUI **exited**, not merely stopped.

### REGRESSION FIXED: launch.sh must BLOCK until the game exits

Adding the picker brought back the "Onion keyboard opens when I press X" bug.
Same mechanism docs/13 records for MCPI, confirmed live here:

```
game=3593                            <- game running
MainUI 845 state=S ppid=780          <- ALIVE, not stopped, child of runtime.sh
event0 held by: keymon (1057), mcpelauncher-cl (3593)
```

Onion exits MainUI to run an app and **its supervisor relaunches MainUI the
moment launch.sh returns**. Backgrounding the game and exiting therefore brings
MainUI up *behind* the running game: keymon still owns `event0` and feeds
Onion, so X pops Onion's search keyboard over the game -- and MainUI burns ~6.5%
of a core repainting underneath, which is a performance bug as well as an input
one. **One root cause, both symptoms.**

The picker did not create this. `launch.sh` has always returned early; it was
surviving on a race, because `launch-mcpe.sh` samples `pidof MainUI` a few
seconds in and usually caught the relaunched instance in time to SIGSTOP it.
Inserting the dialog shifted the timing and the race started losing.

Fix: **run `launch-mcpe.sh` in the foreground.** Onion cannot relaunch MainUI
while launch.sh is still running, so the race is removed rather than re-tuned.
A 2-second watchdog also SIGSTOPs any MainUI that appears anyway and **counts
them**, so the belt-and-braces reports whether it was needed instead of hiding
the fact that blocking alone was insufficient.

Each run now appends one self-diagnosing line to `run12.log`:

```
[session] 160x120  412s  2730 frames  avg 6.62 fps (whole session, includes load)  MainUI-stops=0
```

`MainUI-stops` should be **0**; nonzero means the race is live again. The fps
figure is a whole-session average including the ~60 s of load and menu, so it is
pessimistic by design -- compare it against itself across sessions, never against
the in-world numbers above. It costs nothing in the render path (no
`FBEGL_STATS`, no extra GL calls); it is just the existing frame counter
divided by wall time.
### Still open, in the order worth trying

**Both leading candidates are now closed.** Async PBO is refuted, and the +21%
from 160x120 is unshippable because its UI overflows. There is currently **no
banked, shippable win** — 320x240 remains the default at ~6.5 fps in-world.

1. **Render the GUI at panel resolution over a low-res world.** The only route
   left to the +21%, since 160x120 is fast but its UI overflows (see above).
   Two render targets at different sizes in the present path. Unexplored, and a
   real change rather than a knob.
2. **Reduce submitted geometry.** Now known to be main-thread vertex + binning
   work. `gfx_viewdistance` is floored at 80 (5 chunks) for this whole era, so
   the obvious knob is already exhausted; anything here needs a real idea.
3. **Overdraw / fragment cost** explains the ~0.48 ms per 1000 px, but that is
   only ~37 ms of a 157 ms frame at 320x240 and ~9 ms at 160x120. Lowest
   priority, and both obvious options.txt knobs are dead (see "Dead levers").

Why 1.2 and not the faster build: 1.1.5 PE benchmarks 7.58 FPS vs 1.2's 5.52, but
1.1.5 **predates gamepad support entirely** (feeding it `onGamepad*` corrupts the
heap), so it is touch-only. The owner has ruled that out as a dealbreaker. 1.2 is
the earliest version with real controller support, so 1.2 is the one to optimize.
Do not re-litigate this.

**MCPI Reborn is CLOSED** — it works end to end and runs at 0.9 FPS, ~8x slower
than Bedrock. Do not reopen it. The section below records why, and its X11 stack
is reusable for other things.

### Device state at end of 2026-08-17 session

**Powered off / off the network — see the power-cycle note at the top.**

Changes left on the device, all reversible with one `cp`:

| path | change | restore with |
| --- | --- | --- |
| `App/mcpe/egl-wrap/libEGL.so.1` | instrumented build (`FBEGL_STATS`) | `cp libEGL.so.1.known-good libEGL.so.1` |
| `App/mcpe/launch-mcpe.sh` | `runtime.sh` OOM protection | `cp launch-mcpe.sh.known-good launch-mcpe.sh` |

The instrumented shim is behaviour-identical when `FBEGL_STATS` is unset, so it
is safe to leave installed for normal play.

New files on the device: `App/mcpe/res-sweep.sh` (+ `res-sweep-results.txt`,
`sweep-*.log`) and `App/mcpe/thread-probe.sh` — **staged but never run**, see
"Still open" above. MCPI logs remain under `App/mcpi/logs/`.

### Tooling you inherit

| tool | what it is |
| --- | --- |
| `tools/mm.ps1` | run a command/script on the device over telnet — `pwsh tools/mm.ps1 -File x.sh` |
| `tools/serve.js` | static server; the device `wget`s from it (`node tools/serve.js . 8098`) |
| `App/mcpe/bench.sh` | 3-run Bedrock FPS benchmark, already `setsid`s the game |
| `mcpi-reborn/bench-mcpi.sh` | MCPI benchmark that drives menus over XTEST (MCPI only) |

### The four leads — all worked, verdicts above

Superseded by "The four leads are DONE" above. The original text is kept under
"Bedrock 1.2 optimization" at the bottom for the reasoning that motivated them.

### `runtime.sh` OOM protection — DONE (owner approved 2026-08-17)

`protect_ui()` is ported: `launch-mcpe.sh` now pins `runtime.sh` alongside
`MainUI`/`keymon`/`batmon` at `oom_score_adj=-1000`, and **warns per process if
`pidof` finds nothing** rather than leaving a silent protection gap. Deployed and
syntax-checked on the device (`launch-mcpe.sh.known-good` is the previous copy).

Note it uses `pidof runtime.sh`, which does match on this busybox — verified
returning the supervisor's PID. The warning line is the regression detector if
that ever stops being true.

**Postscript: this fixed nothing, and that is the interesting part.** The
supervisor was dying to a SIGTERM from smbd, not to the OOM killer, and
`oom_score_adj` is irrelevant to an explicit signal (see "SOLVED" above). Keep it
— it costs nothing and does cover real OOM — but the value delivered here was the
**warning line**, which is what exposed the real bug on the very next run. When a
theory is cheap to act on, still make the action self-reporting.

### Read this before touching anything

"Traps", "Measure properly or don't bother", and "Measurement hygiene" below are
not padding — each entry cost real hours. In particular: single benchmark runs
mislead badly on this device, and two version "winners" were crowned and
retracted on the strength of them.

## TOWARD A PUBLIC RELEASE (2026-08-18)

### Google sign-in on the MM+: the on-device flow CANNOT be ported

The RG34XXSP port's "Google sign-in" is the **APK downloader**, not Xbox Live
(its `ANNOUNCEMENT.md` says plainly: no Xbox Live / Marketplace sign-in). It
signs into the Google account that OWNS Minecraft and pulls the split APKs,
which is the mechanism that makes a public release lawful -- no game files ship.

**Blocked on this device, from that port's own docs:** *"An ARM32 choice on the
RG34XXSP downloads a set for transfer to an armhf target; it does not turn the
ARM64-only on-device browser into an armhf application."* It renders Google's
real sign-in page in a browser runtime that adds **~700 MB** and is **ARM64
only**. The MM+ is armhf with **128 MB of RAM** and **no Python at all**
(checked: it has `unzip`, `curl`, `openssl`, `wget`, nothing else).

**But it is already solved for MM+ users.** `mcbedrock_get.py` already offers
`armeabi-v7a` and already lists `1.2.20.2` and `1.6.0.30` -- line 69 of it
even reads *"Last 1.2 - oldest modern-launcher target tried (armhf; no-GPU
MM+)"*. The user signs in on a PC exactly as an R36S user does. The gap was
never the sign-in; it was that nothing on the MM+ side received the APK.

### DONE: on-device APK installer

`App/mcpe/install-apk.sh` turns a user-supplied APK into `App/mcpe/game1220`.
`App/MinecraftBedrock12/launch.sh` runs it automatically when no game is
present and refuses to launch if it returns non-zero.

- Looks in `App/mcpe/apk/` and the card root; lets the user pick if several.
- Verifies from the zip listing only (fast): `lib/armeabi-v7a/libminecraftpe.so`
  present, `assets/` present. An arm64 APK gets a specific "this is 64-bit,
  re-run mcbedrock-get and choose armeabi-v7a" message rather than a generic
  failure.
- Checks free space (needs ~500 MB) before starting.
- Extracts to `.game1220-staging` and only then moves it into place, so an
  interrupted install cannot leave a half-built directory that the
  already-installed check would accept.
- Applies first-run graphics defaults ONCE (marker `.first-run-tuned`), so a
  new world does not open at a render distance this hardware cannot carry.
- Every path is overridable by env (`MCPE_ROOT`/`MCPE_GAMEDIR`/`MCPE_APKDIR`/
  `MCPE_PROMPT`/`MCPE_EXTRA_APK_DIR`) purely so it can be tested against
  scratch directories. **Production passes nothing.**

**Tested on-device, all five paths**, against fake APKs built for the purpose,
with the real `game1220` verified untouched afterwards: no APK -> exit 1 with
guidance; arm64 APK -> exit 1 wrong-ABI; non-Minecraft APK -> exit 1; valid
armhf -> exit 0, correct tree, all 10 tuned options written; already installed
-> exit 0 immediately. A sixth run confirmed a versioned filename yields
`version: 1.2.20.2`.

**Do not try to read the version out of `libminecraftpe.so`.** Measured on the
real 1.2.20.2 library: both an anchored and an unanchored `strings | grep` over
all 48 MB returned **nothing** -- the version lives in the binary
AndroidManifest, which busybox cannot parse. The first draft did exactly this and
it could only ever print "unknown" while costing a full decompress-and-scan per
install. It now reads the version from the FILE NAME and says so.


### Onion dependency audit -- the port no longer needs OnionOS's libraries

Tested on Onion **v4.4.0-beta-20260120-07505ea5** (a BETA; most users will be on
a stable build, so this is narrower than it looks).

All ten external paths the scripts reference exist: `prompt`, `parasyte`,
`samba`, `libpadsp.so`, `MainUI`, `keymon`, `batmon`, `runtime.sh`,
`/config/lib`, `/usr/bin/unzip`.

**The dangerous dependency was `.tmp_update/lib/parasyte`**, an OnionOS
component whose contents can differ between builds. Found the true minimum
empirically -- start with only our own directories plus base `/lib`, run, stage
whatever the loader names, repeat:

```
needs libatomic.so.1   <- parasyte      needs libexpat.so.1  <- parasyte
needs libz.so.1        <- parasyte      needs libdrm.so.2    <- parasyte
needs libpng16.so.16   <- parasyte
then, only once it actually RENDERED:
needs libtinfo.so.6    <- samba
```

**A loader-only check was not enough.** The first five let the client start, and
it still produced zero frames: Mesa `dlopen`s `swrast_dri.so` at runtime, so
ITS dependencies never appear in the client's NEEDED list and only surface when
something draws. docs/13 already recorded that libtinfo is dragged in by
statically-linked LLVM; the run test rediscovered it the honest way.

With all six added the game reaches `Renderer: llvmpipe (LLVM 7.0.1, 128 bits)`
and presents frames **with no OnionOS library directory on the path at all** --
no parasyte, no samba, no `/config/lib`.

They are now gathered by `client/Dockerfile` from **Debian Buster armhf**, not
copied off a device, so provenance is clean for publication. That matters and is
not the same artifact: Debian's `libatomic` is 21,892 bytes against Onion's
29,908, `libdrm` 42,732 against 75,420. **The Debian-built set was verified
separately on the device** (staged in its own directory, working `lib/`
untouched): no missing libraries, llvmpipe, frames presenting.

Still Onion-dependent, and unavoidably so: `prompt` (the picker and installer
UI), `libpadsp.so` (required to run any Onion UI binary), `runtime.sh` /
`MainUI` / `keymon` / `batmon` (the platform itself), and `/usr/bin/unzip`.
### FRESH-CARD INSTALL TEST DONE -- and it found a real bug (2026-08-18)

A spare card became available. Onion **v4.3.1-1 STABLE** (the device had only ever
run v4.4.0-beta), installed from scratch, port installed by following the README
literally: extract the archive at the SD root, drop an APK in `App/mcpe/apk/`.

**All five Onion dependencies exist on 4.3.1-1 too** -- `prompt`, `parasyte`,
`samba`, `libpadsp.so`, `unzip`. FAT32 mounts everything `rwxrwxrwx`, so
no execute-bit problem. The install worked end to end: dialog, ~95 s extraction
(the dialog promises "about 2 minutes"), resolution picker, game running.

**THE BUG IT FOUND: the launcher's own menu bar covered the game.**
mcpelauncher draws a "File / Mods / View / Video" bar across the top unless told
otherwise, and it defaults ON. It is unusable here anyway -- this port has no
pointer -- so it is pure obstruction. Fixed by writing, on every install:

```
enable_menubar=false
enable_imgui=false
```

to `<HOME>/.local/share/mcpelauncher/mcpelauncher-client-settings.txt` (the path
the launcher logs at startup) and an app-dir mirror.

**Why every previous test missed it, which is the lesson.** The development card
happened to carry that settings file from some earlier session, so the bar was
invisible in every screenshot and every benchmark on that device -- including the
two framebuffer captures used to judge GUI overflow. **A setting that exists only
on the developer's machine is not a setting, it is a coincidence.** No amount of
dependency analysis would have caught this: the file is not a dependency, it is
state. Only a genuinely fresh install could surface it.

Released as **v0.1.1-testing**; v0.1.0-testing must not be published.
### OVERCLOCK WORKS: +18.5% measured -- and sysfs lies about it

**CORRECTION.** An earlier version of this section said "there is NO overclock to
enable". That was WRONG, and the way it was wrong is the useful part: it trusted
what the driver reported instead of measuring work done.

What sysfs claims, and why it is not evidence:

```
scaling_available_frequencies : 400 600 800 1000 1100 1200 MHz
OPP table (debugfs + DT)      : ends at 1200 MHz @ 1.00 V, all "available Y", no turbo
write >1200000 to scaling_max_freq -> clamped back to 1200000
after cpuclock 1500         : scaling_cur_freq AND cpuinfo_cur_freq still read 1200000
```

Every reading says 1200 MHz. **The hardware is not at 1200 MHz.** Timing a fixed
integer workload (three runs each):

```
performance (1200)       5.63 / 5.63 / 5.66 s
cpuclock 1500            4.48 / 4.49 / 4.52 s     -> 25.3% faster  => ~1504 MHz
setspeed 1500000 direct  4.54 / 4.46 / 4.52 s     -> same
control @ 600 MHz       11.74 / 11.76 / 11.85 s   -> 2.09x slower, exactly as expected
```

The 600 MHz control is what makes this airtight: the benchmark tracks clock
faithfully, so the 1500 MHz speedup is real and the Mstar cpufreq driver simply
does not report frequencies above its own table.

**Actual clocks achieved** (derived from a timed workload, since sysfs will not
tell you) -- every request landed within ~1%, and 1800 survived a 60 s stress:

| requested | measured | temp |
| ---: | ---: | --- |
| 1500 | ~1500 MHz | 74 C |
| 1600 | ~1606 MHz | 74 C |
| 1700 | ~1719 / ~1714 MHz (measured twice) | 75 C |
| 1800 | ~1817 MHz | 75 C |

**In frame rate** (menu, 160x120, all arms one script, baseline repeated last):

| clock | app+submit | glFinish | total | fps | vs stock | peak temp |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1200 (stock) | 11.2 | 23.2 | 39.5 | 25.34 | -- | 74 C |
| 1500 | 10.1 | 19.0 | 33.3 | 30.02 | +18% | 77 C |
| 1600 | 10.0 | 17.9 | 31.8 | 31.45 | **+24%** | 77 C |
| 1700 | -- | 16.9 | 30.2 | 33.06 | **+29%** | 78 C |
| **1800** | 9.5 | **16.5** | 29.5 | **33.92** | **+33%** | 77 C |
| 1200 repeat | 11.2 | 22.8 | 39.2 | 25.52 | drift 0.7% | 74 C |

Two separate runs, each with its own baseline and drift control (0.24% and
0.71%), so these are real. **The game survived every arm** -- no crash, no lockup,
at any clock. Gains are sub-linear (1800 is +50% clock for +33% fps) because DRAM
does not scale with the CPU and the rasterizer is partly memory-bound. It is less than the 25% the
clock alone implies because DRAM does not scale with the CPU clock and the
rasterizer is partly memory-bound -- but both halves improved (`glFinish` -18%,
`app+submit` -10%).



**A contaminated run, kept as a warning.** The first attempt at 1700 interleaved
a CPU benchmark with the game arms and produced nonsense: a "1700" request timed
SLOWER than baseline (implying ~947 MHz), and the run's two identical 1200 MHz
baselines disagreed by 57% (16.41 vs 25.70 fps). Nothing was wrong with 1700 --
the device was simply hot and busy from the benchmark when the first arm started.
Re-measured on an idle machine with a baseline recheck between every step (all
within 0.9%), 1700 is a perfectly ordinary step at ~1715 MHz, reproducible twice.
**Never benchmark the clock and the game in the same script.**
**SHIPPED: the CPU speed picker.** `launch.sh` now shows a second dialog after
the resolution one -- 1200 / 1500 / 1600 / 1700 / 1800 MHz, defaulting to **stock**, with
the measured fps on each entry and the heat warning in the body. Choice is
remembered in `App/mcpe/clock-choice.txt` and recorded in the session line.

Two implementation details that are load-bearing:
- The clock is applied by a **delayed background call** (`sleep 12` then
  `cpuclock`), because `launch-mcpe.sh` switches to the `performance`
  governor during its freeram phase and would overwrite anything set earlier.
- **Nothing needs to undo it.** `launch-mcpe.sh`'s `cleanup()` restores the
  original governor, and switching away from `userspace` drops the clock back
  to the stock table. Verified: governor `userspace` during the run,
  `ondemand` at 400 MHz after.
**How to apply it:** `/mnt/SDCARD/.tmp_update/bin/cpuclock <MHz>` (sets the
`userspace` governor and writes `scaling_setspeed`). It must be called
**AFTER** `launch-mcpe.sh` starts, because that sets the `performance`
governor and would overwrite it.

**Caveats that matter before shipping this:**
- **Heat.** The SoC has no `thermal_zone` but does expose
  `/sys/devices/virtual/mstar/msys/TEMP_R`. It idles at **68-72 C** and reached
  **77 C** at 1500 MHz. There is no throttling to save you.
- **No voltage control.** `/sys/class/regulator` does not exist, so this is an
  overclock at the stock 1.0 V rail.
- Community reports (OnionUI discussions, LiveLoveLinux's overclock app) put the
  MM+ at 1600-1800 MHz; Onion's own presets stop at 1500. Untested here.
- The port does **not** overclock by default, and should not without the owner
  opting in.
### KNOWN ISSUE: the build-info overlay cannot be turned off

The stat line across the top (`beta 1.2.20.2 Gui:1.00` / renderer, OS, FPS,
Mem) is **Minecraft's own** overlay, not the launcher's and not ours. Accepted as
a known issue on the owner's call.

Identified precisely -- the format string is in `libminecraftpe.so`:

```
%s, %s, %s, FPS:%4.1f, Mem:%4dMB, Highest Mem:%4dMB%s
options.dev_showBuildInfo   (stored as dev_showbuildinfo)
```

Two fixes tried and REFUTED, so do not repeat them:

1. `fps_hud_location=0` in the launcher settings -- wrong feature entirely.
   That is mcpelauncher's own FPS HUD, which is separate and was never the thing
   on screen. No change.
2. `dev_showbuildinfo:0` in `options.txt` -- correct key name, but **the game
   strips it on startup**. It reads the file, re-serialises it, and drops the
   line, so the option is not persisted from there in this build.

Remaining untried ideas, in rough order of plausibility: it may be inherent to
this being a **beta** APK (the version string literally reads `beta 1.2.20.2`
and the title art says "Beta!!!"), so a retail build of another version may not
show it; otherwise a dev console, a launcher flag, or a mod hook via
`mcpelauncher --mods`.
### CORRECTED: normal-world in-world numbers (2026-08-18)

The superflat benchmark world was NOT the big distortion I feared. Re-measured in
an ordinary generated world, two loads, clock changed in-session so each load
gives three phases with its own drift control:

| resolution | 1200 MHz | 1800 MHz | 1200 again | drift |
| --- | ---: | ---: | ---: | ---: |
| 320x240 | 5.98 | 8.57 | 6.20 | 3.6% |
| 160x120 | 7.43 | 10.20 | 7.41 | 0.3% |

`MainUI-stops 0` in every phase. Details: at 320x240 app+submit 92.9 /
glFinish 68.1; at 160x120 app+submit 89.9 / glFinish 39.6.

**Superflat vs normal is only ~6%:**

| | superflat | normal |
| --- | ---: | ---: |
| 320x240 stock | 6.49 | 6.09 |
| 160x120 stock | 7.87 | 7.42 |

And 160x120 @ 1800 measured **10.20** against a projected 10.5, so the overclock
projection was sound.

**The real gap is MOVEMENT, not world type.** The owner's live session at
256x192 @ 1800 ran at **5.0 fps**; standing still at that setting interpolates to
~9.3. Their app+submit was 109 ms against 68 ms here. Walking forces chunk load
and mesh building onto the main thread and **costs roughly another 45%**.

Updated model (normal world, standing still):
`glFinish ~= 31 ms + 0.46 ms/1000 px`, `app+submit ~= 90 ms` at stock.

README, preset labels and both custom menus now carry these figures plus the
"walking costs ~45%" caveat.

**Two method notes worth keeping:**

- The **"never settled" warning fired on both arms and was wrong to worry about**.
  The criterion (5 consecutive reports within 12%) cannot be met in a normal
  world -- clouds, mobs and daylight keep frame time moving. The drift control is
  the real validity test, and both arms passed it. Do not tighten the settle
  criterion; trust the repeated baseline instead.
- The first attempt at this measurement produced 2.77 / 8.57 / 6.19 fps and its
  own drift control exposed it as junk (baseline disagreeing with itself by 2x).
  Causes: MainUI alive behind the game (a direct `launch-mcpe.sh` launch has no
  MainUI watchdog -- only the app shortcut does), and a 45 s settle tuned on
  superflat while a normal world was still generating chunks at app+submit
  259 ms. **A single-arm run would have reported 2.77 fps and been believed.**
### DEVICE AUDIT: nothing in the background, and a number that does not match

Measured on a live play session (the owner's own, not a benchmark), 30 s deltas.

**Background load is nil.** Everything except the game totals **0.5% of one
core**: disp0_P0_MAIN 0.2%, a kworker 0.2%, batmon 0.1%. MainUI is stopped,
smbd/filebrowser are killed at launch, telnetd/dropbear/bftpd/wpa_supplicant are
idle. **There is nothing left to reclaim -- stop looking here.**

**Not paging either.** Over 30 s: game majflt **+9**, system pgmajfault **+0**.
The scary-looking 52,400 cumulative majflt is world-loading, not steady state.
122 MB sits in swap untouched. The earlier "not paging" conclusion holds for real
play, not just for benchmarks.

**The machine is only 72% busy** (idle 1613 of 5797 ticks over 2 cores). The
missing 28% is the serialisation already documented: main thread computes while
both rasterizer threads idle, then blocks while they work. Same limit the async
PBO attempt failed to remove.

### THE BENCHMARK WORLD IS NOT A REAL WORLD - published figures are optimistic

The owner's session, 256x192 @ 1800 MHz, in a world they created:

    live fps over 30 s : 5.00
    threads            : main 54.7%  llvmpipe-0 38.1%  llvmpipe-1 38.3%  (+9.9%)
    implies            : app+submit ~109 ms/frame, glFinish ~76 ms/frame

The in-world model in this document predicts **~9.4 fps** for that configuration
(app+submit 82 ms, glFinish ~40 ms at 1800). Reality is **5.0**, with roughly
**double** the rasterizer work.

**Why: every in-world number here was measured in the SUPERFLAT, peaceful world
on the old dev card, standing still.** docs/13 records superflat being chosen
precisely because it removed movement stalls - which also removed most of the
geometry. An ordinary generated world has far more to draw.

So the resolution table and the overclock table are **valid for comparing
settings against each other** and **not valid as absolute promises**. The README
now says so explicitly rather than quietly.

**To fix properly:** re-run the in-world A/B in an ordinary generated world
(needs an operator). Until then do not quote absolute fps to users without the
caveat. Also worth noting a sustained session reached **82 C** at 1800 MHz,
above the 77-78 C the 90-second benchmark arms ever showed.

### /tmp is a 49 MB tmpfs and filling it silently bricks the shortcut

A leftover 50 MB file from a diagnostic filled /tmp; after that, pressing the app
entry did **nothing at all** - no error, no screen. launch.sh could not create
/tmp/mcpe12.running. It looks identical to the port being broken, and it cost a
wrong-headed hunt through a menu rewrite that was not at fault. The tell was
`sed: write error` in a trace.

launch.sh now checks for 2 MB free in /tmp before doing anything and shows a
dialog naming the problem. Both branches verified on device: 50,056 kB free
passes through; filled to 0 kB it blocks. **Never write large files to /tmp on
this device** - it is RAM, and it is small.
### DONE: release archive builds and is verified

`minecraft-bedrock/build-release.ps1` assembles
`release/minecraft-bedrock-miyoo-mini-plus-<version>.zip` (**14.1 MB**), which
extracts at the SD card root into `App/mcpe`, `App/glsmoke-llvm` and
`App/MinecraftBedrock12` plus `README.md`.

**It refuses to build if game content is present.** The safety check scans the
staged tree for `libminecraftpe.so`, `*.apk`, `options.txt`,
`client_payload.tar`, logs, captures and any `game*`/`home`/`assets`
directory, and throws rather than packaging. The dev device carries seven
extracted game directories and worlds; none of it may ship.

**The client is named explicitly, not chosen by date.** `client-quitfix` is the
build running on the device (md5 `abc9b26c8554…`); three `client-*` dirs share
the same file size, so picking by size or timestamp would eventually ship the
wrong binary.

**libOSMesa is excluded and must stay excluded.** The first archive was 43.6 MB
because copying the whole Mesa lib dir pulled in three 25.5 MB copies of it
(`.so`, `.so.8`, `.so.8.0.0`) -- ~76 MB of dead weight. The game never
touches OSMesa; it goes through EGL, GLESv2 and `swrast_dri`. Verified, not
assumed: the known-good install on the device has no OSMesa at all and
`strings` finds zero references in either the client or the EGL shim.
Excluding it took the archive from **43.6 MB to 14.1 MB**.

**Verified end to end**: fetched, extracted to a fresh directory, and run through
its own `launch-mcpe.sh` with `MCPE_MESA` pointed at the archive's own Mesa so
nothing from the working install was used. Result: android stubs staged from
`android-libs/`, no missing libraries, `Renderer: llvmpipe (LLVM 7.0.1, 128
bits)`, `surface 160x120`, frames presenting.

**A test that bypasses the entry point is not testing the product.** The first
attempt invoked `mcpelauncher-client` directly and died on `Failed to find data
file: lib/armeabi-v7a/libc.so`. That was the test's fault, not the archive's:
`launch-mcpe.sh` stages those Android stubs from `android-libs/` at startup,
so skipping the launcher skips the setup.

### Default resolution is now 160x120 (owner's call, 2026-08-18)

The picker defaults to 160x120 on a fresh install and the README recommends it:
it is the only setting reaching ~8 fps, which the owner judges the threshold of
playable. Its cost is unchanged and is stated on the entry and in the README --
Settings and Store fall off the screen edges at that size. What makes it
acceptable is that **the picker runs every launch**, so the documented workaround
is to play at 160x120 and relaunch at 320x240 when those menus are needed.
### Still needed before publishing

1. ~~Fresh-SD install test~~ -- DONE on Onion **v4.3.1-1 stable**, see above. It
   found the menu-bar bug that dependency analysis could not.
2. ~~Packaging must exclude all game content~~ -- DONE, enforced by the safety
   check in `build-release.ps1`, which fails the build rather than trusting the
   file list.
3. **Disclose the 512 MB swap file.** `launch-mcpe.sh` creates it silently on
   first run (~1 min). That is a large uninvited change to a stranger's card.
4. ~~README~~ -- DONE, `minecraft-bedrock/README.md`, shipped inside the archive.
5. **Decide whether the 1.1.5 touch shortcut ships at all** (it is faster but
   touch-only, and the owner ruled it out for play).
## Quick start

```sh
# Default: Pocket Edition 1.1.5 (fastest). Touch input + keyboard movement.
cd /mnt/SDCARD/App/mcpe
MCPE_INPUT=touch MCPE_MOVE=keys MCPE_CAM_SPEED=60 MCPE_GL=llvmpipe \
MCPE_FREERAM=1 MCPE_TIMEOUT=0 MCPE_W=320 MCPE_H=240 \
  setsid sh -c 'sh launch-mcpe.sh /mnt/SDCARD/App/mcpe/game115 > run.log 2>&1' </dev/null &

# Bedrock 1.2 / 1.6 (gamepad controls, full HUD). Needs gfx_hidegui:0.
MCPE_GL=llvmpipe MCPE_FREERAM=1 MCPE_TIMEOUT=0 MCPE_W=320 MCPE_H=240 \
  setsid sh -c 'sh launch-mcpe.sh /mnt/SDCARD/App/mcpe/game1600 > run.log 2>&1' </dev/null &
```

Recover a stuck run: `kill -9 $(pidof mcpelauncher-client)` — the launcher's trap
restores the UI. If the screen stays dead, `reboot` over telnet.

---

## Measured performance (3 runs each, controlled workload, 2026-08-16)

320×240, llvmpipe, 5-chunk render distance, **operator standing still**, 180 s
windows, via `App/mcpe/bench.sh`.

| version | mean FPS | range | stalls/run | VmSwap | library |
| --- | ---: | --- | ---: | ---: | ---: |
| **1.1.5 PE** | **7.58** | 5.93–8.45 | 1 | ~100 MB | 36 MB |
| 1.6.0.30 | 5.57 | 4.56–6.32 | 1 | 114–117 MB | 52 MB |
| 1.2.20.2 | 5.52 | 4.84–6.15 | 1–2 | 103–107 MB | 49 MB |
| 1.16.221.01 | 4.1–5.5 | (single run) | 6.6–10.5 % of intervals | 210 MB | 87 MB |

- **1.1.5 is genuinely ~37 % faster.** Two of its three runs beat *every* run of
  1.2/1.6. Mechanism: smallest engine, least swap.
- **1.2 and 1.6 are indistinguishable** (means 0.05 apart, ~1.5 spread).
- **Stalls are universal** — every build, every run, ~1 interval under 2 FPS with
  a 0.9–1.1 floor. 1.16 differs in *degree*, not kind.

### Measure properly or don't bother

Single runs mislead badly here. The same build, same settings, measured twice by
hand gave **5.17 and 7.22**. Every conclusion that survived triplicate testing
came from a **controlled A/B** (one variable changed); every conclusion that died
came from comparing single runs across sessions — including two version
"winners" I crowned and had to retract.

```sh
sh bench.sh <gamedir> <tag> 3     # launches, waits for world entry, measures, repeats
cat bench-results.txt
```

`bench.sh` waits for a **world-entry marker** in the log. Markers differ per
version — `Player connected|IP_MULTICAST_TTL|port: 19132` covers 1.2/1.6/1.16/1.1.5.
**Verify the marker against a real log of that version before running**; assuming
one version's marker generalises cost three 15-minute timeouts.

---

## Controls

### Bedrock 1.2 / 1.6 (gamepad mode, default)

The MM+ has no second stick, so the **face diamond IS the right stick**:

| Input | Action |
| --- | --- |
| D-pad | move |
| X / B / Y / A | look up / down / left / right |
| hold R2 | face buttons revert to real A/B/X/Y (modifier, not a mode) |
| L1 | use / place block |
| R1 | attack / break block |
| SELECT / START | hotbar left / right |
| L2 | pause menu |
| **hold MENU 2 s** | **quit** |

### Pocket Edition 1.1.5 (touch mode)

| Input | Action |
| --- | --- |
| D-pad | move — W/A/S/D keys, **diagonals work** |
| X / B / Y / A | look (synthetic drag) |
| L1 / R1 | jump / mine-place |
| L2 | toggle virtual cursor (menus, inventory) |
| **hold MENU 2 s** | **quit** |

**Camera acceleration** is what makes digital buttons usable as a stick: a tap
nudges at MIN, holding ramps to MAX over RAMP seconds. Full deflection on press
is unaimable at these frame rates.

```
MCPE_LOOK_MIN=0.16  MCPE_LOOK_MAX=0.70  MCPE_LOOK_RAMP=0.9    # confirmed good
MCPE_CAM_SPEED=60   MCPE_PAD_X/Y/R      MCPE_CURSOR_MIN/MAX   MCPE_QUIT_HOLD=2
```

The ramp is re-evaluated **every `pollEvents`**, not only on key events — that
per-frame call is what makes it accelerate at all.
Source: `<PORT_REPO>/build/clients/inject_miyoo_input.py`.

**Quit is a HELD button, never a chord.** The original `MENU+SELECT` check ran
after every event and fired the instant both flags were true, so one stale flag
turned every SELECT press into an instant quit — and SELECT is the hotbar button.
It killed two live sessions. A duration requirement cannot be tripped by a
latched flag plus a tap. It also logs `[input] MENU held 2.0s -> quitting`, so an
unexplained exit can be attributed instead of guessed at.

---

## The working stack (`/mnt/SDCARD/App/`)

- `mcpe/mcpelauncher-client` — glibc-2.28 Buster build, **two source patches**:
  miyoo input (event0 → gamepad/touch/keys) + ipv4only (libc-shim AF_INET6→AF_INET,
  fixes the RakNet SIGSEGV — this kernel has no IPv6).
- `mcpe/egl-wrap/libEGL.so.1` (+`librealEGL.so`) — wrapper EGL that blits each
  frame to `/dev/fb0` (SDL `dlsym`s `eglSwapBuffers`, bypassing LD_PRELOAD).
  Also draws the touch-mode cursor from `/tmp/mcpe_cursor`. `client/src/fbegl.c`.
- `glsmoke-llvm/lib` — Mesa 20.3.5 **llvmpipe** (LLVM 7 JIT, both A7 cores).
  `swrast_dri.so` is 20.4 MB because LLVM is statically linked — no 50 MB
  `libLLVM.so` to ship. Contains softpipe too; pick with `MCPE_GL=`.
- `glsmoke/lib` — original softpipe-only Mesa, kept for A/B.
- `mcpe/game115` (1.1.5 PE), `game1220`, `game1600`, `game1900`, `game1114`,
  `game1121`, `game221` — all installed, all runnable.
- `mcpe/launch-mcpe.sh` — free-RAM, DNS-neuter, offscreen SDL, UI protection,
  watchdog, trap-restore.
- `mcpe/bench.sh` — unattended 3-run benchmark harness.

---

## Traps (each of these cost real time)

**Device scripts must be pure ASCII.** Non-ASCII bytes do not survive the telnet
push -- an em-dash arrived on the device as `??"`, which closed a shell string
early and produced `syntax error: unexpected "("` twenty lines from the real
cause. It had been harmless for sessions because it only ever landed in comments.
Filter before staging: `iconv -f UTF-8 -t ASCII//TRANSLIT`, and always
`sh -n` the file on the device before running it.

**Do not detect world entry with a log marker.** `bench.sh` greps for
`IP_MULTICAST_TTL`; on 2026-08-17 that never appeared, the script waited its full
8-minute timeout and produced nothing, while 204 stats reports sat there showing
the menu. Detect from the FRAME SIGNATURE instead -- in-world `app+submit` is
~82 ms against the menu's ~11.5 ms, a 7x gap that no version difference can
disguise. `App/mcpe/majflt2.sh` has the working `inworld()` helper.

**A blank screen usually means the wrong framebuffer PAGE, not a dead game.**
See the double-buffering note; `fb_open()` now pans to page 0 and logs what it
found, so check the `fb:` line before believing the game failed to start.


**A frozen picture almost always means the game is already DEAD.** Nothing
redraws `/dev/fb0` after the client exits, so the last frame stays forever —
looking identical to a hang. This came up ~7 times: watchdog kills, the quit
combo, benchmark completion, real crashes. **Always check
`pidof mcpelauncher-client` before assuming a hang.** The device still pings and
telnets throughout.

**The power button is software-only.** `docs/04-input.md`: the power slider never
reaches `event0` — OnionOS handles it in userspace, in **keymon**. No keymon = no
working buttons at all, and there is **no hardware long-press fallback**. keymon
is supervised by `.tmp_update/runtime.sh`, which itself dies sometimes (tell by
`MainUI` reparented to PID 1 in `top`).

**MainUI needs runtime.sh's FULL env** (its lines 222–226), not just the library
path — `PATH`, `LD_LIBRARY_PATH`, **and `LD_PRELOAD=$miyoodir/lib/libpadsp.so`**
(the audio shim it is built to run under). Missing `LD_PRELOAD` made it die
instantly and silently. Inheriting *our* `LD_LIBRARY_PATH` is equally fatal: it
feeds the OnionOS front end our fbegl `libEGL`. `restore_mainui()` now sets the
full env, retries 3×, and **verifies with `pidof` before claiming success** — the
original bug was not the missing preload but *asserting success it never checked*.

**`options.txt` is SHARED by every version** (same `HOME`). A fresh version
inherits the previous one's tuning — 1.12's first run was accidentally at 16
chunks and looked no better than 1.16. `gfx_hidegui` must be pinned per launch
(1.1.5 wants `1`, everything else `0`). **Re-check `gfx_viewdistance` after every
version switch.**

**Render distance has a per-version floor you cannot edit past.** Write `64` and
the game clamps it back on load: 1.16 → **256 (16 chunks)**, but 1.2/1.6/1.11/1.12
→ **80 (5 chunks)**. That floor, not the version number, is what killed 1.16's
movement stalls. The in-game slider bottoms out at the same floor.

**Removing `vanilla/sounds` crashes the game** (SIGABRT). It hooks
`FMOD::System::init` and genuinely resolves those files, dummy SDL audio or not.

**Git-Bash mangles `/mnt/c/...` paths to `wsl`** — use PowerShell to call `wsl`.

---

## What actually worked (controlled A/Bs, all still standing)

1. **llvmpipe over softpipe** — ~1–2 → 5–7 FPS. Cross-compiling needs the
   *target's* `llvm-config`, an ARM binary on an x86 host: install
   `llvm-7-dev:armhf` and wrap it in `qemu-arm-static` (`cross-armhf-llvm.ini`).
2. **Present-blit rewrite — +33 % avg, peak 7.5 → 15.0.**
   `fb_blit_rgba_scaled` touches **all 307,200 panel pixels every frame
   regardless of MCPE_W/H**, so it was a fixed tax that low internal resolutions
   could not reduce — which is why 200×150 failed to beat 320×240. It did an
   integer divide *per pixel* plus **four byte stores into uncached mmap'd
   framebuffer memory**. Now: precomputed x/y tables + one aligned 32-bit store,
   180° rotation by walking the destination pointer backwards.
3. **Older engine** — 1.1.5 vs 1.16: 210 MB → 100 MB swap.
4. **Superflat + peaceful world** — removed most movement stalls.
5. **Touch input for 1.1.5** — see below.

### Pocket Edition 1.1.5 specifics

**1.1.5 predates gamepad support entirely.** Sending it `onGamepad*` corrupts the
heap — `free(): invalid next size (fast)` → SIGABRT after ~77 s. It idled 389 s
untouched and survives indefinitely once only touch/keys are sent.
`MCPE_INPUT=touch` never calls the gamepad API at all. *(The user diagnosed this
from behaviour before the logs confirmed it.)*

`MCPE_MOVE=keys` sends W/A/S/D + SPACE via `onKeyboard` — 1.1.5 accepts hardware
keyboard. This is what makes **diagonals** work and lets the on-screen d-pad be
hidden; with pad-touch movement the pad *is* the input device and `gfx_hidegui:1`
would break walking. Look is a synthetic drag on finger 1 while movement holds
finger 0 — `onTouch*` takes a finger id, so both are held at once. The drag
re-seeds on the **far side** of its box relative to travel; seeding mid-box halves
the travel and feels sporadic.

**`onKeyboard` is `(KeyCode, KeyAction)` in this pinned tree — no `mods`.**
Upstream master has three args. Check the pinned `MANIFEST_COMMIT`, not GitHub.

---

## Builds (PowerShell → wsl → docker)

```powershell
# Mesa llvmpipe (~10 min)
docker build -f smoke/Dockerfile.llvmpipe --target export --output out-llvmpipe .

# EGL shim only (~1 min, reuses smoke/out)
docker build -f client/Dockerfile --output type=local,dest=client/out .

# Patched client (~25 min, context = PORT repo)
docker build -f "<MM+>/client/Dockerfile.client-input" --target export `
  --output type=local,dest=<MM+>/client/out <PORT_REPO>
```

Injectors: `<PORT_REPO>/build/clients/inject_miyoo_input.py`, `inject_ipv4only.py`.
Validate the injected C++ **before** a 25-minute build:

```bash
python -c "import ast,re;src=open('inject_miyoo_input.py').read();ast.parse(src);
b=re.search(r'BLOCK = r\"\"\"(.*?)\"\"\"',src,re.S).group(1);
print(b.count('{'),b.count('}'),b.count('('),b.count(')'))"
```

APK downloader: `<PORT_REPO>/tools/mcbedrock-get` — now offers 1.2.20.2, 1.6.0.30,
1.9.0.5, 1.11.4.2, 1.12.1.1 alongside the 1.16/1.21 builds. **Version-code
encoding changes by era** (1.11/1.12 = `87…`, 1.13.0.16+ = `94…`, 1.16.221 = `95…`)
— always look codes up in `mcpelauncher-versiondb`, never derive by pattern. It
also accepts **monolithic pre-App-Bundle APKs** now (old versions ship one APK
with `lib/<abi>/` inside; the old code demanded a `config.<abi>.apk` split and
silently rejected every version below ~1.13).

---

## The device now has X11 + software OpenGL (2026-08-16)

Built while chasing MCPI Reborn, but **reusable for any X11 software** cross-built
for armhf/glibc 2.28. See [`../docs/13-…`](../docs/13-older-minecraft-versions-plan.md)
for the full build notes.

| piece | path | what it is |
| --- | --- | --- |
| X server | `App/xvfb/Xvfb` | Xvfb; renders to an mmap-able file via `-fbdir` |
| panel mirror | `App/xvfb/xvfbmirror` | blits that file to /dev/fb0 (5.6 KB, libc only) |
| software GL | `App/mesa-x11/lib` | Mesa 20.3.5, GLX + EGL + **GLES1** + GLES2, llvmpipe |
| GL test client | `App/mesa-x11/glestest` | draws a fixed-function ES1 triangle |

```sh
X=/mnt/SDCARD/App/xvfb; MESA=/mnt/SDCARD/App/mesa-x11
mkdir -p /tmp/xvfbdir        # tmpfs: RECREATE AFTER EVERY REBOOT
kill -STOP $(pidof MainUI)   # PAUSE, never kill — killing powers the device off
env LD_LIBRARY_PATH=$X/lib:/mnt/SDCARD/.tmp_update/lib/parasyte setsid \
  $X/Xvfb :0 -screen 0 640x480x24 -fbdir /tmp/xvfbdir -fp $X/fonts/misc &
setsid $X/xvfbmirror /tmp/xvfbdir/Xvfb_screen0 640 480 &
DISPLAY=:0 LIBGL_DRIVERS_PATH=$MESA/lib LIBGL_ALWAYS_SOFTWARE=1 \
  GALLIUM_DRIVER=llvmpipe $MESA/glestest 150     # -> OpenGL ES-CM 1.1, llvmpipe
kill -CONT $(pidof MainUI)   # always restore
```

Hard-won details, each cost a build or a session:
- **Xfbdev no longer exists** — removed from xorg-server years ago. Xvfb + our
  own mirror is the replacement. `--enable-xfbdev` is silently ignored.
- Screen spec is `WxHx`**depth** — `640x480x32` is invalid; use `x24`.
- **`--prefix` is compiled into the binary** (xkbcomp path). Must be the FINAL
  on-device path; `/opt/...` cannot exist on read-only squashfs.
- **Build your own xkbcomp** with `--with-xkb-config-root=<on-device path>`:
  X invokes it as `-R<dir>` and it then resolves includes against its
  COMPILED-IN root, which `XKB_CONFIG_ROOT` does not override.
- **FAT32 stores neither symlinks nor hardlinks** — `tar -h` converts symlinks to
  hardlinks, which also fail, and the *original* file is what gets lost. Always
  `tar --hard-dereference --dereference`.
- Mesa: `-Dglx=xlib` **cannot** build EGL ("EGL requires dri"); use
  `-Dglx=dri -Ddri3=disabled`, which falls back to **drisw** (XPutImage
  software path, no GPU or /dev/dri needed).
- `swrast_dri.so` needs **`libtinfo.so.6`** (static LLVM drags in terminfo) plus
  13 more libs, several under `/lib`, not `/usr/lib`.
- **Xvfb needs `--enable-glx`** or GLFW-based apps fail with
  "GLX: Failed to load GLX" even though client-side libGL is fine.
- Xvfb also needs `libbz2.so.1.0` (grab it from `/mnt/SDCARD/miyoo/lib`).
- Screenshot **while the client runs** — X repaints the root black on exit.

### MCPI Reborn: CLOSED — plays, but at 0.9 FPS. Not viable. (2026-08-16)

It runs, renders, takes input, and has a working Onion shortcut. It is also
**eight times slower than Bedrock 1.1.5 on the same device** and is parked.

| configuration | FPS |
| --- | ---: |
| 640x480, Short, animated textures + title panorama | 0.75 |
| **best: 320x240, Tiny, flags stripped, llvmpipe, 2 threads** | **0.9** |
| render distance `Far` | 0.5 |
| `LP_NUM_THREADS=0` | 0.4 |
| **softpipe** instead of llvmpipe | 0.1 |

Three hypotheses died in those A/Bs, and the disproofs are the useful part:
llvmpipe is **not** pathological (softpipe is 10x worse); the rasterizer threads
are **not** spinning (`LP=0` halves the frame rate, so they do real parallel
work); and culling **does** work (`Far` costs 45%, so `Tiny` is the floor).

**Why it loses to a heavier game:** Bedrock 1.1.5 hits 7.58 FPS at the same
320x240 through the same llvmpipe. The difference is the path — Bedrock is GLES2
with a handful of shaders presenting straight to `/dev/fb0`; MCPI is **desktop GL
1.x fixed-function** through GLX and an X server. Mesa implements fixed-function
by generating a shader per state combination and Minecraft changes state
constantly. Not fixable from outside the process.

Reusable regardless: the X11 stack (GLX + EGL + GLES 1.1/2.0 on llvmpipe, ~0.7%
CPU), `miyoo-x-input` (XTEST bridge with menu/world mode switching), and
`bench-mcpi.sh`, which drives the game's own menus over XTEST and reports FPS.

**Two open MCPI bugs**, if it is ever picked up again: selecting an *existing*
world does nothing (reproduced with a synthetic click inside the entry — `Create
new` is the only way in), and benchmark runs left 5 worlds in
`.minecraft-pi/games/com.mojang/minecraftWorlds`.

### Measurement hygiene — applies to BEDROCK benchmarks too

Learned the hard way on MCPI, and it invalidates measurements silently:

1. **`telnetd` burns ~0.7 of the 2 cores for the whole session** — measured 1422
   ticks per 20 s while the shell merely slept. Any benchmark taken with a telnet
   session open loses ~36% of the machine. `bench.sh` already `setsid`s the game
   so it survives a disconnect; **actually disconnect**, then reconnect and read
   `bench-results.txt`. This is a strong candidate for the documented
   same-config spread of **5.17 vs 7.22**.
2. **Shell loops over `/proc` are ruinous** — `for d in /proc/[0-9]*` with
   `cat`/`awk` per iteration forks hundreds of processes. One awk pass instead:
   `awk '{split(FILENAME,p,"/"); print p[3], $14+$15}' /proc/[0-9]*/stat`.
3. **Never benchmark one renderer while another game is running.** A `glestest`
   run gave 120 frames in 8 s purely because MCPI was eating 1.25 cores beside
   it; with the machine idle the same test did 600 frames in ~0.5 s.
4. **The panel is DOUBLE-BUFFERED** — `fbset` reports `640 480 640 960 32`, two
   pages, and MainUI pans between them. Anything that writes page 0 while the
   visible page is 1 renders perfectly into a page nobody can see, which is
   indistinguishable from a hang. Capture **both** pages when a freeze does not
   add up: `dd if=/dev/fb0 of=both.raw bs=2560 count=960`.

### Bedrock 1.2 optimization — where to look next

> **SUPERSEDED 2026-08-17.** All four candidates below were worked; see "The four
> leads are DONE" at the top for the verdicts and the numbers. Candidate 3 is
> dead (worth ~1%) and candidate 4 is answered (present is 7% of the frame, so by
> this section's own test "items 2–3 are not worth the effort"). Candidate 2
> flipped and is now the biggest live lever. Kept for the reasoning that
> motivated them.

1.2.20.2 sits at **5.52 mean FPS** (3 runs, 320x240). 1.1.5 is faster at 7.58 but
is **touch-only and therefore ruled out** — 1.2 is the first version with real
gamepad support, so it is the one worth optimizing.

The present path is `client/src/fbegl.c`, and every frame it does:

```c
glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, g_buf);   /* full flush + copy */
fb_blit_rgba_scaled(&g_fb, g_buf, w, h, 1);                   /* all 307,200 panel px */
```

Ranked candidates, cheapest first:

1. **Re-baseline with the telnet session closed** (see above). Before optimizing
   anything, find out what 1.2 actually does when the machine is not 36% busy
   serving the measurement.
2. **Re-test `MCPE_W/H` at 256x192 and 200x150.** The recorded conclusion that
   low internal resolution "failed to beat 320x240" was measured with the **old**
   per-pixel-divide blit, when the blit was a fixed tax that swamped the saving.
   `glReadPixels` cost *is* proportional to `MCPE_W x MCPE_H`, and the blit is now
   ~33% cheaper, so **that conclusion may have flipped and is worth redoing.**
3. **Ask GL for the format it actually has.** We request `GL_RGBA/UNSIGNED_BYTE`;
   if llvmpipe's internal layout is BGRA that is a per-pixel swizzle across
   76,800 pixels every frame. Query `GL_IMPLEMENTATION_COLOR_READ_FORMAT` /
   `_TYPE` and match it, letting the existing blit do the swizzle it already
   does for free.
4. **Instrument the present path before optimizing it** — time `glReadPixels`
   and `fb_blit_rgba_scaled` separately and log every N frames. If present is 10%
   of frame time, items 2–3 are not worth the effort; if it is 40%, they are the
   whole game. This is the Phase 0 that was never done for the present path.

### MCPI Reborn status: THE GAME RUNS — no input yet

`App/mcpi/minecraft-pi-reborn/launcher --version` works. No source build was
needed — the armhf **.deb** (not the AppImage, which is not standard squashfs)
plus a bundled **Debian Bookworm runtime** satisfies its GLIBC_2.34 /
GLIBCXX_3.4.29 requirement on this glibc-2.28 device.

- Put the bundled loader **inside** the app dir — MCPI derives its install path
  from the running executable.
- `patchelf --set-interpreter` **and `--force-rpath --set-rpath`** on all 143 ELF
  objects. Manually invoking the loader only fixes the first process; MCPI execs
  logger → bootstrap → game. patchelf writes DT_RUNPATH by default, which is not
  enough — the launcher still picked up `/lib/libc.so.6`.
**Launch it with `mcpi-reborn/run-mcpi.sh`** (deployed to `/mnt/SDCARD/App/mcpi/`):
`game` goes straight in, `start` opens the GUI launcher, `stop` tears the stack
down and resumes MainUI. Confirmed reaching `Running On llvmpipe (LLVM 7.0.1)`
with the title screen on the panel.

Five separate walls came down to get there — each one is written up with its
evidence in `docs/13-older-minecraft-versions-plan.md`. The load-bearing ones:

- **The LIEF interpreter problem.** MCPI LIEF-patches the 2013 binary at runtime
  and **sets PT_INTERP itself**, discarding our patchelf work. But it already
  supports a bundled loader — gated on `reborn_config.internal.use_prebuilt_armhf_toolchain`,
  a compile-time `const`. `mcpi-reborn/flip-toolchain-flag.sh` flips that one byte
  in `lib/native/libreborn-util.so`; put the Bookworm runtime in `lib/arm`, which
  is where `get_ld_path()` points the patched binary anyway.
- **`lib/native` and `lib/arm` are two different C++ ABIs of the same .so names.**
  Never put them on one RPATH — `libmods.so` picked the launcher's
  `_Z8home_getB5cxx11v` twin and died on `undefined symbol: _Z8home_getv`.
  `fix-rpath-split.sh` keeps the game side on `lib/arm` only.
- **"GLX: Failed to load GLX" is a lie.** It means `dlopen("libGL.so.1")` failed
  and GLFW threw the reason away. Run the loader by hand with `--list` to get the
  real message; here it was a missing `libXdamage.so.1` (`fetch-xlibs.sh`).
- **GLX needs runtime flags, not just `--enable-glx`:** `+extension GLX +iglx`
  plus `LIBGL_DRIVERS_PATH` **for the server process**, pointing at the lib dir
  itself (this Mesa puts `swrast_dri.so` in `lib/`, not `lib/dri`).
- **`bootstrap` treats an empty env var as missing** and aborts. `MCPI_SERVER_LIST`
  must be the real default `mcpi.thebrokenrail.com:19132|`; `MCPI_FEATURE_FLAGS`
  is the ~4 KB list in `mcpi-reborn/feature-flags.txt`.

**Input works, via XTEST.** `mcpi-reborn/src/miyoo-x-input.c` reads
`/dev/input/event0` and injects with `XTestFakeKeyEvent` /
`XTestFakeRelativeMotionEvent`. `inject_miyoo_input.py` does not transfer — it
calls mcpelauncher's `onGamepad*`/`onTouch*` entry points, which have no X
equivalent — but XTEST **is** compiled into this Xvfb (`strings Xvfb | grep
XTEST`), so no rebuild was needed. `/dev/uinput` would not have worked: vfb
creates only the virtual core devices and this build has `--disable-config-udev`,
so nothing would ever have opened the node.

- Keycodes were **decoded from the gpio_keys capability bitmask** in
  `/proc/bus/input/devices` (`KEY=1c1682 0 3000400 3014c002`) rather than assumed:
  words are printed high-index first, 32 bits each. It does match the usual Miyoo
  layout, but now that is verified rather than hoped.
- Name your button constants `MB_*`, not `BTN_*` — `linux/input.h` already owns
  `BTN_A`/`BTN_START`/`BTN_UP` for real gamepads and the collision is a build
  error.
- **No `EVIOCGRAB`.** Grabbing would cut Onion's daemons off from POWER, and a
  device with no working power button is a failure mode this port has already
  been through once.
- `libXtst.so.6`/`libXi.so.6` are not on the device (`build-x-input.sh` collects
  them); `libXext.so.6` lives in `xvfb/serverlib`, not `xvfb/lib`.

Onion app entry in `mcpi-reborn/app-MinecraftPi/` → `/mnt/SDCARD/App/MinecraftPi/`.
It blocks until the game exits and then tears the stack down, because Onion only
redraws its menu once `launch.sh` returns.

**MCPI reaches its title screen. Two menu-stage traps, both found by screenshotting
/dev/fb0 rather than reading logs** — do that first on this device:
- MCPI's first-run **welcome screen is mouse-only**, and it is the reason
  "controls do nothing": clicks work (X routes pointer events by position) while
  keys do not (they go to the focus window, which ignores them). Turn it off —
  `sed -i 's/Add Welcome Screen|//' feature-flags.txt`, a pipe-separated list of
  *enabled* flags.
- The game window is **840x480 on a 640x480 screen** with no WM to negotiate it,
  so 200 px are unreachable. `miyoo-x-input` now `XMoveResizeWindow`s it to the
  screen and logs both the discovery and the fix.

**"Nothing happens" had a second, independent cause: the panel is
double-buffered.** `fbset` reports `geometry 640 480 640 960 32`, and MainUI pans
between the two pages. `xvfbmirror` only ever writes page 0, so with MainUI
parked at yoffset 480 the game rendered into the invisible page and the panel
kept showing MainUI's last frame — identical, from the outside, to a game that
never started. One `FBIOPAN_DISPLAY` at mirror startup fixes it, and the daemon
now logs `yoffset 480->0` so it cannot fail silently again. Rebuild it only with
`build-xvfbmirror.sh` under `debian:buster-slim` — a modern cross-gcc links
GLIBC_2.34/2.38 against a 2.28 device.

**The input bridge's evdev fd must be `O_NONBLOCK`.** The drain loop is
`while (read(...) == sizeof ev)`, so a blocking fd parks in `read()` after the
last event and the tick loop — pointer motion, mode probe, MENU-hold — never runs
again. Holding a button freezes the code meant to react to it; anything sent
inline from the event still works, which is why the camera was silently dead for
sessions while the d-pad "worked". Keep the `evdev`/`pointer` tracing in
`App/mcpi/logs/input.log`: it distinguishes device-never-sent-it from
X-ignored-it from game-ignored-it, and that is what finally settled it.

**Onion prefixes every app launch with `LD_PRELOAD=<miyoo>/lib/libpadsp.so`.**
That SDL audio shim needs `libmi_common.so` from `/config/lib`, which
`run-mcpi.sh` replaces in `LD_LIBRARY_PATH`, so every child died before `main()`
with `Xvfb: error while loading shared libraries: libmi_common.so`. This is why
the app ran fine over telnet and did nothing from the tile. `run-mcpi.sh` now
does `unset LD_PRELOAD`. **Test the shortcut path by reproducing it exactly** —
`LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so sh launch.sh` — not by running
`launch.sh` bare, which hides the whole class of bug.

**No native controller support exists.** MCPI Reborn added *Minimal Controller
Support* in v2.4.6 and **removed it in v3.0.0**; MCPI++ is keyboard-only and
unsupported. The XTEST bridge is not a workaround for a missing mod — it is the
only path. `Tab` is the game's own Lock/Unlock Mouse toggle, and `1`–`9` pick
hotbar slots (currently unreachable).

**A shortcut that does nothing when pressed means `runtime.sh` is dead, not that
your `launch.sh` is broken.** MainUI writes `/tmp/cmd_to_run.sh` and *exits*; the
supervisor `.tmp_update/runtime.sh` is what actually executes it and relaunches
MainUI. Kill the supervisor and every app press is a silent no-op. Neither it nor
MainUI can be restarted by hand (`launch_main_ui` bind-mounts the MainUI binary
first) — `reboot` is the only way back. It dies to the OOM killer, and all four
UI processes ship at `oom_score_adj=0`; `launch-mcpe.sh` protected
`MainUI keymon batmon` but not the supervisor, whose loss is the unrecoverable
one. `run-mcpi.sh` now pins all four at `-1000` via `protect_ui()` and marks the
game `800`. See docs/13 for the verification table.

**Watch:** memory is at 100 MB of 103 MB with ~18 MB swap in use, before a world
is even loaded.

- MCPI **downloads Minecraft Pi 0.1.1 at first run** and sets its own
  LD_LIBRARY_PATH for children, which breaks Onion's `wget` (needs
  `.tmp_update/lib` for `libuclient.so`) and passes GNU-wget flags that Onion's
  uclient-fetch rejects. Fixed with a shim at `App/mcpi/bin/wget` that keeps only
  `-O`/URL and restores Onion's library path; put that dir first on `PATH`.

## Device access

- **Exec:** telnet, passwordless root, `192.168.1.40`. Sessions drop often under
  load — retry rather than assume failure.
- **Deploy:** PC serves HTTP (`node serve.js <dir> 8099`, PC = `192.168.1.17`),
  device `wget`s. Device has `/usr/bin/unzip`, so push APKs whole and extract
  in place (~90 s for 8k files on FAT32).
- **Screenshots:** `cat /dev/fb0 > /mnt/SDCARD/x.raw`; `httpd -p 8081 -h /mnt/SDCARD`;
  pull; `ffmpeg -f rawvideo -pixel_format bgra -video_size 640x480 -i x.raw -frames:v 1 -vf vflip,hflip x.png`.

---

## Open questions

- **Why the stalls happen is still unknown.** Swap correlates loosely but is
  demonstrably not the mechanism: 1.2 swaps *less* than 1.6 yet stalls slightly
  more, and 1.9 never stalled at 156 MB while 1.11 stalls at 148 MB. Finding the
  real cause is probably worth more than another version bisect, since a fix
  might apply to any build.
- **MCPI Reborn (Path C)** — the only untried lever that changes the *engine*
  rather than the version. Native ARM ELF, no Android linker, built for the
  original Raspberry Pi. Needs a Buster-container build (its AppImage wants
  glibc 2.36, device has 2.28) and Mesa with `-Dgles1=enabled`.
- **Below 1.1.5 is a dead end for this launcher.** 1.1.5 already produces 25
  missing JNI symbols (all Xbox Live / HttpClient / PlayIntegrity — harmless).
  The 2011 Xperia Play 0.1.x builds predate essentially the whole JNI surface.
- `gfx_hidegui:1` was deployed for 1.1.5 but **never visually confirmed**.
