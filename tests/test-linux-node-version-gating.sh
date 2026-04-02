#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-linux-codex.sh"

run_case() {
  local mode="$1"
  local expect_nvm_install="$2"
  local expect_npm_update="$3"

  output="$(
    MODE="$mode" bash -lc '
      set -euo pipefail
      export CODEX_BOOTSTRAP_LIB=1
      export HOME="$(mktemp -d)"
      mkdir -p "$HOME/.nvm"
      printf "# nvm placeholder\n" > "$HOME/.nvm/nvm.sh"
      source "'"$script_path"'"

      ensure_root_home() { :; }
      write_codex_path_file() {
        mkdir -p "$HOME/.codex"
        printf "# path placeholder\n" > "$HOME/.codex/path.sh"
      }
      write_apply_patch_wrapper() { :; }
      ensure_codex_shell_hook() { :; }
      log_info() { printf "INFO:%s\n" "$1"; }
      log_warn() { printf "WARN:%s\n" "$1"; }
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
            printf "NPM_UPDATE:%s\n" "$*"
            ;;
          i)
            printf "NPM_CODEX:%s\n" "$*"
            ;;
          *)
            printf "NPM:%s\n" "$*"
            ;;
        esac
      }

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

      install_node_codex
    ' 2>&1
  )"

  if [ "$expect_nvm_install" = "yes" ]; then
    case "$output" in
      *NVM_INSTALL*)
        ;;
      *)
        printf 'expected nvm install in outdated case, got:\n%s\n' "$output" >&2
        exit 1
        ;;
    esac
  else
    case "$output" in
      *NVM_INSTALL*)
        printf 'did not expect nvm install in current-version case.\n%s\n' "$output" >&2
        exit 1
        ;;
    esac
  fi

  if [ "$expect_npm_update" = "yes" ]; then
    case "$output" in
      *NPM_UPDATE*)
        ;;
      *)
        printf 'expected npm update in outdated case, got:\n%s\n' "$output" >&2
        exit 1
        ;;
    esac
  else
    case "$output" in
      *NPM_UPDATE*)
        printf 'did not expect npm update in current-version case.\n%s\n' "$output" >&2
        exit 1
        ;;
    esac
  fi
}

run_case current no no
run_case outdated yes yes
