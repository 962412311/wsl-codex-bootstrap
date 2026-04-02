#!/usr/bin/env bash
set -euo pipefail

# Version: 1.0.7
# Update this version every time this script changes.

log_info() { printf '[INFO] %s\n' "$1"; }
log_ok() { printf '[OK] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }

log_info "install-mac-codex.sh version 1.0.7"

source_linux_bootstrap() {
  local script_dir script_source linux_script tmp cleanup had_bootstrap_lib previous_bootstrap_lib
  script_source="${BASH_SOURCE[0]:-$0}"
  script_dir="$(cd "$(dirname "$script_source")" && pwd)"
  linux_script="$script_dir/install-linux-codex.sh"
  had_bootstrap_lib=0
  previous_bootstrap_lib="${CODEX_BOOTSTRAP_LIB:-}"
  if [ "${CODEX_BOOTSTRAP_LIB+x}" = x ]; then
    had_bootstrap_lib=1
  fi

  if [ -f "$linux_script" ]; then
    CODEX_BOOTSTRAP_LIB=1 . "$linux_script"
  else
    tmp="$(mktemp)"
    cleanup="rm -f '$tmp'"
    trap "$cleanup" EXIT
    /usr/bin/curl -fsSL https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-linux-codex.sh -o "$tmp"
    CODEX_BOOTSTRAP_LIB=1 . "$tmp"
  fi

  if [ "$had_bootstrap_lib" = '1' ]; then
    CODEX_BOOTSTRAP_LIB="$previous_bootstrap_lib"
  else
    unset CODEX_BOOTSTRAP_LIB
  fi
}

source_linux_bootstrap

write_codex_path_file() {
  ensure_root_home

  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/path.sh" <<'EOF_PATH'
#!/usr/bin/env sh

codex_local_bin="$HOME/.local/bin"
codex_npm_bin="$HOME/.codex/npm-global/bin"
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

append_existing_path() {
  [ -d "$1" ] && append_path "$1"
}

append_existing_path "$codex_local_bin"
append_existing_path "$codex_npm_bin"
append_existing_path "/opt/homebrew/bin"
append_existing_path "/opt/homebrew/sbin"
append_existing_path "/usr/local/bin"
append_existing_path "/usr/local/sbin"

IFS=:
for segment in $PATH; do
  [ -n "$segment" ] || continue
  case "$segment" in
    "$codex_local_bin"|"$codex_npm_bin"|/opt/homebrew/bin|/opt/homebrew/sbin|/usr/local/bin|/usr/local/sbin)
      continue
      ;;
  esac
  append_path "$segment"
done
unset IFS

PATH="$path_entries"
export PATH
EOF_PATH
  chmod 0644 "$HOME/.codex/path.sh"
}

load_homebrew_shellenv() {
  local brew_bin
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$($brew_bin shellenv)"
      return 0
    fi
  done
  return 1
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  if load_homebrew_shellenv; then
    return 0
  fi

  log_info '未检测到 Homebrew，开始安装。'
  if NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    if load_homebrew_shellenv; then
      return 0
    fi
  fi

  log_warn 'Homebrew 安装失败，请手动安装后重新运行脚本。'
  return 1
}

install_base_packages() {
  local skip_upgrade="$1"
  local packages=(
    git
    jq
    ripgrep
    fd
    rsync
    unzip
    zip
    xz
    moreutils
    python@3.12
  )

  ensure_homebrew

  if [ "$skip_upgrade" != "1" ]; then
    brew update
    brew upgrade || log_warn 'Homebrew 升级失败，将继续执行安装。'
  else
    log_info '已跳过 Homebrew 升级。'
  fi

  for package in "${packages[@]}"; do
    if brew list --formula --versions "$package" >/dev/null 2>&1; then
      log_info "$package 已安装，跳过。"
      continue
    fi

    if brew install "$package"; then
      log_ok "$package 已安装。"
    else
      log_warn "$package 安装失败，将继续执行。"
    fi
  done

  brew cleanup >/dev/null 2>&1 || true
}

install_node_codex() {
  ensure_root_home

  local codex_prefix="$HOME/.codex/npm-global"
  mkdir -p "$HOME/.local/bin" "$HOME/code" "$codex_prefix"

  write_codex_path_file
  . "$HOME/.codex/path.sh"

  set +u
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
  fi

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  nvm install --lts
  nvm alias default 'lts/*'
  nvm use --lts
  set -u

  npm i -g --prefix "$codex_prefix" @openai/codex@latest --silent --no-fund --no-audit
  local codex_bin="$codex_prefix/bin/codex"

  printf 'Node version: %s\n' "$(node -v)"
  printf 'npm version : %s\n' "$(npm -v)"
  printf 'codex version: %s\n' "$($codex_bin --version)"
}

bootstrap() {
  local skip_upgrade="${1:-0}"
  local temp_manifest
  local subscription_json

  install_base_packages "$skip_upgrade"
  write_codex_path_file
  install_node_codex
  ensure_default_model
  subscription_json="$(check_subscription_json)"
  print_subscription_summary "$subscription_json"

  temp_manifest="$(mktemp)"
  if curl -fsSL "$DEFAULT_SKILLS_MANIFEST_URL" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_skills_from_manifest "$temp_manifest"
    else
      log_warn "下载到的 skills manifest 无效：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 安装。"
    fi
  else
    log_warn "未能下载 skills manifest：$DEFAULT_SKILLS_MANIFEST_URL，跳过 skills 安装。"
  fi
  rm -f "$temp_manifest"

  temp_manifest="$(mktemp)"
  if curl -fsSL "$DEFAULT_PLUGINS_MANIFEST_URL" -o "$temp_manifest"; then
    if [ -s "$temp_manifest" ] && grep -q '^{' "$temp_manifest"; then
      install_claude_plugins_from_manifest "$temp_manifest" "$HOME/.claude"
    else
      log_warn "下载到的 plugins manifest 无效：$DEFAULT_PLUGINS_MANIFEST_URL，跳过插件恢复。"
    fi
  else
    log_warn "未能下载 plugins manifest：$DEFAULT_PLUGINS_MANIFEST_URL，跳过插件恢复。"
  fi
  rm -f "$temp_manifest"

  log_ok 'macOS 侧 Codex 已完成安装。'
  log_info '进入 macOS 后运行：codex'
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

if [ -z "${CODEX_BOOTSTRAP_LIB:-}" ]; then
  main "$@"
fi
