# WSL Codex Bootstrap

[English](./README.en.md) | [简体中文](./README.md)

This repository is the Windows-side bootstrapper for getting a fresh Windows machine ready for Codex.

Run it once and it installs WSL, Codex, and all 33 skills from the upstream skills pack.

The script also writes Codex's default model as `gpt-5.4-mini`.
After installation and before each automatic launch, it first checks whether Codex is already up to date inside WSL, updates only when it is not, and also checks whether the subscription is nearing expiry or already expired; it only warns and does not block. It also refreshes locally installed skills and plugins once per day before launching Codex, and restores the recorded Claude plugin state from the plugin manifest. The online one-click entry now runs unattended by default, so it does not stop for confirmation prompts and it does not auto-create a Linux user; if no regular user exists yet, it opens WSL once so you can create one manually.

It is responsible for:

- enabling and updating WSL
- installing a Linux distro
- installing base packages, `nvm`, Node.js LTS, and `@openai/codex`
- checking Codex subscription status
- installing Codex skills from the upstream skills pack
- restoring Claude plugins from the plugin manifest

## Quick Start

### Online one-liner

Online installer: [install.ps1](https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install.ps1)

Run this in **Windows PowerShell or Windows Terminal on the Windows host**, preferably as Administrator:

```powershell
$tmp = Join-Path $env:TEMP "install.ps1"; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install.ps1", $tmp); powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
```

Do not run this inside WSL.

### Online one-liner in WSL

Run this inside WSL to install Codex directly into the current Linux user account:

```bash
curl -fsSL https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-linux-codex.sh | bash -s -- bootstrap
```

### Online one-liner for macOS

Run this on macOS to install Codex into the current macOS user account:

```bash
curl -fsSL https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-mac-codex.sh | bash -s -- bootstrap
```

The first run will install or reuse Homebrew, then configure `~/.local/bin/codex`, `~/.local/bin/apply_patch`, shell startup hooks, the default model, subscription checks, skills syncing, and plugin state restoration.

The first run may prompt for `sudo` when it installs base packages.

### Local checkout

1. Clone or download this repository.
2. The installer always pulls skills from the upstream skills pack and restores plugins from the plugin manifest.
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
```

## Related Repository

The skills inventory lives in [codex-skills-pack](https://github.com/962412311/codex-skills-pack).

## Repository Layout

- `install-wsl-codex.ps1` - bootstrap installer
- `install-mac-codex.sh` - macOS bootstrap installer
- `docs/bootstrap-flow.md` - installation flow overview

## Notes

- Rerunning the installer is intended to be safe.
- The installer expects a working GitHub token only when creating or updating GitHub repositories from the local automation flow.


## Install WSL and Ubuntu First

If you only want to get WSL and Ubuntu set up on Windows, run `install-wsl-ubuntu.ps1` or double-click `install-wsl-ubuntu.cmd`. It only handles WSL, Ubuntu, the default distribution, and first-time initialization. It does not install Codex.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-ubuntu.ps1
```
