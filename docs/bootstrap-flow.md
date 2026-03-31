# Bootstrap Flow

1. Validate the Windows host.
2. Install or update WSL.
3. Install the selected Linux distro.
4. Ensure the distro is initialized and using WSL 2.
5. Install base Linux tooling.
6. Install `nvm`, Node.js LTS, and `@openai/codex`.
7. Check whether Codex is already up to date inside WSL; update it only if it is not, refresh the local skills and plugin mirror once per day, then check the local Codex subscription expiry metadata and warn if it is near expiry or already expired.
8. Read the external skills manifest from `skills-source.json`, clone upstream repositories, and install the listed skills.
9. Optionally launch `codex` for first-time login.

The design goal is repeatability:

- rerunning the installer should be safe
- the bootstrap repository should stay small and stable
- skills should be declarative, external, and easy to audit
