#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-mac-codex.sh"

output="$(
  bash -lc '
    set -euo pipefail
    export CODEX_BOOTSTRAP_LIB=1
    source "'"$script_path"'"

    install_base_packages() { printf "INSTALL_BASE_PACKAGES\n"; }
    install_node_codex() { printf "INSTALL_NODE_CODEX\n"; }
    write_codex_wrapper() { printf "WRITE_CODEX_WRAPPER\n"; }
    write_apply_patch_wrapper() { printf "WRITE_APPLY_PATCH_WRAPPER\n"; }
    ensure_default_model() { printf "ENSURE_DEFAULT_MODEL\n"; }
    check_subscription_json() { printf "{\"status\":\"missing_auth\"}\n"; }
    print_subscription_summary() { printf "PRINT_SUBSCRIPTION_SUMMARY\n"; }
    install_skills_from_manifest() { printf "INSTALL_SKILLS\n"; }
    install_claude_plugins_from_manifest() { printf "INSTALL_PLUGINS\n"; }
    curl() {
      if [ "${1:-}" = "-fsSL" ] && [ "${3:-}" = "-o" ] && [ -n "${4:-}" ]; then
        printf "{}\n" > "$4"
        return 0
      fi
      printf "UNEXPECTED_CURL\n" >&2
      return 1
    }

    bootstrap
  ' 2>&1
)"

case "$output" in
  *WRITE_CODEX_WRAPPER* ) : ;;
  *)
    printf 'mac bootstrap did not install the codex wrapper.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

case "$output" in
  *WRITE_APPLY_PATCH_WRAPPER* ) : ;;
  *)
    printf 'mac bootstrap did not install the apply_patch wrapper.\n' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac
