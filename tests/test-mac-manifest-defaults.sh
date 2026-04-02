#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"
    printf "%s\n" "${DEFAULT_SKILLS_MANIFEST_URL:-missing}"
    printf "%s\n" "${DEFAULT_PLUGINS_MANIFEST_URL:-missing}"
  '
)"

case "$output" in
  *missing*)
    printf 'install-mac-codex.sh did not define default manifest URLs in library mode.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
