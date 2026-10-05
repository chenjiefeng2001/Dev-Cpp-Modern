#!/usr/bin/env pwsh
# f3_lazarus_setup.ps1 -- install the F3 toolchain, or say precisely why it cannot.
#
# WHY A SCRIPT AND NOT A MANUAL STEP
# ==================================
# F3's remaining risk is LFM deserialisation: text analysis cannot tell whether
# a converted form actually loads, because the failures that matter
# (`Property X does not exist`, mis-placed Anchor ratios) only appear when the
# LCL runtime streams the file. That needs a real Lazarus.
#
# So this script exists to make the step reproducible and, when it fails, to say
# WHY -- which is not something "download failed" ever told us.
#
# MEASURED IN THIS ENVIRONMENT (2026-10-04)
# ==========================================
# Every mirror of the installer was tried and none served binary content:
#
#   * sourceforge.net/.../download        -> 200 but text/html (an interstitial)
#   * *.dl.sourceforge.net (10 mirrors)  -> 200 but text/html
#   * the same URLs via curl.exe           -> text/html as well
#   * ftp.freepascal.org                  -> TLS handshake refused by the proxy
#   * api.github.com FPCSource/releases   -> reachable, but publishes no Windows
#                                           installer
#
# SourceForge serves binaries only after a browser-side interstitial, so any
# non-browser fetch lands on the HTML page. That is a network policy here, not a
# broken URL, and it is why this script does not simply retry harder.
#
# WHAT TO DO WHEN IT SUCCEEDS
# ===========================
# Run with -Install, then verify `lazbuild --version` and `fpc -iV`. The F3
# pipeline (f3_dfm_to_lfm.py) is written to work against whatever lazbuild is on
# PATH, so nothing else needs to change.
#
# If the download is blocked, the honest options are (a) fetch the installer on
# another machine and copy it here, or (b) push the conversion to CI, which
# already installs Lazarus via gcarreno/setup-lazarus. Neither is a workaround
# for a missing measurement -- the measurement is what F3 is waiting on.

[CmdletBinding()]
param(
    [string]$Installer = "$env:TEMP\lazarus-4.4.0-win64.exe",
    [string]$InstallDir = "$env:ProgramFiles\Lazarus",
    # CI pins this. A local box on a different version would convert forms the
    # CI then rejects, or worse, the reverse -- so the pin is not advisory.
    [string]$Version = "4.4"
)

$ErrorActionPreference = 'Stop'
function Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "    ok   $m" }
function Note { param($m) Write-Host "    note $m" -ForegroundColor Yellow }

Step "is Lazarus already usable?"
if (Get-Command lazbuild -ErrorAction SilentlyContinue) {
    Ok "lazbuild on PATH: $((Get-Command lazbuild).Source)"
    & lazbuild --version
    exit 0
}
Note "not found on PATH"

Step "attempting the installer download (Lazarus $Version, win64)"
$url = "https://downloads.sourceforge.net/project/lazarus/Lazarus%20Windows%2064%20bits/Lazarus%20$Version/lazarus-$Version.0-win64.exe"
try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $Installer -TimeoutSec 900
} catch {
    Note "download failed: $($_.Exception.Message)"
}

if (Test-Path $Installer) {
    $head = [System.IO.File]::ReadAllBytes($Installer)[0..1]
    $isPe = $head[0] -eq 0x4D -and $head[1] -eq 0x5A   # 'MZ'
    if (-not $isPe) {
        # Verified here: the response is a text/html interstitial, not a broken
        # download. Retrying will not change it.
        throw @"
Installer at $Installer is not a PE executable (first bytes: $($head -join ',')).
SourceForge is serving an HTML interstitial to non-browser clients in this
environment. Retry from a browser, or copy the installer here from a machine that
can fetch it, then re-run this script.
"@
    }
    Ok "installer fetched ($([math]::Round((Get-Item $Installer).Length/1MB,1)) MB)"

    Step "running the installer silently to $InstallDir"
    # NSIS: /S silent, /D must be last and unquoted.
    $p = Start-Process -FilePath $Installer -ArgumentList "/S", "/D=$InstallDir" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "installer exited $($p.ExitCode)" }
} else {
    throw "no installer at $Installer and the download did not produce one."
}

Step "verifying"
$lazbuild = Join-Path $InstallDir 'lazbuild.exe'
if (-not (Test-Path $lazbuild)) { throw "lazbuild.exe not found under $InstallDir" }
$env:PATH = "$InstallDir;$env:PATH"
Ok "lazbuild --version -> $(& $lazbuild --version)"
Ok "fpc -iV -> $((& fpc -iV) -join ' / ')"
Write-Host "LAZARUS READY" -ForegroundColor Green
exit 0