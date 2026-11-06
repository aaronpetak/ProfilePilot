# Changelog

All notable changes to ProfilePilot are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, a minor version may change environment variables or installed files incompatibly.

## [Unreleased]

### Fixed

- Cleanup no longer touches global npm, go, cargo and uv packages, VS Code extensions or other bundle extensions. Before, choosing "Remove" uninstalled any of them that the Brewfile did not list.
- The cleanup list no longer shows Homebrew progress messages and warnings as packages to remove. A preview that cannot be read now removes nothing.
- A failed cleanup no longer stops the run before the summary, and removing a tap no longer asks a second question about packages that were not on the list.
- Machines with the old `tldr` package no longer end every developer-profile run as FAILED: `tldr` is unlinked so `tlrc` can provide the `tldr` command.
- oh-my-posh installed from the old `jandedobbeleer/oh-my-posh` tap is replaced with homebrew-core's. Before, it was never upgraded, and cleanup could not remove the tap.

### Added

- The summary reports the cleanup outcome, and says how to get `brew` in your current terminal when the run had to add it to `PATH`.

## [0.1.0] - 2026-11-05

First tagged release.

### Added

- `bootstrap.sh` provisions a fresh machine on macOS or on glibc Linux with `apt-get`, `dnf`, `pacman` or `zypper` (Debian/Ubuntu, Fedora/RHEL family, Arch, openSUSE). It refuses to run as root.
- Two profiles: **Developer** (`Brewfile-developer`, a shell add-on and the Oh My Posh prompt) and **Minimal** (`Brewfile-minimal` and the base shell config).
- Source resolution: installs from the local checkout when run inside one, otherwise from a single tarball of `DOTFILES_REF` from `DOTFILES_REPO_SLUG`, so forks and pinned refs work.
- Unattended runs through `PROFILE`, `DOTFILES_CONFLICT`, `CLEANUP`, `GIT_NAME` and `GIT_EMAIL`.
- Non-destructive dotfile handling: identical files are left alone, and conflicts are overwritten, skipped or decided per file, with timestamped backups. Unattended runs skip conflicts by default.
- Git identity is written to `~/.gitconfig.local`, which the shipped `~/.gitconfig` includes, so re-applying a profile never overwrites it.
- Homebrew detection across all four standard prefixes, `brew bundle` retries, and handling for formulae blocked by global npm packages.
- tflint on Linux is installed from its GitHub release and verified against the published checksums.
- Opt-in removal of Homebrew packages that are not in the selected Brewfile.
- An end-of-run summary that reports packages, dotfiles and git identity separately, with a non-zero exit status when any step is incomplete.
- CI: shellcheck and syntax checks, logic tests on Ubuntu and on macOS's stock bash 3.2, and end-to-end smoke runs on Ubuntu, Fedora, Rocky Linux 8, Arch, openSUSE Tumbleweed and macOS.

[Unreleased]: https://github.com/aaronpetak/ProfilePilot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aaronpetak/ProfilePilot/releases/tag/v0.1.0
