#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/install-linux-codex.sh"
real_git="$(command -v git)"

init_git_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  "$real_git" -C "$repo_dir" init -q
  "$real_git" -C "$repo_dir" config user.name 'Codex Test'
  "$real_git" -C "$repo_dir" config user.email 'codex-test@example.com'
}

home_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
fake_bin_dir="$work_dir/fake-bin"
clone_state_file="$work_dir/clone-attempts"
manifest_path="$work_dir/plugins.manifest.json"
market_repo="$work_dir/market-repo"
plugin_repo="$work_dir/plugin-repo"

mkdir -p "$fake_bin_dir"
cat > "$fake_bin_dir/git" <<EOF_GIT
#!/usr/bin/env bash
set -euo pipefail

real_git="$real_git"
state_file="$clone_state_file"

if [ "\${1:-}" = 'clone' ]; then
  attempts=0
  if [ -f "\$state_file" ]; then
    attempts="\$(cat "\$state_file")"
  fi
  attempts=\$((attempts + 1))
  printf '%s\n' "\$attempts" > "\$state_file"
  if [ "\$attempts" = '1' ]; then
    printf 'simulated transient clone failure\n' >&2
    exit 128
  fi
fi

exec "\$real_git" "\$@"
EOF_GIT
chmod +x "$fake_bin_dir/git"

init_git_repo "$market_repo"
(
  cd "$market_repo"
  printf "marketplace\n" > README.md
  "$real_git" add README.md
  "$real_git" commit -q -m "initial"
)

init_git_repo "$plugin_repo"
(
  cd "$plugin_repo"
  mkdir -p skills
  printf "demo skill\n" > skills/demo.txt
  "$real_git" add skills/demo.txt
  "$real_git" commit -q -m "initial"
)

cat > "$manifest_path" <<JSON
{
  "version": 1,
  "marketplaces": [
    {
      "id": "claude-plugins-official",
      "source": "github",
      "repo": "$market_repo"
    }
  ],
  "plugins": [
    {
      "pluginId": "demo@claude-plugins-official",
      "marketplaceId": "claude-plugins-official",
      "sourceRepo": "$plugin_repo",
      "restore": {
        "kind": "codex-skill-package",
        "installRoot": ".codex/demo",
        "links": [
          {
            "source": "skills",
            "target": ".agents/skills/demo",
            "type": "dir"
          }
        ]
      }
    }
  ]
}
JSON

(
  set -euo pipefail
  export CODEX_BOOTSTRAP_LIB=1
  export HOME="$home_dir"
  export PATH="$fake_bin_dir:$PATH"
  source "$script_path"
  ensure_root_home() { :; }
  install_claude_plugins_from_manifest "$manifest_path" "$HOME/.claude"

  test -d "$HOME/.claude/plugins/marketplaces/claude-plugins-official/.git"
  test -d "$HOME/.codex/demo/.git"
  test -e "$HOME/.agents/skills/demo"
  test "$(cat "$clone_state_file")" -ge 3
)
