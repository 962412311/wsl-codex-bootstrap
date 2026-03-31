#!/usr/bin/env bash
set -euo pipefail

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_ok() {
  printf '[OK] %s\n' "$1"
}

log_warn() {
  printf '[WARN] %s\n' "$1"
}

ensure_root_home() {
  export HOME="${HOME:-/root}"
  mkdir -p "$HOME"
}

DEFAULT_SKILLS_MANIFEST_URL='https://raw.githubusercontent.com/962412311/codex-skills-pack/main/skills.manifest.json'

sanitize_path() {
  local path_value="$1"
  local result=""
  local segment
  local IFS=:
  for segment in $path_value; do
    if [[ "$segment" == /mnt/c/Users/*/AppData/Roaming/npm ]]; then
      continue
    fi
    if [ -z "$result" ]; then
      result="$segment"
    else
      result="$result:$segment"
    fi
  done
  printf '%s' "$result"
}

install_base_packages() {
  local skip_upgrade="$1"
  local packages=(
    ca-certificates
    curl
    git
    jq
    ripgrep
    fd-find
    unzip
    zip
    xz-utils
    rsync
    openssh-client
    build-essential
    pkg-config
    python3
    python3-pip
    python3-venv
    cmake
    ninja-build
    dnsutils
    iputils-ping
    moreutils
    bubblewrap
  )

  export DEBIAN_FRONTEND=noninteractive
  local apt_get=(sudo apt-get -o DPkg::Lock::Timeout=300)
  "${apt_get[@]}" update
  if [ "$skip_upgrade" != "1" ]; then
    "${apt_get[@]}" upgrade -y
  fi
  "${apt_get[@]}" install -y "${packages[@]}"
  if command -v fdfind >/dev/null 2>&1 && [ ! -e /usr/local/bin/fd ]; then
    ln -s "$(command -v fdfind)" /usr/local/bin/fd || true
  fi
  "${apt_get[@]}" autoremove -y
  "${apt_get[@]}" clean
}

install_node_codex() {
  ensure_root_home

  local codex_prefix="$HOME/.codex/npm-global"
  mkdir -p "$HOME/.local/bin" "$HOME/code" "$codex_prefix"

  set +u
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
PATH="$(sanitize_path "$PATH")"
export PATH
### /codex-wsl-bootstrap ###
EOF_BASHRC
  fi

  PATH="$(sanitize_path "$PATH")"
  export PATH

  nvm install --lts
  nvm alias default 'lts/*'
  nvm use --lts
  set -u

  npm i -g --prefix "$codex_prefix" @openai/codex@latest
  local codex_bin="$codex_prefix/bin/codex"

  printf 'Node version: %s\n' "$(node -v)"
  printf 'npm version : %s\n' "$(npm -v)"
  printf 'codex version: %s\n' "$("$codex_bin" --version)"
}

write_codex_wrapper() {
  ensure_root_home

  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/codex" <<'EOF_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

codex_prefix="$HOME/.codex/npm-global"
real_codex="$codex_prefix/bin/codex"
update_stamp="$HOME/.codex/.codex-update-check.date"
plugins_repo="$HOME/.codex/.tmp/plugins"
skills_manifest="$HOME/.codex/skills.manifest.json"
skills_dir="$HOME/.codex/skills"
skills_sync_root="$HOME/.codex/.tmp/skill-sync"

update_plugins() {
  if [ -d "$plugins_repo/.git" ]; then
    echo "[INFO] 正在检查插件镜像更新。"
    before="$(git -C "$plugins_repo" rev-parse --short HEAD 2>/dev/null || true)"
    if git -C "$plugins_repo" pull --ff-only --quiet >/dev/null 2>&1; then
      after="$(git -C "$plugins_repo" rev-parse --short HEAD 2>/dev/null || true)"
      if [ -n "$before" ] && [ "$before" = "$after" ]; then
        echo "[INFO] 插件镜像已是最新版本：$after。"
      else
        echo "[OK] 插件镜像已更新：${before:-unknown} -> ${after:-unknown}。"
      fi
      return 0
    fi
    echo '[WARN] 插件镜像更新失败，将继续启动 Codex。'
    return 0
  fi

  echo "[WARN] 未找到插件镜像仓库：$plugins_repo，跳过插件更新。"
  return 0
}

update_skills() {
  if [ -f "$skills_manifest" ]; then
    echo "[INFO] 正在检查 skills 更新。"
    mkdir -p "$skills_dir" "$skills_sync_root"

    python3 - "$skills_manifest" "$skills_dir" "$skills_sync_root" <<'PY'
import json
import shutil
import subprocess
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
skills_dir = Path(sys.argv[2])
sync_root = Path(sys.argv[3])

def info(message):
    print(f'[INFO] {message}')

def ok(message):
    print(f'[OK] {message}')

def warn(message):
    print(f'[WARN] {message}')

try:
    manifest_text = manifest_path.read_text().strip()
    if not manifest_text:
        raise ValueError('skills manifest is empty')
    manifest = json.loads(manifest_text)
except Exception as exc:
    warn(f'无法读取 skills manifest：{exc}')
    sys.exit(0)

skills = [
    skill for skill in manifest.get('skills', [])
    if skill is not None and (skill.get('enabled') is None or bool(skill.get('enabled')))
]
if not skills:
    info('skills manifest 为空，跳过。')
    sys.exit(0)

info(f'准备安装 {len(skills)} 个 skills。')

sources = {}
for skill in skills:
    name = skill.get('name')
    source_id = skill.get('sourceId')
    source_path = skill.get('sourcePath')
    if not name or not source_id or not source_path:
        warn('skills manifest 中存在缺少 name/sourceId/sourcePath 的条目，跳过。')
        sys.exit(0)
    if source_id not in sources:
        source = next((item for item in manifest.get('sources', []) if item.get('id') == source_id), None)
        if not source or not source.get('repo'):
            warn(f'Source 缺少 repo：{source_id}')
            sys.exit(0)
        sources[source_id] = source

sync_root.mkdir(parents=True, exist_ok=True)
skills_dir.mkdir(parents=True, exist_ok=True)

for source_id, source in sorted(sources.items()):
    info(f'正在同步 skills 源：{source_id}。')
    checkout_dir = sync_root / source_id
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    repo = source['repo']
    cmd = ['git', 'clone', '--depth', '1']
    ref = source.get('ref')
    if ref:
        cmd.extend(['--branch', str(ref)])
    cmd.extend([repo, str(checkout_dir)])
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not checkout_dir.exists():
        warn(f'克隆 skills 源失败：{source_id}')
        sys.exit(0)
    ok(f'已同步 skills 源：{source_id}。')

info('正在安装 skills 内容。')
for skill in skills:
    source_id = skill['sourceId']
    source_path = skill['sourcePath']
    name = skill['name']
    checkout_dir = sync_root / source_id
    source_dir = checkout_dir / source_path
    dest_dir = skills_dir / name

    if not source_dir.exists():
        warn(f'找不到技能源：{source_id}/{source_path}')
        sys.exit(0)

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    if source_path == '.':
        subprocess.run(
            ['rsync', '-a', '--delete', '--exclude=.git', f'{checkout_dir}/', f'{dest_dir}/']
,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        subprocess.run(
            ['rsync', '-a', '--delete', f'{source_dir}/', f'{dest_dir}/'],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

ok(f'已刷新 {len(skills)} 个 skills。')
PY
    return 0
  fi

  echo "[WARN] 未找到 skills manifest：$skills_manifest，跳过 skills 更新。"
  return 0
}

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
    auth_text = auth_path.read_text().strip()
    if not auth_text:
        raise ValueError('auth.json is empty')
    auth = json.loads(auth_text)
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
expiry_text = expiry.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')

if remaining.total_seconds() <= 0:
    warn(f'Codex 订阅已过期，到期时间：{expiry_text}。')
    sys.exit(0)

if remaining_days <= 7:
    warn(f'Codex 订阅还剩 {remaining_days:.1f} 天，到期时间：{expiry_text}。')
    sys.exit(0)

info(f'Codex 订阅还剩 {remaining_days:.1f} 天，到期时间：{expiry_text}。')
PY
}

touch_update_stamp() {
  mkdir -p "$HOME/.codex"
  date +%F > "$update_stamp"
}

should_check_update() {
  local today current
  today="$(date +%F)"
  current="$(cat "$update_stamp" 2>/dev/null || true)"
  if [ "$current" = "$today" ]; then
    echo '[INFO] 今天已检查过 Codex / skills / plugin 检查，跳过。'
    return 1
  fi
  return 0
}

update_codex() {
  if ! command -v npm >/dev/null 2>&1; then
    echo '[WARN] 未找到 npm，跳过 Codex 更新。'
    touch_update_stamp
    return 0
  fi

  if ! should_check_update; then
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
    touch_update_stamp
    return 0
  fi

  current_version="$($real_codex --version 2>/dev/null | awk '{print $NF}')"
  latest_version="$(npm view @openai/codex version --silent 2>/dev/null || true)"

  if [ -z "$latest_version" ]; then
    echo '[WARN] 无法获取 Codex 最新版本，跳过自动更新。'
    touch_update_stamp
    return 0
  fi

  if [ "$current_version" = "$latest_version" ]; then
    echo "[INFO] Codex 已是最新版本：$current_version。"
    touch_update_stamp
    return 0
  fi

  echo "[INFO] 检测到 Codex 新版本：$current_version -> $latest_version，开始更新。"
  mkdir -p "$codex_prefix"
  if npm i -g --prefix "$codex_prefix" @openai/codex@latest --silent --no-fund --no-audit >/dev/null 2>&1; then
    echo "[OK] Codex 已更新到最新版本：$latest_version。"
  else
    echo '[WARN] Codex 更新失败，将继续使用当前版本。'
  fi
  touch_update_stamp
}

sync_update_artifacts() {
  if should_check_update; then
    update_codex
    update_plugins
    update_skills
    touch_update_stamp
  fi
}

check_subscription
sync_update_artifacts
if [ -x "$real_codex" ]; then
  :
elif [ -x "/usr/local/bin/codex" ]; then
  real_codex="/usr/local/bin/codex"
fi

exec "$real_codex" "$@"
EOF_WRAPPER
  chmod +x "$HOME/.local/bin/codex"
}

ensure_default_model() {
  ensure_root_home

  mkdir -p "$HOME/.codex"
  local config="$HOME/.codex/config.toml"
  local tmp
  tmp="$(mktemp)"
  local status

  status="$(
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

def get_value(key):
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"')
    for line in lines:
        match = pattern.match(line)
        if match:
            return match.group(1)
    return None

current_model = get_value('model')
current_effort = get_value('model_reasoning_effort')

if current_model == desired_model and current_effort == desired_effort:
    print('NO_CHANGE')
    sys.exit(0)

def replace_or_prepend(key, value, source_lines):
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=')
    updated = []
    replaced = False
    for line in source_lines:
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
print('UPDATED')
PY
  )"

  case "$status" in
    NO_CHANGE)
      printf 'Codex 默认模型已是 gpt-5.4-mini，跳过写入。\n'
      rm -f "$tmp"
      ;;
    UPDATED)
      mv "$tmp" "$config"
      printf '已将 Codex 默认模型设为 gpt-5.4-mini。\n'
      ;;
    *)
      rm -f "$tmp"
      printf 'ERROR: %s\n' "$status" >&2
      return 1
      ;;
  esac
}

check_subscription_json() {
  ensure_root_home

  python3 - <<'PY'
import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

auth_path = Path.home() / '.codex' / 'auth.json'

def emit(payload):
    print(json.dumps(payload, ensure_ascii=True))

if not auth_path.exists():
    emit({'status': 'missing_auth'})
    sys.exit(0)

try:
    auth_text = auth_path.read_text().strip()
    if not auth_text:
        raise ValueError('auth.json is empty')
    auth = json.loads(auth_text)
except Exception as exc:
    emit({'status': 'read_error', 'message': str(exc)})
    sys.exit(0)

if auth.get('auth_mode') != 'chatgpt':
    emit({'status': 'not_chatgpt'})
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
    emit({'status': 'no_expiry'})
    sys.exit(0)

normalized_until = subscription_until.replace('Z', '+00:00')
try:
    expiry = datetime.fromisoformat(normalized_until)
except ValueError:
    emit({'status': 'parse_error', 'subscription_until': subscription_until})
    sys.exit(0)

now = datetime.now(timezone.utc)
remaining = expiry - now
remaining_days = remaining.total_seconds() / 86400
expiry_text = expiry.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')

if remaining.total_seconds() <= 0:
    emit({'status': 'expired', 'expiry_text': expiry_text, 'remaining_days': remaining_days})
    sys.exit(0)

level = 'warning' if remaining_days <= 7 else 'info'
emit({'status': level, 'expiry_text': expiry_text, 'remaining_days': remaining_days})
PY
}

persist_manifest() {
  ensure_root_home

  local source_path="$1"
  mkdir -p "$HOME/.codex"
  install -m 0644 "$source_path" "$HOME/.codex/skills.manifest.json"
}

install_skills() {
  ensure_root_home

  local skills_manifest="$HOME/.codex/skills.manifest.json"
  local skills_dir="$HOME/.codex/skills"
  local skills_sync_root="$HOME/.codex/.tmp/skill-sync"

  mkdir -p "$skills_dir" "$skills_sync_root"
  python3 - "$skills_manifest" "$skills_dir" "$skills_sync_root" <<'PY'
import json
import shutil
import subprocess
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
skills_dir = Path(sys.argv[2])
sync_root = Path(sys.argv[3])

if not manifest_path.exists():
    print('skills manifest 不存在，跳过技能安装。')
    sys.exit(0)

manifest_text = manifest_path.read_text().strip()
if not manifest_text:
    print('skills manifest 为空，跳过技能安装。')
    sys.exit(0)

try:
    manifest = json.loads(manifest_text)
except Exception as exc:
    print(f'无法读取 skills manifest：{exc}')
    sys.exit(0)
skills = [
    skill for skill in manifest.get('skills', [])
    if skill is not None and (skill.get('enabled') is None or bool(skill.get('enabled')))
]
if not skills:
    raise SystemExit('技能清单为空，跳过技能安装。')

sources = {}
for skill in skills:
    name = skill.get('name')
    source_id = skill.get('sourceId')
    source_path = skill.get('sourcePath')
    if not name or not source_id or not source_path:
        raise SystemExit('每个技能清单条目都必须包含 name、sourceId 和 sourcePath。')
    if source_id not in sources:
        source = next((item for item in manifest.get('sources', []) if item.get('id') == source_id), None)
        if not source or not source.get('repo'):
            raise SystemExit(f"Source '{source_id}' is missing a repo URL.")
        sources[source_id] = source

for source_id, source in sorted(sources.items()):
    info(f'正在同步 skills 源：{source_id}。')
    checkout_dir = sync_root / source_id
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    cmd = ['git', 'clone', '--depth', '1']
    ref = source.get('ref')
    if ref:
        cmd.extend(['--branch', str(ref)])
    cmd.extend([source['repo'], str(checkout_dir)])
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

for skill in skills:
    checkout_dir = sync_root / skill['sourceId']
    source_path = skill['sourcePath']
    dest_dir = skills_dir / skill['name']
    source_dir = checkout_dir / source_path

    if not source_dir.exists():
        raise SystemExit(f"Missing skill source: {skill['sourceId']}/{source_path}")

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    if source_path == '.':
        subprocess.run(
            ['rsync', '-a', '--delete', '--exclude=.git', f'{checkout_dir}/', f'{dest_dir}/']
,
            check=True,
        )
    else:
        subprocess.run(
            ['rsync', '-a', '--delete', f'{source_dir}/', f'{dest_dir}/'],
            check=True,
        )
PY
}

bootstrap() {
  local skip_upgrade="${1:-0}"
  local manifest_url="${2:-$DEFAULT_SKILLS_MANIFEST_URL}"
  local temp_manifest

  install_base_packages "$skip_upgrade"
  install_node_codex
  write_codex_wrapper
  ensure_default_model
  check_subscription_json

  temp_manifest="$(mktemp)"
  if curl -fsSL "$manifest_url" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      persist_manifest "$temp_manifest"
      install_skills
    else
      log_warn "下载到的 skills manifest 无效：$manifest_url，跳过 skills 安装。"
    fi
  else
    log_warn "未能下载 skills manifest：$manifest_url，跳过 skills 安装。"
  fi
  rm -f "$temp_manifest"

  log_ok 'WSL 侧 Codex 已完成安装。'
  log_info '进入 WSL 后运行：codex'
}

main() {
  local command="${1:-}"
  case "$command" in
    install-base-packages)
      install_base_packages "${2:-0}"
      ;;
    install-node-codex)
      install_node_codex
      ;;
    install-wrapper)
      write_codex_wrapper
      ;;
    ensure-default-model)
      ensure_default_model
      ;;
    check-subscription-json)
      check_subscription_json
      ;;
    persist-manifest)
      persist_manifest "${2:?missing manifest path}"
      ;;
    install-skills)
      install_skills
      ;;
    bootstrap)
      bootstrap "${2:-0}" "${3:-$DEFAULT_SKILLS_MANIFEST_URL}"
      ;;
    "")
      printf 'missing command\n' >&2
      return 1
      ;;
    *)
      printf 'unknown command: %s\n' "$command" >&2
      return 1
      ;;
  esac
}

main "$@"
