#!/bin/sh
# OnionOS shortcut -> Minecraft Bedrock 1.2.20.2, software-rendered.
#
# Shows a RESOLUTION PICKER first (Onion's own `prompt` dialog), because the
# right trade between frame rate and clarity is a taste call, not a benchmark
# call, and it changes with what you are doing: building wants pixels, walking
# around wants frames.
#
# There is no GPU on the SSD202D. Every pixel is rasterized on two 1.2 GHz A7
# cores by llvmpipe. Measured in an ORDINARY generated world, standing still:
#     glFinish   ~= 31 ms fixed + 0.46 ms per 1000 pixels
#     app+submit ~= 90 ms, and does NOT shrink with resolution
# so frame rate tracks pixel count, but only down to a point -- which is why the
# gain flattens out at the bottom of the list. Walking costs roughly 45% on top
# of all of it, because loading and meshing chunks lands on the main thread.
# Full workings in ../HANDOFF.md.
#
# Sibling of the 1.1.5 shortcut. What differs, and why:
#
#   game1220 instead of game115  - 1.2.20.2 rather than Pocket Edition.
#   gamepad input (MCPE_INPUT unset) - 1.2 supports the gamepad API properly.
#                                  1.1.5 must use touch because feeding it
#                                  onGamepad* corrupts the heap; that does not
#                                  apply here, and gamepad gives the better
#                                  control scheme (L1 place / R1 mine).
#   gfx_hidegui:0                - options.txt is SHARED by every version, so it
#                                  has to be pinned per shortcut or 1.2 inherits
#                                  1.1.5's hidden HUD and you lose the hotbar.
touch /tmp/stay_awake 2>/dev/null
# The CPU governor is deliberately NOT touched here. launch-mcpe.sh owns it: it
# records the original, switches to performance, and restores it on exit. If
# this script set performance first, launch-mcpe.sh would record "performance"
# as the original and the restore would silently do nothing, leaving the device
# pinned at 1200 MHz until reboot.

MCPE=/mnt/SDCARD/App/mcpe
PROMPT=/mnt/SDCARD/.tmp_update/bin/prompt
PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so

# --- /tmp must have room -------------------------------------------------------
# /tmp is a 49 MB tmpfs. When it fills, this script cannot create its own flag
# files and the shortcut does NOTHING when pressed -- no error, no screen, just
# a return to the Apps list. That is indistinguishable from the port being
# broken, and it happened during development when a stray 50 MB download was
# left behind. Fail loudly instead: a reboot clears a tmpfs completely.
TMPFREE=$(df -k /tmp 2>/dev/null | tail -1 | awk '{print $4}')
case "$TMPFREE" in ''|*[!0-9]*) TMPFREE=99999 ;; esac
if [ "$TMPFREE" -lt 2048 ]; then
  if [ -x "$PROMPT" ]; then
    LD_PRELOAD=$PRELOAD "$PROMPT" -t "Cannot start - /tmp is full" \
      -m "Only ${TMPFREE} kB free in /tmp, and the game needs a\nlittle room there to start.\n\nRebooting the console clears it completely.\n\nIf it fills again straight away, something is writing\nlarge files to /tmp -- check for leftovers there." \
      "OK" >/dev/null 2>&1
  fi
  exit 0
fi

# --- first run: no game yet --------------------------------------------------
# NO Minecraft files ship with this port and none ever can. install-apk.sh turns
# a user-supplied APK (their own Google Play purchase, fetched with the PC
# helper) into App/mcpe/game1220, and explains how to get one if none is found.
# It returns non-zero when there is nothing to launch, and has already told the
# user why, so just stop.
if [ ! -f "$MCPE/game1220/lib/armeabi-v7a/libminecraftpe.so" ]; then
  sh "$MCPE/install-apk.sh" || exit 0
fi

OPT=$MCPE/home/.local/share/mcpelauncher/games/com.mojang/minecraftpe/options.txt
[ -f "$OPT" ] && sed -i 's/^gfx_hidegui:.*/gfx_hidegui:0/' "$OPT" 2>/dev/null

# --- settings ------------------------------------------------------------------
# One PRESET menu, with the detailed menus kept behind "Custom".
#
# `prompt` gives us title, message, preselection and a list -- no icons, no
# styling -- but it does render in the user's own Onion theme, which is why the
# port uses it rather than drawing its own screen: it looks like the rest of the
# system for free. So "better looking" here means fewer, clearer choices rather
# than more decoration. Two menus every launch, each needing a real decision
# about a trade the user cannot see yet, was the actual problem.
#
# Presets deliberately do NOT include an overclock in the default: pushing a
# stranger's console past stock without them choosing it is not ours to do. The
# overclocked presets sit one press away and say what they cost.
#
# Inserting a preset mid-list is safe ONLY because settings.txt stores the
# values, not the menu index. "Balanced" was added at position 3 and pushed the
# two below it down; with an index-based file that would have silently turned
# every saved "320x240 stock" into "256x192 @ 1800".
#
# "~9.2 fps" is interpolated, not measured: 320x240 and 160x120 were measured
# in-world at both clocks, and the resulting model
# (glFinish ~= 31 ms + 0.46 ms/1000 px, app+submit ~= 90 ms stock / 68 ms at
# 1800) predicted the measured 1800 MHz points to within 3%. The tilde marks
# the difference, as it does everywhere else in this port.
SET_FILE=$MCPE/settings.txt          # "W H MHZ" -- values, never menu indices
W=160; H=120; MHZ=1200               # fresh-install default: fast, no overclock
if [ -f "$SET_FILE" ]; then
  read sW sH sM < "$SET_FILE" 2>/dev/null
  case "$sW" in 320|256|208|160) W=$sW; H=$sH ;; esac
  case "$sM" in 1200|1500|1600|1700|1800) MHZ=$sM ;; esac
fi

if [ -x "$PROMPT" ]; then
  # Preselect whichever preset matches the saved settings, else Custom.
  PIDX=5
  case "${W}x${H}_${MHZ}" in
    160x120_1200) PIDX=0 ;;
    160x120_1700) PIDX=1 ;;
    160x120_1800) PIDX=2 ;;
    256x192_1800) PIDX=3 ;;
    320x240_1200) PIDX=4 ;;
  esac

  LD_PRELOAD=$PRELOAD "$PROMPT" \
    -t "Minecraft 1.2" \
    -m "Pick how the game should run.\n\nfps are measured in a normal world STANDING STILL.\nWalking loads chunks and costs roughly 45% more, so\nexpect around half these numbers while exploring.\n\nOverclocking makes the console hotter and there is no\nthermal protection -- see the README first.\n\nCustom lets you set resolution and CPU speed yourself." \
    -s "$PIDX" \
    "Recommended    160x120, stock      7.4 fps" \
    "Faster         160x120, 1700 MHz   9.9 fps" \
    "Fastest        160x120, 1800 MHz  10.2 fps" \
    "Balanced       256x192, 1800 MHz  ~9.2 fps" \
    "Best picture   320x240, stock      6.1 fps" \
    "Custom..."
  psel=$?
  case "$psel" in
    0) W=160; H=120; MHZ=1200 ;;
    1) W=160; H=120; MHZ=1700 ;;
    2) W=160; H=120; MHZ=1800 ;;
    3) W=256; H=192; MHZ=1800 ;;
    4) W=320; H=240; MHZ=1200 ;;
    5) CUSTOM=1 ;;
    255) exit 0 ;;
    *)  W=160; H=120; MHZ=1200 ;;
  esac
fi

# --- custom: the detailed menus ------------------------------------------------
if [ -x "$PROMPT" ] && [ "${CUSTOM:-0}" = 1 ]; then
  case "${W}x${H}" in
    320x240) LAST=0 ;; 256x192) LAST=1 ;; 208x156) LAST=2 ;; *) LAST=3 ;;
  esac
  # `prompt` returns the chosen index as its EXIT CODE (255 = B/cancel).
  # It needs Onion's audio shim preloaded, like every other Onion UI binary.
  LD_PRELOAD=$PRELOAD "$PROMPT" \
    -t "Minecraft 1.2 - Render Resolution" \
    -m "Lower resolution = higher frame rate, softer picture.\nThe game is upscaled to the 640x480 screen either way.\n\n160x120 is RECOMMENDED as the fastest setting that is\nstill usable. The catch is that Settings and Store fall\noff the screen edges at that size -- if you need them,\nquit and relaunch at 320x240. This menu appears every\nlaunch.\n\nfps are from a normal world STANDING STILL; walking\ncosts roughly 45% more. 320x240 and 160x120 were\nMEASURED, the middle two interpolated between them." \
    -s "$LAST" \
    "320x240  -  6.1 fps  -  sharpest, all menus fit" \
    "256x192  -  ~6.7 fps  -  slight shimmer" \
    "208x156  -  ~7.0 fps  -  shimmer, menus still fit" \
    "160x120  -  7.4 fps  -  RECOMMENDED (menus cut off)"
  sel=$?

  case "$sel" in
    0) W=320; H=240 ;;
    1) W=256; H=192 ;;
    2) W=208; H=156 ;;
    3) W=160; H=120 ;;
    255) exit 0 ;;                 # B pressed: back to the Onion menu
    *)  W=320; H=240 ;;            # anything unexpected: safest option, still launch
  esac

  # Overclocking is REAL here but invisible to sysfs: the Mstar cpufreq driver
  # keeps reporting 1200000 whatever you ask for. Verified by timing a fixed
  # workload -- requests land within ~1% (1500->1500, 1600->1606, 1700->1719,
  # 1800->1817 MHz). Do not "fix" this by trusting scaling_cur_freq.
  case "$MHZ" in
    1200) CIDX=0 ;; 1500) CIDX=1 ;; 1600) CIDX=2 ;; 1700) CIDX=3 ;; 1800) CIDX=4 ;;
    *) CIDX=0 ;;
  esac
  LD_PRELOAD=$PRELOAD "$PROMPT" \
    -t "Minecraft 1.2 - CPU Speed" \
    -m "Overclocking makes the game faster and the console\nhotter. There is NO thermal throttling on this device\nto protect it, and it already idles near 70 C.\n\nStock is safe. The faster settings are widely used by\nthe community but are not guaranteed for your unit --\nif the game crashes or the console locks up, pick a\nlower speed next launch.\n\nMeasured at 160x120: 1200=25.3, 1500=30.0, 1600=31.4,\n1700=33.1, 1800=33.9 fps. All were stable here and\npeaked at 78 C, but that is one console, not yours.\n1700 and 1800 differ by only 3%." \
    -s "$CIDX" \
    "1200 MHz  -  stock, coolest  (default)" \
    "1500 MHz  -  +18% fps" \
    "1600 MHz  -  +24% fps" \
    "1700 MHz  -  +29% fps" \
    "1800 MHz  -  +33% fps, hottest"
  csel=$?
  case "$csel" in
    0) MHZ=1200 ;;
    1) MHZ=1500 ;;
    2) MHZ=1600 ;;
    3) MHZ=1700 ;;
    4) MHZ=1800 ;;
    255) exit 0 ;;
    *)  MHZ=1200 ;;
  esac
fi

# Persist as VALUES, not menu positions: an index silently changes meaning when
# the list changes (adding 1700 would have turned every stored 1800 into 1700).
echo "$W $H $MHZ" > "$SET_FILE" 2>/dev/null

# --- run the game, BLOCKING ---------------------------------------------------
# This must NOT return while the game is alive.
#
# Onion exits MainUI to run an app and its supervisor relaunches it the moment
# launch.sh returns. If we background the game and exit, MainUI comes back up
# BEHIND it: keymon still owns /dev/input/event0 and feeds Onion, so pressing X
# pops Onion's on-screen search keyboard over the game, and MainUI burns ~6.5%
# of a core repainting underneath. Exactly the failure docs/13 records for MCPI.
#
# It used to survive on a race -- launch-mcpe.sh samples `pidof MainUI` a few
# seconds in and usually caught the relaunched instance in time to SIGSTOP it.
# Adding the picker changed the timing and the race started losing. Blocking
# removes the race instead of re-tuning it.
RUNNING=/tmp/mcpe12.running
STOPS=/tmp/mcpe12.stops
: > "$RUNNING"
echo 0 > "$STOPS"

# Belt and braces: this bug has now bitten twice, so also SIGSTOP any MainUI
# that appears anyway. Costs one pidof every 2 s and stops when the flag goes.
# It COUNTS what it had to stop, which is the point: a nonzero count in the
# session line below means blocking alone was not enough and the race is still
# live, rather than us assuming it is fixed because the symptom went away.
( n=0
  while [ -f "$RUNNING" ]; do
    for p in $(pidof MainUI 2>/dev/null); do
      st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
      if [ "$st" != T ]; then
        kill -STOP "$p" 2>/dev/null && { n=$((n + 1)); echo "$n" > "$STOPS"; }
      fi
    done
    sleep 2
  done ) >/dev/null 2>&1 &

# Apply the overclock a few seconds in. It cannot be set before launching:
# launch-mcpe.sh switches to the performance governor during its freeram phase,
# which would overwrite it. Nothing to undo here -- launch-mcpe.sh's cleanup
# restores the original governor, and that drops the clock back with it.
CPUCLOCK=/mnt/SDCARD/.tmp_update/bin/cpuclock
if [ "$MHZ" != 1200 ] && [ -x "$CPUCLOCK" ]; then
  ( sleep 12; "$CPUCLOCK" "$MHZ" ) >/dev/null 2>&1 &
fi

START=$(date +%s)
MCPE_CAM_SPEED=60 \
MCPE_GL=llvmpipe MCPE_FREERAM=1 MCPE_TIMEOUT=0 MCPE_W=$W MCPE_H=$H \
  sh "$MCPE/launch-mcpe.sh" "$MCPE/game1220" > "$MCPE/run12.log" 2>&1
END=$(date +%s)

rm -f "$RUNNING"
# Anything we paused must be resumed, or Onion comes back to a frozen menu.
for p in $(pidof MainUI 2>/dev/null); do kill -CONT "$p" 2>/dev/null; done

# One free line of self-diagnosis per session. The frame counter is already in
# the log; dividing by wall time costs nothing and needs no instrumentation in
# the render path, so normal play stays exactly as fast as the benchmarks say.
# It is a WHOLE-SESSION average and therefore pessimistic -- it includes the
# ~60 s of asset loading and menu before you reach a world -- so compare it
# against itself across sessions, never against the in-world figures in
# ../HANDOFF.md.
FRAMES=$(grep -a "presented frame" "$MCPE/run12.log" 2>/dev/null | tail -1 | sed 's/.*presented frame \([0-9]*\).*/\1/')
[ -z "$FRAMES" ] && FRAMES=0
ELAPSED=$((END - START))
AVG="n/a"
[ "$ELAPSED" -gt 0 ] && [ "$FRAMES" -gt 0 ] && \
  AVG=$(awk "BEGIN{printf \"%.2f\", $FRAMES / $ELAPSED}")
echo "[session] ${W}x${H}  ${MHZ}MHz  ${ELAPSED}s  ${FRAMES} frames  avg ${AVG} fps (whole session, includes load)  MainUI-stops=$(cat "$STOPS" 2>/dev/null)" \
  >> "$MCPE/run12.log"

exit 0
