#!/usr/bin/env bash
set -euo pipefail

# Version: 1.0.16
# Update this version every time this script changes.

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_ok() {
  printf '[OK] %s\n' "$1"
}

log_warn() {
  printf '[WARN] %s\n' "$1"
}

print_script_version() {
  printf "[INFO] install-linux-codex.sh version 1.0.16\n" >&2
}

ensure_root_home() {
  local target_user target_home

  target_user="${SUDO_USER:-$(id -un)}"
  if [ -z "$target_user" ] || [ "$target_user" = 'root' ]; then
    target_user="$(id -un)"
  fi

  target_home="$(getent passwd "$target_user" 2>/dev/null | awk -F: 'NR==1 { print $6 }')"
  if [ -z "$target_home" ]; then
    target_home="${HOME:-/root}"
  fi

  export USER="$target_user"
  export LOGNAME="$target_user"
  export HOME="$target_home"
  mkdir -p "$HOME"
}


is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null
}

write_wsl_home_profile() {
  if ! is_wsl; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF_WSL_HOME'
#!/usr/bin/env sh

if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
  _codex_user="$(id -un 2>/dev/null || true)"
  _codex_home="$(getent passwd "$_codex_user" 2>/dev/null | awk -F: 'NR==1 { print $6 }')"
  if [ -n "$_codex_user" ] && [ -n "$_codex_home" ] && [ "$HOME" != "$_codex_home" ]; then
    export USER="$_codex_user"
    export LOGNAME="$_codex_user"
    export HOME="$_codex_home"
  fi
fi

unset _codex_user _codex_home
EOF_WSL_HOME
  sudo install -d -m 0755 /etc/profile.d
  sudo install -m 0644 "$tmp" /etc/profile.d/99-codex-home.sh
  rm -f "$tmp"
}

DEFAULT_SKILLS_MANIFEST_URL='https://raw.githubusercontent.com/962412311/codex-skills-pack/main/skills.manifest.json'
DEFAULT_PLUGINS_MANIFEST_URL='https://raw.githubusercontent.com/962412311/codex-skills-pack/main/plugins.manifest.json'

get_codex_target_triple() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' 'x86_64-unknown-linux-musl'
      ;;
    aarch64|arm64)
      printf '%s\n' 'aarch64-unknown-linux-musl'
      ;;
    *)
      printf '%s\n' "Unsupported architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
}

get_codex_vendor_path_dir() {
  local target_triple
  local package_name
  target_triple="$(get_codex_target_triple)"

  case "$target_triple" in
    x86_64-unknown-linux-musl)
      package_name='@openai/codex-linux-x64'
      ;;
    aarch64-unknown-linux-musl)
      package_name='@openai/codex-linux-arm64'
      ;;
    *)
      printf '%s\n' "Unsupported Codex target triple: $target_triple" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$HOME/.codex/npm-global/lib/node_modules/@openai/codex/node_modules/$package_name/vendor/$target_triple/path"
}

write_codex_path_file() {
  ensure_root_home

  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/path.sh" <<'EOF_PATH'
#!/usr/bin/env sh

codex_local_bin="$HOME/.local/bin"
codex_npm_bin="$HOME/.codex/npm-global/bin"
get_codex_target_triple() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' 'x86_64-unknown-linux-musl'
      ;;
    aarch64|arm64)
      printf '%s\n' 'aarch64-unknown-linux-musl'
      ;;
    *)
      return 1
      ;;
  esac
}

get_codex_vendor_path_dir() {
  local target_triple
  local package_name
  target_triple="$(get_codex_target_triple)" || return 1

  case "$target_triple" in
    x86_64-unknown-linux-musl)
      package_name='@openai/codex-linux-x64'
      ;;
    aarch64-unknown-linux-musl)
      package_name='@openai/codex-linux-arm64'
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\n' "$HOME/.codex/npm-global/lib/node_modules/@openai/codex/node_modules/$package_name/vendor/$target_triple/path"
}

codex_vendor_path="$(get_codex_vendor_path_dir)"
path_entries=""

append_path() {
  case ":$path_entries:" in
    *":$1:"*)
      return 0
      ;;
  esac

  if [ -z "$path_entries" ]; then
    path_entries="$1"
  else
    path_entries="$path_entries:$1"
  fi
}

append_path "$codex_local_bin"
append_path "$codex_npm_bin"
append_path "$codex_vendor_path"

IFS=:
for segment in $PATH; do
  [ -n "$segment" ] || continue
  case "$segment" in
    "$codex_local_bin"|"$codex_npm_bin"|/mnt/c/Users/*/AppData/Roaming/npm)
      continue
      ;;
  esac
  append_path "$segment"
done
unset IFS

PATH="$path_entries"
export PATH

# Prefer the stable apply_patch wrapper, while still allowing direct calls
# to the session-local shim when it exists.
apply_patch() {
  "$HOME/.local/bin/apply_patch" "$@"
}

applypatch() {
  apply_patch "$@"
}
EOF_PATH
  chmod 0644 "$HOME/.codex/path.sh"
}

ensure_codex_shell_hook() {
  local shell_file="$1"
  local shell_dir
  shell_dir="$(dirname "$shell_file")"
  mkdir -p "$shell_dir"
  touch "$shell_file"

  python3 - "$shell_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if path.name == '.bash_profile':
    block = '''### codex-wsl-bootstrap ###
if [ -f "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi
if [ -f "$HOME/.codex/path.sh" ]; then
  . "$HOME/.codex/path.sh"
fi
### /codex-wsl-bootstrap ###'''
else:
    block = '''### codex-wsl-bootstrap ###
if [ -f "$HOME/.codex/path.sh" ]; then
  . "$HOME/.codex/path.sh"
fi
### /codex-wsl-bootstrap ###'''
text = path.read_text()
start = text.find('### codex-wsl-bootstrap ###')
end = text.find('### /codex-wsl-bootstrap ###')
if start != -1 and end != -1:
    end += len('### /codex-wsl-bootstrap ###')
    prefix = text[:start].rstrip('\n')
    suffix = text[end:].lstrip('\n')
    parts = []
    if prefix:
        parts.append(prefix)
    parts.append(block)
    if suffix:
        parts.append(suffix)
    text = '\n\n'.join(parts) + '\n'
else:
    if text and not text.endswith('\n'):
        text += '\n'
    if text and not text.endswith('\n\n'):
        text += '\n'
    text += block + '\n'
path.write_text(text)
PY
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

version_is_older() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

def parts(value):
    cleaned = value.strip().lstrip('v').split('-', 1)[0]
    return [int(item) for item in re.findall(r'\d+', cleaned)]

current = parts(sys.argv[1])
latest = parts(sys.argv[2])

for current_part, latest_part in zip(current, latest):
    if current_part < latest_part:
        sys.exit(0)
    if current_part > latest_part:
        sys.exit(1)

sys.exit(0 if len(current) < len(latest) else 1)
PY
}

get_latest_node_lts_version() {
  if command -v nvm >/dev/null 2>&1; then
    nvm ls-remote --lts 2>/dev/null | awk '/^[[:space:]]*v[0-9]/ { version = $1 } END { gsub(/^v/, "", version); print version }'
  fi
}

ensure_latest_node_runtime() {
  local current_node_version latest_node_version

  current_node_version="$(node -v 2>/dev/null | sed 's/^v//')"
  latest_node_version="$(get_latest_node_lts_version)"

  if [ -z "$latest_node_version" ]; then
    log_warn 'Unable to determine latest Node.js LTS version; skipping check.'
    return 0
  fi

  if [ -z "$current_node_version" ]; then
    log_info "Node.js not found; latest LTS is $latest_node_version."
    return 1
  fi

  if version_is_older "$current_node_version" "$latest_node_version"; then
    log_info "Node.js update available: $current_node_version -> $latest_node_version."
    return 1
  fi

  log_info "Node.js is already up to date: $current_node_version."
  return 0
}

ensure_latest_npm() {
  local current_npm_version latest_npm_version

  current_npm_version="$(npm -v 2>/dev/null || true)"
  latest_npm_version="$(npm view npm version --silent 2>/dev/null || true)"

  if [ -z "$latest_npm_version" ]; then
    log_warn 'Unable to determine latest npm version; skipping check.'
    return 0
  fi

  if [ -z "$current_npm_version" ]; then
    log_info "npm not found; latest version is $latest_npm_version."
    return 1
  fi

  if version_is_older "$current_npm_version" "$latest_npm_version"; then
    log_info "npm update available: $current_npm_version -> $latest_npm_version."
    return 1
  fi

  log_info "npm is already up to date: $current_npm_version."
  return 0
}

install_node_codex() {
  ensure_root_home

  local codex_prefix="$HOME/.codex/npm-global"
  mkdir -p "$HOME/.local/bin" "$HOME/code" "$codex_prefix"

  write_codex_path_file
  write_apply_patch_wrapper
  ensure_codex_shell_hook "$HOME/.bashrc"
  ensure_codex_shell_hook "$HOME/.profile"
  ensure_codex_shell_hook "$HOME/.bash_profile"
  ensure_codex_shell_hook "$HOME/.zshrc"
  ensure_codex_shell_hook "$HOME/.zprofile"
  . "$HOME/.codex/path.sh"

  set +u
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
  fi

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  if ensure_latest_node_runtime; then
    :
  else
    nvm install --lts
    nvm alias default 'lts/*'
    nvm use --lts
  fi
  set -u

  if ensure_latest_npm; then
    :
  else
    npm install -g npm@latest
  fi

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

resolve_codex_home() {
  local target_user target_home

  target_user="${SUDO_USER:-$(id -un)}"
  if [ -z "$target_user" ] || [ "$target_user" = 'root' ]; then
    target_user="$(id -un)"
  fi

  target_home="$(getent passwd "$target_user" 2>/dev/null | awk -F: 'NR==1 { print $6 }')"
  if [ -z "$target_home" ]; then
    target_home="${HOME:-/root}"
  fi

  export USER="$target_user"
  export LOGNAME="$target_user"
  export HOME="$target_home"
}

resolve_codex_home

ensure_root_home() {
  local target_user target_home

  target_user="${SUDO_USER:-$(id -un)}"
  if [ -z "$target_user" ] || [ "$target_user" = 'root' ]; then
    target_user="$(id -un)"
  fi

  target_home="$(getent passwd "$target_user" 2>/dev/null | awk -F: 'NR==1 { print $6 }')"
  if [ -z "$target_home" ]; then
    target_home="${HOME:-/root}"
  fi

  export USER="$target_user"
  export LOGNAME="$target_user"
  export HOME="$target_home"
}

codex_prefix="$HOME/.codex/npm-global"
real_codex="$codex_prefix/bin/codex"
update_stamp="$HOME/.codex/.codex-update-check.date"
plugins_repo="$HOME/.codex/.tmp/plugins"
skills_dir="$HOME/.codex/skills"
skills_sync_root="$HOME/.codex/.tmp/skill-sync"
DEFAULT_SKILLS_MANIFEST_URL='https://raw.githubusercontent.com/962412311/codex-skills-pack/main/skills.manifest.json'
DEFAULT_PLUGINS_MANIFEST_URL='https://raw.githubusercontent.com/962412311/codex-skills-pack/main/plugins.manifest.json'

update_plugins() {
  if [ -d "${plugins_repo:-}/.git" ]; then
    echo "[INFO] 正在检查插件镜像更新。"
    before="$(git -C "${plugins_repo:-}" rev-parse --short HEAD 2>/dev/null || true)"
    if git -C "${plugins_repo:-}" pull --ff-only --quiet >/dev/null 2>&1; then
      after="$(git -C "${plugins_repo:-}" rev-parse --short HEAD 2>/dev/null || true)"
      if [ -n "$before" ] && [ "$before" = "$after" ]; then
        echo "[INFO] 插件镜像已是最新版本：${after:-unknown}。"
      else
        echo "[OK] 插件镜像已更新：${before:-unknown} -> ${after:-unknown}。"
      fi
      return 0
    fi
    echo '[WARN] 插件镜像更新失败，将继续启动 Codex。'
    return 0
  fi

  echo "[WARN] 未找到插件镜像仓库：${plugins_repo:-}，跳过插件更新。"
  return 0
}

install_skills_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local skills_dir="$HOME/.codex/skills"
  local skills_sync_root="$HOME/.codex/.tmp/skill-sync"

  mkdir -p "$skills_dir" "$skills_sync_root"
  python3 - "$manifest_path" "$skills_dir" "$skills_sync_root" <<'PY'
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
resolved_skills = []
for skill in skills:
    name = skill.get('name')
    source_id = skill.get('sourceId')
    source_path = skill.get('sourcePath')
    if not name or not source_id or not source_path:
        warn('忽略一个缺少 name、sourceId 或 sourcePath 的 skill 条目。')
        continue
    if source_id not in sources:
        source = next((item for item in manifest.get('sources', []) if item.get('id') == source_id), None)
        if not source or not source.get('repo'):
            warn(f"跳过 skill {name}：source '{source_id}' 缺少 repo URL。")
            continue
        sources[source_id] = source
    resolved_skills.append(skill)

skills = resolved_skills
if not skills:
    warn('没有可安装的有效 skills，跳过 skills 安装。')
    sys.exit(0)

info(f'准备安装 {len(skills)} 个 skills，来自 {len(sources)} 个源。')
installed_count = 0
for source_id, source in sorted(sources.items()):
    info(f'正在同步 skills 源：{source_id}（{source["repo"]}）。')
    checkout_dir = sync_root / source_id
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    cmd = ['git', 'clone', '--depth', '1']
    ref = source.get('ref')
    if ref:
        cmd.extend(['--branch', str(ref)])
    cmd.extend([source['repo'], str(checkout_dir)])
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as exc:
        warn(f'同步 skills 源失败，已跳过：{source_id}（{exc}）。')
        continue
    if not checkout_dir.exists():
        warn(f'同步 skills 源后目录不存在，已跳过：{source_id}。')
        continue
    ok(f'已同步 skills 源：{source_id}。')

info('正在安装 skills 内容。')
for skill in skills:
    name = skill['name']
    info(f'正在安装 skill：{name}。')
    checkout_dir = sync_root / skill['sourceId']
    source_path = skill['sourcePath']
    dest_dir = skills_dir / name
    source_dir = checkout_dir / source_path

    if not source_dir.exists():
        warn(f'跳过 skill {name}：缺少源文件 {skill["sourceId"]}/{source_path}。')
        continue

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    try:
        if source_path == '.':
            subprocess.run(
                ['rsync', '-a', '--delete', '--exclude=.git', f'{checkout_dir}/', f'{dest_dir}/'],
                check=True,
            )
        else:
            subprocess.run(
                ['rsync', '-a', '--delete', f'{source_dir}/', f'{dest_dir}/'],
                check=True,
            )
    except subprocess.CalledProcessError as exc:
        warn(f'安装 skill 失败，已跳过：{name}（{exc}）。')
        continue
    installed_count += 1
    ok(f'已安装 skill：{name}。')

ok(f'已刷新 {installed_count} 个 skills。')
PY
}

install_claude_plugins_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local claude_root="$2"
  local plugins_sync_root="$HOME/.codex/.tmp/plugin-sync"

  mkdir -p "$plugins_sync_root" "$claude_root/plugins"
  python3 - "$manifest_path" "$claude_root" "$plugins_sync_root" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
claude_root = Path(sys.argv[2])
sync_root = Path(sys.argv[3])
plugins_root = claude_root / 'plugins'
marketplaces_root = plugins_root / 'marketplaces'
cache_root = plugins_root / 'cache'

def info(message):
    print(f'[INFO] {message}')

def ok(message):
    print(f'[OK] {message}')

def warn(message):
    print(f'[WARN] {message}')

def wsl_to_windows_path(path: Path) -> str:
    text = str(path)
    match = re.match(r'^/mnt/([a-zA-Z])/(.*)$', text)
    if match:
      drive = match.group(1).upper()
      tail = match.group(2).replace('/', '\\')
      return f'{drive}:\\{tail}'
    return text

def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def run_with_retry(cmd, cwd=None, attempts=2):
    last_exc = None
    for attempt in range(attempts):
        try:
            run(cmd, cwd=cwd)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            if attempt + 1 < attempts:
                continue
            raise last_exc

def is_hex_version(version):
    return bool(version) and re.fullmatch(r'[0-9a-fA-F]{7,40}', str(version)) is not None

def clone_repo(repo, dest, version=None, commit=None):
    if dest.exists() and (dest / '.git').exists():
        try:
            run(['git', '-C', str(dest), 'pull', '--ff-only', '--quiet'])
            return
        except subprocess.CalledProcessError as exc:
            warn(f'更新现有仓库失败，准备重建：{dest}（{exc}）')
            shutil.rmtree(dest)
    elif dest.exists():
        shutil.rmtree(dest)

    version_text = str(version or '')
    commit_text = str(commit or '')

    dest.parent.mkdir(parents=True, exist_ok=True)

    cloned = False
    ref_candidates = []
    if version_text and version_text != 'unknown' and not is_hex_version(version_text):
        ref_candidates.append(version_text)
        if version_text.startswith('v'):
            stripped_version = version_text[1:]
            if stripped_version and stripped_version not in ref_candidates:
                ref_candidates.append(stripped_version)
        else:
            prefixed_version = f'v{version_text}'
            if prefixed_version not in ref_candidates:
                ref_candidates.append(prefixed_version)

    for ref in ref_candidates:
        cmd = ['git', 'clone', '--depth', '1', '--branch', ref, '--single-branch', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
            break
        except subprocess.CalledProcessError:
            if dest.exists():
                shutil.rmtree(dest)

    if not cloned:
        cmd = ['git', 'clone', '--depth', '1', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
        except subprocess.CalledProcessError as exc:
            warn(f'克隆仓库失败：{repo} -> {dest}（{exc}）')
            return False

    if commit_text and is_hex_version(commit_text):
        try:
            run(['git', '-C', str(dest), 'checkout', '--quiet', commit_text])
        except subprocess.CalledProcessError as exc:
            warn(f'检出指定提交失败：{dest} @ {commit_text}（{exc}）')
    return True

def home_path(relative_path):
    text = str(relative_path).strip()
    if text.startswith('~'):
        text = text[1:]
    text = text.lstrip('/\\')
    return Path.home() / text

def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if path.exists():
        shutil.rmtree(path)

def ensure_symlink(source, target, is_dir=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        remove_path(target)
    os.symlink(source, target, target_is_directory=is_dir)

def copy_tree(source, destination):
    if destination.exists():
        remove_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        raise FileNotFoundError(source)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    else:
        shutil.copy2(source, destination)

if not manifest_path.exists():
    print('plugins manifest 不存在，跳过插件恢复。')
    sys.exit(0)

manifest_text = manifest_path.read_text().strip()
if not manifest_text:
    print('plugins manifest 为空，跳过插件恢复。')
    sys.exit(0)

try:
    manifest = json.loads(manifest_text)
except Exception as exc:
    print(f'无法读取 plugins manifest：{exc}')
    sys.exit(0)

marketplaces = manifest.get('marketplaces', [])
plugins = manifest.get('plugins', [])
if not marketplaces or not plugins:
    warn('plugins manifest 中没有可恢复的 marketplace 或 plugin。')
    sys.exit(0)

now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
marketplace_state = {}
for marketplace in marketplaces:
    marketplace_id = marketplace.get('id')
    repo = marketplace.get('repo')
    if not marketplace_id or not repo:
        warn('忽略一个缺少 id 或 repo 的 marketplace 条目。')
        continue

    dest_dir = marketplaces_root / marketplace_id
    clone_repo(repo, dest_dir, marketplace.get('version'))
    marketplace_state[marketplace_id] = {
        'source': {
            'source': marketplace.get('source', 'github'),
            'repo': repo,
        },
        'installLocation': wsl_to_windows_path(dest_dir),
        'lastUpdated': marketplace.get('lastUpdated', now_iso),
    }
    ok(f'已同步 marketplace：{marketplace_id}。')

installed_plugins = {}
for plugin in plugins:
    plugin_id = plugin.get('pluginId')
    marketplace_id = plugin.get('marketplaceId')
    source_repo = plugin.get('sourceRepo')
    install_path = plugin.get('installPath')
    version = plugin.get('version')
    restore = plugin.get('restore') or {}
    restore_kind = restore.get('kind', 'marketplace-plugin')
    if not plugin_id or not marketplace_id or not source_repo:
        warn('忽略一个缺少 pluginId、marketplaceId 或 sourceRepo 的 plugin 条目。')
        continue

    plugin_name = plugin_id.split('@', 1)[0]
    if restore_kind == 'codex-skill-package':
        install_root = home_path(restore.get('installRoot') or f'.codex/{plugin_name}')
        clone_repo(source_repo, install_root, version, plugin.get('gitCommitSha'))

        for link in restore.get('links', []):
            source_rel = link.get('source')
            target_rel = link.get('target')
            if not source_rel or not target_rel:
                warn(f'忽略一个缺少 source 或 target 的链接：{plugin_id}。')
                continue
            source_path = install_root / source_rel
            target_path = home_path(target_rel)
            if not source_path.exists():
                warn(f'跳过链接，源路径不存在：{source_path}。')
                continue
            ensure_symlink(source_path, target_path, link.get('type') == 'dir')

        installed_plugins.setdefault(plugin_id, []).append({
            'scope': 'user',
            'installPath': str(install_root),
            'version': version,
            'installedAt': plugin.get('installedAt', now_iso),
            'lastUpdated': plugin.get('lastUpdated', now_iso),
            **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
        })
        ok(f'已恢复本地 plugin 包：{plugin_name}。')
        continue

    source_path = restore.get('sourcePath', '.')
    if not install_path:
        warn(f'忽略一个缺少 installPath 的 marketplace plugin 条目：{plugin_id}。')
        continue

    checkout_dir = sync_root / marketplace_id / plugin_name
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    clone_repo(source_repo, checkout_dir, version, plugin.get('gitCommitSha'))

    cache_dir = claude_root / install_path
    source_dir = checkout_dir / source_path
    if not source_dir.exists():
        warn(f'跳过 plugin {plugin_name}：缺少源文件 {source_path}。')
        continue

    if source_dir.resolve() == checkout_dir.resolve():
        copy_tree(checkout_dir, cache_dir)
    else:
        copy_tree(source_dir, cache_dir)

    installed_plugins.setdefault(plugin_id, []).append({
        'scope': 'user',
        'installPath': wsl_to_windows_path(cache_dir),
        'version': version,
        'installedAt': plugin.get('installedAt', now_iso),
        'lastUpdated': plugin.get('lastUpdated', now_iso),
        **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
    })
    ok(f'已同步 plugin：{plugin_name}。')

installed_plugins_path = plugins_root / 'installed_plugins.json'
known_marketplaces_path = plugins_root / 'known_marketplaces.json'

installed_plugins_path.write_text(json.dumps({'version': 2, 'plugins': installed_plugins}, indent=2, ensure_ascii=False) + '\n')
known_marketplaces_path.write_text(json.dumps(marketplace_state, indent=2, ensure_ascii=False) + '\n')

ok(f'已重建 Claude 插件状态：{len(installed_plugins)} 个 plugins，{len(marketplace_state)} 个 marketplaces。')
PY
}

install_claude_plugins_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local claude_root="$2"
  local plugins_sync_root="$HOME/.codex/.tmp/plugin-sync"

  mkdir -p "$plugins_sync_root" "$claude_root/plugins"
  python3 - "$manifest_path" "$claude_root" "$plugins_sync_root" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
claude_root = Path(sys.argv[2])
sync_root = Path(sys.argv[3])
plugins_root = claude_root / 'plugins'
marketplaces_root = plugins_root / 'marketplaces'
cache_root = plugins_root / 'cache'

def info(message):
    print(f'[INFO] {message}')

def ok(message):
    print(f'[OK] {message}')

def warn(message):
    print(f'[WARN] {message}')

def wsl_to_windows_path(path: Path) -> str:
    text = str(path)
    match = re.match(r'^/mnt/([a-zA-Z])/(.*)$', text)
    if match:
      drive = match.group(1).upper()
      tail = match.group(2).replace('/', '\\')
      return f'{drive}:\\{tail}'
    return text

def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def run_with_retry(cmd, cwd=None, attempts=2):
    last_exc = None
    for attempt in range(attempts):
        try:
            run(cmd, cwd=cwd)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            if attempt + 1 < attempts:
                continue
            raise last_exc

def is_hex_version(version):
    return bool(version) and re.fullmatch(r'[0-9a-fA-F]{7,40}', str(version)) is not None

def clone_repo(repo, dest, version=None, commit=None):
    if dest.exists() and (dest / '.git').exists():
        try:
            run(['git', '-C', str(dest), 'pull', '--ff-only', '--quiet'])
            return
        except subprocess.CalledProcessError as exc:
            warn(f'更新现有仓库失败，准备重建：{dest}（{exc}）')
            shutil.rmtree(dest)
    elif dest.exists():
        shutil.rmtree(dest)

    version_text = str(version or '')
    commit_text = str(commit or '')

    dest.parent.mkdir(parents=True, exist_ok=True)

    cloned = False
    ref_candidates = []
    if version_text and version_text != 'unknown' and not is_hex_version(version_text):
        ref_candidates.append(version_text)
        if version_text.startswith('v'):
            stripped_version = version_text[1:]
            if stripped_version and stripped_version not in ref_candidates:
                ref_candidates.append(stripped_version)
        else:
            prefixed_version = f'v{version_text}'
            if prefixed_version not in ref_candidates:
                ref_candidates.append(prefixed_version)

    for ref in ref_candidates:
        cmd = ['git', 'clone', '--depth', '1', '--branch', ref, '--single-branch', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
            break
        except subprocess.CalledProcessError:
            if dest.exists():
                shutil.rmtree(dest)

    if not cloned:
        cmd = ['git', 'clone', '--depth', '1', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
        except subprocess.CalledProcessError as exc:
            warn(f'克隆仓库失败：{repo} -> {dest}（{exc}）')
            return False

    if commit_text and is_hex_version(commit_text):
        try:
            run(['git', '-C', str(dest), 'checkout', '--quiet', commit_text])
        except subprocess.CalledProcessError as exc:
            warn(f'检出指定提交失败：{dest} @ {commit_text}（{exc}）')
    return True

def home_path(relative_path):
    text = str(relative_path).strip()
    if text.startswith('~'):
        text = text[1:]
    text = text.lstrip('/\\')
    return Path.home() / text

def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if path.exists():
        shutil.rmtree(path)

def ensure_symlink(source, target, is_dir=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        remove_path(target)
    os.symlink(source, target, target_is_directory=is_dir)

def copy_tree(source, destination):
    if destination.exists():
        remove_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        raise FileNotFoundError(source)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    else:
        shutil.copy2(source, destination)

if not manifest_path.exists():
    print('plugins manifest 不存在，跳过插件恢复。')
    sys.exit(0)

manifest_text = manifest_path.read_text().strip()
if not manifest_text:
    print('plugins manifest 为空，跳过插件恢复。')
    sys.exit(0)

try:
    manifest = json.loads(manifest_text)
except Exception as exc:
    print(f'无法读取 plugins manifest：{exc}')
    sys.exit(0)

marketplaces = manifest.get('marketplaces', [])
plugins = manifest.get('plugins', [])
if not marketplaces or not plugins:
    warn('plugins manifest 中没有可恢复的 marketplace 或 plugin。')
    sys.exit(0)

now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
marketplace_state = {}
for marketplace in marketplaces:
    marketplace_id = marketplace.get('id')
    repo = marketplace.get('repo')
    if not marketplace_id or not repo:
        warn('忽略一个缺少 id 或 repo 的 marketplace 条目。')
        continue

    dest_dir = marketplaces_root / marketplace_id
    clone_repo(repo, dest_dir, marketplace.get('version'))
    marketplace_state[marketplace_id] = {
        'source': {
            'source': marketplace.get('source', 'github'),
            'repo': repo,
        },
        'installLocation': wsl_to_windows_path(dest_dir),
        'lastUpdated': marketplace.get('lastUpdated', now_iso),
    }
    ok(f'已同步 marketplace：{marketplace_id}。')

installed_plugins = {}
for plugin in plugins:
    plugin_id = plugin.get('pluginId')
    marketplace_id = plugin.get('marketplaceId')
    source_repo = plugin.get('sourceRepo')
    install_path = plugin.get('installPath')
    version = plugin.get('version')
    restore = plugin.get('restore') or {}
    restore_kind = restore.get('kind', 'marketplace-plugin')
    if not plugin_id or not marketplace_id or not source_repo:
        warn('忽略一个缺少 pluginId、marketplaceId 或 sourceRepo 的 plugin 条目。')
        continue

    plugin_name = plugin_id.split('@', 1)[0]
    if restore_kind == 'codex-skill-package':
        install_root = home_path(restore.get('installRoot') or f'.codex/{plugin_name}')
        clone_repo(source_repo, install_root, version, plugin.get('gitCommitSha'))

        for link in restore.get('links', []):
            source_rel = link.get('source')
            target_rel = link.get('target')
            if not source_rel or not target_rel:
                warn(f'忽略一个缺少 source 或 target 的链接：{plugin_id}。')
                continue
            source_path = install_root / source_rel
            target_path = home_path(target_rel)
            if not source_path.exists():
                warn(f'跳过链接，源路径不存在：{source_path}。')
                continue
            ensure_symlink(source_path, target_path, link.get('type') == 'dir')

        installed_plugins.setdefault(plugin_id, []).append({
            'scope': 'user',
            'installPath': str(install_root),
            'version': version,
            'installedAt': plugin.get('installedAt', now_iso),
            'lastUpdated': plugin.get('lastUpdated', now_iso),
            **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
        })
        ok(f'已恢复本地 plugin 包：{plugin_name}。')
        continue

    source_path = restore.get('sourcePath', '.')
    if not install_path:
        warn(f'忽略一个缺少 installPath 的 marketplace plugin 条目：{plugin_id}。')
        continue

    checkout_dir = sync_root / marketplace_id / plugin_name
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    clone_repo(source_repo, checkout_dir, version, plugin.get('gitCommitSha'))

    cache_dir = claude_root / install_path
    source_dir = checkout_dir / source_path
    if not source_dir.exists():
        warn(f'跳过 plugin {plugin_name}：缺少源文件 {source_path}。')
        continue

    if source_dir.resolve() == checkout_dir.resolve():
        copy_tree(checkout_dir, cache_dir)
    else:
        copy_tree(source_dir, cache_dir)

    installed_plugins.setdefault(plugin_id, []).append({
        'scope': 'user',
        'installPath': wsl_to_windows_path(cache_dir),
        'version': version,
        'installedAt': plugin.get('installedAt', now_iso),
        'lastUpdated': plugin.get('lastUpdated', now_iso),
        **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
    })
    ok(f'已同步 plugin：{plugin_name}。')

installed_plugins_path = plugins_root / 'installed_plugins.json'
known_marketplaces_path = plugins_root / 'known_marketplaces.json'

installed_plugins_path.write_text(json.dumps({'version': 2, 'plugins': installed_plugins}, indent=2, ensure_ascii=False) + '\n')
known_marketplaces_path.write_text(json.dumps(marketplace_state, indent=2, ensure_ascii=False) + '\n')

ok(f'已重建 Claude 插件状态：{len(installed_plugins)} 个 plugins，{len(marketplace_state)} 个 marketplaces。')
PY
}

update_skills() {
  echo "[INFO] 正在检查 skills 更新。"
  local temp_manifest
  temp_manifest="$(mktemp)"
  if curl -fsSL "$DEFAULT_SKILLS_MANIFEST_URL" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_skills_from_manifest "$temp_manifest"
    else
      echo "[WARN] 下载到的 skills manifest 无效：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 更新。"
    fi
  else
    echo "[WARN] 未能下载 skills manifest：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 更新。"
  fi
  rm -f "$temp_manifest"
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

  current_version="$($real_codex --version 2>/dev/null | awk '{print $NF}' || true)"
  current_version="${current_version:-}"
  latest_version="$(npm view @openai/codex version --silent 2>/dev/null || true)"
  latest_version="${latest_version:-}"

  if [ -z "${latest_version:-}" ]; then
    echo '[WARN] 无法获取 Codex 最新版本，跳过自动更新。'
    touch_update_stamp
    return 0
  fi

  if [ "${current_version:-}" = "${latest_version:-}" ]; then
    echo "[INFO] Codex 已是最新版本：${current_version:-}。"
    touch_update_stamp
    return 0
  fi

  echo "[INFO] 检测到 Codex 新版本：${current_version:-} -> ${latest_version:-}，开始更新。"
  mkdir -p "$codex_prefix"
  if npm i -g --prefix "$codex_prefix" @openai/codex@latest --silent --no-fund --no-audit >/dev/null 2>&1; then
    echo "[OK] Codex 已更新到最新版本：${latest_version:-}。"
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

install_skills_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local skills_dir="$HOME/.codex/skills"
  local skills_sync_root="$HOME/.codex/.tmp/skill-sync"

  mkdir -p "$skills_dir" "$skills_sync_root"
  python3 - "$manifest_path" "$skills_dir" "$skills_sync_root" <<'PY'
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
resolved_skills = []
for skill in skills:
    name = skill.get('name')
    source_id = skill.get('sourceId')
    source_path = skill.get('sourcePath')
    if not name or not source_id or not source_path:
        warn('忽略一个缺少 name、sourceId 或 sourcePath 的 skill 条目。')
        continue
    if source_id not in sources:
        source = next((item for item in manifest.get('sources', []) if item.get('id') == source_id), None)
        if not source or not source.get('repo'):
            warn(f"跳过 skill {name}：source '{source_id}' 缺少 repo URL。")
            continue
        sources[source_id] = source
    resolved_skills.append(skill)

skills = resolved_skills
if not skills:
    warn('没有可安装的有效 skills，跳过 skills 安装。')
    sys.exit(0)

info(f'准备安装 {len(skills)} 个 skills，来自 {len(sources)} 个源。')
installed_count = 0
for source_id, source in sorted(sources.items()):
    info(f'正在同步 skills 源：{source_id}（{source["repo"]}）。')
    checkout_dir = sync_root / source_id
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    cmd = ['git', 'clone', '--depth', '1']
    ref = source.get('ref')
    if ref:
        cmd.extend(['--branch', str(ref)])
    cmd.extend([source['repo'], str(checkout_dir)])
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as exc:
        warn(f'同步 skills 源失败，已跳过：{source_id}（{exc}）。')
        continue
    if not checkout_dir.exists():
        warn(f'同步 skills 源后目录不存在，已跳过：{source_id}。')
        continue
    ok(f'已同步 skills 源：{source_id}。')

info('正在安装 skills 内容。')
for skill in skills:
    name = skill['name']
    info(f'正在安装 skill：{name}。')
    checkout_dir = sync_root / skill['sourceId']
    source_path = skill['sourcePath']
    dest_dir = skills_dir / name
    source_dir = checkout_dir / source_path

    if not source_dir.exists():
        warn(f'跳过 skill {name}：缺少源文件 {skill["sourceId"]}/{source_path}。')
        continue

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    try:
        if source_path == '.':
            subprocess.run(
                ['rsync', '-a', '--delete', '--exclude=.git', f'{checkout_dir}/', f'{dest_dir}/'],
                check=True,
            )
        else:
            subprocess.run(
                ['rsync', '-a', '--delete', f'{source_dir}/', f'{dest_dir}/'],
                check=True,
            )
    except subprocess.CalledProcessError as exc:
        warn(f'安装 skill 失败，已跳过：{name}（{exc}）。')
        continue
    installed_count += 1
    ok(f'已安装 skill：{name}。')

ok(f'已刷新 {installed_count} 个 skills。')
PY
}

install_claude_plugins_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local claude_root="$2"
  local plugins_sync_root="$HOME/.codex/.tmp/plugin-sync"

  mkdir -p "$plugins_sync_root" "$claude_root/plugins"
  python3 - "$manifest_path" "$claude_root" "$plugins_sync_root" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
claude_root = Path(sys.argv[2])
sync_root = Path(sys.argv[3])
plugins_root = claude_root / 'plugins'
marketplaces_root = plugins_root / 'marketplaces'
cache_root = plugins_root / 'cache'

def info(message):
    print(f'[INFO] {message}')

def ok(message):
    print(f'[OK] {message}')

def warn(message):
    print(f'[WARN] {message}')

def wsl_to_windows_path(path: Path) -> str:
    text = str(path)
    match = re.match(r'^/mnt/([a-zA-Z])/(.*)$', text)
    if match:
      drive = match.group(1).upper()
      tail = match.group(2).replace('/', '\\')
      return f'{drive}:\\{tail}'
    return text

def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def run_with_retry(cmd, cwd=None, attempts=2):
    last_exc = None
    for attempt in range(attempts):
        try:
            run(cmd, cwd=cwd)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            if attempt + 1 < attempts:
                continue
            raise last_exc

def is_hex_version(version):
    return bool(version) and re.fullmatch(r'[0-9a-fA-F]{7,40}', str(version)) is not None

def clone_repo(repo, dest, version=None, commit=None):
    if dest.exists() and (dest / '.git').exists():
        try:
            run(['git', '-C', str(dest), 'pull', '--ff-only', '--quiet'])
            return
        except subprocess.CalledProcessError as exc:
            warn(f'更新现有仓库失败，准备重建：{dest}（{exc}）')
            shutil.rmtree(dest)
    elif dest.exists():
        shutil.rmtree(dest)

    version_text = str(version or '')
    commit_text = str(commit or '')

    dest.parent.mkdir(parents=True, exist_ok=True)

    cloned = False
    ref_candidates = []
    if version_text and version_text != 'unknown' and not is_hex_version(version_text):
        ref_candidates.append(version_text)
        if version_text.startswith('v'):
            stripped_version = version_text[1:]
            if stripped_version and stripped_version not in ref_candidates:
                ref_candidates.append(stripped_version)
        else:
            prefixed_version = f'v{version_text}'
            if prefixed_version not in ref_candidates:
                ref_candidates.append(prefixed_version)

    for ref in ref_candidates:
        cmd = ['git', 'clone', '--depth', '1', '--branch', ref, '--single-branch', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
            break
        except subprocess.CalledProcessError:
            if dest.exists():
                shutil.rmtree(dest)

    if not cloned:
        cmd = ['git', 'clone', '--depth', '1', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
        except subprocess.CalledProcessError as exc:
            warn(f'克隆仓库失败：{repo} -> {dest}（{exc}）')
            return False

    if commit_text and is_hex_version(commit_text):
        try:
            run(['git', '-C', str(dest), 'checkout', '--quiet', commit_text])
        except subprocess.CalledProcessError as exc:
            warn(f'检出指定提交失败：{dest} @ {commit_text}（{exc}）')
    return True

def home_path(relative_path):
    text = str(relative_path).strip()
    if text.startswith('~'):
        text = text[1:]
    text = text.lstrip('/\\')
    return Path.home() / text

def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if path.exists():
        shutil.rmtree(path)

def ensure_symlink(source, target, is_dir=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        remove_path(target)
    os.symlink(source, target, target_is_directory=is_dir)

def copy_tree(source, destination):
    if destination.exists():
        remove_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        raise FileNotFoundError(source)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    else:
        shutil.copy2(source, destination)

if not manifest_path.exists():
    print('plugins manifest 不存在，跳过插件恢复。')
    sys.exit(0)

manifest_text = manifest_path.read_text().strip()
if not manifest_text:
    print('plugins manifest 为空，跳过插件恢复。')
    sys.exit(0)

try:
    manifest = json.loads(manifest_text)
except Exception as exc:
    print(f'无法读取 plugins manifest：{exc}')
    sys.exit(0)

marketplaces = manifest.get('marketplaces', [])
plugins = manifest.get('plugins', [])
if not marketplaces or not plugins:
    warn('plugins manifest 中没有可恢复的 marketplace 或 plugin。')
    sys.exit(0)

now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
marketplace_state = {}
for marketplace in marketplaces:
    marketplace_id = marketplace.get('id')
    repo = marketplace.get('repo')
    if not marketplace_id or not repo:
        warn('忽略一个缺少 id 或 repo 的 marketplace 条目。')
        continue

    dest_dir = marketplaces_root / marketplace_id
    clone_repo(repo, dest_dir, marketplace.get('version'))
    marketplace_state[marketplace_id] = {
        'source': {
            'source': marketplace.get('source', 'github'),
            'repo': repo,
        },
        'installLocation': wsl_to_windows_path(dest_dir),
        'lastUpdated': marketplace.get('lastUpdated', now_iso),
    }
    ok(f'已同步 marketplace：{marketplace_id}。')

installed_plugins = {}
for plugin in plugins:
    plugin_id = plugin.get('pluginId')
    marketplace_id = plugin.get('marketplaceId')
    source_repo = plugin.get('sourceRepo')
    install_path = plugin.get('installPath')
    version = plugin.get('version')
    restore = plugin.get('restore') or {}
    restore_kind = restore.get('kind', 'marketplace-plugin')
    if not plugin_id or not marketplace_id or not source_repo:
        warn('忽略一个缺少 pluginId、marketplaceId 或 sourceRepo 的 plugin 条目。')
        continue

    plugin_name = plugin_id.split('@', 1)[0]
    if restore_kind == 'codex-skill-package':
        install_root = home_path(restore.get('installRoot') or f'.codex/{plugin_name}')
        clone_repo(source_repo, install_root, version, plugin.get('gitCommitSha'))

        for link in restore.get('links', []):
            source_rel = link.get('source')
            target_rel = link.get('target')
            if not source_rel or not target_rel:
                warn(f'忽略一个缺少 source 或 target 的链接：{plugin_id}。')
                continue
            source_path = install_root / source_rel
            target_path = home_path(target_rel)
            if not source_path.exists():
                warn(f'跳过链接，源路径不存在：{source_path}。')
                continue
            ensure_symlink(source_path, target_path, link.get('type') == 'dir')

        installed_plugins.setdefault(plugin_id, []).append({
            'scope': 'user',
            'installPath': str(install_root),
            'version': version,
            'installedAt': plugin.get('installedAt', now_iso),
            'lastUpdated': plugin.get('lastUpdated', now_iso),
            **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
        })
        ok(f'已恢复本地 plugin 包：{plugin_name}。')
        continue

    source_path = restore.get('sourcePath', '.')
    if not install_path:
        warn(f'忽略一个缺少 installPath 的 marketplace plugin 条目：{plugin_id}。')
        continue

    checkout_dir = sync_root / marketplace_id / plugin_name
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    clone_repo(source_repo, checkout_dir, version, plugin.get('gitCommitSha'))

    cache_dir = claude_root / install_path
    source_dir = checkout_dir / source_path
    if not source_dir.exists():
        warn(f'跳过 plugin {plugin_name}：缺少源文件 {source_path}。')
        continue

    if source_dir.resolve() == checkout_dir.resolve():
        copy_tree(checkout_dir, cache_dir)
    else:
        copy_tree(source_dir, cache_dir)

    installed_plugins.setdefault(plugin_id, []).append({
        'scope': 'user',
        'installPath': wsl_to_windows_path(cache_dir),
        'version': version,
        'installedAt': plugin.get('installedAt', now_iso),
        'lastUpdated': plugin.get('lastUpdated', now_iso),
        **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
    })
    ok(f'已同步 plugin：{plugin_name}。')

installed_plugins_path = plugins_root / 'installed_plugins.json'
known_marketplaces_path = plugins_root / 'known_marketplaces.json'

installed_plugins_path.write_text(json.dumps({'version': 2, 'plugins': installed_plugins}, indent=2, ensure_ascii=False) + '\n')
known_marketplaces_path.write_text(json.dumps(marketplace_state, indent=2, ensure_ascii=False) + '\n')

ok(f'已重建 Claude 插件状态：{len(installed_plugins)} 个 plugins，{len(marketplace_state)} 个 marketplaces。')
PY
}

install_claude_plugins_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local claude_root="$2"
  local plugins_sync_root="$HOME/.codex/.tmp/plugin-sync"

  mkdir -p "$plugins_sync_root" "$claude_root/plugins"
  python3 - "$manifest_path" "$claude_root" "$plugins_sync_root" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
claude_root = Path(sys.argv[2])
sync_root = Path(sys.argv[3])
plugins_root = claude_root / 'plugins'
marketplaces_root = plugins_root / 'marketplaces'
cache_root = plugins_root / 'cache'

def info(message):
    print(f'[INFO] {message}')

def ok(message):
    print(f'[OK] {message}')

def warn(message):
    print(f'[WARN] {message}')

def wsl_to_windows_path(path: Path) -> str:
    text = str(path)
    match = re.match(r'^/mnt/([a-zA-Z])/(.*)$', text)
    if match:
      drive = match.group(1).upper()
      tail = match.group(2).replace('/', '\\')
      return f'{drive}:\\{tail}'
    return text

def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def run_with_retry(cmd, cwd=None, attempts=2):
    last_exc = None
    for attempt in range(attempts):
        try:
            run(cmd, cwd=cwd)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            if attempt + 1 < attempts:
                continue
            raise last_exc

def is_hex_version(version):
    return bool(version) and re.fullmatch(r'[0-9a-fA-F]{7,40}', str(version)) is not None

def clone_repo(repo, dest, version=None, commit=None):
    if dest.exists() and (dest / '.git').exists():
        try:
            run(['git', '-C', str(dest), 'pull', '--ff-only', '--quiet'])
            return
        except subprocess.CalledProcessError as exc:
            warn(f'更新现有仓库失败，准备重建：{dest}（{exc}）')
            shutil.rmtree(dest)
    elif dest.exists():
        shutil.rmtree(dest)

    version_text = str(version or '')
    commit_text = str(commit or '')

    dest.parent.mkdir(parents=True, exist_ok=True)

    cloned = False
    ref_candidates = []
    if version_text and version_text != 'unknown' and not is_hex_version(version_text):
        ref_candidates.append(version_text)
        if version_text.startswith('v'):
            stripped_version = version_text[1:]
            if stripped_version and stripped_version not in ref_candidates:
                ref_candidates.append(stripped_version)
        else:
            prefixed_version = f'v{version_text}'
            if prefixed_version not in ref_candidates:
                ref_candidates.append(prefixed_version)

    for ref in ref_candidates:
        cmd = ['git', 'clone', '--depth', '1', '--branch', ref, '--single-branch', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
            break
        except subprocess.CalledProcessError:
            if dest.exists():
                shutil.rmtree(dest)

    if not cloned:
        cmd = ['git', 'clone', '--depth', '1', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
        except subprocess.CalledProcessError as exc:
            warn(f'克隆仓库失败：{repo} -> {dest}（{exc}）')
            return False

    if commit_text and is_hex_version(commit_text):
        try:
            run(['git', '-C', str(dest), 'checkout', '--quiet', commit_text])
        except subprocess.CalledProcessError as exc:
            warn(f'检出指定提交失败：{dest} @ {commit_text}（{exc}）')
    return True

def home_path(relative_path):
    text = str(relative_path).strip()
    if text.startswith('~'):
        text = text[1:]
    text = text.lstrip('/\\')
    return Path.home() / text

def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if path.exists():
        shutil.rmtree(path)

def ensure_symlink(source, target, is_dir=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        remove_path(target)
    os.symlink(source, target, target_is_directory=is_dir)

def copy_tree(source, destination):
    if destination.exists():
        remove_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        raise FileNotFoundError(source)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    else:
        shutil.copy2(source, destination)

if not manifest_path.exists():
    print('plugins manifest 不存在，跳过插件恢复。')
    sys.exit(0)

manifest_text = manifest_path.read_text().strip()
if not manifest_text:
    print('plugins manifest 为空，跳过插件恢复。')
    sys.exit(0)

try:
    manifest = json.loads(manifest_text)
except Exception as exc:
    print(f'无法读取 plugins manifest：{exc}')
    sys.exit(0)

marketplaces = manifest.get('marketplaces', [])
plugins = manifest.get('plugins', [])
if not marketplaces or not plugins:
    warn('plugins manifest 中没有可恢复的 marketplace 或 plugin。')
    sys.exit(0)

now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
marketplace_state = {}
for marketplace in marketplaces:
    marketplace_id = marketplace.get('id')
    repo = marketplace.get('repo')
    if not marketplace_id or not repo:
        warn('忽略一个缺少 id 或 repo 的 marketplace 条目。')
        continue

    dest_dir = marketplaces_root / marketplace_id
    clone_repo(repo, dest_dir, marketplace.get('version'))
    marketplace_state[marketplace_id] = {
        'source': {
            'source': marketplace.get('source', 'github'),
            'repo': repo,
        },
        'installLocation': wsl_to_windows_path(dest_dir),
        'lastUpdated': marketplace.get('lastUpdated', now_iso),
    }
    ok(f'已同步 marketplace：{marketplace_id}。')

installed_plugins = {}
for plugin in plugins:
    plugin_id = plugin.get('pluginId')
    marketplace_id = plugin.get('marketplaceId')
    source_repo = plugin.get('sourceRepo')
    install_path = plugin.get('installPath')
    version = plugin.get('version')
    restore = plugin.get('restore') or {}
    restore_kind = restore.get('kind', 'marketplace-plugin')
    if not plugin_id or not marketplace_id or not source_repo:
        warn('忽略一个缺少 pluginId、marketplaceId 或 sourceRepo 的 plugin 条目。')
        continue

    plugin_name = plugin_id.split('@', 1)[0]
    if restore_kind == 'codex-skill-package':
        install_root = home_path(restore.get('installRoot') or f'.codex/{plugin_name}')
        clone_repo(source_repo, install_root, version, plugin.get('gitCommitSha'))

        for link in restore.get('links', []):
            source_rel = link.get('source')
            target_rel = link.get('target')
            if not source_rel or not target_rel:
                warn(f'忽略一个缺少 source 或 target 的链接：{plugin_id}。')
                continue
            source_path = install_root / source_rel
            target_path = home_path(target_rel)
            if not source_path.exists():
                warn(f'跳过链接，源路径不存在：{source_path}。')
                continue
            ensure_symlink(source_path, target_path, link.get('type') == 'dir')

        installed_plugins.setdefault(plugin_id, []).append({
            'scope': 'user',
            'installPath': str(install_root),
            'version': version,
            'installedAt': plugin.get('installedAt', now_iso),
            'lastUpdated': plugin.get('lastUpdated', now_iso),
            **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
        })
        ok(f'已恢复本地 plugin 包：{plugin_name}。')
        continue

    source_path = restore.get('sourcePath', '.')
    if not install_path:
        warn(f'忽略一个缺少 installPath 的 marketplace plugin 条目：{plugin_id}。')
        continue

    checkout_dir = sync_root / marketplace_id / plugin_name
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    clone_repo(source_repo, checkout_dir, version, plugin.get('gitCommitSha'))

    cache_dir = claude_root / install_path
    source_dir = checkout_dir / source_path
    if not source_dir.exists():
        warn(f'跳过 plugin {plugin_name}：缺少源文件 {source_path}。')
        continue

    if source_dir.resolve() == checkout_dir.resolve():
        copy_tree(checkout_dir, cache_dir)
    else:
        copy_tree(source_dir, cache_dir)

    installed_plugins.setdefault(plugin_id, []).append({
        'scope': 'user',
        'installPath': wsl_to_windows_path(cache_dir),
        'version': version,
        'installedAt': plugin.get('installedAt', now_iso),
        'lastUpdated': plugin.get('lastUpdated', now_iso),
        **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
    })
    ok(f'已同步 plugin：{plugin_name}。')

installed_plugins_path = plugins_root / 'installed_plugins.json'
known_marketplaces_path = plugins_root / 'known_marketplaces.json'

installed_plugins_path.write_text(json.dumps({'version': 2, 'plugins': installed_plugins}, indent=2, ensure_ascii=False) + '\n')
known_marketplaces_path.write_text(json.dumps(marketplace_state, indent=2, ensure_ascii=False) + '\n')

ok(f'已重建 Claude 插件状态：{len(installed_plugins)} 个 plugins，{len(marketplace_state)} 个 marketplaces。')
PY
}
update_skills() {
  echo "[INFO] 正在检查 skills 更新。"
  local temp_manifest
  temp_manifest="$(mktemp)"
  if curl -fsSL "$DEFAULT_SKILLS_MANIFEST_URL" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_skills_from_manifest "$temp_manifest"
    else
      echo "[WARN] 下载到的 skills manifest 无效：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 更新。"
    fi
  else
    echo "[WARN] 未能下载 skills manifest：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 更新。"
  fi
  rm -f "$temp_manifest"
  return 0
}

update_plugins_state() {
  echo "[INFO] 正在检查插件状态恢复。"
  local temp_manifest
  temp_manifest="$(mktemp)"
  if curl -fsSL "$DEFAULT_PLUGINS_MANIFEST_URL" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_claude_plugins_from_manifest "$temp_manifest" "$HOME/.claude"
    else
      echo "[WARN] 下载到的 plugins manifest 无效：$DEFAULT_PLUGINS_MANIFEST_URL，跳过插件恢复。"
    fi
  else
    echo "[WARN] 未能下载 plugins manifest：$DEFAULT_PLUGINS_MANIFEST_URL，跳过插件恢复。"
  fi
  rm -f "$temp_manifest"
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

  current_version="$($real_codex --version 2>/dev/null | awk '{print $NF}' || true)"
  current_version="${current_version:-}"
  latest_version="$(npm view @openai/codex version --silent 2>/dev/null || true)"
  latest_version="${latest_version:-}"

  if [ -z "${latest_version:-}" ]; then
    echo '[WARN] 无法获取 Codex 最新版本，跳过自动更新。'
    touch_update_stamp
    return 0
  fi

  if [ "${current_version:-}" = "${latest_version:-}" ]; then
    echo "[INFO] Codex 已是最新版本：${current_version:-}。"
    touch_update_stamp
    return 0
  fi

  echo "[INFO] 检测到 Codex 新版本：${current_version:-} -> ${latest_version:-}，开始更新。"
  mkdir -p "$codex_prefix"
  if npm i -g --prefix "$codex_prefix" @openai/codex@latest --silent --no-fund --no-audit >/dev/null 2>&1; then
    echo "[OK] Codex 已更新到最新版本：${latest_version:-}。"
  else
    echo '[WARN] Codex 更新失败，将继续使用当前版本。'
  fi
  touch_update_stamp
}

sync_update_artifacts() {
  if should_check_update; then
    update_codex
    update_plugins
    update_plugins_state
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

write_apply_patch_wrapper() {
  ensure_root_home

  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/apply_patch" <<'EOF_APPLY_PATCH'
#!/usr/bin/env bash
set -euo pipefail

find_session_apply_patch() {
  local candidate

  shopt -s nullglob
  for candidate in "$HOME/.codex/tmp/arg0"/codex-arg0*/apply_patch "$HOME/.codex/tmp/arg0"/codex-arg0*/applypatch; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

find_stable_apply_patch() {
  local candidate

  for candidate in "$HOME/.codex/npm-global/lib/node_modules/@openai/codex"/node_modules/@openai/codex-*/vendor/*/codex/codex; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

if target="$(find_session_apply_patch 2>/dev/null)"; then
  exec "$target" "$@"
fi

if target="$(find_stable_apply_patch 2>/dev/null)"; then
  exec "$target" "$@"
fi

printf '%s\n' 'apply_patch: no session-local Codex apply_patch executable found under ~/.codex/tmp/arg0.' >&2
printf '%s\n' 'No stable Codex patch binary was found either.' >&2
exit 1
EOF_APPLY_PATCH
  chmod +x "$HOME/.local/bin/apply_patch"
  ln -sf "$HOME/.local/bin/apply_patch" "$HOME/.local/bin/applypatch"

  local vendor_path_dir
  vendor_path_dir="$(get_codex_vendor_path_dir)"
  mkdir -p "$vendor_path_dir"
  ln -sf "$HOME/.local/bin/apply_patch" "$vendor_path_dir/apply_patch"
  ln -sf "$HOME/.local/bin/apply_patch" "$vendor_path_dir/applypatch"
}

install_skills_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local skills_dir="$HOME/.codex/skills"
  local skills_sync_root="$HOME/.codex/.tmp/skill-sync"

  mkdir -p "$skills_dir" "$skills_sync_root"
  python3 - "$manifest_path" "$skills_dir" "$skills_sync_root" <<'PY'
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
resolved_skills = []

info(f'准备安装 {len(skills)} 个 skills。')
for skill in skills:
    name = skill.get('name')
    source_id = skill.get('sourceId')
    source_path = skill.get('sourcePath')
    if not name or not source_id or not source_path:
        warn('忽略一个缺少 name、sourceId 或 sourcePath 的 skill 条目。')
        continue
    if source_id not in sources:
        source = next((item for item in manifest.get('sources', []) if item.get('id') == source_id), None)
        if not source or not source.get('repo'):
            warn(f"跳过 skill {name}：source '{source_id}' 缺少 repo URL。")
            continue
        sources[source_id] = source
    resolved_skills.append(skill)

skills = resolved_skills
if not skills:
    warn('没有可安装的有效 skills，跳过 skills 安装。')
    sys.exit(0)

installed_count = 0
for source_id, source in sorted(sources.items()):
    info(f'正在同步 skills 源：{source_id}（{source["repo"]}）。')
    checkout_dir = sync_root / source_id
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    cmd = ['git', 'clone', '--depth', '1']
    ref = source.get('ref')
    if ref:
        cmd.extend(['--branch', str(ref)])
    cmd.extend([source['repo'], str(checkout_dir)])
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as exc:
        warn(f'同步 skills 源失败，已跳过：{source_id}（{exc}）。')
        continue
    if not checkout_dir.exists():
        warn(f'同步 skills 源后目录不存在，已跳过：{source_id}。')
        continue
    ok(f'已同步 skills 源：{source_id}。')

info('正在安装 skills 内容。')
for skill in skills:
    info(f'正在安装 skill：{skill["name"]}。')
    checkout_dir = sync_root / skill['sourceId']
    source_path = skill['sourcePath']
    dest_dir = skills_dir / skill['name']
    source_dir = checkout_dir / source_path

    if not source_dir.exists():
        warn(f'跳过 skill {skill["name"]}：缺少源文件 {skill["sourceId"]}/{source_path}。')
        continue

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    try:
        if source_path == '.':
            subprocess.run(
                ['rsync', '-a', '--delete', '--exclude=.git', f'{checkout_dir}/', f'{dest_dir}/'],
                check=True,
            )
        else:
            subprocess.run(
                ['rsync', '-a', '--delete', f'{source_dir}/', f'{dest_dir}/'],
                check=True,
            )
    except subprocess.CalledProcessError as exc:
        warn(f'安装 skill 失败，已跳过：{skill["name"]}（{exc}）。')
        continue
    installed_count += 1
    ok(f'已安装 skill：{skill["name"]}。')
ok(f'已刷新 {installed_count} 个 skills。')
PY
}

install_claude_plugins_from_manifest() {
  ensure_root_home

  local manifest_path="$1"
  local claude_root="$2"
  local plugins_sync_root="$HOME/.codex/.tmp/plugin-sync"

  mkdir -p "$plugins_sync_root" "$claude_root/plugins"
  python3 - "$manifest_path" "$claude_root" "$plugins_sync_root" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
claude_root = Path(sys.argv[2])
sync_root = Path(sys.argv[3])
plugins_root = claude_root / 'plugins'
marketplaces_root = plugins_root / 'marketplaces'
cache_root = plugins_root / 'cache'

def info(message):
    print(f'[INFO] {message}')

def ok(message):
    print(f'[OK] {message}')

def warn(message):
    print(f'[WARN] {message}')

def wsl_to_windows_path(path: Path) -> str:
    text = str(path)
    match = re.match(r'^/mnt/([a-zA-Z])/(.*)$', text)
    if match:
        drive = match.group(1).upper()
        tail = match.group(2).replace('/', '\\')
        return f'{drive}:\\{tail}'
    return text

def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def run_with_retry(cmd, cwd=None, attempts=2):
    last_exc = None
    for attempt in range(attempts):
        try:
            run(cmd, cwd=cwd)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            if attempt + 1 < attempts:
                continue
            raise last_exc

def is_hex_version(version):
    return bool(version) and re.fullmatch(r'[0-9a-fA-F]{7,40}', str(version)) is not None

def clone_repo(repo, dest, version=None, commit=None):
    if dest.exists() and (dest / '.git').exists():
        try:
            run(['git', '-C', str(dest), 'pull', '--ff-only', '--quiet'])
            return
        except subprocess.CalledProcessError as exc:
            warn(f'更新现有仓库失败，准备重建：{dest}（{exc}）')
            shutil.rmtree(dest)
    elif dest.exists():
        shutil.rmtree(dest)

    version_text = str(version or '')
    commit_text = str(commit or '')
    dest.parent.mkdir(parents=True, exist_ok=True)
    cloned = False
    ref_candidates = []
    if version_text and version_text != 'unknown' and not is_hex_version(version_text):
        ref_candidates.append(version_text)
        if version_text.startswith('v'):
            stripped_version = version_text[1:]
            if stripped_version and stripped_version not in ref_candidates:
                ref_candidates.append(stripped_version)
        else:
            prefixed_version = f'v{version_text}'
            if prefixed_version not in ref_candidates:
                ref_candidates.append(prefixed_version)

    for ref in ref_candidates:
        cmd = ['git', 'clone', '--depth', '1', '--branch', ref, '--single-branch', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
            break
        except subprocess.CalledProcessError:
            if dest.exists():
                shutil.rmtree(dest)

    if not cloned:
        cmd = ['git', 'clone', '--depth', '1', repo, str(dest)]
        try:
            run_with_retry(cmd)
            cloned = True
        except subprocess.CalledProcessError as exc:
            warn(f'克隆仓库失败：{repo} -> {dest}（{exc}）')
            return False
    if commit_text and is_hex_version(commit_text):
        try:
            run(['git', '-C', str(dest), 'checkout', '--quiet', commit_text])
        except subprocess.CalledProcessError:
            try:
                run(['git', '-C', str(dest), 'fetch', '--depth', '1', 'origin', commit_text])
                run(['git', '-C', str(dest), 'checkout', '--quiet', commit_text])
            except subprocess.CalledProcessError as exc:
                warn(f'检出指定提交失败：{dest} @ {commit_text}（{exc}）')
    return True

def home_path(relative_path):
    text = str(relative_path).strip()
    if text.startswith('~'):
        text = text[1:]
    text = text.lstrip('/\\')
    return Path.home() / text

def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if path.exists():
        shutil.rmtree(path)

def ensure_symlink(source, target, is_dir=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        remove_path(target)
    os.symlink(source, target, target_is_directory=is_dir)

def copy_tree(source, destination):
    if destination.exists():
        remove_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        raise FileNotFoundError(source)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    else:
        shutil.copy2(source, destination)

if not manifest_path.exists():
    print('plugins manifest 不存在，跳过插件恢复。')
    sys.exit(0)

manifest_text = manifest_path.read_text().strip()
if not manifest_text:
    print('plugins manifest 为空，跳过插件恢复。')
    sys.exit(0)

try:
    manifest = json.loads(manifest_text)
except Exception as exc:
    print(f'无法读取 plugins manifest：{exc}')
    sys.exit(0)

marketplaces = manifest.get('marketplaces', [])
plugins = manifest.get('plugins', [])
if not marketplaces or not plugins:
    warn('plugins manifest 中没有可恢复的 marketplace 或 plugin。')
    sys.exit(0)

now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
marketplace_state = {}
for marketplace in marketplaces:
    marketplace_id = marketplace.get('id')
    repo = marketplace.get('repo')
    if not marketplace_id or not repo:
        warn('忽略一个缺少 id 或 repo 的 marketplace 条目。')
        continue

    dest_dir = marketplaces_root / marketplace_id
    clone_repo(repo, dest_dir, marketplace.get('version'))
    marketplace_state[marketplace_id] = {
        'source': {
            'source': marketplace.get('source', 'github'),
            'repo': repo,
        },
        'installLocation': wsl_to_windows_path(dest_dir),
        'lastUpdated': marketplace.get('lastUpdated', now_iso),
    }
    ok(f'已同步 marketplace：{marketplace_id}。')

installed_plugins = {}
for plugin in plugins:
    plugin_id = plugin.get('pluginId')
    marketplace_id = plugin.get('marketplaceId')
    source_repo = plugin.get('sourceRepo')
    install_path = plugin.get('installPath')
    version = plugin.get('version')
    restore = plugin.get('restore') or {}
    restore_kind = restore.get('kind', 'marketplace-plugin')
    if not plugin_id or not marketplace_id or not source_repo:
        warn('忽略一个缺少 pluginId、marketplaceId 或 sourceRepo 的 plugin 条目。')
        continue

    plugin_name = plugin_id.split('@', 1)[0]
    if restore_kind == 'codex-skill-package':
        install_root = home_path(restore.get('installRoot') or f'.codex/{plugin_name}')
        clone_repo(source_repo, install_root, version, plugin.get('gitCommitSha'))

        for link in restore.get('links', []):
            source_rel = link.get('source')
            target_rel = link.get('target')
            if not source_rel or not target_rel:
                warn(f'忽略一个缺少 source 或 target 的链接：{plugin_id}。')
                continue
            source_path = install_root / source_rel
            target_path = home_path(target_rel)
            if not source_path.exists():
                warn(f'跳过链接，源路径不存在：{source_path}。')
                continue
            ensure_symlink(source_path, target_path, link.get('type') == 'dir')

        installed_plugins.setdefault(plugin_id, []).append({
            'scope': 'user',
            'installPath': str(install_root),
            'version': version,
            'installedAt': plugin.get('installedAt', now_iso),
            'lastUpdated': plugin.get('lastUpdated', now_iso),
            **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
        })
        ok(f'已恢复本地 plugin 包：{plugin_name}。')
        continue

    source_path = restore.get('sourcePath', '.')
    if not install_path:
        warn(f'忽略一个缺少 installPath 的 marketplace plugin 条目：{plugin_id}。')
        continue

    checkout_dir = sync_root / marketplace_id / plugin_name
    if checkout_dir.exists():
        shutil.rmtree(checkout_dir)
    clone_repo(source_repo, checkout_dir, version, plugin.get('gitCommitSha'))

    cache_dir = claude_root / install_path
    source_dir = checkout_dir / source_path
    if not source_dir.exists():
        warn(f'跳过 plugin {plugin_name}：缺少源文件 {source_path}。')
        continue

    if source_dir.resolve() == checkout_dir.resolve():
        copy_tree(checkout_dir, cache_dir)
    else:
        copy_tree(source_dir, cache_dir)

    installed_plugins.setdefault(plugin_id, []).append({
        'scope': 'user',
        'installPath': wsl_to_windows_path(cache_dir),
        'version': version,
        'installedAt': plugin.get('installedAt', now_iso),
        'lastUpdated': plugin.get('lastUpdated', now_iso),
        **({'gitCommitSha': plugin['gitCommitSha']} if plugin.get('gitCommitSha') else {}),
    })
    ok(f'已同步 plugin：{plugin_name}。')

installed_plugins_path = plugins_root / 'installed_plugins.json'
known_marketplaces_path = plugins_root / 'known_marketplaces.json'

installed_plugins_path.write_text(json.dumps({'version': 2, 'plugins': installed_plugins}, indent=2, ensure_ascii=False) + '\n')
known_marketplaces_path.write_text(json.dumps(marketplace_state, indent=2, ensure_ascii=False) + '\n')

ok(f'已重建 Claude 插件状态：{len(installed_plugins)} 个 plugins，{len(marketplace_state)} 个 marketplaces。')
PY
}

update_skills() {
  echo "[INFO] 正在检查 skills 更新。"
  local temp_manifest
  temp_manifest="$(mktemp)"
  if curl -fsSL "$DEFAULT_SKILLS_MANIFEST_URL" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_skills_from_manifest "$temp_manifest"
    else
      echo "[WARN] 下载到的 skills manifest 无效：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 更新。"
    fi
  else
    echo "[WARN] 未能下载 skills manifest：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 更新。"
  fi
  rm -f "$temp_manifest"
  return 0
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

print_subscription_summary() {
  local subscription_json="${1:-}"

  python3 - "$subscription_json" <<'PY'
import json
import sys

def info(message):
    print(f'[INFO] {message}')

def warn(message):
    print(f'[WARN] {message}')

raw = sys.argv[1].strip()
if not raw:
    warn('未找到 Codex 登录信息，跳过订阅检查。')
    sys.exit(0)

try:
    payload = json.loads(raw)
except Exception as exc:
    warn(f'无法读取 Codex 订阅状态：{exc}')
    sys.exit(0)

status = payload.get('status')
if status == 'missing_auth':
    warn('未找到 Codex 登录信息，跳过订阅检查。')
elif status == 'not_chatgpt':
    warn('当前 Codex 登录不是 ChatGPT 订阅，跳过订阅检查。')
elif status == 'no_expiry':
    warn('未找到 Codex 订阅到期时间。')
elif status == 'read_error':
    warn(f"无法读取 Codex 登录信息：{payload.get('message', 'unknown error')}")
elif status == 'parse_error':
    warn(f"无法解析 Codex 订阅到期时间：{payload.get('subscription_until', '')}")
elif status == 'expired':
    info(f"Codex 订阅已过期，到期时间：{payload.get('expiry_text', '')}。")
else:
    days = float(payload.get('remaining_days', 0))
    expiry_text = payload.get('expiry_text', '')
    if status == 'warning':
        warn(f'Codex 订阅还剩 {days:.1f} 天，到期时间：{expiry_text}。')
    else:
        info(f'Codex 订阅还剩 {days:.1f} 天，到期时间：{expiry_text}。')
PY
}


bootstrap() {
  local skip_upgrade="${1:-0}"
  local temp_manifest
  local subscription_json
  local skills_manifest_url="${DEFAULT_SKILLS_MANIFEST_URL:-https://raw.githubusercontent.com/962412311/codex-skills-pack/main/skills.manifest.json}"
  local plugins_manifest_url="${DEFAULT_PLUGINS_MANIFEST_URL:-https://raw.githubusercontent.com/962412311/codex-skills-pack/main/plugins.manifest.json}"

  install_base_packages "$skip_upgrade"
  write_wsl_home_profile
  install_node_codex
  write_codex_wrapper
  write_apply_patch_wrapper
  ensure_default_model
  subscription_json="$(check_subscription_json)"
  print_subscription_summary "$subscription_json"

  temp_manifest="$(mktemp)"
  if curl -fsSL "$skills_manifest_url" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_skills_from_manifest "$temp_manifest"
    else
      log_warn "下载到的 skills manifest 无效：${skills_manifest_url}，跳过 skills 安装。"
    fi
  else
    log_warn "未能下载 skills manifest：${skills_manifest_url}，跳过 skills 安装。"
  fi
  rm -f "$temp_manifest"

  temp_manifest="$(mktemp)"
  if curl -fsSL "$plugins_manifest_url" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_claude_plugins_from_manifest "$temp_manifest" "$HOME/.claude"
    else
      log_warn "下载到的 plugins manifest 无效：${plugins_manifest_url}，跳过插件恢复。"
    fi
  else
    log_warn "未能下载 plugins manifest：${plugins_manifest_url}，跳过插件恢复。"
  fi
  rm -f "$temp_manifest"

  log_ok 'WSL 侧 Codex 已完成安装。'
  log_info '进入 WSL 后运行：codex'
}

main() {
  local command="${1:-bootstrap}"
  case "$command" in
    check-subscription-json|ensure-default-model)
      ;;
    *)
      print_script_version
      ;;
  esac
  case "$command" in
    install-base-packages)
      install_base_packages "${2:-0}"
      ;;
    install-node-codex)
      install_node_codex
      ;;
    install-wrapper)
      write_codex_wrapper
      write_apply_patch_wrapper
      ;;
    ensure-default-model)
      ensure_default_model
      ;;
    check-subscription-json)
      check_subscription_json
      ;;
    install-skills)
      install_skills_from_manifest "${2:?missing manifest path}"
      ;;
    install-claude-plugins)
      install_claude_plugins_from_manifest "${2:?missing manifest path}" "${3:?missing claude root path}"
      ;;
    bootstrap)
      bootstrap "${2:-0}"
      ;;
    *)
      printf 'unknown command: %s\n' "$command" >&2
      return 1
      ;;
  esac
}

if [ -z "${CODEX_BOOTSTRAP_LIB:-}" ]; then
  main "$@"
fi
