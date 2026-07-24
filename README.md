# ProfilePilot

Self-contained provisioning repository: a `bootstrap.sh` script plus the Homebrew package definitions (Brewfiles) and shell configurations (dotfiles) it downloads and applies when setting up a fresh macOS or Linux machine.

The bootstrap script lives in this repository as [`bootstrap.sh`](bootstrap.sh) and is fetched directly from this repo — there is no external gist or separate script to install.

## Quick Start

To bootstrap a fresh machine, run the one-liner:

```bash
curl -fsSL -o /tmp/profile-pilot.sh https://raw.githubusercontent.com/aaronpetak/ProfilePilot/main/bootstrap.sh && bash /tmp/profile-pilot.sh
```

The script will detect your OS (macOS or Linux), prompt you to select a profile, and configure your system using files from this repository.

## Overview

This repository is organized by:

- **Operating System** (macOS, or Linux — one shared set for all distros)
- **Profile** (Developer and Minimal; Bastion is planned)

Each profile includes:

- A **Brewfile** with curated package lists
- **Dotfiles** with shell and tool configurations specific to that profile

## Directory Structure

```text
ProfilePilot/
├── bootstrap.sh              # Provisioning script (run this)
├── macos/
│   ├── profile-developer/    # macOS Zsh configs for full dev environment
│   │   ├── .zprofile
│   │   └── .zshrc
│   └── profile-minimal/      # macOS Zsh configs for minimal setup
│       ├── .zprofile
│       └── .zshrc
├── linux/                    # Shared across all Linux distros (Debian/Ubuntu, Fedora/RHEL)
│   ├── profile-developer/    # Bash configs for full dev environment
│   │   ├── .bashrc
│   │   └── .bash_environment
│   └── profile-minimal/      # Bash configs for minimal setup
│       └── .bashrc
├── universal/
│   ├── brewfiles/            # Package definitions (all OS-compatible)
│   │   ├── Brewfile-bastion
│   │   ├── Brewfile-developer
│   │   └── Brewfile-minimal
│   ├── .shell_aliases        # Shared aliases/functions, sourced by bash AND zsh
│   ├── .gitconfig            # Git configuration
│   ├── .gitmessage           # Git commit message template
│   └── .poshthemes/          # Oh My Posh prompt themes
│       └── meridian-2.omp.json
└── README.md
```

## Profiles

### Developer

Complete engineering workstation environment including:

- DevOps and cloud tools (AWS, Kubernetes, Terraform, etc.)
- Programming language toolchains (Python, Node.js, Go, Rust, etc.)
- Security and networking utilities
- Development utilities and linters
- Git configuration with commit message templates
- PowerShell theme for enhanced terminal appearance

**Files:**

- `universal/brewfiles/Brewfile-developer`
- `macos/profile-developer/` (Zsh configuration)
- `linux/profile-developer/` (Bash configuration, all distros)
- `universal/.shell_aliases`, `.gitconfig`, `.gitmessage`, `.poshthemes/`

### Minimal

Lightweight, essential-only setup for security-constrained or resource-limited systems:

- Essential utilities: `git`, `jq`, `yq`, `ripgrep`, `tmux`, `age`, `gnupg`
- Lean shell configurations
- No prompt theme (`.poshthemes/` is developer-only)

**Files:**

- `universal/brewfiles/Brewfile-minimal`
- `macos/profile-minimal/` (Zsh configuration)
- `linux/profile-minimal/` (Bash configuration, all distros)
- `universal/.shell_aliases`, `.gitconfig`, `.gitmessage`

### Bastion (planned — not in current version)

A future profile for hardened/security-focused systems. A `Brewfile-bastion` package list exists, but Bastion is **not yet wired into the bootstrap script** (the profile menu currently offers only Developer and Minimal) and has no dotfiles. Selecting it is not possible until a future release adds it to the menu and creates its shell configurations.

**Files (partial):**

- `universal/brewfiles/Brewfile-bastion`

## How It Works

The bootstrap script (`bootstrap.sh`) performs these steps:

1. **OS Detection** - Determines if running on macOS or Linux
2. **Homebrew Installation** - Installs Homebrew if not present
3. **Profile Selection** - Prompts user to choose Developer or Minimal
4. **Package Installation** - Downloads and executes the selected Brewfile from `universal/brewfiles/`
5. **Dotfiles Application** - Downloads and applies OS and profile-specific dotfiles
6. **Cleanup (Optional)** - Prompts to remove packages not in the selected profile

### Cross-Platform Compatibility

- **Homebrew casks** are macOS-only; on Linux they are silently ignored (casks needed on both are guarded with `if OS.mac?` in the Brewfile)
- **All Brewfiles** are designed to be cross-platform (macOS and Linux)
- **Shell configurations** are shell-specific:
  - macOS uses Zsh (`.zprofile`, `.zshrc`)
  - All Linux distros share one Bash set (`.bashrc`, `.bash_environment`) under `linux/`. Distro- and environment-specific behavior — Debian's `debian_chroot`, Ubuntu's `lesspipe`, and the WSL Edge `BROWSER` export — is guarded inside the files with file/executable tests, so the same file works on Ubuntu, Fedora, and WSL alike.
- **Aliases** live in a single `universal/.shell_aliases`, sourced by both bash and zsh. Tool-specific entries (git, Terraform, virtualenv) are guarded with `command -v`, so they self-disable when the tool is absent — the same file serves both the minimal and developer profiles.
- **Universal dotfiles** (`.shell_aliases`, `.gitconfig`, `.gitmessage`) are applied to every profile; the `.poshthemes/` prompt theme is downloaded only for the Developer profile.

## Post-Bootstrap Customization

Some files require user-specific customization after the bootstrap script completes:

### `.gitconfig`

The git configuration file is downloaded but **must be customized** with your personal information:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
git config --global user.username "your-github-username"
```

Or edit `~/.gitconfig` directly to add:

```text
[user]
    name = Your Name
    email = your.email@example.com
    username = your-github-username
```

**Note:** This file list may grow as profiles are extended with additional customizable configurations.

## Maintenance

### Adding or Updating Packages

Edit the appropriate Brewfile in `universal/brewfiles/`:

- Add packages as `brew "package_name"` (formulae) or `cask "package_name"` (macOS applications)
- Update comments to explain why the package is included
- Test on both macOS and Linux to ensure compatibility

### Updating Shell Configurations

Edit dotfiles in the respective profile directories:

- **macOS:** `macos/profile-{developer,minimal}/.z*`
- **Linux (all distros):** `linux/profile-{developer,minimal}/.bash*`
- **Aliases (all shells/OSes):** `universal/.shell_aliases`

Keep anything portable in `.shell_aliases` and guard tool- or OS-specific behavior with `command -v` or file tests, rather than forking per-OS copies.

Changes are applied the next time the bootstrap script is run.

### Adding New Profiles

To create a new profile (e.g., `profile-security`):

1. Create `universal/brewfiles/Brewfile-security`
2. Create `macos/profile-security/` with `.zprofile`, `.zshrc`
3. Create `linux/profile-security/` with `.bashrc` (and `.bash_environment` if needed)
4. Update `bootstrap.sh` in this repository to add the new profile to the selection menu

## Notes

- Missing dotfiles in a profile are logged as informational notes but do not cause installation failures
- The bootstrap script is idempotent—running it multiple times is safe
- Homebrew packages are **not** version-pinned; each run installs the current version from the tap. Add a `@version` suffix in the Brewfile if you need to pin a specific release.
- The Oh My Posh prompt theme (`.poshthemes/`) is downloaded only for the Developer profile

## Related Links

- **Bootstrap Script:** [bootstrap.sh](bootstrap.sh)
- **Homebrew:** [https://brew.sh](https://brew.sh)
- **Oh My Posh (theme engine):** [https://ohmyposh.dev](https://ohmyposh.dev)
