#!/usr/bin/env pwsh
# Build Tests/FpcCoreTests/syn/SynRcProbe.lpr -- the probe that asks whether the
# native LCL RC highlighter tokenises, not merely whether it constructs.
#
# Same -Fu ORDER rule as build_form_probe.ps1: `Interfaces` exists only under
# the widgetset directory, and the generic LCL units sit one level up.
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$laz = 'C:\lazarus'
$fpcBin = Join-Path $laz 'fpc\3.2.2\bin\x86_64-win64'
$env:PATH = "$fpcBin;$laz;$env:PATH"

$dir = Join-Path $Root 'Tests\FpcCoreTests\syn'
Set-Location $dir
New-Item -ItemType Directory -Path 'lib' -Force | Out-Null

$fu = @(
    "$laz\lcl\units\x86_64-win64\win32",
    "$laz\lcl\units\x86_64-win64",
    "$laz\components\lazutils\lib\x86_64-win64",
    "$laz\components\synedit\units\x86_64-win64\win32",
    (Resolve-Path '.').Path,
    (Join-Path $Root 'Source\Fpc\UI\Controls')
)
foreach ($d in $fu) {
    if (-not (Test-Path $d)) { Write-Host "MISSING unit dir: $d" -ForegroundColor Red; exit 1 }
}

$a = @('-Mdelphiunicode', '-FUlib', '-FE.')
foreach ($d in $fu) { $a += "-Fu$d" }
$a += 'SynRcProbe.lpr'
& fpc @a
exit $LASTEXITCODE