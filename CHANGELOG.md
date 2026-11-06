# Changelog

All notable changes to ProfilePilot are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, a minor version may change environment variables or installed files incompatibly.

## [Unreleased]

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
- Opt-in removal of Homebrew formulae, casks and taps that are not in the selected Brewfile. It never touches global npm, go, cargo or uv packages or VS Code extensions, and it removes nothing if Homebrew's preview cannot be read. A failed removal is reported instead of stopping the run.
- Upgrades from earlier installs: an old `tldr` package is unlinked so `tlrc` can provide the `tldr` command, and oh-my-posh from the old `jandedobbeleer/oh-my-posh` tap is replaced with homebrew-core's.
- An end-of-run summary that reports packages, dotfiles, git identity and cleanup separately, and exits non-zero when packages fail to install. When the run had to add `brew` to `PATH`, it also says how to get `brew` in your current terminal.
- CI: shellcheck and syntax checks, logic tests on Ubuntu and on macOS's stock bash 3.2, and end-to-end smoke runs on Ubuntu, Fedora, Rocky Linux 8, Arch, openSUSE Tumbleweed and macOS.

[Unreleased]: https://github.com/aaronpetak/ProfilePilot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aaronpetak/ProfilePilot/releases/tag/v0.1.0
