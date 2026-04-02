param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ForwardArgs
)

# Version: 1.0.4
# Update this version every time this script changes.
$ScriptVersion = '1.0.4'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoOwner = '962412311'
$repoName = 'wsl-codex-bootstrap'
$bootstrapRef = 'main'
$tempScript = Join-Path $env:TEMP 'install-wsl-codex.ps1'
$tempLinuxScript = Join-Path $env:TEMP 'install-linux-codex.sh'

Write-Host "[INFO] install.ps1 version $ScriptVersion" -ForegroundColor Gray
# Test edit: no functional change. apply_patch works.

try {
     $scriptUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$bootstrapRef/install-wsl-codex.ps1"
     $linuxScriptUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$bootstrapRef/install-linux-codex.sh"
    (New-Object System.Net.WebClient).DownloadFile($scriptUrl, $tempScript)
    (New-Object System.Net.WebClient).DownloadFile($linuxScriptUrl, $tempLinuxScript)

    $installerArgs = @()
    if (@($ForwardArgs).Count -gt 0) {
        $installerArgs += $ForwardArgs
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScript -BootstrapRef $bootstrapRef -AutoConfirm -NoAutoLaunchCodex @installerArgs

    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempLinuxScript -Force -ErrorAction SilentlyContinue
}
