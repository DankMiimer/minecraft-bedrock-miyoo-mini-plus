# Legal notes

This repository distributes launcher scripts, a small EGL/framebuffer shim, a
software OpenGL build, support libraries, and the patches used to build a
modified launcher. Nothing else.

**No Minecraft APKs, extracted Minecraft game libraries, assets, worlds, skins
or other Mojang/Microsoft game files are included.** Users must provide their
own legally obtained Minecraft Bedrock Edition for Android APK.

Users obtain Minecraft themselves, from their own Google Play purchase. The
on-device installer (`App/mcpe/install-apk.sh`) only reads an APK the user has
already placed on their own SD card: it checks that the file is a Minecraft
Bedrock APK for the correct 32-bit ABI and extracts it locally. It does not
download anything, contact any server, or contain any part of the game.

Nothing here mirrors or hosts game files, defeats a protection measure, or
provides any way to obtain Minecraft without owning it. An APK a user downloads
is their own copy and must not be redistributed.

The release archive is built by `build-release.ps1`, which **fails the build**
rather than packaging if it finds `libminecraftpe.so`, any `*.apk`, an
`options.txt`, a world directory or any other game or user data in the staged
tree.

For the licences of the third-party components that *are* distributed — the
modified mcpelauncher binary, Mesa, and the Debian runtime libraries — and for
where to get their source, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG
OR MICROSOFT.**
