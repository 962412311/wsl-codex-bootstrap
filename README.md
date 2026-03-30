# WSL Codex Bootstrap

This repository is the Windows-side bootstrapper.

It is responsible for:

- enabling and updating WSL
- installing a Linux distro
- installing base packages, `nvm`, Node.js LTS, and `@openai/codex`
- reading a separate skills manifest and installing Codex skills from upstream repositories

## Quick Start

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

## Skills Source

The installer reads `skills-source.json`, which points to the external skills repository manifest.

For local development in this workspace, it points at the sibling `Codex&WSL_all_in_one` checkout.

For public release, update it to the raw manifest URL from the published skills repository.

## Repository Layout

- `install-wsl-codex.ps1` - bootstrap installer
- `skills-source.json` - pointer to the external skills manifest
- `docs/bootstrap-flow.md` - installation flow overview
