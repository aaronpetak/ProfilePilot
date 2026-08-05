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
2. **Profile Selection** - Prompts you to choose Developer or Minimal (or preselect non-interactively with `PROFILE=developer`/`PROFILE=minimal`)
3. **Homebrew Installation** - Installs Homebrew if not present (on Linux it also ensures the build tools Homebrew needs)
4. **Package Installation** - Downloads the selected Brewfile from `universal/brewfiles/` and installs it, retrying transient failures (see [Package Installation & Retries](#package-installation--retries))
5. **Dotfiles Application** - Downloads and applies OS and profile-specific dotfiles (see [Existing Dotfiles & Backups](#existing-dotfiles--backups) for how conflicts with files you already have are handled)
6. **Git Personalization** - Fills in your name, email, and GitHub username in the installed `~/.gitconfig` (see [Git Identity](#git-identity))
7. **Cleanup (Optional)** - Asks before removing installed packages not in the selected profile (see [Package Cleanup](#package-cleanup))

### Package Installation & Retries

Packages are installed with `brew bundle` against the selected Brewfile. Because transient failures (broken pipes mid-download, Cellar lock contention) are common on a fresh machine, the install is retried. If some packages still fail after all attempts, the script reports them and **continues** with the remaining steps (dotfiles, git personalization, cleanup) rather than aborting the whole run — the end-of-run summary flags the incomplete install.

Two environment variables tune the retry loop:

```bash
# Number of brew bundle attempts (default 3)
BREW_BUNDLE_ATTEMPTS=5 bash bootstrap.sh

# Seconds to wait between attempts (default 5)
BREW_BUNDLE_RETRY_DELAY=10 bash bootstrap.sh
```

### Existing Dotfiles & Backups

On a fresh machine the profile's dotfiles are simply installed. On a machine you've already customized, the script does **not** blindly overwrite what you have. For each dotfile it compares your version against the profile version and acts as follows:

- **File doesn't exist yet** → installed silently.
- **File is identical** to the profile version → left untouched, no backup made.
- **File exists but differs** → treated as a *conflict* and resolved according to the mode below.

When conflicts are found, the script lists them and (on an interactive terminal) asks once how to proceed:

- **`[O]` Overwrite all** — install the profile versions; your originals are backed up first.
- **`[S]` Skip all** — keep your existing files; install none of the conflicting ones.
- **`[D]` Decide per file** — for each conflict, choose overwrite / skip / view a diff of your version vs. the profile version.

Backups are written **in place** with a per-run timestamp, e.g. `~/.zshrc.bak.20260728-145900`. Because the timestamp is unique per run, re-running the script never overwrites an earlier backup.

You can control this non-interactively with the `DOTFILES_CONFLICT` environment variable:

```bash
# Replace differing dotfiles (originals are still backed up)
DOTFILES_CONFLICT=overwrite bash bootstrap.sh

# Never touch existing dotfiles (only install ones you don't have)
DOTFILES_CONFLICT=skip bash bootstrap.sh

# Force the interactive prompt
DOTFILES_CONFLICT=prompt bash bootstrap.sh
```

If no terminal is available (e.g. CI or a container) and `DOTFILES_CONFLICT` is unset, the script defaults to **skip** — it will never silently replace an existing file unattended. Set `DOTFILES_CONFLICT=overwrite` in automation that should always apply the latest dotfiles.

### Package Cleanup

After installing the profile's packages, the script checks for Homebrew packages that are installed but **not** listed in the selected Brewfile — for example, tools you installed yourself with `brew install`. It does **not** remove them automatically. On an interactive terminal it lists them and asks once:

- **`[R]` Remove them** — uninstall the listed packages. Removal is delegated to `brew bundle cleanup`, so a package still required by something in your profile is never removed. This cannot be undone (Homebrew keeps no backup).
- **`[K]` Keep them** — leave every installed package in place.

Control it non-interactively with the `CLEANUP` environment variable:

```bash
# Uninstall packages not in the profile
CLEANUP=remove bash bootstrap.sh

# Keep everything (never remove)
CLEANUP=skip bash bootstrap.sh

# Force the interactive prompt
CLEANUP=prompt bash bootstrap.sh
```

If no terminal is available and `CLEANUP` is unset, the script defaults to **keep** — it will never uninstall your packages unattended. The older `SKIP_CLEANUP=1` opt-out still works and is treated the same as `CLEANUP=skip`.

> **Note:** the prompt is global (remove all listed / keep all) rather than per-package. Deciding which packages are safe to remove depends on Homebrew's dependency graph, so that decision is left to `brew bundle cleanup` rather than reimplemented here.

### Package Manager Overlaps (npm ↔ Homebrew)

Occasionally a command in the Brewfile is *also* installed globally via npm, and the npm copy owns the command's path (e.g. `/opt/homebrew/bin/<cmd>`). Homebrew still installs its own copy but can't link it, so `brew bundle` keeps reporting the formula as missing. The script detects this "overlap":

- If the keg is merely unlinked (nothing else in the way), it links it automatically.
- If a foreign file owns the path, it identifies the culprit — naming the global npm package when that's the source — and, on an interactive terminal, **offers** to run `brew link --overwrite <formula>` so Homebrew's copy becomes the active command (this keeps it updatable via `brew upgrade`). It never does this unattended.

Because Homebrew's copy is already installed, the fix is `brew link --overwrite`, *not* a reinstall. The duplicate npm package is **never uninstalled automatically** — the script only prints the exact `npm rm -g <package>` command for you to run yourself if you want to remove the leftover.

### Cross-Platform Compatibility

- **Homebrew casks** are macOS-only; on Linux they are silently ignored (casks needed on both are guarded with `if OS.mac?` in the Brewfile)
- **All Brewfiles** are designed to be cross-platform (macOS and Linux)
- **Shell configurations** are shell-specific:
  - macOS uses Zsh (`.zprofile`, `.zshrc`)
  - All Linux distros share one Bash set (`.bashrc`, `.bash_environment`) under `linux/`. Distro- and environment-specific behavior — Debian's `debian_chroot`, Ubuntu's `lesspipe`, and the WSL Edge `BROWSER` export — is guarded inside the files with file/executable tests, so the same file works on Ubuntu, Fedora, and WSL alike.
- **Aliases** live in a single `universal/.shell_aliases`, sourced by both bash and zsh. Tool-specific entries (git, Terraform, virtualenv) are guarded with `command -v`, so they self-disable when the tool is absent — the same file serves both the minimal and developer profiles.
- **Universal dotfiles** (`.shell_aliases`, `.gitconfig`, `.gitmessage`) are applied to every profile; the `.poshthemes/` prompt theme is downloaded only for the Developer profile.

## Git Identity

The shipped `.gitconfig` carries `{FULL NAME}`, `{GITHUB EMAIL}`, and `{GITHUB USERNAME}` placeholders. Rather than leave you to edit them by hand after the run (easy to forget — commits end up attributed to `{FULL NAME}`), the script fills them in for you as its Git Personalization step:

- On an interactive terminal it **prompts** for your full name, GitHub email, and GitHub username, then substitutes them into `~/.gitconfig` in place.
- On a re-run where the placeholders are already gone, it detects that and leaves your `~/.gitconfig` untouched.

You can supply the values non-interactively (for unattended runs) with environment variables:

```bash
GIT_NAME="Your Name" \
GIT_EMAIL="your.email@example.com" \
GIT_USERNAME="your-github-username" \
bash bootstrap.sh
```

Any field you provide via env is used as-is; any field left unset is prompted for when a terminal is available. If **no** value is provided and there is **no** terminal (e.g. CI), the script leaves the placeholders in place rather than baking in blanks, and prints how to set them later:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
git config --global user.username "your-github-username"
```

**Note:** This behavior may grow as profiles are extended with additional customizable configurations.

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

- A dotfile that simply isn't present in a profile (an HTTP 404) is logged as an informational note and does not cause installation failure. A *download* failure (TLS, DNS, connection) is instead surfaced as a warning, so a real network or certificate problem is never mistaken for a missing-but-optional file.
- The bootstrap script is idempotent—running it multiple times is safe; unchanged dotfiles are detected and left alone, and each run's backups carry a unique timestamp so they never clobber one another
- Homebrew packages are **not** version-pinned; each run installs the current version from the tap. Add a `@version` suffix in the Brewfile if you need to pin a specific release.
- The Oh My Posh prompt theme (`.poshthemes/`) is downloaded only for the Developer profile

## Related Links

- **Bootstrap Script:** [bootstrap.sh](bootstrap.sh)
- **Homebrew:** [https://brew.sh](https://brew.sh)
- **Oh My Posh (theme engine):** [https://ohmyposh.dev](https://ohmyposh.dev)
