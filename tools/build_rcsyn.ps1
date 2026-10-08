#!/usr/bin/env pwsh
# Compile the native LCL RC highlighter on its own, before it is wired into a
# probe. Its whole point is that it compiles against the LCL API; finding that
# out here rather than inside a probe's build log keeps the failure readable.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$laz = 'C:\lazarus'
$fpcBin = Join-Path $laz 'fpc\3.2.2\bin\x86_64-win64'
$env:PATH = "$fpcBin;$laz;$env:PATH"

$root = Join-Path $PSScriptRoot '..'
$out = Join-Path $env:TEMP 'rcsyn'
New-Item -ItemType Directory -Path $out -Force | Out-Null

$a = @(
    '-Mdelphiunicode', '-FU' + $out, '-FE' + $out,
    "-Fu$laz\lcl\units\x86_64-win64\win32",
    "-Fu$laz\lcl\units\x86_64-win64",
    "-Fu$laz\components\lazutils\lib\x86_64-win64",
    "-Fu$laz\components\synedit\units\x86_64-win64\win32",
    (Join-Path $root 'Source\Fpc\UI\Controls\SynHighlighterRc.pas')
)
& fpc @a
exit $LASTEXITCODE