# build-repo.ps1 - assemble the public repository tree for the MM+ port.
#
# Publishes SOURCE, not just the archive: the port ships a modified GPL
# launcher binary, so the patches and build recipes need to be visible, and
# anyone should be able to rebuild what they are running.
#
# Same rule as the release archive: nothing Minecraft, nothing personal. The
# check at the bottom fails the build rather than trusting this list.
param(
    [string]$Root = $PSScriptRoot,
    [string]$Out  = (Join-Path $PSScriptRoot "repo")
)
$ErrorActionPreference = "Stop"

if (Test-Path $Out) { Get-ChildItem $Out -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# --- top-level docs and licences ---------------------------------------------
foreach ($f in @("README.md","LEGAL.md","THIRD_PARTY_NOTICES.md","TRADEMARKS.md","LICENSE","AUTHORS.md")) {
    Copy-Item (Join-Path $Root $f) $Out
}

# --- the port itself ----------------------------------------------------------
$app = Join-Path $Out "App/MinecraftBedrock12"
$src = Join-Path $Out "src"
$bld = Join-Path $Out "build"
New-Item -ItemType Directory -Force -Path $app, $src, $bld | Out-Null

Copy-Item (Join-Path $Root "app-MinecraftBedrock12/launch.sh")   $app
Copy-Item (Join-Path $Root "app-MinecraftBedrock12/config.json") $app
Copy-Item (Join-Path $Root "client/launch-mcpe.sh")  $src
Copy-Item (Join-Path $Root "client/install-apk.sh")  $src
Copy-Item (Join-Path $Root "client/src/fbegl.c")     $src
Copy-Item (Join-Path $Root "smoke/src/fb.h")         $src

# --- build recipes: how to reproduce every binary we ship ---------------------
Copy-Item (Join-Path $Root "client/Dockerfile")              (Join-Path $bld "Dockerfile.shim")
Copy-Item (Join-Path $Root "client/Dockerfile.client-input") (Join-Path $bld "Dockerfile.client")
if (Test-Path (Join-Path $Root "smoke/Dockerfile.llvmpipe")) {
    Copy-Item (Join-Path $Root "smoke/Dockerfile.llvmpipe")  (Join-Path $bld "Dockerfile.mesa")
}
Copy-Item (Join-Path $Root "build-release.ps1") $bld
Copy-Item (Join-Path $Root "build-repo.ps1")    $bld

# --- developer notes ----------------------------------------------------------
$docs = Join-Path $Out "docs"
New-Item -ItemType Directory -Force -Path $docs | Out-Null
Copy-Item (Join-Path $Root "HANDOFF.md") (Join-Path $docs "DEVELOPMENT-NOTES.md")

Set-Content -Path (Join-Path $Out ".gitignore") -Encoding ascii -Value @"
# never commit game content or build output
*.apk
release/
release-staging/
repo/
out*/
client-*/
game*/
*.raw
*.log
"@

# --- SAFETY CHECK -------------------------------------------------------------
$bad = @()
foreach ($pat in @("libminecraftpe.so","*.apk","options.txt","client_payload.tar","*.raw","*.log")) {
    $bad += Get-ChildItem $Out -Recurse -Force -Filter $pat -ErrorAction SilentlyContinue
}
$bad += Get-ChildItem $Out -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(game\d+|home|assets|minecraftWorlds)$' }
# A binary here would mean shipping something unbuildable from this tree.
$bad += Get-ChildItem $Out -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 1MB -and $_.Name -ne "LICENSE" }
if ($bad.Count -gt 0) {
    Write-Host "REPO SAFETY CHECK FAILED:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  $($_.FullName)" }
    throw "refusing to build repo tree"
}

$n = (Get-ChildItem $Out -Recurse -File).Count
$kb = [math]::Round(((Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum / 1KB), 0)
"repo tree: $n files, $kb kB"
Get-ChildItem $Out -Recurse -File | ForEach-Object { "  " + $_.FullName.Substring($Out.Length + 1) }
