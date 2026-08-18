# build-release.ps1 - assemble the Miyoo Mini Plus Bedrock release archive.
#
# The archive extracts at the SD card root, so everything lives under App/.
#
# NOTHING Minecraft goes in. The device this was developed on carries seven
# extracted game directories, worlds, and a client_payload.tar; none of that may
# ship. The safety check at the bottom fails the build rather than trusting this
# script to have listed the right things.
param(
    [string]$Version = "v0.1.0-testing",
    [string]$Root    = $PSScriptRoot
)
$ErrorActionPreference = "Stop"

$stage = Join-Path $Root "release-staging"
$out   = Join-Path $Root "release"
$tree  = Join-Path $stage "tree"

foreach ($d in @($tree)) { if (Test-Path $d) { Get-ChildItem $d -Recurse | Remove-Item -Recurse -Force } }
New-Item -ItemType Directory -Force -Path $tree, $out | Out-Null

$mcpe  = Join-Path $tree "App\mcpe"
$mesa  = Join-Path $tree "App\glsmoke-llvm\lib"
$entry = Join-Path $tree "App\MinecraftBedrock12"
New-Item -ItemType Directory -Force -Path $mcpe, "$mcpe\apk", $mesa, "$mesa\dri", $entry | Out-Null

# --- the patched client -------------------------------------------------------
# client-quitfix is the build running on the device (md5 abc9b26c8554...). The
# other client-* dirs are earlier iterations; picking by date would eventually
# ship the wrong one, so it is named explicitly.
Copy-Item (Join-Path $Root "client\client-quitfix\mcpelauncher-client.armhf.standard") (Join-Path $mcpe "mcpelauncher-client")

# --- EGL shim + support libraries (built from Debian Buster armhf) -------------
Copy-Item (Join-Path $Root "client\out-rel\egl-wrap") $mcpe -Recurse
Copy-Item (Join-Path $Root "client\out-rel\lib")      $mcpe -Recurse

# --- android stub libs + app icon (no local build source; taken from device) ---
$bits = Join-Path $stage "bits"
if (Test-Path $bits) { Get-ChildItem $bits -Recurse | Remove-Item -Recurse -Force }
New-Item -ItemType Directory -Force -Path $bits | Out-Null
tar -xf (Join-Path $stage "pkgbits.tar") -C $bits
Copy-Item (Join-Path $bits "App\mcpe\android-libs") $mcpe -Recurse
Copy-Item (Join-Path $bits "App\MinecraftBedrock12\icon.png") $entry

# --- scripts ------------------------------------------------------------------
Copy-Item (Join-Path $Root "client\launch-mcpe.sh") $mcpe
Copy-Item (Join-Path $Root "client\install-apk.sh") $mcpe
Copy-Item (Join-Path $Root "app-MinecraftBedrock12\launch.sh")   $entry
Copy-Item (Join-Path $Root "app-MinecraftBedrock12\config.json") $entry
Copy-Item (Join-Path $Root "README.md") $tree

# --- Mesa (llvmpipe) ----------------------------------------------------------
# Only swrast_dri.so: kms_swrast_dri.so is another 20 MB and needs a DRM device
# this SoC does not have.
#
# libOSMesa is EXCLUDED and must stay excluded: it is 25.5 MB and the build
# emits three copies of it (.so, .so.8, .so.8.0.0), so blindly copying the
# whole lib dir added ~76 MB of dead weight. The game never touches it -- it
# goes through EGL, GLESv2 and swrast_dri. Verified rather than assumed: the
# known-good install on the device has no OSMesa at all, and `strings` finds
# zero references to it in either the client or the EGL shim.
Copy-Item (Join-Path $Root "smoke\out-llvmpipe\lib\dri\swrast_dri.so") (Join-Path $mesa "dri")
Get-ChildItem (Join-Path $Root "smoke\out-llvmpipe\lib") -File |
    Where-Object { $_.Name -notlike "libOSMesa*" } |
    ForEach-Object { Copy-Item $_.FullName $mesa }

# --- a placeholder so the drop folder survives archiving ----------------------
Set-Content -Path (Join-Path $mcpe "apk\PUT-YOUR-APK-HERE.txt") -Encoding ascii -Value @"
Copy your own Minecraft Bedrock APK into this folder, then launch
"Minecraft Bedrock 1.2" from the Apps list.

It must be the 32-bit armeabi-v7a build - the Miyoo Mini Plus is a 32-bit
device and an arm64-v8a APK will not run. Version 1.2.20.2 is what this port
is tuned for.

See README.md at the root of this archive.
"@

# --- SAFETY CHECK: no Minecraft content, no user data -------------------------
# Fail the build rather than publish game files by accident.
$bad = @()
$forbidden = @("libminecraftpe.so", "client_payload.tar", "options.txt", "*.apk",
               "minecraftWorlds", "bench-*.log", "run*.log", "*.raw")
foreach ($pat in $forbidden) {
    $bad += Get-ChildItem $tree -Recurse -Force -Filter $pat -ErrorAction SilentlyContinue
}
$bad += Get-ChildItem $tree -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(game\d+|home|assets)$' }
if ($bad.Count -gt 0) {
    Write-Host "RELEASE SAFETY CHECK FAILED - forbidden content in the tree:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  $($_.FullName)" }
    throw "refusing to package"
}
Write-Host "safety check passed: no game content, no user data"

# --- archive ------------------------------------------------------------------
$zip = Join-Path $out "minecraft-bedrock-miyoo-mini-plus-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $tree "*") -DestinationPath $zip -CompressionLevel Optimal
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content -Path (Join-Path $out "SHA256SUMS.txt") -Encoding ascii -Value "$sha  $(Split-Path $zip -Leaf)"

"{0}" -f (Split-Path $zip -Leaf)
"  size   : {0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
"  sha256 : $sha"
