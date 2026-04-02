#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

init_git_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name 'Codex Test'
  git -C "$repo_dir" config user.email 'codex-test@example.com'
}

run_case() {
  local script_path="$1"
  local home_dir work_dir manifest_path
  home_dir="$(mktemp -d)"
  work_dir="$(mktemp -d)"
  manifest_path="$work_dir/plugins.manifest.json"

  local market_repo="$work_dir/market-repo"
  local super_repo="$work_dir/superpowers-repo"
  local pua_repo="$work_dir/pua-repo"

  init_git_repo "$market_repo"
  (
    cd "$market_repo"
    printf "marketplace\n" > README.md
    git add README.md
    git commit -q -m "initial"
  )

  init_git_repo "$super_repo"
  (
    cd "$super_repo"
    mkdir -p skills
    printf "superpowers\n" > skills/skill.txt
    git add skills/skill.txt
    git commit -q -m "initial"
    git tag v5.0.6
  )

  init_git_repo "$pua_repo"
  (
    cd "$pua_repo"
    mkdir -p codex/pua commands
    printf "pua skill\n" > codex/pua/skill.txt
    printf "# pua\n" > commands/pua.md
    git add codex/pua/skill.txt commands/pua.md
    git commit -q -m "initial"
  )

  local super_commit pua_commit
  super_commit="$(git -C "$super_repo" rev-parse HEAD)"
  pua_commit="$(git -C "$pua_repo" rev-parse HEAD)"

  cat > "$manifest_path" <<JSON
{
  "version": 1,
  "marketplaces": [
    {
      "id": "claude-plugins-official",
      "source": "github",
      "repo": "$market_repo"
    },
    {
      "id": "pua-skills",
      "source": "github",
      "repo": "$market_repo"
    }
  ],
  "plugins": [
    {
      "pluginId": "superpowers@claude-plugins-official",
      "marketplaceId": "claude-plugins-official",
      "sourceRepo": "$super_repo",
      "version": "5.0.6",
      "gitCommitSha": "$super_commit",
      "restore": {
        "kind": "codex-skill-package",
        "installRoot": ".codex/superpowers",
        "links": [
          {
            "source": "skills",
            "target": ".agents/skills/superpowers",
            "type": "dir"
          }
        ]
      }
    },
    {
      "pluginId": "pua@pua-skills",
      "marketplaceId": "pua-skills",
      "sourceRepo": "$pua_repo",
      "version": "3.1.0",
      "gitCommitSha": "$pua_commit",
      "restore": {
        "kind": "codex-skill-package",
        "installRoot": ".codex/pua",
        "links": [
          {
            "source": "codex/pua",
            "target": ".codex/skills/pua",
            "type": "dir"
          },
          {
            "source": "commands/pua.md",
            "target": ".codex/prompts/pua.md",
            "type": "file"
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
    source "$script_path"
    ensure_root_home() { :; }
    install_claude_plugins_from_manifest "$manifest_path" "$HOME/.claude"
    test -e "$HOME/.agents/skills/superpowers"
    test -e "$HOME/.codex/skills/pua"
    test -e "$HOME/.codex/prompts/pua.md"
  )
}

run_case "$repo_root/install-linux-codex.sh"
run_case "$repo_root/install-mac-codex.sh"
