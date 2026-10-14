<#
.SYNOPSIS
    Publishes this fork's build as a GitHub release for omawin (github.com/mjveilleux/omawin),
    whose bin/noctty.ps1 installs it.

.DESCRIPTION
    Zips zig-out\bin (build it first: zig build -Demit-exe=true -Doptimize=ReleaseFast, inside
    Visual Studio's build environment) as noctty-<version>-windows-x64-portable.zip with a
    SHA256SUMS-windows-x64.txt beside it (the names upstream's releases use, so the installer
    reads both alike), and creates the release on the fork with gh. The builds are unsigned;
    the checksum is the check.
#>
param([Parameter(Mandatory = $true)][string]$Version, [switch]$NoPublish)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$bin = Join-Path $root 'zig-out\bin'
$out = Join-Path $root "dist\omawin\$Version"
$stage = Join-Path $out "noctty-$Version"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

foreach ($file in 'noctty.exe', 'noctty.com', 'conpty.dll', 'OpenConsole.exe', 'noctty-terminal-handoff-proxy.dll', 'noctty.ico') {
    Copy-Item (Join-Path $bin $file) $stage
}
Copy-Item (Join-Path $root 'LICENSE') $stage
foreach ($extra in 'dist\windows\LICENSE-conpty.txt', 'dist\windows\config-template.ghostty') {
    $path = Join-Path $root $extra
    if (Test-Path $path) { Copy-Item $path $stage }
}

$zipName = "noctty-$Version-windows-x64-portable.zip"
$zip = Join-Path $out $zipName
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$sums = Join-Path $out 'SHA256SUMS-windows-x64.txt'
Set-Content $sums "$hash  $zipName" -NoNewline
"$zip`n$hash"

if ($NoPublish) { return }
$commit = git -C $root rev-parse HEAD
gh release create "v$Version" $zip $sums --repo mjveilleux/noctty --target $commit --title "noctty $Version" `
    --notes "omawin's noctty build ($commit): Ghostty-themed tab strip, spare shells (windows-spare-shell). Unsigned; verify with SHA256SUMS-windows-x64.txt."
