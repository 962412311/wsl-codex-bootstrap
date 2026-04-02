#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"

    getent() {
      printf "GETENT_SHOULD_NOT_RUN\n"
      return 1
    }

    ensure_root_home
    printf "HOME=%s\n" "$HOME"
    printf "USER=%s\n" "$USER"
    printf "LOGNAME=%s\n" "$LOGNAME"
  ' 2>&1
)"

case "$output" in
  *GETENT_SHOULD_NOT_RUN*)
    printf 'mac ensure_root_home still depends on getent.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

case "$output" in
  *"HOME="*"USER="*"LOGNAME="*)
    ;;
  *)
    printf 'mac ensure_root_home did not populate HOME/USER/LOGNAME.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
