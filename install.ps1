param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ForwardArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoOwner = '962412311'
$repoName = 'wsl-codex-bootstrap'
$tempScript = Join-Path $env:TEMP 'install-wsl-codex.ps1'
$tempLinuxScript = Join-Path $env:TEMP 'install-linux-codex.sh'

try {
    $scriptUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/7f8e126810ee6d97c22115654d5bc5f8f9edf5d5/install-wsl-codex.ps1"
    $linuxScriptUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/7f8e126810ee6d97c22115654d5bc5f8f9edf5d5/install-linux-codex.sh"
    (New-Object System.Net.WebClient).DownloadFile($scriptUrl, $tempScript)
    (New-Object System.Net.WebClient).DownloadFile($linuxScriptUrl, $tempLinuxScript)

    $installerArgs = @()
    if ($ForwardArgs.Count -gt 0) {
        $installerArgs += $ForwardArgs
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScript @installerArgs

    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempLinuxScript -Force -ErrorAction SilentlyContinue
}
