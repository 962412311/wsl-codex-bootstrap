# WSL Codex Bootstrap

[English](./README.md) | [简体中文](./README.zh.md)

This repository is the Windows-side bootstrapper for getting a fresh Windows machine ready for Codex.

It is responsible for:

- enabling and updating WSL
- installing a Linux distro
- installing base packages, `nvm`, Node.js LTS, and `@openai/codex`
- reading a separate skills manifest and installing Codex skills from upstream repositories

## Quick Start

### Online one-liner

Run the latest bootstrap script directly from GitHub:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-wsl-codex.ps1' | iex"
```

If you want to pin a specific manifest source, edit `skills-source.json` first or pass `-SkillsManifestUrl` / `-SkillsManifestPath` after downloading the script locally.

### Local checkout

1. Clone or download this repository.
2. Make sure `skills-source.json` points to the skills repository manifest you want to install.
3. Open PowerShell as Administrator.
4. Run:

```powershell
.\install-wsl-codex.ps1
```

Optional flags:

```powershell
.\install-wsl-codex.ps1 -Distro Ubuntu
.\install-wsl-codex.ps1 -SkipAptUpgrade
.\install-wsl-codex.ps1 -NoAutoLaunchCodex
.\install-wsl-codex.ps1 -InstallBubblewrap
.\install-wsl-codex.ps1 -SkillsManifestPath "..\Codex&WSL_all_in_one\skills.manifest.json"
```

## Production Setup

For public releases, change `skills-source.json` to the raw manifest URL from the published skills repository.

Example:

```json
{
  "skillsManifestUrl": "https://raw.githubusercontent.com/<owner>/codex-skills-pack/main/skills.manifest.json"
}
```

The installer still accepts `-SkillsManifestPath` and `-SkillsManifestUrl` as overrides.

## Related Repository

The skills inventory lives in [codex-skills-pack](https://github.com/962412311/codex-skills-pack).

## Repository Layout

- `install-wsl-codex.ps1` - bootstrap installer
- `skills-source.json` - pointer to the external skills manifest
- `docs/bootstrap-flow.md` - installation flow overview

## Notes

- Rerunning the installer is intended to be safe.
- Keep a cloned copy of the skills repository nearby if you want to test local manifest edits before publishing.
- The installer expects a working GitHub token only when creating or updating GitHub repositories from the local automation flow.
