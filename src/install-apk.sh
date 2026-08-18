#!/bin/sh
# install-apk.sh - first-run setup: turn a user-supplied Bedrock APK into a
# playable game directory under App/mcpe/.
#
# WHY THIS EXISTS: no Minecraft files ship with this port and none ever can.
# The user downloads their own APK from their own Google Play purchase with the
# PC helper (mcbedrock-get: pick "32-bit armeabi-v7a" and 1.2.20.2), drops it on
# the SD card, and this turns it into App/mcpe/game1220.
#
# Uses OnionOS's own `prompt` dialog, which returns the chosen index as its EXIT
# CODE (255 = B/cancel) and needs LD_PRELOAD=libpadsp.so like every Onion UI
# binary. Callers to copy from: .tmp_update/script/m3u_gen.sh.
#
# Exit: 0 = a game is installed and ready, 1 = nothing installed (caller must
# not try to launch).
set -u

# Overridable so the install paths can be exercised against scratch directories
# without risking a real installation. Production passes nothing.
MCPE=${MCPE_ROOT:-/mnt/SDCARD/App/mcpe}
GAMEDIR=${MCPE_GAMEDIR:-$MCPE/game1220}
APKDIR=${MCPE_APKDIR:-$MCPE/apk}
PROMPT=${MCPE_PROMPT:-/mnt/SDCARD/.tmp_update/bin/prompt}
EXTRA_APK_DIR=${MCPE_EXTRA_APK_DIR:-/mnt/SDCARD}
PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so
LOG=$MCPE/install-apk.log

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
say() {   # say <title> <message>   - one-button notice
  [ -x "$PROMPT" ] || { log "NOTICE: $2"; return 0; }
  LD_PRELOAD=$PRELOAD "$PROMPT" -t "$1" -m "$2" "OK" >/dev/null 2>&1
  return 0
}

: > "$LOG"
log "install-apk starting"
mkdir -p "$APKDIR" 2>/dev/null

# --- already installed? -------------------------------------------------------
if [ -f "$GAMEDIR/lib/armeabi-v7a/libminecraftpe.so" ] && [ -d "$GAMEDIR/assets" ]; then
  log "game already present at $GAMEDIR"
  exit 0
fi

# --- find candidate APKs ------------------------------------------------------
# Two locations: the documented drop folder, and the card root because that is
# where a file copied from a PC most often lands.
set --
for f in "$APKDIR"/*.apk "$APKDIR"/*.APK "$EXTRA_APK_DIR"/*.apk "$EXTRA_APK_DIR"/*.APK; do
  [ -f "$f" ] || continue
  set -- "$@" "$f"
done

if [ "$#" -eq 0 ]; then
  log "no APKs found"
  say "Minecraft is not installed yet" \
"No Minecraft APK was found.\n\nThis port ships NO game files. You supply your own\ncopy from your own Google Play purchase.\n\n1. On a PC, run the mcbedrock-get helper.\n2. Choose 32-bit armeabi-v7a, version 1.2.20.2.\n3. Copy the .apk onto this SD card, into:\n     App/mcpe/apk/\n   (the card root also works)\n4. Start Minecraft Bedrock 1.2 again.\n\nNeeds about 500 MB free on the card."
  exit 1
fi

# --- choose one ---------------------------------------------------------------
APK=$1
if [ "$#" -gt 1 ]; then
  # prompt takes a bounded list; show at most 8 and use basenames.
  n=0
  set -- "$@"
  args=""
  for f in "$@"; do
    n=$((n + 1)); [ "$n" -gt 8 ] && break
    args="$args \"$(basename "$f")\""
  done
  sel=$(eval "LD_PRELOAD=$PRELOAD \"$PROMPT\" -t 'Which APK?' -m 'Several APKs were found.\nChoose the Minecraft one to install.' $args >/dev/null 2>&1; echo \$?")
  [ "$sel" = 255 ] && { log "user cancelled APK choice"; exit 1; }
  n=0
  for f in "$@"; do
    [ "$n" = "$sel" ] && { APK=$f; break; }
    n=$((n + 1))
  done
fi
log "selected APK: $APK"

# --- verify -------------------------------------------------------------------
# An APK is a zip, so the listing alone answers both questions that matter:
# is this actually Minecraft, and is it the right ABI for this 32-bit device?
LIST=/tmp/apk-list.txt
if ! unzip -l "$APK" > "$LIST" 2>/dev/null; then
  log "unzip -l failed"
  say "That file is not readable" \
"$(basename "$APK")\n\ncould not be opened as an APK. It may have copied\nacross incompletely. Try copying it again."
  exit 1
fi

if ! grep -q "lib/armeabi-v7a/libminecraftpe.so" "$LIST"; then
  if grep -q "lib/arm64-v8a/" "$LIST"; then
    log "wrong ABI: arm64 APK"
    say "Wrong version - 64-bit APK" \
"This is an arm64-v8a (64-bit) APK.\n\nThe Miyoo Mini Plus is 32-bit and needs the\narmeabi-v7a build.\n\nRe-run mcbedrock-get on your PC and select\n\"32-bit armeabi-v7a\", then copy that APK over."
  else
    log "not a Bedrock APK"
    say "That is not a Minecraft APK" \
"$(basename "$APK")\n\ndoes not contain libminecraftpe.so, so it is not a\nMinecraft Bedrock APK."
  fi
  exit 1
fi
grep -q "assets/" "$LIST" || { log "no assets/"; say "APK looks incomplete" "This APK has no assets/ folder and will not run."; exit 1; }

# Version, best effort, FROM THE FILENAME ONLY.
#
# Do not be tempted to read it out of libminecraftpe.so: tried and measured on a
# real 1.2.20.2 install, and the version is simply not in there as text (it
# lives in the binary AndroidManifest, which busybox cannot parse). Both an
# anchored and an unanchored `strings | grep` over the whole 48 MB library
# returned nothing at all -- so that check could only ever print "unknown" while
# costing a full decompress-and-scan on every install.
VER=$(basename "$APK" | grep -oE '1\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$VER" ]; then
  VERLINE="Version: $VER  (read from the file name)"
  VERNAME="Minecraft $VER"
else
  VER="not detected"
  VERLINE="Version: not detected from the file name"
  VERNAME="Minecraft"
fi
log "version: $VER"

# --- space check --------------------------------------------------------------
AVAIL=$(df -k /mnt/SDCARD 2>/dev/null | tail -1 | awk '{print $4}')
[ -z "$AVAIL" ] && AVAIL=0
if [ "$AVAIL" -lt 1100000 ]; then
  log "low space: ${AVAIL}k"
  say "Not enough space" \
"Needs about 1 GB free; the card has about $((AVAIL / 1024)) MB.\n\nThe game expands to roughly 300 MB, and the port also\ncreates a 512 MB swap file the first time it runs.\nChecking only the 300 MB would let the install succeed\nand then fill your card.\n\nFree some space and try again."
  exit 1
fi

# --- confirm ------------------------------------------------------------------
if [ -x "$PROMPT" ]; then
  LD_PRELOAD=$PRELOAD "$PROMPT" -t "Install Minecraft?" \
    -m "File:  $(basename "$APK")\n$VERLINE\nInto:  App/mcpe/game1220\n\nThis takes about 2 minutes and the screen will look\nfrozen while it works. Do not power off.\n\nThis port is tuned for 1.2.20.2; other versions may\nrun badly or not at all." \
    "Install now" "Cancel" >/dev/null 2>&1
  [ $? -ne 0 ] && { log "user cancelled install"; exit 1; }
fi

# --- extract ------------------------------------------------------------------
# Into a staging dir first, so an interrupted extract cannot leave a half-built
# game directory that looks installed to the check at the top of this script.
STAGE=$MCPE/.game1220-staging
rm -rf "$STAGE" 2>/dev/null
mkdir -p "$STAGE" || { say "Install failed" "Could not create a staging folder on the card."; exit 1; }
log "extracting to $STAGE"
if ! unzip -q -o "$APK" -d "$STAGE" >> "$LOG" 2>&1; then
  log "unzip failed"
  rm -rf "$STAGE" 2>/dev/null
  say "Install failed" "The APK could not be extracted.\n\nIt may be damaged - try downloading it again.\nDetails: App/mcpe/install-apk.log"
  exit 1
fi

if [ ! -f "$STAGE/lib/armeabi-v7a/libminecraftpe.so" ] || [ ! -d "$STAGE/assets" ]; then
  log "post-extract verification failed"
  rm -rf "$STAGE" 2>/dev/null
  say "Install failed" "The extracted APK is missing files it needs.\n\nTry downloading it again."
  exit 1
fi

rm -rf "$GAMEDIR" 2>/dev/null
mv "$STAGE" "$GAMEDIR" || { log "mv failed"; say "Install failed" "Could not move the game into place."; exit 1; }
log "installed to $GAMEDIR"

# --- launcher settings --------------------------------------------------------
# Written on EVERY install, deliberately not behind the first-run marker.
#
# mcpelauncher draws its own menu bar ("File Mods View Video") across the top of
# the window unless told not to. It defaults ON, and it is unusable here anyway
# because this port has no pointer -- it just covers the game.
#
# This was missed in the first release archive and only surfaced on a genuinely
# fresh install: the development card happened to carry this file, so the bar was
# invisible throughout every test on that device. A setting that exists only on
# the developer's machine is not a setting, it is a coincidence.
#
# The launcher logs the path it reads at startup:
#   Reading Launcher Settings File: <HOME>/.local/share/mcpelauncher/mcpelauncher-client-settings.txt
# so HOME is authoritative; the app-dir copy mirrors it.
LSET=$MCPE/home/.local/share/mcpelauncher/mcpelauncher-client-settings.txt
mkdir -p "$(dirname "$LSET")" 2>/dev/null
printf 'enable_menubar=false\nenable_imgui=false\n' > "$LSET" 2>/dev/null
printf 'enable_menubar=false\nenable_imgui=false\n' > "$MCPE/mcpelauncher-client-settings.txt" 2>/dev/null
log "wrote launcher settings (menu bar off)"

# --- first-run graphics defaults ---------------------------------------------
# Applied ONCE, not on every launch: these are a sane starting point for a
# device with no GPU, not a policy. After this the settings are the user's.
# Without it a new world can open at a far higher render distance than this
# hardware can carry, and the first impression is far worse than the ~6.5 fps
# the port actually achieves.
OPT=$MCPE/home/.local/share/mcpelauncher/games/com.mojang/minecraftpe/options.txt
MARK=$MCPE/.first-run-tuned
if [ ! -f "$MARK" ]; then
  mkdir -p "$(dirname "$OPT")" 2>/dev/null
  [ -f "$OPT" ] || : > "$OPT"
  for kv in "gfx_viewdistance:80" "gfx_particleviewdistance:0" "gfx_fancygraphics:0" \
            "gfx_transparentleaves:0" "gfx_smoothlighting:0" "gfx_fancyskies:0" \
            "gfx_viewbobbing:0" "gfx_msaa:1" "gfx_guiscale_offset:-2" "gfx_hidegui:0"; do
    k=${kv%%:*}
    if grep -q "^$k:" "$OPT" 2>/dev/null; then
      sed -i "s/^$k:.*/$kv/" "$OPT" 2>/dev/null
    else
      echo "$kv" >> "$OPT" 2>/dev/null
    fi
  done
  : > "$MARK"
  log "applied first-run graphics defaults"
fi

say "Minecraft installed" \
"$VERNAME is installed and ready.\n\nStarting the game now. First launch takes about a\nminute to load.\n\nHold MENU for 2 seconds to quit at any time."
log "install complete"
exit 0
