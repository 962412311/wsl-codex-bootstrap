#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

run_case() {
  local mode="$1"
  local expected_nvm="$2"
  local expected_npm="$3"

  output="$(
    MODE="$mode" bash -lc '
      set -euo pipefail
      export CODEX_BOOTSTRAP_LIB=1
      export HOME="$(mktemp -d)"
      mkdir -p "$HOME/.nvm"
      printf "# nvm placeholder\n" > "$HOME/.nvm/nvm.sh"
      source "'"$script_path"'"

      ensure_root_home() { :; }
      log_info() { printf "INFO:%s\n" "$1"; }
      log_warn() { printf "WARN:%s\n" "$1"; }
      brew() { printf "BREW:%s\n" "$*"; return 0; }

      nvm() {
        case "$1" in
          ls-remote)
            if [ "$MODE" = "current" ]; then
              printf "       v22.17.0   (Latest LTS: Jod)\n"
            else
              printf "       v22.18.0   (Latest LTS: Jod)\n"
            fi
            ;;
          install)
            printf "NVM_INSTALL:%s\n" "$*"
            ;;
          alias|use)
            printf "NVM_%s:%s\n" "$(printf "%s" "$1" | tr "[:lower:]" "[:upper:]")" "$*"
            ;;
        esac
      }

      node() {
        if [ "$MODE" = "current" ]; then
          printf "v22.17.0\n"
        else
          printf "v22.17.0\n"
        fi
      }

      npm() {
        case "$1" in
          -v)
            if [ "$MODE" = "current" ]; then
              printf "10.0.0\n"
            else
              printf "10.0.0\n"
            fi
            ;;
          view)
            if [ "$MODE" = "current" ]; then
              printf "10.0.0\n"
            else
              printf "10.1.0\n"
            fi
            ;;
          install)
            printf "NPM_INSTALL:%s\n" "$*"
            ;;
          i)
            printf "NPM_GLOBAL_INSTALL:%s\n" "$*"
            ;;
          *)
            printf "NPM:%s\n" "$*"
            ;;
        esac
      }

      install_node_codex
    ' 2>&1
  )"

  if [ -n "$expected_nvm" ]; then
    case "$output" in
      *"$expected_nvm"*)
        ;;
      *)
        printf 'expected NVM update marker %s, got:\n%s\n' "$expected_nvm" "$output" >&2
        exit 1
        ;;
    esac
  else
    case "$output" in
      *NVM_INSTALL*)
        printf 'did not expect NVM install in current-version case.\n%s\n' "$output" >&2
        exit 1
        ;;
    esac
  fi

  if [ -n "$expected_npm" ]; then
    case "$output" in
      *"$expected_npm"*)
        ;;
      *)
        printf 'expected npm update marker %s, got:\n%s\n' "$expected_npm" "$output" >&2
        exit 1
        ;;
    esac
  else
    case "$output" in
      *NPM_INSTALL*)
        printf 'did not expect npm install in current-version case.\n%s\n' "$output" >&2
        exit 1
        ;;
    esac
  fi
}

run_case current '' ''
run_case outdated 'NVM_INSTALL' 'NPM_INSTALL'
