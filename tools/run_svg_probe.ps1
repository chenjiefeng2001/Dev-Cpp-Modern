# Run the SVG probes and report pass/fail per probe.
#
# The probes are NOT interchangeable with respect to working directory or
# arguments, and nothing in the .lpr sources says so:
#
#   repo root      SvgDataProbe, SvgListProbe, SvgLfmProbe, ImgCollProbe,
#                  RasterProbe
#                  SvgLfmProbe resolves FRAGMENT_DIR = 'Source\Fpc\UI\Forms'
#                  relative to the CWD, so from anywhere else it reports
#                  "the converter produced no fragment to test -- FAIL".
#
#   probe dir      SvgNorm     defaults to VariantDir 'zerochord'
#   probe dir      SvgParse <dir>, SvgTry <dir>   require an explicit dir
#
# SvgNorm exits 1 with all counts at zero when its variant directory is not
# found -- it fails loudly rather than reporting a vacuous pass, so a wrong CWD
# is visible as a failure and not as a silent green.

$ErrorActionPreference = 'Stop'

$repo  = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $repo 'Tests\FpcCoreTests\svg'

$fromRoot = @('SvgDataProbe', 'SvgListProbe', 'SvgLfmProbe', 'ImgCollProbe', 'RasterProbe')
$results = @()

Push-Location $repo
try {
    foreach ($n in $fromRoot) {
        $exe = Get-ChildItem -Path $repo -Filter "$n.exe" -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if (-not $exe) { $results += [pscustomobject]@{ Probe = $n; Code = -1; Note = 'not built' }; continue }
        $out = & $exe.FullName 2>&1 | Out-String
        $results += [pscustomobject]@{ Probe = $n; Code = $LASTEXITCODE
                                      Note = (($out.TrimEnd() -split "`n")[-1]).Trim() }
    }
} finally { Pop-Location }

Push-Location $probe
try {
    foreach ($n in @('SvgNorm')) {
        $out = & ".\$n.exe" 2>&1 | Out-String
        $results += [pscustomobject]@{ Probe = $n; Code = $LASTEXITCODE
                                      Note = (($out.TrimEnd() -split "`n")[-1]).Trim() }
    }
    foreach ($n in @('SvgParse', 'SvgTry')) {
        $out = & ".\$n.exe" zerochord 2>&1 | Out-String
        $results += [pscustomobject]@{ Probe = $n; Code = $LASTEXITCODE
                                      Note = (($out.TrimEnd() -split "`n")[-1]).Trim() }
    }
} finally { Pop-Location }

$results | Format-Table -AutoSize

$bad = @($results | Where-Object { $_.Code -ne 0 })
if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "FAIL: $($bad.Count) probe(s) did not exit 0: $($bad.Probe -join ', ')"
    exit 1
}
Write-Host ""
Write-Host "All $($results.Count) SVG probes passed."