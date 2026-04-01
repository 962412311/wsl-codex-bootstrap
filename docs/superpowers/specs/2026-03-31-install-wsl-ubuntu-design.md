# Install WSL + Ubuntu Bootstrap Design

## Goal
Create a separate local-only PowerShell script that installs or updates WSL, installs Ubuntu, sets Ubuntu as the default distribution, and completes first-time Ubuntu initialization. This script is intentionally independent from the Codex bootstrap flow.

## In Scope
- Check the Windows host before touching WSL.
- Check the current WSL version and update only when needed.
- Install Ubuntu if it is missing.
- Set Ubuntu as the default WSL distribution when needed.
- Detect whether Ubuntu has already been initialized.
- Open an interactive Ubuntu shell for first-time initialization when required.
- Stop after `wsl --install` and ask the user to rerun the script after reboot.
- Keep all user-facing output in Chinese.

## Out of Scope
- Codex installation.
- Codex model configuration.
- Skills installation or manifest handling.
- Subscription checks.
- Node.js, nvm, or npm setup.
- Auto-restart after WSL installation.
- Support for distributions other than Ubuntu.

## Script Shape
- New file: `install-wsl-ubuntu.ps1`.
- Default target distribution: `Ubuntu`.
- Local execution only: this script is not meant for the online bootstrap path.
- The script should be safe to rerun.

## Execution Flow
1. Validate that PowerShell is running with administrator privileges.
2. Read WSL version and status information.
3. If the current WSL version is already up to date, skip the update step.
4. If the WSL version is outdated, ask for confirmation before updating.
5. If Ubuntu is not installed, ask for confirmation, run `wsl --install -d Ubuntu`, then exit without rebooting.
6. If Ubuntu is installed, continue without reinstalling it.
7. Check whether Ubuntu is already the default distribution.
8. If Ubuntu is not the default distribution, ask for confirmation before switching.
9. Check whether Ubuntu has completed first-time initialization.
10. If initialization is incomplete, launch an interactive Ubuntu shell, instruct the user to create the Linux user, and then rerun the script.
11. Print a final success message when Ubuntu is installed, set as default, and initialized.

## Confirmation Rules
- Ask for confirmation before any state-changing WSL or Ubuntu operation.
- Default Enter should mean `Yes` for installation/update prompts.
- Do not auto-restart the machine.
- Do not auto-continue past `wsl --install`.

## Status Reporting
- Keep logs concise and in Chinese.
- For version checks, report the detected version and whether an update is needed.
- For Ubuntu install and default-distribution changes, report whether the step was skipped, applied, or deferred.
- For first-time initialization, report whether Ubuntu is already ready or still needs user setup.

## Reliability Notes
- The script must not depend on Codex bootstrap config files.
- The script must not use any temporary bootstrap state from the Codex installer.
- The script should reuse existing WSL/Ubuntu installations instead of reinstalling them.
- Path and encoding handling should avoid the PowerShell 5.1 issues that previously affected the Codex bootstrap script.

## Acceptance Criteria
- A user can run the script on a fresh Windows machine, approve the prompts, reboot once if Ubuntu installation is required, rerun the script, and end with Ubuntu installed, default, and initialized.
- A user can rerun the script on an already configured machine without reinstalling Ubuntu or unnecessarily changing the default distribution.
- The script never enters the Codex installation flow.
