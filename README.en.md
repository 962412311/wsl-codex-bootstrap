# WSL Codex Bootstrap

[English](./README.en.md) | [简体中文](./README.md)

This repository is the Windows-side bootstrapper for getting a fresh Windows machine ready for Codex.

Run it once and it installs WSL, Codex, and all 32 skills from the configured skills manifest.

The script also writes Codex's default model as `gpt-5.4-mini`.
After installation and before each automatic launch, it first checks whether Codex is already up to date inside WSL, updates only when it is not, and also checks whether the subscription is nearing expiry or already expired; it only warns and does not block. It also refreshes locally installed skills and plugins once per day before launching Codex.

It is responsible for:

- enabling and updating WSL
- installing a Linux distro
- installing base packages, `nvm`, Node.js LTS, and `@openai/codex`
- checking Codex subscription status
- reading a separate skills manifest and installing Codex skills from upstream repositories

## Quick Start

### Online one-liner

Online installer: [install-wsl-codex.ps1](https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-wsl-codex.ps1)

Run this in **Windows PowerShell or Windows Terminal on the Windows host**, preferably as Administrator:

```powershell
$tmp = Join-Path $env:TEMP "install-wsl-codex.ps1"; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/4bc54d9/install-wsl-codex.ps1", $tmp); powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
```

Do not run this inside WSL.

If you want to pin a specific manifest source, edit `skills-source.json` first or pass `-SkillsManifestUrl` / `-SkillsManifestPath` after downloading the script locally.

### Local checkout

1. Clone or download this repository.
2. Make sure `skills-source.json` points to the skills repository manifest you want to install.
3. Open PowerShell as Administrator.
4. Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1
```

If you prefer to double-click a local launcher, use `install-wsl-codex.cmd`.

Optional flags:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -Distro Ubuntu
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -SkipAptUpgrade
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -NoAutoLaunchCodex
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -InstallBubblewrap
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -SkillsManifestPath "..\Codex&WSL_all_in_one\skills.manifest.json"
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


## Install WSL and Ubuntu First

If you only want to get WSL and Ubuntu set up on Windows, run `install-wsl-ubuntu.ps1` or double-click `install-wsl-ubuntu.cmd`. It only handles WSL, Ubuntu, the default distribution, and first-time initialization. It does not install Codex.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-ubuntu.ps1
```
