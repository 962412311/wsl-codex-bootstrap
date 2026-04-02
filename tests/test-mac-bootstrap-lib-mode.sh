#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    brew() {
      printf "BREW_SHOULD_NOT_RUN\n"
      return 0
    }

    set -- install-base-packages
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"
    printf "AFTER_SOURCE\n"
  '
)"

case "$output" in
  *BREW_SHOULD_NOT_RUN*)
    printf 'install-mac-codex.sh executed bootstrap logic while in library mode.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

case "$output" in
  *AFTER_SOURCE*)
    ;;
  *)
    printf 'install-mac-codex.sh did not return control to the caller after sourcing.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
