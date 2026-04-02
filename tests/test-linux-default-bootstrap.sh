#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-linux-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"
    install_base_packages() { printf "BOOTSTRAP\n"; }
    write_wsl_home_profile() { :; }
    install_node_codex() { :; }
    write_codex_wrapper() { :; }
    write_apply_patch_wrapper() { :; }
    ensure_default_model() { :; }
    check_subscription_json() { printf "{}\n"; }
    print_subscription_summary() { :; }
    install_skills_from_manifest() { :; }
    install_claude_plugins_from_manifest() { :; }
    log_ok() { :; }
    log_info() { :; }
    log_warn() { :; }
    curl() { return 1; }
    main
  '
)"

case "$output" in
  *BOOTSTRAP*)
    ;;
  *)
    printf 'install-linux-codex.sh did not default to bootstrap.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
