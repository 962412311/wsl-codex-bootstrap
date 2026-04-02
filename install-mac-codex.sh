#!/usr/bin/env bash
set -euo pipefail

# Version: 1.0.3
# Update this version every time this script changes.

log_info() { printf '[INFO] %s\n' "$1"; }
log_ok() { printf '[OK] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }

log_info "install-mac-codex.sh version 1.0.3"

source_linux_bootstrap() {
  local script_dir script_source linux_script tmp cleanup
  script_source="${BASH_SOURCE[0]:-$0}"
  script_dir="$(cd "$(dirname "$script_source")" && pwd)"
  linux_script="$script_dir/install-linux-codex.sh"

  if [ -f "$linux_script" ]; then
    CODEX_BOOTSTRAP_LIB=1 . "$linux_script"
    return 0
  fi

  tmp="$(mktemp)"
  cleanup="rm -f '$tmp'"
  trap "$cleanup" EXIT
  /usr/bin/curl -fsSL https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-linux-codex.sh -o "$tmp"
  CODEX_BOOTSTRAP_LIB=1 . "$tmp"
}

source_linux_bootstrap
unset CODEX_BOOTSTRAP_LIB

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

if [ -z "${CODEX_BOOTSTRAP_LIB:-}" ]; then
  main "$@"
fi
