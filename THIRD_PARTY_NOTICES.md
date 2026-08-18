# Third-party notices

This port is a set of scripts plus a small EGL shim. Everything else it
distributes belongs to other projects, listed here with what was changed and
where the corresponding source lives.

**No Minecraft code, assets or data is included or redistributed.** See
[LEGAL.md](LEGAL.md).

## mcpelauncher (modified binary — GPL family)

`App/mcpe/mcpelauncher-client` is a **modified build** of the minecraft-linux
launcher. It is distributed here in binary form, so the corresponding source and
the modifications are named explicitly:

| Component | Upstream | Source used |
| --- | --- | --- |
| mcpelauncher-client | https://github.com/minecraft-linux/mcpelauncher-client | https://github.com/DankMiimer/mcpelauncher-client |
| mcpelauncher-manifest | https://github.com/minecraft-linux/mcpelauncher-manifest | https://github.com/DankMiimer/mcpelauncher-manifest |
| game-window | https://github.com/minecraft-linux/game-window | https://github.com/DankMiimer/game-window |
| libc-shim | https://github.com/minecraft-linux/libc-shim | https://github.com/DankMiimer/libc-shim |

**Two modifications were applied to the stock launcher**, both as source patches
before compiling:

1. **Miyoo input.** A reader for `/dev/input/event0` is spliced into
   `SDL3GameWindow::pollEvents`, translating the handheld's buttons into the
   launcher's `onGamepad*` / `onTouch*` / `onKeyboard` entry points. This is what
   makes the face buttons act as a right stick and MENU-held quit the game.
   Patch: `build/clients/inject_miyoo_input.py` in the port repository.
2. **IPv4-only sockets.** `libc-shim` is patched to map `AF_INET6` to `AF_INET`.
   This kernel has no IPv6 and RakNet's dual-stack bind segfaults without it.
   Patch: `build/clients/inject_ipv4only.py`.

The build recipe is `client/Dockerfile.client-input` in this repository.

## Mesa (MIT)

`App/glsmoke-llvm/` is Mesa 20.3.5 built for armhf with the **llvmpipe**
software rasterizer (LLVM 7 statically linked). Unmodified upstream source,
built with the recipe in `smoke/Dockerfile.llvmpipe`.

- Upstream: https://www.mesa3d.org/
- Licence: MIT. See https://docs.mesa3d.org/license.html

## Debian armhf runtime libraries (LGPL and others)

`App/mcpe/lib/` contains unmodified binaries taken from **Debian 10 (Buster)
armhf** packages, gathered by `client/Dockerfile`. They are shipped because
OnionOS does not provide all of them, and depending on its copies made the port
break on other Onion builds.

| Library | Debian package | Licence |
| --- | --- | --- |
| libstdc++.so.6 | libstdc++6 | GPL-3 with GCC Runtime Library Exception |
| libssl.so.1.1, libcrypto.so.1.1 | libssl1.1 | OpenSSL / Apache-2.0 |
| libz.so.1 | zlib1g | zlib |
| libpng16.so.16 | libpng16-16 | libpng |
| libexpat.so.1 | libexpat1 | MIT |
| libdrm.so.2 | libdrm2 | MIT |
| libudev.so.1 | libudev1 | LGPL-2.1+ |
| libevdev.so.2 | libevdev2 | MIT |
| libatomic.so.1 | libatomic1 | GPL-3 with GCC Runtime Library Exception |
| libtinfo.so.6 | libtinfo6 | MIT (ncurses) |

All are **unmodified**. Corresponding source for any of them is obtainable from
Debian:

```
apt-get source <package>          # on a Debian 10 system
```

or from https://snapshot.debian.org/archive/debian/20240612T000000Z/ , which is
the exact snapshot this port builds against (pinned in `client/Dockerfile`).

For the LGPL components, the licence is satisfied by dynamic linking plus the
availability of the unmodified library source above; nothing here relinks or
statically embeds them.

## OnionOS

The port calls OnionOS's own `prompt` dialog for its menus and relies on the
OnionOS runtime. Nothing from OnionOS is redistributed here.

- https://github.com/OnionUI/Onion

## Trademarks

See [TRADEMARKS.md](TRADEMARKS.md).
