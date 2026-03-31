param(
    [string]$Distro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UbuntuRootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
$MinimumFreeSpaceBytes = 20GB

function Write-Section {
    param([string]$Text)
    Write-Host "`n==== $Text ====" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-WarnEx {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[FAIL] $Text" -ForegroundColor Red
}

function Confirm-Yes {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { ' [Y/n]' } else { ' [y/N]' }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }
    return $answer.Trim().ToLowerInvariant() -in @('y', 'yes')
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-External {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure,
        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
        if (-not $AllowFailure -and $code -ne 0) {
            $message = ($output | Out-String).Trim()
            throw ("Command failed: {0} {1}`n{2}" -f $FilePath, ($ArgumentList -join ' '), $message)
        }
        return [pscustomobject]@{ Output = $output; ExitCode = $code }
    }

    & $FilePath @ArgumentList
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw ("Command failed: {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    }
    return [pscustomobject]@{ ExitCode = $code }
}

function Invoke-ExternalUnicode {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure
    )

    $stdout = New-TemporaryFile
    $stderr = New-TemporaryFile
    try {
        $argumentString = ($ArgumentList | ForEach-Object {
            if ($_ -match '\s') {
                '"' + ($_ -replace '"', '\"') + '"'
            }
            else {
                $_
            }
        }) -join ' '

        $process = Start-Process -FilePath $FilePath -ArgumentList $argumentString -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout.FullName -RedirectStandardError $stderr.FullName
        $outputBytes = [System.IO.File]::ReadAllBytes($stdout.FullName)
        $errorBytes = [System.IO.File]::ReadAllBytes($stderr.FullName)
        $outputText = [System.Text.Encoding]::Unicode.GetString($outputBytes)
        $errorText = [System.Text.Encoding]::Unicode.GetString($errorBytes)
        $combined = @()
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            $combined += ($outputText -split "`r?`n")
        }
        if (-not [string]::IsNullOrWhiteSpace($errorText)) {
            $combined += ($errorText -split "`r?`n")
        }

        if (-not $AllowFailure -and $process.ExitCode -ne 0) {
            throw ("Command failed: {0} {1}`n{2}" -f $FilePath, $argumentString, ($combined | Out-String))
        }

        return [pscustomobject]@{
            Output   = $combined
            Text     = $outputText
            Error    = $errorText
            ExitCode = $process.ExitCode
        }
    }
    finally {
        Remove-Item -LiteralPath $stdout.FullName, $stderr.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Convert-ToWslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match '^[A-Za-z]:\\') {
        $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
        $rest = $fullPath.Substring(2).Replace('\', '/')
        return "/mnt/$drive$rest"
    }

    throw "无法转换路径为 WSL 格式：$WindowsPath"
}

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildText = $cv.CurrentBuildNumber
    if ([string]::IsNullOrWhiteSpace([string]$buildText)) {
        $buildText = $cv.CurrentBuild
    }
    $build = [int]$buildText
    $productName = [string]$cv.ProductName
    if ($build -ge 22000 -and $productName.StartsWith('Windows 10')) {
        $productName = 'Windows 11' + $productName.Substring('Windows 10'.Length)
    }
    elseif ($build -lt 22000 -and $productName.StartsWith('Windows 11')) {
        $productName = 'Windows 10' + $productName.Substring('Windows 11'.Length)
    }
    if ([string]::IsNullOrWhiteSpace($productName)) {
        $productName = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    }

    [pscustomobject]@{
        ProductName    = $productName
        CurrentBuild   = $build
        DisplayVersion = $cv.DisplayVersion
    }
}

function Get-WslVersionSummary {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--version') -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-WslVersionValues {
    param([string[]]$Lines)

    foreach ($line in @($Lines)) {
        if ($line -match '^(?:WSL version|WSL 版本|Kernel version|Kernel 版本|WSLg version|WSLg 版本|MSRDC version|MSRDC 版本|Direct3D version|Direct3D 版本|DXCore version|DXCore 版本)\s*:\s*(?<version>[0-9]+(?:\.[0-9]+){1,3}(?:[-+][^ ]+)?)\s*$') {
            $Matches.version
        }
    }
}

function Get-WslStatusSummary {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--status') -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-WslInstalledVersion {
    $lines = Get-WslVersionSummary
    foreach ($line in $lines) {
        if ($line -match '^(?:WSL version|WSL 版本)\s*:\s*(?<version>[0-9]+(?:\.[0-9]+){1,3})\s*$') {
            return $Matches.version
        }
    }
    return $null
}

function Convert-ToWslVersionObject {
    param([Parameter(Mandatory)][string]$VersionText)

    $clean = $VersionText.Trim().TrimStart('v', 'V')
    if ($clean -match '^[0-9]+\.[0-9]+\.[0-9]+$') {
        $clean += '.0'
    }

    try {
        return [version]$clean
    }
    catch {
        return $null
    }
}

function Get-LatestWslVersion {
    try {
        $release = Invoke-WebRequest -Uri 'https://github.com/microsoft/WSL/releases/latest' -Headers @{ 'User-Agent' = 'wsl-ubuntu-bootstrap' } -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop

        $releaseUri = $null
        if ($release.BaseResponse -and $release.BaseResponse.ResponseUri) {
            $releaseUri = [string]$release.BaseResponse.ResponseUri.AbsoluteUri
        }
        elseif ($release.Headers -and $release.Headers.Location) {
            $releaseUri = [string]$release.Headers.Location
        }

        if (-not [string]::IsNullOrWhiteSpace($releaseUri) -and $releaseUri -match '/microsoft/WSL/releases/tag/(?<tag>[^/?#]+)') {
            return $Matches.tag.Trim().TrimStart('v', 'V')
        }
    }
    catch {
        return $null
    }

    return $null
}

function Test-WslVersionIsLatest {
    param(
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$LatestVersion
    )

    $currentObject = Convert-ToWslVersionObject -VersionText $CurrentVersion
    $latestObject = Convert-ToWslVersionObject -VersionText $LatestVersion
    if ($null -eq $currentObject -or $null -eq $latestObject) {
        return $false
    }

    return ($currentObject -ge $latestObject)
}

function Get-InstalledDistros {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DistroVersionMap {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -AllowFailure
    $map = @{}
    if ($result.ExitCode -ne 0) { return $map }
    foreach ($line in ($result.Text -split "`r?`n")) {
        $text = $line.Trim()
        if (-not $text -or $text -match '^(NAME|Windows)') { continue }
        $clean = $text.TrimStart('*').Trim()
        if ($clean -match '^(?<name>.+?)\s+(?<state>Running|Stopped|Installing|Unregistering|Converting)\s+(?<version>\d+)\s*$') {
            $map[$Matches.name.Trim()] = $Matches.version.Trim()
            continue
        }
        $parts = $clean -split '\s{2,}'
        if ($parts.Count -ge 2) {
            $map[$parts[0].Trim()] = $parts[-1].Trim()
        }
    }
    return $map
}

function Get-DefaultDistro {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -AllowFailure
    if ($result.ExitCode -ne 0) { return $null }

    foreach ($line in ($result.Text -split "`r?`n")) {
        $text = $line.Trim()
        if ($text -match '^\*\s*(.+?)\s{2,}') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Invoke-WslBash {
    param(
        [Parameter(Mandatory)]
        [string]$TargetDistro,
        [string]$User,
        [Parameter(Mandatory)]
        [string]$Command,
        [switch]$AllowFailure,
        [switch]$CaptureOutput
    )

    $tempScript = New-TemporaryFile
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempScript.FullName, $Command, $utf8NoBom)
        $tempScriptPath = Convert-ToWslPath -WindowsPath $tempScript.FullName

        $args = @('-d', $TargetDistro)
        if ($User) {
            $args += @('-u', $User)
        }
        $args += @('--', 'bash', $tempScriptPath)
        return Invoke-External -FilePath 'wsl.exe' -ArgumentList $args -AllowFailure:$AllowFailure -CaptureOutput:$CaptureOutput
    }
    finally {
        Remove-Item -LiteralPath $tempScript.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Test-UbuntuReady {
    param([string]$TargetDistro)

    $script = @'
set -euo pipefail
users="$(awk -F: '$3 >= 1000 && $1 != "nobody" { print $1 }' /etc/passwd | head -n 1 || true)"
if [ -n "$users" ]; then
  printf '__READY__:%s\n' "$users"
fi
'@

    $result = Invoke-WslBash -TargetDistro $TargetDistro -User 'root' -Command $script -AllowFailure -CaptureOutput
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Ready = $false; User = $null }
    }

    $text = ($result.Output | Out-String).Trim()
    if ($text -match '__READY__:(?<user>[^\s]+)') {
        return [pscustomobject]@{ Ready = $true; User = $Matches.user.Trim() }
    }

    return [pscustomobject]@{ Ready = $false; User = $null }
}

function Get-FreeSpaceBytes {
    param([Parameter(Mandatory)][ValidatePattern('^[DEde]$')][string]$DriveLetter)

    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($DriveLetter.ToUpperInvariant()):'"
    if ($null -eq $disk) {
        return $null
    }
    return [int64]$disk.FreeSpace
}

function Prompt-InstallDrive {
    while ($true) {
        $drive = Read-Host '请选择 Ubuntu 安装盘符（仅支持 D 或 E）'
        if ([string]::IsNullOrWhiteSpace($drive)) {
            Write-WarnEx '盘符不能为空，请输入 D 或 E。'
            continue
        }

        $drive = $drive.Trim().TrimEnd(':').ToUpperInvariant()
        if ($drive -notin @('D', 'E')) {
            Write-WarnEx '只支持 D 或 E 盘，请重新输入。'
            continue
        }

        $space = Get-FreeSpaceBytes -DriveLetter $drive
        if ($null -eq $space) {
            Write-WarnEx "无法读取 $drive 盘的可用空间，请重新选择。"
            continue
        }

        if ($space -lt $MinimumFreeSpaceBytes) {
            $freeGiB = [math]::Round($space / 1GB, 1)
            $needGiB = [math]::Round($MinimumFreeSpaceBytes / 1GB, 1)
            Write-WarnEx "$drive 盘可用空间只有 $freeGiB GB，少于最低要求 $needGiB GB。请重新选择。"
            continue
        }

        return [pscustomobject]@{
            DriveLetter = $drive
            FreeBytes   = $space
        }
    }
}

function Get-UbuntuInstallPath {
    param([Parameter(Mandatory)][string]$DriveLetter)
    return Join-Path "${DriveLetter}:\" 'WSL\Ubuntu'
}

function Ensure-UbuntuImported {
    param([string]$TargetDistro)

    $installed = Get-InstalledDistros
    if ($installed -contains $TargetDistro) {
        Write-Ok "$TargetDistro 已经安装。"
        return
    }

    Write-Section "安装 Ubuntu：$TargetDistro"
    Write-Info "将使用官方 Ubuntu WSL 根文件系统：$UbuntuRootfsUrl"
    if (-not (Confirm-Yes "是否现在继续安装 $TargetDistro？")) {
        throw '用户已取消。'
    }

    $target = Prompt-InstallDrive
    $installPath = Get-UbuntuInstallPath -DriveLetter $target.DriveLetter

    if (Test-Path $installPath) {
        $existing = Get-ChildItem -LiteralPath $installPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.Count -gt 0) {
            Write-WarnEx "目标目录已存在且不为空：$installPath"
            Write-WarnEx '请清空该目录后重新运行脚本，或选择其他盘符。'
            exit 1
        }
    }
    else {
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    }

    $tempTarball = Join-Path $installPath 'ubuntu-rootfs.tar.gz'
    Write-Info ("可用空间满足要求：{0:N1} GB" -f ($target.FreeBytes / 1GB))
    Write-Info "将把 Ubuntu 安装到：$installPath"
    Write-Info '正在下载 Ubuntu 根文件系统...'
    Invoke-WebRequest -Uri $UbuntuRootfsUrl -UseBasicParsing -OutFile $tempTarball

    Write-Info '正在导入 Ubuntu 到指定磁盘...'
    Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--import', $TargetDistro, $installPath, $tempTarball, '--version', '2') | Out-Null
    Remove-Item -LiteralPath $tempTarball -Force -ErrorAction SilentlyContinue
    Write-Ok "$TargetDistro 已导入到 $installPath。"
    Write-WarnEx '如果这是第一次安装，请重新运行脚本继续完成默认发行版和初始设置。'
}

function Ensure-WslVersion {
    Write-Section '更新 WSL 引擎'
    $versionLines = Get-WslVersionSummary
    $versionValues = @(Get-WslVersionValues -Lines $versionLines)
    if ($versionValues.Count -gt 0) {
        foreach ($version in $versionValues) {
            Write-Info "  $version"
        }
    }

    $currentVersion = Get-WslInstalledVersion
    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        Write-WarnEx '无法读取当前 WSL 版本，跳过更新。'
        return
    }

    $latestVersion = Get-LatestWslVersion
    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        Write-WarnEx '无法读取最新 WSL 版本，跳过更新。'
        return
    }

    if (Test-WslVersionIsLatest -CurrentVersion $currentVersion -LatestVersion $latestVersion) {
        Write-Ok 'WSL 已经是最新版本，跳过更新。'
        return
    }

    Write-WarnEx "检测到 WSL 不是最新版本，目标版本为 $latestVersion。"
    if (-not (Confirm-Yes "是否现在更新 WSL 到 $latestVersion？")) {
        Write-Info '已跳过 WSL 更新。'
        return
    }

    $updateResult = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--update', '--web-download') -AllowFailure
    if ($updateResult.ExitCode -eq 0) {
        Write-Ok 'WSL 引擎更新完成。'
        $updatedVersion = Get-WslInstalledVersion
        if (-not [string]::IsNullOrWhiteSpace($updatedVersion)) {
            Write-Info "  $updatedVersion"
        }
        return
    }

    $updateText = (($updateResult.Output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($updateText)) {
        Write-WarnEx 'WSL 引擎更新失败。'
        return
    }

    Write-WarnEx 'WSL 引擎更新失败。'
    foreach ($line in ($updateText -split "`r?`n")) {
        $clean = $line.Trim()
        if ($clean) {
            Write-WarnEx "  $clean"
        }
    }
}

function Ensure-UbuntuDefaultAndInitialized {
    param([string]$TargetDistro)

    Write-Section '确保默认发行版'
    $defaultDistro = Get-DefaultDistro
    if ($defaultDistro -eq $TargetDistro) {
        Write-Ok "$TargetDistro 已经是默认 WSL 发行版，直接运行 `wsl` 就会进入 Ubuntu。"
    }
    elseif ([string]::IsNullOrWhiteSpace($defaultDistro)) {
        Write-WarnEx '无法读取当前默认 WSL 发行版。'
        if (Confirm-Yes "是否将 $TargetDistro 设为默认 WSL 发行版？") {
            Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--set-default', $TargetDistro) | Out-Null
            Write-Ok "$TargetDistro 已设为默认 WSL 发行版，直接运行 `wsl` 就会进入 Ubuntu。"
        }
        else {
            Write-Info '已跳过默认发行版设置。'
        }
    }
    else {
        Write-Info "当前默认发行版是：$defaultDistro"
        if (Confirm-Yes "是否将 $TargetDistro 设为默认 WSL 发行版？") {
            Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--set-default', $TargetDistro) | Out-Null
            Write-Ok "$TargetDistro 已设为默认 WSL 发行版，直接运行 `wsl` 就会进入 Ubuntu。"
        }
        else {
            Write-Info '已跳过默认发行版设置。'
        }
    }

    Write-Section '检查发行版初始设置'
    $ready = Test-UbuntuReady -TargetDistro $TargetDistro
    if ($ready.Ready) {
        Write-Ok "$TargetDistro 已完成初始设置。"
        Write-Info "检测到的 Linux 用户：$($ready.User)"
        return
    }

    Write-WarnEx "$TargetDistro 还未完成首次初始化。"
    Write-WarnEx '稍后会打开交互式 Ubuntu 窗口，请在里面创建 Linux 用户，然后输入 exit 返回。'
    & wsl.exe -d $TargetDistro

    $ready = Test-UbuntuReady -TargetDistro $TargetDistro
    if (-not $ready.Ready) {
        Write-Fail "$TargetDistro 仍未完成初始设置。请直接运行 `wsl` 完成 Linux 用户创建后重新运行脚本。"
        exit 1
    }

    Write-Ok "$TargetDistro 首次初始化已完成。"
    Write-Info "检测到的 Linux 用户：$($ready.User)"
}

function Test-WslCommandAvailable {
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        return $true
    }

    return (Test-Path (Join-Path $env:WINDIR 'System32\wsl.exe'))
}

function Main {
    Write-Section 'Windows 主机检查'
    if (-not (Test-IsAdmin)) {
        throw '请以管理员身份运行此脚本。'
    }

    $os = Get-OsInfo
    Write-Info "Windows：$($os.ProductName)（Build $($os.CurrentBuild)）"

    if (-not (Test-WslCommandAvailable)) {
        throw '当前系统找不到 wsl.exe。请先启用 WSL 或确认系统 PATH。'
    }

    Ensure-WslVersion
    Ensure-UbuntuImported -TargetDistro $Distro
    Ensure-UbuntuDefaultAndInitialized -TargetDistro $Distro

    Write-Section '完成'
    Write-Ok 'Ubuntu 已安装、已设为默认发行版，并完成初始设置。'
    Write-Info '现在直接执行 `wsl` 就会进入 Ubuntu。'
}

try {
    Main
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
