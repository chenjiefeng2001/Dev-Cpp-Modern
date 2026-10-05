#!/usr/bin/env pwsh
# Build the SVG data/raster probes against a REAL LCL + fpvectorial.
#
# WHY A SCRIPT AND NOT THE INLINE COMMAND
# ======================================
# Compiling against the LCL needs four search paths and the ORDER matters:
# `Interfaces` exists only under the widgetset directory (lcl/units/<cpu>/win32)
# while the generic LCL units sit one level up, and `nogui` also carries an
# `Interfaces` that would win a tie on a case-insensitive filesystem. Getting
# that wrong reports
#
#     Fatal: Can't find unit Interfaces used by RasterProbe
#
# which reads as "Lazarus is not installed" rather than "wrong -Fu order".
#
# PREREQUISITES (measured 2026-10-05, both exit 0 on this machine):
#   lazbuild --ws=win32 C:\lazarus\lcl\interfaces\lcl.lpk
#   lazbuild C:\lazarus\components\fpvectorial\fpvectorialpkg.lpk
# The stock Lazarus install ships BOTH packages as SOURCE only -- with neither
# built, `fpvectorial.ppu` does not exist and nothing here can compile.
[CmdletBinding()]
param(
    [ValidateSet('all', 'data', 'list', 'lfm', 'raster', 'try', 'parse', 'norm')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'
$laz = 'C:\lazarus'
$fpcBin = Join-Path $laz 'fpc\3.2.2\bin\x86_64-win64'
$env:PATH = "$laz;$fpcBin;$env:PATH"

$svg = Join-Path $PSScriptRoot '..\Tests\FpcCoreTests\svg'
Set-Location $svg
New-Item -ItemType Directory -Path 'lib' -Force | Out-Null

# Widgetset-specific FIRST: it is the only place `Interfaces` exists.
# The last two are the control and the extracted payload, which live under
# Source/Fpc/UI since 2026-10-06 (doc F3-SVG section 11.7) rather than beside
# these probes.
$fu = @(
    "$laz\lcl\units\x86_64-win64\win32"
    "$laz\lcl\units\x86_64-win64"
    "$laz\components\lazutils\lib\x86_64-win64"
    "$laz\components\fpvectorial\lib\x86_64-win64"
    (Resolve-Path '.').Path
    (Resolve-Path (Join-Path $PSScriptRoot '..\Source\Fpc\UI\Controls')).Path
    (Resolve-Path (Join-Path $PSScriptRoot '..\Source\Fpc\UI\Data')).Path
)
foreach ($d in $fu) {
    if (-not (Test-Path $d)) { Write-Host "MISSING unit dir: $d" -ForegroundColor Red }
}

$targets = @()
if ($Target -in @('all', 'data')) { $targets += 'SvgDataProbe.lpr' }
if ($Target -in @('all', 'list')) { $targets += 'SvgListProbe.lpr' }
if ($Target -in @('all', 'lfm')) { $targets += 'SvgLfmProbe.lpr' }
if ($Target -in @('all', 'raster')) { $targets += 'RasterProbe.lpr' }
if ($Target -in @('all', 'try')) { $targets += 'SvgTry.lpr' }
if ($Target -in @('all', 'parse')) { $targets += 'SvgParse.lpr' }
if ($Target -in @('all', 'norm')) { $targets += 'SvgNorm.lpr' }

$failed = 0
foreach ($t in $targets) {
    Write-Host "==> $t" -ForegroundColor Cyan
    $a = @('-Mdelphiunicode', '-FUlib', '-FE.')
    foreach ($d in $fu) { $a += "-Fu$d" }
    $a += $t
    & fpc @a
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
exit $failed