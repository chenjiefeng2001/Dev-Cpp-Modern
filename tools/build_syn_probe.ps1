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
# Where Lazarus lives is not a property of this repository. setup-lazarus on
# windows-latest installs under D:\a\_temp\installers\lazarus, and a hard-coded
# prefix makes every probe fail with
#   Error: ...\ppcx64.exe returned an error exitcode
# which names the compiler rather than the missing directory, so it reads as a
# broken probe.
#
# Walk up from the compiler on PATH to the first ancestor that actually contains
# the LCL package. Walking beats counting levels -- the depth below <laz> varies
# -- and asking the tree whether it is a Lazarus tree is the question worth
# asking. The compiler is also the honest source of truth: these probes are built
# with that fpc, so the -Fu directories they need belong to THAT installation.
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