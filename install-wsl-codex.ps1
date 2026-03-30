param(
    [string]$Distro = "Ubuntu",
    [switch]$InstallBubblewrap,
    [switch]$SkipAptUpgrade,
    [switch]$NoAutoLaunchCodex,
    [switch]$SkipHostChecks,
    [string]$SkillsSourceConfigPath,
    [string]$SkillsManifestPath,
    [string]$SkillsManifestUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSCommandPath
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
        throw 'Cancelled by user.'
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
            throw "Command failed: $FilePath $($ArgumentList -join ' ')`n$($output | Out-String)"
        }
        return [pscustomobject]@{ Output = $output; ExitCode = $code }
    }

    & $FilePath @ArgumentList
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Command failed: $FilePath $($ArgumentList -join ' ')"
    }
    return [pscustomobject]@{ ExitCode = $code }
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

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        ProductName    = $cv.ProductName
        CurrentBuild   = [int]$cv.CurrentBuild
        DisplayVersion = $cv.DisplayVersion
    }
}

function Register-ResumeSelf {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-WarnEx 'Cannot register RunOnce because the script is not being run from a file path.'
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
    Write-Ok 'Registered RunOnce resume entry.'
}

function Get-WslHelpText {
    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--help') -AllowFailure -CaptureOutput
    return ($result.Output | Out-String)
}

function Test-WslInstallSupported {
    try {
        $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--install', '--help') -AllowFailure -CaptureOutput
        return ($result.ExitCode -eq 0 -or (($result.Output | Out-String) -match '--install'))
    }
    catch {
        return $false
    }
}

function Get-InstalledDistros {
    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -AllowFailure -CaptureOutput
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
}

function Get-DistroVersionMap {
    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -AllowFailure -CaptureOutput
    $map = @{}
    if ($result.ExitCode -ne 0) { return $map }
    foreach ($line in $result.Output) {
        $text = "$line".Trim()
        if (-not $text -or $text -match '^(NAME|Windows|\*)') { continue }
        $clean = $text.TrimStart('*').Trim()
        $parts = $clean -split '\s{2,}'
        if ($parts.Count -ge 3) {
            $map[$parts[0].Trim()] = $parts[-1].Trim()
        }
    }
    return $map
}

function Get-DefaultDistro {
    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -AllowFailure -CaptureOutput
    if ($result.ExitCode -ne 0) { return $null }

    foreach ($line in $result.Output) {
        $text = "$line".Trim()
        if ($text.StartsWith('*')) {
            $clean = $text.TrimStart('*').Trim()
            $parts = $clean -split '\s{2,}'
            if ($parts.Count -ge 1) {
                return $parts[0].Trim()
            }
        }
    }

    return $null
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
        Write-Ok "$TargetDistro is already installed."
        return
    }

    Write-Section "Install WSL distro: $TargetDistro"
    Write-Info 'This will run `wsl --install -d <Distro>` and usually requires a reboot.'
    Confirm-ManualStep "是否现在安装 $TargetDistro 并继续？"
    Register-ResumeSelf
    Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $TargetDistro)
    Write-WarnEx 'WSL installation command has been issued. Reboot Windows now to continue.'
    if (Confirm-Yes 'Reboot now?') {
        Restart-Computer -Force
    }
    else {
        Write-WarnEx 'Please reboot manually and rerun the script.'
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

    Write-Section 'Check initial distro setup'
    $probe = Invoke-WslBash -TargetDistro $TargetDistro -User 'root' -Command 'printf __WSL_READY__' -AllowFailure -CaptureOutput
    if ($probe.ExitCode -eq 0 -and (($probe.Output | Out-String) -match '__WSL_READY__')) {
        Write-Ok "$TargetDistro is ready."
        return
    }

    Write-WarnEx "The distro may still need first-time initialization."
    Write-WarnEx 'An interactive WSL window will open. Finish Linux user creation, then type `exit` to return here.'
    & wsl.exe -d $TargetDistro

    $probe2 = Invoke-WslBash -TargetDistro $TargetDistro -User 'root' -Command 'printf __WSL_READY__' -AllowFailure -CaptureOutput
    if ($probe2.ExitCode -ne 0 -or (($probe2.Output | Out-String) -notmatch '__WSL_READY__')) {
        throw "The distro is still not initialized. Run `wsl -d $TargetDistro` manually and rerun this script."
    }
    Write-Ok "$TargetDistro first-time initialization completed."
}

function Get-DefaultLinuxUser {
    param([string]$TargetDistro)

    $result = Invoke-WslBash -TargetDistro $TargetDistro -Command 'id -un' -AllowFailure -CaptureOutput
    if ($result.ExitCode -ne 0) {
        throw 'Unable to determine the default Linux user.'
    }
    return (($result.Output | Select-Object -First 1).ToString().Trim())
}

function Ensure-WslVersion2 {
    param([string]$TargetDistro)

    Write-Section '确保 WSL 2'
    $prereq = Test-Wsl2Prerequisites
    if (-not $prereq.Ready) {
        Write-WarnEx "$TargetDistro 暂不切换到 WSL 2：$($prereq.Reasons -join '；')"
        Write-WarnEx '已继续后续安装流程。若需要 WSL 2，请先启用相关 Windows 功能后重试。'
        return
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
    Write-Info '正在检查并更新 WSL 引擎...'
    $result = Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--update') -AllowFailure -CaptureOutput
    if ($result.ExitCode -eq 0) {
        Write-Ok 'WSL 引擎更新完成。'
    }
    else {
        Write-WarnEx 'WSL 引擎更新失败或当前无需更新。'
    }
    Invoke-External -FilePath 'wsl.exe' -ArgumentList @('--shutdown') -AllowFailure | Out-Null
    Write-Ok 'WSL 已重启。'
}

function Install-LinuxBasePackages {
    param([string]$TargetDistro)

    Write-Section 'Install Linux base packages'
    $packages = @(
        'ca-certificates',
        'curl',
        'git',
        'jq',
        'ripgrep',
        'fd-find',
        'unzip',
        'zip',
        'xz-utils',
        'rsync',
        'openssh-client',
        'build-essential',
        'pkg-config',
        'python3',
        'python3-pip',
        'python3-venv',
        'cmake',
        'ninja-build',
        'dnsutils',
        'iputils-ping',
        'moreutils'
    )

    if ($InstallBubblewrap) {
        $packages += 'bubblewrap'
    }


    $rootScript = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
__UPGRADE_STEP__
apt-get install -y __PACKAGES__
if command -v fdfind >/dev/null 2>&1 && [ ! -e /usr/local/bin/fd ]; then
  ln -s "$(command -v fdfind)" /usr/local/bin/fd || true
fi
apt-get autoremove -y
apt-get clean
'@

    $upgradeCmd = if ($SkipAptUpgrade) { ':' } else { 'apt-get upgrade -y' }
    $rootScript = $rootScript.Replace('__UPGRADE_STEP__', $upgradeCmd).Replace('__PACKAGES__', ($packages -join ' '))
    Invoke-WslBash -TargetDistro $TargetDistro -User 'root' -Command $rootScript | Out-Null
    Write-Ok 'Linux base packages installed.'
}

function Install-NvmNodeAndCodex {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "为 $LinuxUser 安装 nvm / Node.js LTS / Codex"

    $userScript = @'
set -euo pipefail
codex_prefix="$HOME/.codex/npm-global"
mkdir -p "$HOME/.local/bin" "$HOME/code" "$codex_prefix"

if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="$codex_prefix/bin:$HOME/.local/bin:$PATH"

if ! grep -q '### codex-wsl-bootstrap ###' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF_BASHRC'

### codex-wsl-bootstrap ###
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="$HOME/.codex/npm-global/bin:$HOME/.local/bin:$PATH"
if printf '%s' "$PATH" | grep -Eq '/mnt/c/Users/[^/]+/AppData/Roaming/npm'; then
  PATH="$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /\/mnt\/c\/Users\/[^/]+\/AppData\/Roaming\/npm/ {print}' | sed 's/:$//')"
  export PATH
fi
### /codex-wsl-bootstrap ###
EOF_BASHRC
fi

if printf '%s' "$PATH" | grep -Eq '/mnt/c/Users/[^/]+/AppData/Roaming/npm'; then
  PATH="$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /\/mnt\/c\/Users\/[^/]+\/AppData\/Roaming\/npm/ {print}' | sed 's/:$//')"
  export PATH
fi

nvm install --lts
nvm alias default 'lts/*'
nvm use --lts
npm i -g --prefix "$codex_prefix" @openai/codex@latest
codex_bin="$codex_prefix/bin/codex"

echo "Node version: $(node -v)"
echo "npm version : $(npm -v)"
echo "codex version: $("$codex_bin" --version)"
'@

    Invoke-WslBash -TargetDistro $TargetDistro -User $LinuxUser -Command $userScript | Out-Null
    Write-Ok '已安装 nvm、Node.js LTS 和 Codex。'
}

function Install-CodexAutoUpdateWrapper {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "为 $LinuxUser 安装 Codex 自动更新包装器"

    $userScript = @'
set -euo pipefail
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'EOF_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

codex_prefix="$HOME/.codex/npm-global"
real_codex="$codex_prefix/bin/codex"

check_subscription() {
  python3 - <<'PY'
import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

auth_path = Path.home() / '.codex' / 'auth.json'

def warn(message):
    print(f'[WARN] {message}')

def info(message):
    print(f'[INFO] {message}')

if not auth_path.exists():
    warn('未找到 Codex 登录信息，跳过订阅检查。')
    sys.exit(0)

try:
    auth = json.loads(auth_path.read_text())
except Exception as exc:
    warn(f'无法读取 Codex 登录信息：{exc}')
    sys.exit(0)

if auth.get('auth_mode') != 'chatgpt':
    info('当前不是 ChatGPT 登录，跳过订阅检查。')
    sys.exit(0)

tokens = auth.get('tokens') or {}

def decode_jwt(token):
    parts = token.split('.')
    if len(parts) < 2:
        return {}
    payload = parts[1] + '=' * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode('ascii')))

def extract_subscription(payload):
    nested = payload.get('https://api.openai.com/auth')
    if isinstance(nested, dict):
        value = nested.get('chatgpt_subscription_active_until')
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None

subscription_until = None
for token_name in ('id_token', 'access_token'):
    token = tokens.get(token_name)
    if not isinstance(token, str) or not token.strip():
        continue
    try:
        payload = decode_jwt(token)
    except Exception:
        continue
    subscription_until = extract_subscription(payload)
    if subscription_until:
        break

if not subscription_until:
    warn('未找到订阅到期时间，跳过检查。')
    sys.exit(0)

normalized_until = subscription_until.replace('Z', '+00:00')
try:
    expiry = datetime.fromisoformat(normalized_until)
except ValueError:
    warn(f'无法解析订阅到期时间：{subscription_until}')
    sys.exit(0)

now = datetime.now(timezone.utc)
remaining = expiry - now
remaining_days = remaining.total_seconds() / 86400
expiry_text = expiry.astimezone(timezone.utc).isoformat()

if remaining.total_seconds() <= 0:
    warn(f'Codex 订阅已过期，到期时间：{expiry_text}。')
    sys.exit(0)

if remaining_days <= 7:
    warn(f'Codex 订阅还剩 {remaining_days:.1f} 天，到期时间：{expiry_text}。')
    sys.exit(0)

info(f'Codex 订阅还剩 {remaining_days:.1f} 天，到期时间：{expiry_text}。')
PY
}

update_codex() {
  if ! command -v npm >/dev/null 2>&1; then
    echo '[WARN] 未找到 npm，跳过 Codex 更新。'
    return 0
  fi

  if [ ! -x "$real_codex" ]; then
    echo '[INFO] 未检测到已安装的 Codex，开始安装最新版本。'
    mkdir -p "$codex_prefix"
    if npm i -g --prefix "$codex_prefix" @openai/codex@latest --silent --no-fund --no-audit >/dev/null 2>&1; then
      echo '[OK] Codex 已安装。'
    else
      echo '[WARN] Codex 安装失败，将继续使用当前版本。'
    fi
    return 0
  fi

  current_version="$($real_codex --version 2>/dev/null | awk '{print $NF}')"
  latest_version="$(npm view @openai/codex version --silent 2>/dev/null || true)"

  if [ -z "$latest_version" ]; then
    echo '[WARN] 无法获取 Codex 最新版本，跳过自动更新。'
    return 0
  fi

  if [ "$current_version" = "$latest_version" ]; then
    echo "[INFO] Codex 已是最新版本：$current_version。"
    return 0
  fi

  echo "[INFO] 检测到 Codex 新版本：$current_version -> $latest_version，开始更新。"
  mkdir -p "$codex_prefix"
  if npm i -g --prefix "$codex_prefix" @openai/codex@latest --silent --no-fund --no-audit >/dev/null 2>&1; then
    echo "[OK] Codex 已更新到最新版本：$latest_version。"
  else
    echo '[WARN] Codex 更新失败，将继续使用当前版本。'
  fi
}

check_subscription
update_codex
if [ ! -x "$real_codex" ] && [ -x "/usr/local/bin/codex" ]; then
  real_codex="/usr/local/bin/codex"
fi

exec "$real_codex" "$@"
EOF_WRAPPER
chmod +x "$HOME/.local/bin/codex"
'@

    Invoke-WslBash -TargetDistro $TargetDistro -User $LinuxUser -Command $userScript | Out-Null
    Write-Ok '已安装 Codex 自动更新包装器。'
}

function Ensure-CodexDefaultModel {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "为 $LinuxUser 写入 Codex 默认模型"

    $userScript = @'
set -euo pipefail
mkdir -p "$HOME/.codex"
config="$HOME/.codex/config.toml"
tmp="$(mktemp)"

python3 - "$config" "$tmp" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
tmp_path = Path(sys.argv[2])
desired_model = 'gpt-5.4-mini'
desired_effort = 'medium'

text = config_path.read_text() if config_path.exists() else ''
lines = text.splitlines()

def replace_or_prepend(key, value, lines):
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=')
    updated = []
    replaced = False
    for line in lines:
        if pattern.match(line):
            if not replaced:
                updated.append(f'{key} = "{value}"')
                replaced = True
            continue
        updated.append(line)
    if not replaced:
        updated.insert(0, f'{key} = "{value}"')
    return updated

lines = replace_or_prepend('model', desired_model, lines)
lines = replace_or_prepend('model_reasoning_effort', desired_effort, lines)

tmp_path.write_text('\n'.join(lines).rstrip() + '\n')
PY

mv "$tmp" "$config"
echo "Codex config written: $config"
echo "Default model: gpt-5.4-mini"
'@

    Invoke-WslBash -TargetDistro $TargetDistro -User $LinuxUser -Command $userScript | Out-Null
    Write-Ok '已将 Codex 默认模型设为 gpt-5.4-mini。'
}

function Check-CodexSubscriptionStatus {
    param(
        [string]$TargetDistro,
        [string]$LinuxUser
    )

    Write-Section "Check Codex subscription inside WSL for $LinuxUser"

    $userScript = @'
set -euo pipefail
python3 - <<'PY'
import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

auth_path = Path.home() / '.codex' / 'auth.json'

def warn(message: str) -> None:
    print(f'[WARN] {message}')

def info(message: str) -> None:
    print(f'[INFO] {message}')

if not auth_path.exists():
    warn('未找到 Codex 登录信息，跳过订阅检查。')
    sys.exit(0)

try:
    auth = json.loads(auth_path.read_text())
except Exception as exc:
    warn(f'无法读取 Codex 登录信息：{exc}')
    sys.exit(0)

if auth.get('auth_mode') != 'chatgpt':
    info('当前不是 ChatGPT 登录，跳过订阅检查。')
    sys.exit(0)

tokens = auth.get('tokens') or {}

def decode_jwt(token: str) -> dict:
    parts = token.split('.')
    if len(parts) < 2:
        return {}
    payload = parts[1] + '=' * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode('ascii')))

def extract_subscription(payload):
    nested = payload.get('https://api.openai.com/auth')
    if isinstance(nested, dict):
        value = nested.get('chatgpt_subscription_active_until')
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None

subscription_until = None
for token_name in ('id_token', 'access_token'):
    token = tokens.get(token_name)
    if not isinstance(token, str) or not token.strip():
        continue
    try:
        payload = decode_jwt(token)
    except Exception:
        continue
    subscription_until = extract_subscription(payload)
    if subscription_until:
        break

if not subscription_until:
    warn('未找到订阅到期时间，跳过检查。')
    sys.exit(0)

normalized_until = subscription_until.replace('Z', '+00:00')
try:
    expiry = datetime.fromisoformat(normalized_until)
except ValueError:
    warn(f'无法解析订阅到期时间：{subscription_until}')
    sys.exit(0)

now = datetime.now(timezone.utc)
remaining = expiry - now
remaining_days = remaining.total_seconds() / 86400

if remaining.total_seconds() <= 0:
    warn(f'Codex 订阅已过期，到期时间：{expiry.astimezone(timezone.utc).isoformat()}。')
    sys.exit(0)

if remaining_days <= 7:
    warn(
        f'Codex 订阅还剩 {remaining_days:.1f} 天，到期时间：'
        f'{expiry.astimezone(timezone.utc).isoformat()}。'
    )
    sys.exit(0)

info(
    f'Codex 订阅还剩 {remaining_days:.1f} 天，到期时间：'
    f'{expiry.astimezone(timezone.utc).isoformat()}。'
)
PY
'@

    $result = Invoke-WslBash -TargetDistro $TargetDistro -User $LinuxUser -Command $userScript -CaptureOutput
    foreach ($line in @($result.Output)) {
        if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace($line.ToString())) {
            Write-Host $line
        }
    }
}

function Get-SkillManifest {
    $manifestPath = $null
    $manifestUrl = $null

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
        Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -OutFile $tempManifest
        return (Get-Content -Raw -Path $tempManifest | ConvertFrom-Json)
    }

    throw 'Skill manifest source is not configured. Set skills-source.json or pass -SkillsManifestPath / -SkillsManifestUrl.'
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
        Write-WarnEx 'Skill manifest is empty; skipping skill installation.'
        return
    }


    $sourceRoots = @{}
    foreach ($skill in $skills) {
        if ([string]::IsNullOrWhiteSpace($skill.name) -or [string]::IsNullOrWhiteSpace($skill.sourceId) -or [string]::IsNullOrWhiteSpace($skill.sourcePath)) {
            throw 'Each skill manifest entry must include `name`, `sourceId`, and `sourcePath`.'
        }

        if (-not $sourceRoots.ContainsKey($skill.sourceId)) {
            $source = Resolve-SourceById -Manifest $manifest -SourceId $skill.sourceId
            if ($null -eq $source -or [string]::IsNullOrWhiteSpace($source.repo)) {
                throw "Source '$($skill.sourceId)' is missing a repo URL."
            }
            $sourceRoots[$skill.sourceId] = $source
        }
    }

    $skillDir = '$HOME/.codex/skills'
    $tempRoot = '/tmp/codex-skill-sources'

    $bash = New-Object System.Collections.Generic.List[string]
    $bash.Add('set -euo pipefail')
    $bash.Add("skill_dir=$skillDir")
    $bash.Add("temp_root=$(ConvertTo-BashSingleQuoted $tempRoot)")
    $bash.Add('mkdir -p "$temp_root" "$skill_dir"')

    foreach ($sourceId in ($sourceRoots.Keys | Sort-Object)) {
        $source = $sourceRoots[$sourceId]
        $checkoutDir = "$tempRoot/$sourceId"
        $repo = ConvertTo-BashSingleQuoted ([string]$source.repo)
        $checkout = ConvertTo-BashSingleQuoted $checkoutDir
        $branch = if ($null -ne $source.ref -and -not [string]::IsNullOrWhiteSpace([string]$source.ref)) { " --branch $(ConvertTo-BashSingleQuoted ([string]$source.ref))" } else { '' }
        $bash.Add("rm -rf $checkout")
        $bash.Add("git clone --depth 1$branch $repo $checkout")
    }

    foreach ($skill in $skills) {
        $checkoutDir = "$tempRoot/$($skill.sourceId)"
        $sourcePath = [string]$skill.sourcePath
        $name = [string]$skill.name
        $dest = '$skill_dir/' + $name

        $bash.Add("rm -rf `"$dest`"")
        $bash.Add("if [ ! -e $(ConvertTo-BashSingleQuoted "$checkoutDir/$sourcePath") ]; then echo $(ConvertTo-BashSingleQuoted "Missing skill source: $($skill.sourceId)/$sourcePath") >&2; exit 1; fi")
        $bash.Add("mkdir -p `"$dest`"")
        if ($sourcePath -eq '.') {
            $bash.Add("rsync -a --delete --exclude='.git' $(ConvertTo-BashSingleQuoted "$checkoutDir/") `"$dest`"/")
        }
        else {
            $bash.Add("rsync -a --delete $(ConvertTo-BashSingleQuoted "$checkoutDir/$sourcePath/") `"$dest`"/")
        }
    }

    $userScript = ($bash -join "`n")
    Write-Section "为 $LinuxUser 安装 Codex skills"
    Invoke-WslBash -TargetDistro $TargetDistro -User $LinuxUser -Command $userScript | Out-Null
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

    if (-not (Confirm-Yes 'Launch Codex now for first-time sign-in?')) {
        return
    }

    Check-CodexSubscriptionStatus -TargetDistro $TargetDistro -LinuxUser $LinuxUser

    Write-Section 'Launch Codex'
    Write-Info 'This will open WSL in ~/code and start `codex`.'
    & wsl.exe -d $TargetDistro -u $LinuxUser -- bash -lc 'cd ~/code && "$HOME/.local/bin/codex"'
}

try {
    Write-Section 'Windows host checks'

    if (-not $SkipHostChecks) {
        if (-not (Test-IsAdmin)) {
            throw 'Run this script from an elevated PowerShell session.'
        }

        $os = Get-OsInfo
        Write-Info "Windows: $($os.ProductName) $($os.DisplayVersion) (Build $($os.CurrentBuild))"

        if ($os.CurrentBuild -lt 19041) {
            throw 'This Windows build is too old for a reliable WSL 2 bootstrap.'
        }

        if (-not (Test-WslInstallSupported)) {
            Write-WarnEx 'WSL install support could not be confirmed from the client help output. The script will still try the install path directly.'
        }
    }
    else {
        Write-WarnEx 'Host checks are being skipped for validation-only execution.'
    }

    Write-Section 'Prepare WSL'
    Update-WslEngine
    Ensure-DistroInstalled -TargetDistro $Distro
    Ensure-WslVersion2 -TargetDistro $Distro
    $currentDefaultDistro = Get-DefaultDistro
    if ($currentDefaultDistro -eq $Distro) {
        Write-Ok "$Distro 已经是默认 WSL 发行版，跳过设置。"
    }
    elseif ($null -eq $currentDefaultDistro) {
        Write-WarnEx '无法读取当前默认 WSL 发行版，将手动确认是否需要修改。'
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

    $linuxUser = Get-DefaultLinuxUser -TargetDistro $Distro
    Write-Info "Default Linux user: $linuxUser"
    if ($linuxUser -eq 'root') {
        Write-WarnEx 'The default Linux user is root.'
        if (-not (Confirm-Yes 'Continue installing in root?')) {
            throw 'Cancelled.'
        }
    }

    Install-LinuxBasePackages -TargetDistro $Distro
    Install-NvmNodeAndCodex -TargetDistro $Distro -LinuxUser $linuxUser
    Install-CodexAutoUpdateWrapper -TargetDistro $Distro -LinuxUser $linuxUser
    Ensure-CodexDefaultModel -TargetDistro $Distro -LinuxUser $linuxUser
    Check-CodexSubscriptionStatus -TargetDistro $Distro -LinuxUser $linuxUser
    Install-CodexSkills -TargetDistro $Distro -LinuxUser $linuxUser

    Write-Section 'Installation complete'
    Write-Ok 'WSL, the Linux distro, base tools, nvm, Node LTS, Codex, and packaged skills have been installed.'
    Write-Info 'Keep your active projects inside the Linux filesystem when possible, e.g. ~/code/<project>.'
    Write-Info "You can enter WSL later with: wsl -d $Distro"
    Write-Info 'Inside WSL, run: codex'

    Launch-CodexInteractive -TargetDistro $Distro -LinuxUser $linuxUser
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
