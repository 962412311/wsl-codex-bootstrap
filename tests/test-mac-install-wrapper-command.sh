#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"

    write_codex_wrapper() { printf "WRITE_CODEX_WRAPPER\n"; }
    write_apply_patch_wrapper() { printf "WRITE_APPLY_PATCH_WRAPPER\n"; }

    main install-wrapper
  ' 2>&1
)"

case "$output" in
  *WRITE_CODEX_WRAPPER* ) : ;;
  *)
    printf 'install-wrapper did not call write_codex_wrapper.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

case "$output" in
  *WRITE_APPLY_PATCH_WRAPPER* ) : ;;
  *)
    printf 'install-wrapper did not call write_apply_patch_wrapper.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
