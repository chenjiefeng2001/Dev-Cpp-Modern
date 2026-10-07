#!/usr/bin/env pwsh
# Build Tests/FpcCoreTests/forms/{FormLfmProbe,PropRttiProbe}.lpr against the
# real LCL.
#
# WHY A SCRIPT AND NOT AN INLINE COMMAND
# ======================================
# The -Fu ORDER matters (see build_svg_probe.ps1): `Interfaces` exists
# only under the widgetset directory (lcl/units/<cpu>/win32), and the
# generic LCL units sit one level up. Git Bash mangles attached `-FuC:/...`
# arguments (measured 2026-10-06: `uses Interfaces` failed with
# "Can't find unit" from bash but built from pwsh), so this runs under
# pwsh, where the paths reach fpc verbatim.
#
# SynEdit comes from the LAZARUS install (components/synedit/units/
# x86_64-win64/win32), not the vendored Source/VCL/SynEdit copy, which
# is not FPC-compilable yet.
[CmdletBinding()]
param(
    [ValidateSet('all', 'lfm', 'props')]
    [string]$Target = 'all',
    [string]$Root = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$laz = 'C:\lazarus'
$fpcBin = Join-Path $laz 'fpc\3.2.2\bin\x86_64-win64'
$env:PATH = "$fpcBin;$laz;$env:PATH"

$forms = Join-Path $Root 'Tests\FpcCoreTests\forms'
Set-Location $forms
New-Item -ItemType Directory -Path 'lib' -Force | Out-Null

# Widgetset-specific FIRST: it is the only place `Interfaces` exists.
$fu = @(
    "$laz\lcl\units\x86_64-win64\win32",
    "$laz\lcl\units\x86_64-win64",
    "$laz\components\lazutils\lib\x86_64-win64",
    "$laz\components\synedit\units\x86_64-win64\win32",
    (Resolve-Path '.').Path,
    (Join-Path $Root 'Source\Fpc\UI\Controls'),
    (Join-Path $Root 'Source\Fpc\UI\Compat'),
    (Join-Path $Root 'Source\Fpc\UI\Data')
)
foreach ($d in $fu) {
    if (-not (Test-Path $d)) { Write-Host "MISSING unit dir: $d" -ForegroundColor Red; exit 1 }
}

$targets = @()
if ($Target -in @('all', 'lfm')) { $targets += 'FormLfmProbe.lpr' }
if ($Target -in @('all', 'props')) { $targets += 'PropRttiProbe.lpr' }

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
