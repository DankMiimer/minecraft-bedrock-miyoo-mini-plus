#!/bin/sh
# launch-mcpe.sh — run the prebuilt armhf mcpelauncher-client fully headless on
# the MM+: software Mesa (softpipe) for GLES, SDL offscreen, and the fbpresent
# shim copying each frame to /dev/fb0. Run as root over telnet with MainUI paused.
#
#   ./launch-mcpe.sh <extracted-apk-dir>
# where <extracted-apk-dir> contains  lib/armeabi-v7a/libminecraftpe.so  and  assets/
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# Which software Mesa to use. Default is the softpipe build; set
# MCPE_GL=llvmpipe to use the LLVM-JIT, both-cores build in glsmoke-llvm.
# MCPE_MESA overrides the directory outright.
case "${MCPE_GL:-softpipe}" in
  llvmpipe) MESA_DEFAULT=/mnt/SDCARD/App/glsmoke-llvm/lib; GALLIUM=llvmpipe ;;
  *)        MESA_DEFAULT=/mnt/SDCARD/App/glsmoke/lib;      GALLIUM=softpipe ;;
esac
MESA="${MCPE_MESA:-$MESA_DEFAULT}"
PARASYTE=/mnt/SDCARD/.tmp_update/lib/parasyte
SAMBA=/mnt/SDCARD/.tmp_update/lib/samba

GAMEDIR="${1:-}"
if [ -z "$GAMEDIR" ] || [ ! -f "$GAMEDIR/lib/armeabi-v7a/libminecraftpe.so" ]; then
  echo "usage: $0 <extracted-apk-dir>  (needs lib/armeabi-v7a/libminecraftpe.so + assets/)"
  exit 1
fi

export HOME="$HERE/home"
mkdir -p "$HOME/.local/share/mcpelauncher"

# --- Phase 1: free RAM (opt-in via MCPE_FREERAM=1) --------------------------
# The 128 MB device has no zram/zswap, so the only levers are killing idle
# services and giving the game more swap capacity so it pages instead of OOMing.
# Services return on reboot; the extra swap file persists (harmless).
if [ "${MCPE_FREERAM:-0}" = 1 ]; then
  echo "[freeram] killing idle services (smbd/filebrowser) + vm tuning"
  # -9 IS LOAD-BEARING. Do not "clean this up" back to a plain killall.
  #
  # Every userspace process on this device shares ONE process group (pgrp 582,
  # session 564): runtime.sh, MainUI, keymon, batmon, audioserver, filebrowser
  # AND smbd, because OnionOS starts Samba as `smbd --no-process-group -D` so it
  # never moves into a group of its own. Samba's SIGTERM shutdown path signals
  # its process group to reap children — which here is the OnionOS UI's group.
  #
  # So a plain `killall smbd` took out runtime.sh, keymon and batmon within 12
  # seconds, every time, on a completely idle machine. MainUI survived (it
  # ignores SIGTERM), which is why this looked for so long like an OOM kill of
  # the supervisor: MainUI reparented to PID 1 and no dmesg record. It was never
  # the OOM killer, and oom_score_adj cannot defend against an explicit SIGTERM.
  #
  # SIGKILL cannot be caught, so no shutdown handler runs and nothing gets
  # broadcast. Verified: `killall -9 -q smbd` removes all three smbd processes
  # and leaves all four UI processes alive at +12 s and +30 s.
  for svc in smbd smbd-notifyd smbd-cleanupd filebrowser; do
    killall -9 -q "$svc" 2>/dev/null
  done
  echo 100 > /proc/sys/vm/swappiness 2>/dev/null
  # The game allocates big at the loading->interactive transition; the default
  # heuristic overcommit can deny it (commit limit ~= RAM+swap) and crash. Allow
  # overcommit (lazily backed) and raise the mmap count for its many mappings.
  echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null
  echo 262144 > /proc/sys/vm/max_map_count 2>/dev/null
  # Pin BOTH A7 cores to max (ondemand otherwise drops freq during input waits).
  #
  # 1200 MHz is the hardware ceiling, not a tuning choice: the frequency table
  # stops there and writes above it are clamped by the driver, so `performance`
  # already extracts 100% of the available clock (verified holding 1200 MHz on
  # both cores across a 100 s run, with no thermal zone on this device at all).
  #
  # Remember what it was, because cleanup() has to put it back. Leaving the
  # governor pinned means the device idles at 1200 MHz after you quit, burning
  # battery until the next reboot.
  ORIG_GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$g" 2>/dev/null
  done
  echo "[freeram] governor performance (was ${ORIG_GOV:-unknown})"
  SWAPX=/mnt/SDCARD/mcpe-swap
  if ! grep -q "$SWAPX" /proc/swaps 2>/dev/null; then
    if [ ! -f "$SWAPX" ]; then
      echo "[freeram] creating 512 MB extra swap (one-time, ~1 min on SD)"
      dd if=/dev/zero of="$SWAPX" bs=1M count=512 2>/dev/null && mkswap "$SWAPX" 2>/dev/null
    fi
    swapon -p 10 "$SWAPX" 2>/dev/null && echo "[freeram] extra swap on"
  fi
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  echo "[freeram] free now:"; free | sed -n 2p
fi

# mcpelauncher's Android linker looks for the stub libs (libc.so/libm.so/
# libc++_shared.so) in lib/armeabi-v7a relative to the client binary AND in the
# game's own lib dir. Stage them from the shipped android-libs/ if missing.
mkdir -p "$HERE/lib/armeabi-v7a"
for so in libc.so libm.so libc++_shared.so; do
  [ -f "$HERE/lib/armeabi-v7a/$so" ] || cp "$HERE/android-libs/armeabi-v7a/$so" "$HERE/lib/armeabi-v7a/$so" 2>/dev/null
done
[ -f "$GAMEDIR/lib/armeabi-v7a/libc++_shared.so" ] || \
  cp "$HERE/android-libs/armeabi-v7a/libc++_shared.so" "$GAMEDIR/lib/armeabi-v7a/" 2>/dev/null

# Library search order. egl-wrap is FIRST so SDL's dlopen("libEGL.so.1") gets
# our presenting wrapper (which pulls in librealEGL.so = real Mesa EGL). Then
# mcpelauncher's Android stub libs + the game's own libs, our libs, Mesa, and
# Onion's bundled X11/ssl/png/z.
export LD_LIBRARY_PATH="$HERE/egl-wrap:$HERE/android-libs/armeabi-v7a:$GAMEDIR/lib/armeabi-v7a:$HERE/lib:$MESA:$PARASYTE:$SAMBA:${LD_LIBRARY_PATH:-}"

# Force software GLES (no GPU on this SoC). softpipe = single-threaded reference
# rasterizer; llvmpipe = LLVM-JIT'd shaders + rasterization split across both A7
# cores. Same swrast_dri.so carries both in the llvmpipe build.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER="$GALLIUM"
export LIBGL_DRIVERS_PATH="$MESA/dri"
export MESA_LOADER_DRIVER_OVERRIDE=swrast
# llvmpipe raster threads. 2 A7 cores -> 2; LP_NUM_THREADS=0 forces single-
# threaded (useful to isolate "JIT win" from "threading win" when A/B'ing).
[ -n "${LP_NUM_THREADS:-}" ] && export LP_NUM_THREADS
echo "[gl] driver=$GALLIUM mesa=$MESA threads=${LP_NUM_THREADS:-auto}"
if [ ! -f "$MESA/dri/swrast_dri.so" ]; then
  echo "[gl] ERROR: $MESA/dri/swrast_dri.so missing — is that Mesa deployed?"; exit 1
fi

# Two network subsystems crash on this minimal OnionOS: the config/telemetry
# HTTPS (no CA store -> SSL-verify failure crashes the cpprest thread), and
# RakNet/LAN socket init (segfaults if the default route is removed). Thread the
# needle: BREAK DNS so config/telemetry fail gracefully at name resolution, but
# KEEP the default route so RakNet is happy. resolv.conf restored on exit.
# RakNet::RakPeer::Startup segfaults in memset on a bad pointer while binding
# sockets; it binds IPv4 AND IPv6, and the IPv6/dual-stack path via the host
# libc-shim is the prime suspect. Force IPv4-only.
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null && echo "[net] IPv6 disabled"
echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null

RESOLV=/appconfigs/resolv.conf
if [ -f "$RESOLV" ]; then
  [ -f "$RESOLV.mcpe-bak" ] || cp "$RESOLV" "$RESOLV.mcpe-bak" 2>/dev/null
  printf 'nameserver 0.0.0.0\n' > "$RESOLV" 2>/dev/null && echo "[offline] DNS neutered, route intact"
fi

# Headless SDL. SDL3 reads SDL_VIDEO_DRIVER (SDL2 read SDL_VIDEODRIVER); set both.
# Our wrapper libEGL turns each eglSwapBuffers into a /dev/fb0 blit, so no preload.
export SDL_VIDEO_DRIVER=offscreen
export SDL_VIDEODRIVER=offscreen
export EGL_PLATFORM=surfaceless
# No usable audio device on this minimal setup; opening ALSA can segfault the
# game at startup. Force dummy audio (SDL3 uses SDL_AUDIO_DRIVER, SDL2 the old).
export SDL_AUDIO_DRIVER=dummy
export SDL_AUDIODRIVER=dummy

MU="$(pidof MainUI 2>/dev/null || true)"

# A SIGSTOPped MainUI is a fat, idle, unprotected OOM candidate: under swap
# pressure the kernel reaped it mid-run, so when the game exited there was
# nothing to SIGCONT — no UI, no keymon, and the Home/Power buttons went dead
# (recoverable only by telnet or a hard power-cycle). Make the UI processes
# effectively unkillable and the game the preferred victim instead.
# keymon is the ONLY thing that reads the power/menu buttons: per docs/04-input.md
# the power slider never reaches event0, it is handled in userspace by OnionOS.
# So if keymon is not running the buttons are simply DEAD — there is no hardware
# long-press fallback, and the only way out is telnet. keymon is supervised by
# .tmp_update/runtime.sh, which itself dies sometimes (MainUI then shows up
# reparented to PID 1), leaving nothing to restart it. Guarantee both daemons
# exist BEFORE we take over the screen, so the user always has an escape hatch.
SYSDIR=/mnt/SDCARD/.tmp_update
MIYOODIR=/mnt/SDCARD/miyoo

# Bring the OnionOS front end back, VERIFYING it actually came up.
#
# Earlier versions of this just fired ./MainUI and printed "relaunching", which
# reported success while MainUI died instantly — leaving the last game frame
# frozen on the panel and looking exactly like a hang. Two causes, both fixed:
#   1. It needs runtime.sh's FULL env (its lines 222-226), not just the library
#      path: PATH, LD_LIBRARY_PATH, and LD_PRELOAD=libpadsp.so (the audio shim
#      MainUI is built to run under). Missing LD_PRELOAD is why it kept dying.
#   2. Inheriting OUR LD_LIBRARY_PATH feeds it the fbegl libEGL and it exits.
# Never claim the UI is back without checking pidof.
restore_mainui() {
  if pidof MainUI >/dev/null 2>&1; then return 0; fi
  PRELOAD=""
  [ -f "$MIYOODIR/lib/libpadsp.so" ] && PRELOAD="$MIYOODIR/lib/libpadsp.so"
  attempt=1
  while [ "$attempt" -le 3 ]; do
    echo "[ui] starting MainUI (attempt $attempt/3)"
    ( cd "$MIYOODIR/app" 2>/dev/null && \
      PATH="$MIYOODIR/app:$PATH" \
      LD_LIBRARY_PATH="$MIYOODIR/lib:/config/lib:/lib" \
      LD_PRELOAD="$PRELOAD" \
        setsid ./MainUI >/dev/null 2>&1 & ) &
    waited=0
    while [ "$waited" -lt 6 ]; do
      sleep 1
      waited=$((waited + 1))
      if pidof MainUI >/dev/null 2>&1; then
        echo "[ui] MainUI is up (verified)"
        return 0
      fi
    done
    attempt=$((attempt + 1))
  done
  echo "[ui] WARNING: MainUI did not start after 3 attempts — recover with 'reboot'"
  return 1
}

ensure_ui_daemons() {
  for d in keymon batmon; do
    pidof "$d" >/dev/null 2>&1 && continue
    [ -x "$SYSDIR/bin/$d" ] || continue
    echo "[ui] $d was not running — starting it (power/menu buttons need it)"
    # MUST match runtime.sh's own LD_LIBRARY_PATH (its line 4). Our exported one
    # puts egl-wrap first, which would feed keymon/batmon our fake libEGL and
    # kill them instantly — that is exactly how a run used to leave the handheld
    # with no working buttons.
    ( cd "$SYSDIR" && LD_LIBRARY_PATH="/lib:/config/lib:$MIYOODIR/lib:$SYSDIR/lib:$SYSDIR/lib/parasyte" \
        setsid "$SYSDIR/bin/$d" >/dev/null 2>&1 & ) &
  done
  sleep 1
}
ensure_ui_daemons

# runtime.sh is the OnionOS SUPERVISOR and losing it is the unrecoverable
# failure. MainUI only writes /tmp/cmd_to_run.sh and exits; runtime.sh is what
# actually executes it and relaunches MainUI. Without it every app shortcut is a
# silent no-op and MainUI cannot be restarted by hand (launch_main_ui bind-mounts
# the binary first), so the only way back is a reboot. It was the one UI process
# NOT on this list and it was OOM-killed twice in one session while the other
# three sat safely at -1000. Warn loudly if any of them cannot be found rather
# than leaving a protection gap that only shows up as a dead handheld later.
for proc in runtime.sh MainUI keymon batmon; do
  found=0
  for p in $(pidof "$proc" 2>/dev/null); do
    found=1
    echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null && echo "[oom] protected $proc ($p)"
  done
  [ "$found" = 1 ] || echo "[oom] WARNING: $proc not running — NOT protected"
done

# Always restore the console on exit/interrupt: pausing MainUI + a swap-thrashing
# game with no wired input can otherwise strand the device. This trap kills the
# game and resumes the OnionOS UI no matter how the script ends.
cleanup() {
  [ -n "${CLIENT_PID:-}" ] && kill -9 "$CLIENT_PID" 2>/dev/null
  pkill -9 -f "$HERE/mcpelauncher-client" 2>/dev/null
  # Hand the CPU back. Without this the device idles at 1200 MHz until reboot,
  # which is a battery cost the user never asked for and cannot see.
  if [ -n "${ORIG_GOV:-}" ] && [ "${ORIG_GOV:-}" != performance ]; then
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo "$ORIG_GOV" > "$g" 2>/dev/null
    done
    echo "[freeram] governor restored to $ORIG_GOV"
  fi
  [ -n "$MU" ] && kill -CONT "$MU" 2>/dev/null
  # Belt and braces: if MainUI died anyway, relaunch it rather than leaving the
  # handheld with an unresponsive front end.
  sleep 1
  if ! pidof MainUI >/dev/null 2>&1; then
    echo "[ui] MainUI is gone — relaunching so the buttons work again"
    restore_mainui
  fi
  ensure_ui_daemons
  [ -f "${RESOLV:-/nonexistent}.mcpe-bak" ] && { cp "$RESOLV.mcpe-bak" "$RESOLV" 2>/dev/null; rm -f "$RESOLV.mcpe-bak"; }
}
trap cleanup INT TERM EXIT

[ -n "$MU" ] && { echo "pausing MainUI ($MU)"; kill -STOP "$MU" 2>/dev/null; }

# Optional internal render size: export MCPE_W / MCPE_H (e.g. 480x272) to trade
# resolution for software-raster FPS; default is the game's own choice (~720x480).
SZARGS=""
[ -n "${MCPE_W:-}" ] && [ -n "${MCPE_H:-}" ] && SZARGS="-ww ${MCPE_W} -wh ${MCPE_H}"

# Safety watchdog: auto-stop after MCPE_TIMEOUT seconds so the device recovers on
# its own (default 300; set MCPE_TIMEOUT=0 to run indefinitely and recover by
# telnet: kill -9 $(pidof mcpelauncher-client); kill -CONT $(pidof MainUI)).
TIMEOUT="${MCPE_TIMEOUT:-300}"

echo "== launching: mcpelauncher-client -dg $GAMEDIR $SZARGS  (watchdog ${TIMEOUT}s) =="
"$HERE/mcpelauncher-client" -dg "$GAMEDIR" $SZARGS 2>&1 &
CLIENT_PID=$!

# If something must die under memory pressure, it should be the game, not the
# device's UI. (Pairs with the oom_score_adj -1000 on MainUI/keymon above.)
echo 800 > "/proc/$CLIENT_PID/oom_score_adj" 2>/dev/null

if [ "$TIMEOUT" != 0 ]; then
  ( sleep "$TIMEOUT"
    kill -0 "$CLIENT_PID" 2>/dev/null && {
      echo "== watchdog: ${TIMEOUT}s elapsed, stopping game and restoring UI =="
      kill -9 "$CLIENT_PID" 2>/dev/null
    } ) &
  WD=$!
fi

wait "$CLIENT_PID"
RC=$?
[ -n "${WD:-}" ] && kill "$WD" 2>/dev/null
echo "== client exited rc=$RC =="

[ -n "$MU" ] && kill -CONT $MU 2>/dev/null
