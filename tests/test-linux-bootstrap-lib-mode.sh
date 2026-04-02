#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-linux-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"
    declare -F install_skills_from_manifest
    declare -F install_claude_plugins_from_manifest
    printf "AFTER_SOURCE\n"
  '
)"

case "$output" in
  *install_skills_from_manifest*install_claude_plugins_from_manifest*AFTER_SOURCE*)
    ;;
  *)
    printf 'install-linux-codex.sh did not expose both manifest installers in library mode.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
