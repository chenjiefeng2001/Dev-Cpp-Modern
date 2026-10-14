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
    [ValidateSet('all', 'data', 'list', 'lfm', 'raster', 'try', 'parse', 'norm', 'imgcoll')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'

# Where Lazarus lives is not a property of this repository. setup-lazarus on
# windows-latest installs under D:\a\_temp\installers\lazarus, not C:\lazarus,
# and a hard-coded prefix made every probe fail with
# "ppcx64.exe returned an error exitcode" -- which names the compiler rather
# than the missing directory, so it reads as a broken probe.
#
# Ask the compiler that is on PATH. It is also the honest source of truth: the
# probes are built with that fpc, so the -Fu directories they need belong to
# THAT installation. With two Lazarus installs present, a fixed prefix would mix
# units from one with a compiler from the other.
$laz = $null
# Walk up from the compiler until an ancestor actually contains the LCL package.
# Counting levels would be fragile -- <laz>/fpc/<version>/bin/<target>/fpc.exe is
# five directories down, and the depth differs between layouts -- and asking the
# tree whether it is a Lazarus tree is the question worth asking anyway.
$laz = $null
$dir = Split-Path -Parent (Get-Command fpc -ErrorAction SilentlyContinue).Source
while ($dir) {
    if (Test-Path (Join-Path $dir 'lcl\interfaces\lcl.lpk')) { $laz = $dir; break }
    $parent = Split-Path -Parent $dir
    if ($parent -eq $dir) { break }
    $dir = $parent
}
if (-not $laz) {
    throw ('no ancestor of fpc contains lcl\interfaces\lcl.lpk -- is this a ' +
           'Lazarus installation?')
}
if (-not (Test-Path (Join-Path $laz 'components\fpvectorial'))) {
    throw "'$laz' has an LCL but no components\fpvectorial"
}
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

# ImgCollProbe lives in its own directory because it needs a DIFFERENT set of
# unit paths: no fpvectorial (it decodes PNGs through the LCL's own registry
# rather than rendering SVG), and it walks up from the executable to find the
# repo root rather than depending on the working directory the way the probes
# above do with their relative LFM paths.
if ($Target -in @('all', 'imgcoll')) {
    $img = Join-Path $PSScriptRoot '..\Tests\FpcCoreTests\imgcoll'
    Push-Location $img
    try {
        New-Item -ItemType Directory -Path 'lib' -Force | Out-Null
        Write-Host "==> ImgCollProbe.lpr" -ForegroundColor Cyan
        $b = @('-Mdelphiunicode', '-FUlib', '-FE.')
        # Same -Fu ORDER as above: widgetset-specific first.
        foreach ($d in @(
            "$laz\lcl\units\x86_64-win64\win32",
            "$laz\lcl\units\x86_64-win64",
            "$laz\components\lazutils\lib\x86_64-win64",
            (Resolve-Path '.').Path,
            (Join-Path $PSScriptRoot '..\Source\Fpc\UI\Controls'),
            (Join-Path $PSScriptRoot '..\Source\Fpc\UI\Data'))) {
            $b += "-Fu$d"
        }
        & fpc @b 'ImgCollProbe.lpr'
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    finally {
        Pop-Location
    }
}
exit $failed