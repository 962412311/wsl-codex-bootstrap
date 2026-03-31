param(
    [string]$Distro = "Ubuntu",
    [switch]$InstallBubblewrap,
    [switch]$SkipAptUpgrade,
    [switch]$NoAutoLaunchCodex,
    [switch]$SkipHostChecks,
    [string]$SkillsSourceConfigPath,
    [string]$SkillsManifestPath,
    [string]$SkillsManifestUrl,
    [string]$BootstrapRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSCommandPath
$DefaultSkillsManifestUrl = 'https://raw.githubusercontent.com/962412311/codex-skills-pack/main/skills.manifest.json'
$BootstrapRepoOwner = '962412311'
$BootstrapRepoName = 'wsl-codex-bootstrap'
$LinuxInstallerFileName = 'install-linux-codex.sh'
$LinuxInstallerLocalPath = Join-Path $ScriptRoot $LinuxInstallerFileName
$script:ResolvedLinuxInstallerPath = $null
$ConfigPath = if ([string]::IsNullOrWhiteSpace($SkillsSourceConfigPath)) {
    Join-Path $ScriptRoot 'skills-source.json'
}
else {
    $SkillsSourceConfigPath
}

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

function Confirm-ManualStep {
    param([Parameter(Mandatory)][string]$Action)

    if (-not (Confirm-Yes $Action)) {
        throw '用户已取消。'
    }
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
            $message = "Command failed: {0} {1}`n{2}" -f $FilePath, ($ArgumentList -join ' '), ($output | Out-String)
            throw $message
        }
        return [pscustomobject]@{ Output = $output; ExitCode = $code }
    }

    & $FilePath @ArgumentList
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        $message = "Command failed: {0} {1}" -f $FilePath, ($ArgumentList -join ' ')
        throw $message
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
            $message = "Command failed: {0} {1}`n{2}" -f $FilePath, $argumentString, ($combined | Out-String)
            throw $message
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

    throw "Failed to convert path to WSL format: $WindowsPath"
}

function Get-LinuxInstallerPath {
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedLinuxInstallerPath) -and (Test-Path $script:ResolvedLinuxInstallerPath)) {
        return $script:ResolvedLinuxInstallerPath
    }

    if (Test-Path $LinuxInstallerLocalPath) {
        $script:ResolvedLinuxInstallerPath = $LinuxInstallerLocalPath
        return $script:ResolvedLinuxInstallerPath
    }

    $ref = if ([string]::IsNullOrWhiteSpace($BootstrapRef)) { 'main' } else { $BootstrapRef }
    $url = "https://raw.githubusercontent.com/$BootstrapRepoOwner/$BootstrapRepoName/$ref/$LinuxInstallerFileName"
    $tempPath = Join-Path $env:TEMP $LinuxInstallerFileName
    Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $tempPath
    $script:ResolvedLinuxInstallerPath = $tempPath
    return $script:ResolvedLinuxInstallerPath
}

function Invoke-LinuxInstaller {
    param(
        [Parameter(Mandatory)][string]$TargetDistro,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$User = 'root',
        [switch]$AllowFailure,
        [switch]$CaptureOutput
    )

    $installerPath = Get-LinuxInstallerPath
    $wslInstallerPath = Convert-ToWslPath -WindowsPath $installerPath
    $args = @('-d', $TargetDistro)
    if (-not [string]::IsNullOrWhiteSpace($User)) {
        $args += @('-u', $User)
    }
    $args += @('--', 'bash', $wslInstallerPath, $Command)
    if ($Arguments.Count -gt 0) {
        $args += $Arguments
    }

    return Invoke-External -FilePath 'wsl.exe' -ArgumentList $args -AllowFailure:$AllowFailure -CaptureOutput:$CaptureOutput
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

function Register-ResumeSelf {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-WarnEx '无法注册 RunOnce：脚本不是从文件路径运行的。'
        return
    }

    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path $runOncePath)) {
        New-Item -Path $runOncePath -Force | Out-Null
    }

    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($InstallBubblewrap) { $cmd += ' -InstallBubblewrap' }
    if ($SkipAptUpgrade) { $cmd += ' -SkipAptUpgrade' }
    if ($NoAutoLaunchCodex) { $cmd += ' -NoAutoLaunchCodex' }
    if ($Distro -ne 'Ubuntu') { $cmd += " -Distro `"$Distro`"" }

    Set-ItemProperty -Path $runOncePath -Name 'InstallWslCodexResume' -Value $cmd -Force
    Write-Ok '已注册 RunOnce 恢复项。'
}

function Get-WslHelpText {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--help') -AllowFailure
    return $result.Text
}

function Test-WslInstallSupported {
    try {
        $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--version') -AllowFailure
        return ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Text))
    }
    catch {
        return $false
    }
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

function Get-WslVersionSummary {
    $result = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--version') -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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
        $release = Invoke-WebRequest -Uri 'https://github.com/microsoft/WSL/releases/latest' -Headers @{ 'User-Agent' = 'wsl-codex-bootstrap' } -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop

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

function Test-Wsl2Prerequisites {
    $reasons = @()

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -ErrorAction Stop
        if ($feature.State -ne 'Enabled') {
            $reasons += 'Virtual Machine Platform 未启用'
        }
    }
    catch {
        $reasons += '无法读取 Virtual Machine Platform 状态'
    }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $cpu -and $null -ne $cpu.VirtualizationFirmwareEnabled -and -not $cpu.VirtualizationFirmwareEnabled) {
            $reasons += 'BIOS/UEFI 虚拟化未开启'
        }
    }
    catch {
        # If the firmware check is unavailable, keep the feature-state result.
    }

    [pscustomobject]@{
        Ready   = ($reasons.Count -eq 0)
        Reasons = $reasons
    }
}

function Ensure-DistroInstalled {
    param([string]$TargetDistro)

    $distros = Get-InstalledDistros
    if ($distros -contains $TargetDistro) {
        Write-Ok "$TargetDistro 已经安装。"
        return
    }

    Write-Section "安装 WSL 发行版：$TargetDistro"
    Write-Info '这会执行 `wsl --install -d <Distro>`，通常需要重启。'
    Confirm-ManualStep "是否现在安装 $TargetDistro 并继续？"
    Register-ResumeSelf
    Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $TargetDistro)
    Write-WarnEx '已发出 WSL 安装命令。请现在重启 Windows 继续。'
    if (Confirm-Yes '是否现在重启？') {
        Restart-Computer -Force
    }
    else {
        Write-WarnEx '请手动重启后重新运行脚本。'
    }
    exit 0
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

function Ensure-DistroInitialized {
    param([string]$TargetDistro)

    Write-Section '检查发行版初始设置'
    try {
        $linuxUser = Get-NonRootLinuxUser -TargetDistro $TargetDistro
        if (-not [string]::IsNullOrWhiteSpace($linuxUser)) {
            Write-Ok "$TargetDistro 已就绪。"
            Write-Info "检测到的 Linux 用户：$linuxUser"
            return
        }
    }
    catch {
        # If no non-root user exists yet, continue to the interactive setup prompt below.
    }

    Write-WarnEx "$TargetDistro 还未完成首次初始化。"
    Write-WarnEx '稍后会打开交互式 WSL 窗口，请在里面创建一个普通 Linux 用户，然后输入 exit 返回。'
    & wsl.exe -d $TargetDistro

    try {
        $linuxUser = Get-NonRootLinuxUser -TargetDistro $TargetDistro
        if (-not [string]::IsNullOrWhiteSpace($linuxUser)) {
            Write-Ok "$TargetDistro 首次初始化已完成。"
            Write-Info "检测到的 Linux 用户：$linuxUser"
            return
        }
    }
    catch {
        # Fall through to the explicit failure below.
    }

    Write-Fail "$TargetDistro 仍未检测到可用的普通 Linux 用户。请手动运行 `wsl -d $TargetDistro` 创建用户后重新运行脚本。"
    exit 1
}

function Get-WslRegistryInfo {
    param([string]$TargetDistro)

    $baseKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $baseKey)) {
        return $null
    }

    foreach ($key in Get-ChildItem -Path $baseKey -ErrorAction SilentlyContinue) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $props) {
            continue
        }
        if ([string]::Equals([string]$props.DistributionName, $TargetDistro, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $props
        }
    }

    return $null
}

function Parse-LinuxUserFromOutput {
    param([object[]]$Output)

    $lines = @($Output | ForEach-Object {
        $text = [string]$_
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $text.Trim()
        }
    } | Where-Object { $_ })
    return @(
        $lines | Where-Object {
            $_ -match '^[A-Za-z_][A-Za-z0-9_.-]*[$]?$'
        }
    ) | Select-Object -Last 1
}

function Resolve-LinuxUserByCommand {
    param(
        [string]$TargetDistro,
        [string[]]$Command,
        [string]$RunAsUser
    )

    $args = @('-d', $TargetDistro)
    if (-not [string]::IsNullOrWhiteSpace($RunAsUser)) {
        $args += @('-u', $RunAsUser)
    }
    $args += @('--') + $Command

    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList $args -AllowFailure -CaptureOutput
    $userLine = Parse-LinuxUserFromOutput -Output $result.Output
    if (-not [string]::IsNullOrWhiteSpace($userLine)) {
        return $userLine
    }

    return $null
}

function Get-DefaultLinuxUser {
    param([string]$TargetDistro)

    $registryInfo = Get-WslRegistryInfo -TargetDistro $TargetDistro
    if ($null -ne $registryInfo) {
        $defaultUid = 0
        try {
            $defaultUid = [int64]$registryInfo.DefaultUid
        }
        catch {
            $defaultUid = -1
        }

        if ($defaultUid -eq 0) {
            return 'root'
        }

        if ($defaultUid -gt 0) {
            $userFromUid = Resolve-LinuxUserByCommand -TargetDistro $TargetDistro -RunAsUser 'root' -Command @('sh', '-lc', "getent passwd $defaultUid 2>/dev/null | cut -d: -f1")
            if (-not [string]::IsNullOrWhiteSpace($userFromUid)) {
                return $userFromUid
            }
        }
    }

    $userLine = Resolve-LinuxUserByCommand -TargetDistro $TargetDistro -Command @('sh', '-lc', 'id -un 2>/dev/null || whoami 2>/dev/null')
    if (-not [string]::IsNullOrWhiteSpace($userLine)) {
        return $userLine
    }

    $regularUser = Resolve-LinuxUserByCommand -TargetDistro $TargetDistro -RunAsUser 'root' -Command @('sh', '-lc', 'while IFS=: read -r name _ uid _; do if [ "$uid" -ge 1000 ] && [ "$name" != "nobody" ]; then printf "%s\n" "$name"; break; fi; done < /etc/passwd 2>/dev/null')
    if (-not [string]::IsNullOrWhiteSpace($regularUser)) {
        return $regularUser
    }

    throw '无法确定默认 Linux 用户。'
}

function Get-NonRootLinuxUser {
    param([string]$TargetDistro)

    $user = Get-DefaultLinuxUser -TargetDistro $TargetDistro
    if (-not [string]::IsNullOrWhiteSpace($user) -and $user -ne 'root') {
        return $user
    }

    $regularUser = Resolve-LinuxUserByCommand -TargetDistro $TargetDistro -RunAsUser 'root' -Command @(
        'sh',
        '-lc',
        'awk -F: ''$3 >= 1000 && $1 != "nobody" && $1 != "root" { print $1; exit }'' /etc/passwd 2>/dev/null'
    )
    if (-not [string]::IsNullOrWhiteSpace($regularUser)) {
        return $regularUser
    }

    throw '未找到可用于 Codex 安装的非 root Linux 用户。'
}

function Ensure-WslVersion2 {
    param([string]$TargetDistro)

    Write-Section '确保 WSL 2'
    $map = Get-DistroVersionMap
    if ($map.ContainsKey($TargetDistro) -and $map[$TargetDistro] -eq '2') {
        Write-Ok "$TargetDistro 已经是 WSL 2，跳过切换。"
        return
    }

    $prereq = Test-Wsl2Prerequisites
    if (-not $prereq.Ready) {
        throw "$TargetDistro 暂不切换到 WSL 2：$($prereq.Reasons -join '；')。请先启用相关 Windows 功能和硬件虚拟化后再重新运行脚本。"
    }

    Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--set-default-version', '2') -AllowFailure | Out-Null
    $map = Get-DistroVersionMap
    if ($map.ContainsKey($TargetDistro) -and $map[$TargetDistro] -eq '2') {
        Write-Ok "$TargetDistro 已经是 WSL 2，跳过切换。"
        return
    }

    Write-Info "正在将 $TargetDistro 切换到 WSL 2..."
    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--set-version', $TargetDistro, '2') -AllowFailure -CaptureOutput
    if ($result.ExitCode -eq 0) {
        Write-Ok "$TargetDistro 已切换到 WSL 2。"
        return
    }

    $outputText = ($result.Output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($outputText -match 'WSL_E_VM_MODE_INVALID_STATE|VM mode invalid state') {
        Write-WarnEx "$TargetDistro 暂不支持切换到 WSL 2：当前虚拟化环境未就绪。"
        Write-WarnEx '请先在 BIOS/UEFI 中开启虚拟化，并在 Windows 中启用 Virtual Machine Platform 后重试。'
        return
    }

    Write-WarnEx "$TargetDistro 切换到 WSL 2 失败。"
    Write-WarnEx '请确认 Windows 已启用虚拟化，并重启后再试。'
}

function Update-WslEngine {
    Write-Section '更新 WSL 引擎'
    $versionLines = Get-WslVersionSummary
    if (@($versionLines).Count -gt 0) {
        foreach ($line in @($versionLines)) {
            Write-Info "  $line"
        }
    }

    $currentVersion = Get-WslInstalledVersion
    $latestVersion = Get-LatestWslVersion

    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        Write-Info '无法读取当前 WSL 版本，跳过更新。'
        return
    }

    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        Write-Info '无法读取最新 WSL 版本，跳过更新。'
        return
    }

    if (Test-WslVersionIsLatest -CurrentVersion $currentVersion -LatestVersion $latestVersion) {
        Write-Info 'WSL 已经是最新版本，跳过更新。'
        return
    }

    Write-Info "检测到 WSL 不是最新版本，准备更新到 $latestVersion。"
    if (-not (Confirm-Yes "是否现在更新 WSL 到 $latestVersion？")) {
        Write-Info '已跳过 WSL 更新。'
        return
    }

    $updateResult = Invoke-ExternalUnicode -FilePath 'wsl.exe' -ArgumentList @('--update', '--web-download') -AllowFailure
    if ($updateResult.ExitCode -eq 0) {
        Write-Ok 'WSL 引擎更新完成。'
        $updatedVersion = Get-WslInstalledVersion
        if (-not [string]::IsNullOrWhiteSpace($updatedVersion)) {
            Write-Info "更新后的 WSL 版本：$updatedVersion"
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

function Install-LinuxBasePackages {
    param([string]$TargetDistro)

    Write-Section '安装 Linux 基础包'
    $skipAptUpgradeFlag = if ($SkipAptUpgrade) { '1' } else { '0' }
    $installBubblewrapFlag = if ($InstallBubblewrap) { '1' } else { '0' }
    Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'install-base-packages' -Arguments @($skipAptUpgradeFlag, $installBubblewrapFlag) | Out-Null
    Write-Ok 'Linux 基础包已安装。'
}

function Install-NvmNodeAndCodex {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "为 $LinuxUser 安装 nvm / Node.js LTS / Codex"
    Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'install-node-codex' | Out-Null
    Write-Ok '已安装 nvm、Node.js LTS 和 Codex。'
}

function Install-CodexAutoUpdateWrapper {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "为 $LinuxUser 安装 Codex 自动更新包装器"
    Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'install-wrapper' | Out-Null
    Write-Ok '已安装 Codex 自动更新包装器。'
}

function Ensure-CodexDefaultModel {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "为 $LinuxUser 写入 Codex 默认模型"
    $result = Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'ensure-default-model' -CaptureOutput
    if ($result.ExitCode -ne 0) {
        throw '更新 Codex 默认模型失败。'
    }

    $statusText = (($result.Output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($statusText -eq 'UNCHANGED') {
        Write-Ok 'Codex 默认模型已是 gpt-5.4-mini，跳过写入。'
        return
    }

    if ($statusText -eq 'UPDATED') {
        Write-Ok '已将 Codex 默认模型设为 gpt-5.4-mini。'
        return
    }

    Write-Ok '已检查 Codex 默认模型。'
}

function Check-CodexSubscriptionStatus {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "检查 $LinuxUser 的 Codex 订阅状态"
    $result = Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'check-subscription-json' -CaptureOutput
    if ($result.ExitCode -ne 0) {
        Write-WarnEx '订阅检查失败，已跳过。'
        return
    }

    $jsonText = (($result.Output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        Write-WarnEx '未收到订阅检查结果，已跳过。'
        return
    }

    try {
        $payload = $jsonText | ConvertFrom-Json
    }
    catch {
        Write-WarnEx '订阅检查结果解析失败，已跳过。'
        return
    }

    switch ($payload.status) {
        'missing_auth' { Write-WarnEx '未找到 Codex 登录信息，跳过订阅检查。' }
        'read_error' { Write-WarnEx "无法读取 Codex 登录信息：$($payload.message)" }
        'not_chatgpt' { Write-Info '当前不是 ChatGPT 登录，跳过订阅检查。' }
        'no_expiry' { Write-WarnEx '未找到订阅到期时间，跳过检查。' }
        'parse_error' { Write-WarnEx "无法解析订阅到期时间：$($payload.subscription_until)" }
        'expired' { Write-WarnEx ("Codex 订阅已过期，到期时间：{0}。" -f $payload.expiry_iso) }
        'warning' {
            $days = [double]$payload.remaining_days
            Write-Info ("Codex 订阅还剩 {0:N1} 天，到期时间：{1}。" -f $days, $payload.expiry_iso)
        }
        'info' {
            $days = [double]$payload.remaining_days
            Write-Info ("Codex 订阅还剩 {0:N1} 天，到期时间：{1}。" -f $days, $payload.expiry_iso)
        }
        default {
            Write-WarnEx '订阅检查结果未知，已跳过。'
        }
    }
}

function Get-SkillManifest {
    $manifestPath = $null
    $manifestUrl = $null
    $usedDefaultManifestUrl = $false

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path $ConfigPath)) {
        $config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        if ($null -ne $config.skillsManifestPath -and -not [string]::IsNullOrWhiteSpace([string]$config.skillsManifestPath)) {
            $manifestPath = [string]$config.skillsManifestPath
        }
        if ($null -ne $config.skillsManifestUrl -and -not [string]::IsNullOrWhiteSpace([string]$config.skillsManifestUrl)) {
            $manifestUrl = [string]$config.skillsManifestUrl
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SkillsManifestPath)) {
        $manifestPath = $SkillsManifestPath
        $manifestUrl = $null
    }
    elseif (-not [string]::IsNullOrWhiteSpace($SkillsManifestUrl)) {
        $manifestUrl = $SkillsManifestUrl
        $manifestPath = $null
    }
    elseif ([string]::IsNullOrWhiteSpace($manifestPath) -and [string]::IsNullOrWhiteSpace($manifestUrl)) {
        $manifestUrl = $DefaultSkillsManifestUrl
        $usedDefaultManifestUrl = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
        if (-not [System.IO.Path]::IsPathRooted($manifestPath)) {
            $manifestPath = Join-Path $ScriptRoot $manifestPath
        }
        if (-not (Test-Path $manifestPath)) {
            Write-WarnEx "Configured skill manifest path was not found: $manifestPath"
            $manifestPath = $null
        }
        else {
            return (Get-Content -Raw -Path $manifestPath | ConvertFrom-Json)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($manifestUrl)) {
        $tempManifest = Join-Path $env:TEMP 'codex-skills.manifest.json'
        if ($usedDefaultManifestUrl) {
            Write-Info '未检测到 skills-source.json，已使用默认技能清单来源。'
        }
        Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -OutFile $tempManifest
        return (Get-Content -Raw -Path $tempManifest | ConvertFrom-Json)
    }

    throw '未配置技能清单来源。请设置 skills-source.json，或传入 -SkillsManifestPath / -SkillsManifestUrl。'
}

function ConvertTo-BashSingleQuoted {
    param([Parameter(Mandatory)][string]$Text)
    return "'" + ($Text -replace "'", "'\''") + "'"
}

function Resolve-SourceById {
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$SourceId
    )

    foreach ($source in @($Manifest.sources)) {
        if ($source.id -eq $SourceId) {
            return $source
        }
    }

    throw "Unknown sourceId in manifest: $SourceId"
}

function Install-CodexSkills {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    $manifest = Get-SkillManifest
    $skills = @($manifest.skills | Where-Object { $null -eq $_.enabled -or [bool]$_.enabled })
    if ($skills.Count -eq 0) {
        Write-WarnEx '技能清单为空，跳过技能安装。'
        return
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 32
    $tempManifest = New-TemporaryFile
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempManifest.FullName, $manifestJson, $utf8NoBom)
        $wslManifestPath = Convert-ToWslPath -WindowsPath $tempManifest.FullName
        Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'persist-manifest' -Arguments @($wslManifestPath) | Out-Null
        Invoke-LinuxInstaller -TargetDistro $TargetDistro -Command 'install-skills' | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $tempManifest.FullName -Force -ErrorAction SilentlyContinue
    }

    Write-Ok '已从上游仓库安装 Codex skills。'
}

function Launch-CodexInteractive {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    if ($NoAutoLaunchCodex) {
        return
    }

    if (-not (Confirm-Yes -Prompt '是否现在启动 Codex 进行首次登录？' -DefaultYes:$false)) {
        return
    }

    Check-CodexSubscriptionStatus -TargetDistro $TargetDistro -LinuxUser $LinuxUser

    Write-Section '启动 Codex'
    Write-Info '这会在 WSL 的 ~/code 目录中启动 `codex`。'
    $args = @('-d', $TargetDistro)
    if (-not [string]::IsNullOrWhiteSpace($LinuxUser)) {
        $args += @('-u', $LinuxUser)
    }
    $args += @('--', 'bash', '-lc', 'cd ~/code && "$HOME/.local/bin/codex"')
    & wsl.exe @args
}

try {
    Write-Section 'Windows 主机检查'

    if (-not $SkipHostChecks) {
        if (-not (Test-IsAdmin)) {
            throw '请在提升权限的 PowerShell 会话中运行此脚本。'
        }

        $os = Get-OsInfo
        Write-Info "Windows：$($os.ProductName) $($os.DisplayVersion)（Build $($os.CurrentBuild)）"

        if ($os.CurrentBuild -lt 19041) {
            throw '当前 Windows 版本过旧，无法可靠执行 WSL 2 引导。'
        }

        if (-not (Test-WslInstallSupported)) {
            Write-WarnEx '无法从客户端帮助输出确认 WSL 安装支持，脚本仍会直接尝试安装路径。'
        }
    }
    else {
        Write-WarnEx '当前跳过主机检查，仅用于验证执行。'
    }

    Write-Section '准备 WSL'
    Update-WslEngine
    Ensure-DistroInstalled -TargetDistro $Distro
    Ensure-WslVersion2 -TargetDistro $Distro
    $currentDefaultDistro = Get-DefaultDistro
    if ($currentDefaultDistro -eq $Distro) {
        Write-Ok "$Distro 已经是默认 WSL 发行版，跳过设置。"
    }
    elseif ($null -eq $currentDefaultDistro) {
        Write-WarnEx '无法读取当前默认 WSL 发行版，改用手动确认。'
        if (Confirm-Yes "是否将 $Distro 设为默认 WSL 发行版？") {
            Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--set-default', $Distro) -AllowFailure | Out-Null
            Write-Ok "$Distro 已设为默认 WSL 发行版。"
        }
    }
    else {
        Write-Info "当前默认 WSL 发行版是 $currentDefaultDistro。"
        if (Confirm-Yes "是否将 $Distro 设为默认 WSL 发行版？") {
            Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--set-default', $Distro) -AllowFailure | Out-Null
            Write-Ok "$Distro 已设为默认 WSL 发行版。"
        }
        else {
            Write-Info '默认 WSL 发行版保持不变。'
        }
    }

    Ensure-DistroInitialized -TargetDistro $Distro

    Install-LinuxBasePackages -TargetDistro $Distro

    $linuxUser = Get-NonRootLinuxUser -TargetDistro $Distro
    Write-Info "安装用户：$linuxUser"
    Install-NvmNodeAndCodex -TargetDistro $Distro -LinuxUser $linuxUser
    Install-CodexAutoUpdateWrapper -TargetDistro $Distro -LinuxUser $linuxUser
    Ensure-CodexDefaultModel -TargetDistro $Distro -LinuxUser $linuxUser
    Check-CodexSubscriptionStatus -TargetDistro $Distro -LinuxUser $linuxUser
    Install-CodexSkills -TargetDistro $Distro -LinuxUser $linuxUser

    Write-Section '安装完成'
    Write-Ok 'WSL、Linux 发行版、基础工具、nvm、Node LTS、Codex 和打包技能已安装。'
    Write-Info '尽量把当前项目放在 Linux 文件系统中，例如 `~/code/<project>`。'
    Write-Info "之后可使用 `wsl -d $Distro` 进入 WSL。"
    Write-Info '进入 WSL 后运行：`codex`'

    Launch-CodexInteractive -TargetDistro $Distro -LinuxUser $linuxUser
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
