#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

output="$(
  HOME="$tmp_home" bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"
    write_codex_path_file
    . "$HOME/.codex/path.sh"
    printf "SOURCED_OK\n"
  '
)"

case "$output" in
  *SOURCED_OK*)
    ;;
  *)
    printf 'mac path.sh failed to source when optional directories were missing.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
