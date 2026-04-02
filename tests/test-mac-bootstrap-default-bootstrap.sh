#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"

    bootstrap() {
      printf "BOOTSTRAP_CALLED\n"
      return 0
    }

    main
  '
)"

case "$output" in
  *BOOTSTRAP_CALLED*)
    ;;
  *)
    printf 'install-mac-codex.sh did not default to bootstrap when no command was provided.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
