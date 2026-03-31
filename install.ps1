param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ForwardArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoOwner = '962412311'
$repoName = 'wsl-codex-bootstrap'
$refApi = "https://api.github.com/repos/$repoOwner/$repoName/git/ref/heads/main"
$tempScript = Join-Path $env:TEMP 'install-wsl-codex.ps1'

try {
    $headers = @{ 'User-Agent' = 'wsl-codex-bootstrap-installer' }
    $refInfo = Invoke-RestMethod -Uri $refApi -Headers $headers -ErrorAction Stop
    $commitSha = [string]$refInfo.object.sha
    if ([string]::IsNullOrWhiteSpace($commitSha)) {
        throw 'Failed to resolve the latest installer commit from GitHub.'
    }

    $scriptUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$commitSha/install-wsl-codex.ps1"
    (New-Object System.Net.WebClient).DownloadFile($scriptUrl, $tempScript)

    $installerArgs = @('-BootstrapRef', $commitSha)
    if ($ForwardArgs.Count -gt 0) {
        $installerArgs += $ForwardArgs
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScript @installerArgs

    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
