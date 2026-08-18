# Minecraft Bedrock for the Miyoo Mini Plus

Run a legally owned Android copy of **Minecraft Bedrock 1.2.20.2** on a Miyoo
Mini Plus running OnionOS, through the open-source
[minecraft-linux](https://github.com/minecraft-linux) launcher and a software
OpenGL stack.

> **No game files are included.** You supply your own official Minecraft Bedrock
> Android APK, from your own Google Play purchase.
>
> **NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH
> MOJANG OR MICROSOFT.**

## Read this first: what performance to expect

The Miyoo Mini Plus has **no GPU**. Every pixel is drawn on two 1.2 GHz
ARM Cortex-A7 cores by a software rasterizer. Measured in a world, standing
still, at the default resolution:

| Internal resolution | Frame rate | Picture |
| --- | ---: | --- |
| 320x240 | 6.1 fps | sharpest, clean 2x upscale, all menus fit |
| 256x192 | ~6.7 fps | slight shimmer while moving |
| 208x156 | ~7.0 fps | shimmer, menus still usable |
| **160x120 — recommended** | **7.4 fps** | blocky, **Settings/Store off screen** |

**Play at 160x120.** It is the fastest setting that keeps the game usable, which is
where this hardware crosses from a slideshow into something you can actually
play. Everything above it looks nicer and plays worse.

**Its one catch, and the workaround.** Minecraft sizes its menus relative to the
render resolution, so at 160x120 the main menu's Settings and Store buttons fall
off the screen edges. The resolution picker appears *every* time you launch, so
when you need those menus, quit and relaunch at 320x240. In-game play and the
hotbar are unaffected.

**6-8 fps is what this hardware does.** It is enough to build, explore and
potter about; it is not enough for combat or anything twitchy. Render distance
is fixed at 5 chunks — the game itself refuses to go lower on this version, so
that is not a setting we can improve.

320x240 and 160x120 are the only resolutions that divide evenly into the 640x480
screen; the two in between trade a little sharpness for a few frames.

The 320x240 and 160x120 figures were measured in an ordinary generated world,
each with a repeated baseline to prove the run was stable; the two middle sizes
are interpolated from them.

> **These figures are for standing still. Moving costs roughly another 45%.**
> Walking makes the game load and build chunks, which is the single most
> expensive thing it does on this hardware. A measured play session at
> 256x192 and 1800 MHz ran at **5.0 fps** where standing still in the same place
> gives about 9. Nothing is wrong when that happens — it is what exploring costs.
> The table is honest for comparing settings against each other, and optimistic
> as a promise of what you will see while actually playing.

## What you need

- A **Miyoo Mini Plus** with **OnionOS**. Tested on **v4.3.1-1** (stable) and
  `v4.4.0-beta-20260120-07505ea5`. Other versions are untested but likely fine:
  the port needs `.tmp_update/bin/prompt`, `miyoo/lib/libpadsp.so` and
  `unzip`, and ships everything else itself.
- About **1 GB free** on the SD card: ~36 MB port, ~292 MB extracted game, and
  a 512 MB swap file (see below).
- A PC, to download your APK.
- A Google account that **owns Minecraft on Google Play**. Xbox, Windows,
  Switch, PlayStation and Amazon purchases are separate and will not work.

## Install

**1. Copy the port onto the card.** Extract the release archive so these land in
`/mnt/SDCARD/App/`:

```text
App/mcpe/                 launcher, EGL shim, support libraries, scripts
App/glsmoke-llvm/         software OpenGL (Mesa llvmpipe)
App/MinecraftBedrock12/   the entry that appears in your Apps list
```

Refresh the Apps list, or reboot.

**2. Get your APK.** You need your own copy — this port ships none and never
will. On a PC, the **mcbedrock-get** helper signs into your own Google account
and downloads your own Google Play purchase. It can download nothing for an
account that does not own the game.

- Full guide: [GETTING-BEDROCK-APKS.md](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/blob/main/GETTING-BEDROCK-APKS.md)
- Download it from the
  [releases page](https://github.com/DankMiimer/minecraft-bedrock-handheld-port/releases)
  — look for `mcbedrock-get-windows-*.zip` and take the **newest** one. It is
  currently published on a prerelease, so it may not be attached to whichever
  release GitHub marks "Latest". No version is linked here on purpose: a pinned
  link goes stale the moment a new helper is published.

It needs Ubuntu under WSL, and the Google account that owns the Android edition.

In the helper, choose:

- **32-bit armeabi-v7a** — the Miyoo Mini Plus is a 32-bit device. The 64-bit
  `arm64-v8a` build will not run, and the installer will say so rather than
  failing mysteriously.
- **Version 1.2.20.2** — what this port is tuned for.

Any other way of getting a legitimate `armeabi-v7a` 1.2.20.2 APK works equally
well; the installer only cares that the file is a Minecraft Bedrock APK with the
right ABI.

**3. Copy the `.apk` to the card**, into `App/mcpe/apk/` (the card root also
works).

**4. Launch "Minecraft Bedrock 1.2"** from the Apps list. It finds the APK,
checks it, and installs it. This takes about two minutes and **the screen looks
frozen while it works** — that is normal, do not power off.

After that, every launch shows a short menu and starts the game:

```text
Recommended    160x120, stock      7.4 fps
Faster         160x120, 1700 MHz   9.9 fps
Fastest        160x120, 1800 MHz  10.2 fps
Balanced       256x192, 1800 MHz  ~9.2 fps
Best picture   320x240, stock      6.1 fps
Custom...
```

**Custom** opens the detailed resolution and CPU-speed menus if you want to mix
your own. Your choice is remembered, so the routine case is one button press.

## Overclocking (optional)

The second startup menu offers a CPU overclock. It defaults to **stock** and does
nothing unless you choose otherwise. Measured on one console at 160x120:

| CPU speed | Frame rate | vs stock | Peak temperature |
| --- | ---: | ---: | --- |
| 1200 MHz (stock, default) | 25.3 | — | 74 °C |
| 1500 MHz | 30.0 | +18% | 77 °C |
| 1600 MHz | 31.4 | +24% | 77 °C |
| 1700 MHz | 33.1 | +29% | 78 °C |
| 1800 MHz | 33.9 | **+33%** | 77 °C |

This stacks with the resolution setting — they speed up different things. Note
1700 and 1800 are within 3% of each other: past about 1700 MHz the memory, not
the CPU, is the limit.

**Read this before using it.** The console has **no thermal throttling** and
already idles near 70 °C, so nothing will step in to protect it. There is no
voltage control either, so these are overclocks at the stock 1.0 V. All four
speeds were stable through repeated runs here with no crash or lockup, and the
community reports similar, but **that is one console and yours may differ.** A
sustained play session at 1800 MHz reached **82 °C**, above the 77 °C the short
benchmark runs showed, so expect it to run hotter than the table suggests. If
the game crashes or the console locks up, pick a lower speed next launch — the
menu appears every time and nothing is stored on the device that a reboot cannot
clear. Your normal CPU governor is restored when you quit.

## Controls

The Miyoo Mini Plus has no right stick, so **the four face buttons are the right
stick**:

| Input | Action |
| --- | --- |
| D-pad | move |
| X / B / Y / A | look up / down / left / right |
| **hold R2** | face buttons become a real A/B/X/Y again |
| L1 | use / place block |
| R1 | attack / break block |
| SELECT / START | hotbar left / right |
| L2 | pause menu |
| **hold MENU for 2 s** | quit the game |

Looking accelerates: a tap nudges the camera, holding speeds it up. At these
frame rates full deflection on a single press is impossible to aim with.

**To press a real B — for example to dismiss the Xbox sign-in prompt on first
run — hold R2 and press B.** Without R2 held, B looks downwards.

## Things worth knowing

**It creates a 512 MB swap file.** `App/mcpe/launch-mcpe.sh` creates
`/mnt/SDCARD/mcpe-swap` the first time it runs, which takes about a minute. The
device has only 103 MB of RAM and the game needs far more than that. Delete the
file to reclaim the space; it will be recreated on the next launch.

**No Xbox Live / Marketplace sign-in.** Dismiss the prompt on first run (hold R2
and press B). Skins, realms and marketplace content are not available.

**Quitting.** Hold MENU for two seconds. It is a held button rather than a
button combination on purpose: an earlier chord version could fire from a stale
key state and killed live sessions.

**A frozen picture usually means the game has already exited**, not that it has
hung. Nothing else redraws the screen after the game stops, so the last frame
stays there. Press MENU or reboot.

**Rebooting.** If you reboot with a USB cable plugged in, the device powers off
again instead of starting. Unplug it first.

## Known issues

**A line of stats across the top of the screen.** Something like
`beta 1.2.20.2 Gui:1.00 / llvmpipe (LLVM 7.0.1, 128 bits), Linux, FPS:6.4, Mem:...`.
This is Minecraft's own build-info overlay, not part of the port. It is on by
default in this build and **cannot currently be switched off**: the engine gates
it on `dev_showbuildinfo`, but writing that into `options.txt` does not work —
the game strips the key on startup. Cosmetic only.

**No Xbox Live, Realms or Marketplace.** Dismiss the sign-in prompt on first run
by holding R2 and pressing B.

**Settings and Store are off screen at 160x120.** Expected at the recommended
resolution; relaunch at 320x240 to reach them.

**Overclocking is opt-in and defaults to off** — see the Overclocking section
above for the measured numbers and the risks.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "This is an arm64-v8a (64-bit) APK" | You downloaded the wrong build. Re-run the helper and choose **32-bit armeabi-v7a**. |
| "No Minecraft APK was found" | The `.apk` is not in `App/mcpe/apk/` or the card root, or it did not finish copying. |
| Install fails part way | See `App/mcpe/install-apk.log`. A partly-copied APK is the usual cause; copy it again. |
| Black screen after launching | Give it a minute — first load is slow. If it stays black, check `App/mcpe/run12.log`. |
| Settings/Store missing from the main menu | Expected at the recommended 160x120. Quit and relaunch at 320x240 to reach them. |
| Game will not start after an update | Delete `App/mcpe/game1220` and launch again to reinstall from your APK. |

Each session appends a summary line to `App/mcpe/run12.log`:

```text
[session] 160x120  1200MHz  412s  2730 frames  avg 6.62 fps (whole session, includes load)  MainUI-stops=0
```

That average covers the whole session including the minute of loading, so it
reads lower than in-game performance. Include this line in any bug report.

## Uninstall

Delete `App/mcpe/`, `App/glsmoke-llvm/`, `App/MinecraftBedrock12/`, and
`/mnt/SDCARD/mcpe-swap`. Your worlds live in `App/mcpe/home/`, so copy that
somewhere first if you want to keep them.

## Legal

This port distributes launcher scripts, an EGL shim, support libraries and a
software OpenGL build only. **No Minecraft APKs, game libraries, assets or
worlds are included, and none ever will be.** You must supply your own legally
obtained copy, and the APK you download is your own — do not redistribute it.

Nothing here mirrors or hosts game files, defeats a protection measure, or
provides any way to obtain Minecraft without owning it.

Minecraft, Mojang, Microsoft, Xbox, Google Play and Android are trademarks of
their respective owners, used here only to identify compatibility and required
user-provided software.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG
OR MICROSOFT.**

## Credits

- [minecraft-linux](https://github.com/minecraft-linux) — the mcpelauncher
  client this port patches and ships.
- [Mesa](https://www.mesa3d.org/) — llvmpipe, the software rasterizer doing all
  the drawing.
- OnionOS — the platform, and its `prompt` dialog used by the picker and
  installer.
