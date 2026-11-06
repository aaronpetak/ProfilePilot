# ProfilePilot

Provisioning for a fresh macOS or Linux machine: a `bootstrap.sh` script plus the Homebrew package lists (Brewfiles) and shell configuration (dotfiles) it installs. It installs Homebrew if needed, installs a profile's packages, applies the profile's dotfiles, and writes your git identity.

## Quick Start

```bash
f="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/aaronpetak/ProfilePilot/main/bootstrap.sh -o "$f" && bash "$f"
```

The script detects your OS, asks you to pick a profile (Developer or Minimal), and sets up the machine. It must run as a normal user with `sudo` access: Homebrew refuses to install as root, and the Linux distro-package steps use `sudo`.

Piping the script (`curl -fsSL .../bootstrap.sh | bash`) also works. A piped script has no file next to it, so it takes the tarball path described below, and prompts still reach you through `/dev/tty`.

To run unattended, preselect everything with environment variables:

```bash
PROFILE=minimal DOTFILES_CONFLICT=overwrite CLEANUP=skip \
GIT_NAME="Your Name" GIT_EMAIL="you@example.com" \
bash bootstrap.sh
```

Supported platforms: macOS, and glibc-based Linux using `apt-get`, `dnf`, `pacman` or `zypper` (Debian/Ubuntu, Fedora/RHEL family, Arch, openSUSE). musl distros such as Alpine are not supported because Homebrew on Linux needs glibc.

## Where the Files Come From

`bootstrap.sh` resolves its source in one of two ways:

- **Local checkout.** If the script file sits in a ProfilePilot clone (its directory contains `universal/brewfiles`), it installs from that clone. This is what `bash bootstrap.sh` does inside a checkout, and it is how you test local changes.
- **One tarball.** Otherwise (piped, or copied somewhere by itself) it downloads a single tarball of `$DOTFILES_REF` from `$DOTFILES_REPO_SLUG` (`https://codeload.github.com/<slug>/tar.gz/<ref>`) and unpacks it into a private temporary directory. Every file comes from the same snapshot. The archive is checked for `universal/brewfiles/Brewfile-minimal` and the run stops if it is missing.

`DOTFILES_REPO_SLUG` (default `aaronpetak/ProfilePilot`) selects a fork, and `DOTFILES_REF` (default `main`) accepts a branch, tag or commit SHA:

```bash
# A fork, pinned to a tag
DOTFILES_REPO_SLUG=your-user/ProfilePilot DOTFILES_REF=v1.2.0 bash "$f"
```

Both variables only matter in tarball mode; a local checkout ignores them.

## Environment Variables

| Variable | Values / default | Effect |
| --- | --- | --- |
| `PROFILE` | `developer`, `minimal` | Selects the profile without the menu. Unset: menu on a terminal; with no terminal the run stops with an error. |
| `DOTFILES_CONFLICT` | `overwrite`, `skip`, `prompt` | How to treat an existing dotfile that differs from the profile's. Unset: prompt on a terminal, otherwise `skip`. |
| `CLEANUP` | `remove`, `skip`, `prompt` | What to do with installed Homebrew packages that are not in the Brewfile. Unset: prompt on a terminal, otherwise `skip`. |
| `SKIP_CLEANUP` | any non-empty value | Same as `CLEANUP=skip` (used only when `CLEANUP` is unset). |
| `GIT_NAME` | text | Git `user.name`, written to `~/.gitconfig.local`. Unset: prompted when a terminal is available. |
| `GIT_EMAIL` | text | Git `user.email`, written to `~/.gitconfig.local`. Unset: prompted when a terminal is available. |
| `DOTFILES_REPO_SLUG` | `owner/repo`, default `aaronpetak/ProfilePilot` | Repository the tarball is fetched from (tarball mode only). |
| `DOTFILES_REF` | branch, tag or SHA, default `main` | Ref of that repository to fetch (tarball mode only). |
| `BREW_BUNDLE_ATTEMPTS` | number, default `3` | How many times `brew bundle` is tried. |
| `BREW_BUNDLE_RETRY_DELAY` | seconds, default `5` | Pause between `brew bundle` attempts. |

## Directory Structure

```text
ProfilePilot/
├── bootstrap.sh                      # Provisioning script (run this)
├── linux/
│   ├── .bashrc                       # Base bash config for every profile and distro
│   └── profile-developer/
│       └── .bashrc.developer         # Developer add-on, sourced last by .bashrc
├── macos/
│   ├── .zprofile                     # Homebrew shellenv for login shells
│   ├── .zshrc                        # Base zsh config for every profile
│   └── profile-developer/
│       └── .zshrc.developer          # Developer add-on, sourced last by .zshrc
├── universal/
│   ├── .shell_aliases                # Aliases and functions, sourced by bash AND zsh
│   ├── .gitconfig                    # Shared git configuration
│   ├── .gitmessage                   # Commit message template
│   ├── .poshthemes/                  # Oh My Posh themes (developer only)
│   │   └── meridian-2.omp.json
│   └── brewfiles/
│       ├── Brewfile-developer
│       └── Brewfile-minimal
├── test/
│   ├── logic_tests.sh                # Unit tests for bootstrap.sh and the dotfiles
│   └── ci/                           # Scripts used by the CI smoke jobs
└── .github/workflows/ci.yml
```

The shell is chosen by the OS, not by `$SHELL`: macOS gets the zsh files, Linux gets the bash files.

## Profiles

### Developer

Installs `Brewfile-developer` and the developer add-on for your shell. The Brewfile covers these categories:

- Core CLI tools: `bat`, `direnv`, `fzf`, `git`, `gh`, `htop`, `jq`, `ripgrep`, `tmux`, `tree`, `tldr`, `age`, `gnupg`, `ipcalc`, the `fresh` editor
- Programming language: Go
- Networking: `iperf3`, `mtr`, `nmap`, `speedtest-cli`
- Cloud and Kubernetes: `kubectl`, `kubectx`, `stern`, `awscli`, `aws-sso-cli`, `step`, `grpcurl`
- IaC and security: `terraform-docs`, `tfenv`, `tflint`, `checkov`, `trivy`, `semgrep`
- Config and formatting: `yq`, `yamllint`, `jsonlint`
- Python tooling: `pyenv`, `virtualenv`, `virtualenvwrapper`
- Containers and Ansible: `hadolint`, `ansible`, `ansible-lint`
- Misc: `just`, `pre-commit`, Oh My Posh (the prompt theme engine)
- Casks: `1password-cli` (macOS and Linux); `meetingbar` and `monitorcontrol` are macOS-only and guarded with `if OS.mac?`

The profile also installs `~/.poshthemes/`. The add-on is `~/.bashrc.developer` on Linux (projects directory, virtualenvwrapper, Go environment, the Oh My Posh prompt with the theme from `~/.poshthemes/`, and a `BROWSER` setting under WSL) or `~/.zshrc.developer` on macOS (Oh My Posh, virtualenvwrapper, `fzf` integration).

### Minimal

Installs `Brewfile-minimal` (`git`, `jq`, `yq`, `ripgrep`, `tmux`, `age`, `gnupg`) and the base shell config only: no add-on and no prompt theme.

Both profiles also get `~/.shell_aliases`, `~/.gitconfig` and `~/.gitmessage`.

## How It Works

1. **OS detection.** macOS or glibc Linux; anything else stops the run. Running as root is refused.
2. **Profile selection.** `PROFILE`, or the menu.
3. **Source resolution.** Local checkout or one tarball (see above).
4. **Homebrew.** If `brew` is not on `PATH`, the known prefixes are checked first, so an existing install is wired up instead of reinstalled. Otherwise the official installer is downloaded to a file and run; a failed download stops the run. On Linux it makes sure `git`, `curl`, `tar` and `gzip` exist before running the installer, and afterwards installs `unzip`, `bubblewrap`, `gawk` and a compiler toolchain through the distro package manager (on Arch this is a full `pacman -Syu`; on apt systems `apt-get update` runs once before the first install).
5. **Packages.** `brew update` (a failure is only a warning), then `brew bundle` on the profile's Brewfile with retries. Packages that still fail are reported and the run continues, but the exit status is non-zero.
6. **Dotfiles.** Applied to `$HOME` as described below.
7. **Git identity.** Written to `~/.gitconfig.local`.
8. **Cleanup.** Offers to remove installed packages that are not in the Brewfile.
9. **Summary.** Reports packages, dotfiles and git identity separately.

### Homebrew prefix detection

Nothing hardcodes where Homebrew lives. The prefixes are tried in this order and the first with an executable `bin/brew` is used: `/opt/homebrew` (Apple Silicon), `/usr/local` (Intel macOS), `/home/linuxbrew/.linuxbrew` (Linux default), `~/.linuxbrew` (per-user Linux). The dotfiles do the same at shell start with `brew shellenv` for the first brew found: `macos/.zprofile` (and `.zshrc`, for non-login shells that have no `HOMEBREW_PREFIX` yet) check the two macOS prefixes and use `shellenv zsh`; `linux/.bashrc` checks all four and uses `shellenv bash`. On Linux the lookup is at the top of `.bashrc`, before `.shell_aliases` is sourced, so the `command -v` guards there can see Homebrew tools.

`bootstrap.sh` also writes `eval "$(<prefix>/bin/brew shellenv bash)"` to `~/.profile` (and `~/.bash_profile` when it exists, because a bash login shell reads that file instead of `~/.profile`) on Linux, once per line. On macOS it makes sure `~/.zprofile` has a `shellenv` line and appends one only if yours has none.

### Package installation and retries

`brew bundle` runs with serial downloads (`HOMEBREW_DOWNLOAD_CONCURRENCY=1`), which avoids interleaved progress output and cache races. Failures are retried `BREW_BUNDLE_ATTEMPTS` times. If a formula is installed but cannot be linked because another file (for example a global npm package) owns its path, the script links it automatically when that is safe, or on a terminal offers `brew link --overwrite <formula>`. It never uninstalls the npm copy; it only prints the `npm rm -g` command.

Third-party taps are trusted per tap in the Brewfile (`trusted: true`); the tap-trust check stays enabled.

### tflint on Linux

`tflint` is only a Homebrew cask on macOS, so on Linux the developer profile installs it from the GitHub release. The latest release tag is resolved once, then that tag's `tflint_linux_<arch>.zip` and `checksums.txt` are downloaded and the zip is verified with `sha256sum -c` before the binary is installed into the Homebrew `bin` directory (amd64 and arm64). The check guards against a corrupted download or a tampered mirror. The checksums are published next to the artifact, so it does not protect against a compromised upstream release. If the download or the check fails, tflint is skipped, the package step is marked incomplete and the exit status is non-zero.

### Existing dotfiles and backups

For each dotfile the script compares your version with the profile's:

- Missing: installed.
- Identical: left alone, no backup.
- Different (including a dangling symlink): a conflict, resolved by mode.

On a terminal you are asked once: `[O]` overwrite all, `[S]` skip all, or `[D]` decide per file (overwrite, skip, or view a diff). Without a terminal, `DOTFILES_CONFLICT` decides, and unset means skip, so an unattended run never replaces your files. Overwriting moves the original to `<name>.bak.<timestamp>` in place; the timestamp is per run, so a re-run never overwrites an earlier backup.

### Package cleanup

After installing, the script lists packages that are installed but not in the selected Brewfile and asks whether to remove them (`[R]`) or keep them (`[K]`). Removal is done by `brew bundle cleanup`, so packages still required by something in the Brewfile stay. It cannot be undone. Without a terminal, `CLEANUP` decides, and unset means keep.

### Git identity

The shipped `~/.gitconfig` has no `[user]` section. It starts with

```ini
[include]
    path = ~/.gitconfig.local
```

and `bootstrap.sh` writes `user.name` and `user.email` into `~/.gitconfig.local` with `git config --file` (so special characters need no escaping, and a name or email containing a newline is rejected). That file is never shipped, so re-applying the profile cannot overwrite your identity. Values come from `GIT_NAME` and `GIT_EMAIL`, an identity already in `~/.gitconfig.local`, or a prompt on a terminal. With no terminal and no values, nothing is written and the script prints how to set them. After writing, it checks that `git config --global --includes user.email` returns the value; if your own `~/.gitconfig` lacks the include it says so and marks the identity step incomplete.

The include must stay at the top: git applies later entries last, so the per-directory identities below override it only if they come after. `~/projects/gh/` and `~/projects/ghe/` each load their own `.gitconfig` through `includeIf "gitdir:..."`, so a repository under those directories can use a different identity.

### Editor

Each base rc (`.bashrc`, `.zshrc`) sets `EDITOR` only when it is not already set: `code --wait` if `code` is on `PATH` and the session is not over SSH (`SSH_CONNECTION` and `SSH_TTY` unset), otherwise `vim` if present, otherwise `vi`. `VISUAL` defaults to `EDITOR`. `.gitconfig` does not set `core.editor`, so git follows `EDITOR`.

### Shell config model: base rc plus developer add-on

Each OS has one base rc shared by every profile. The developer profile additionally installs an add-on (`~/.bashrc.developer` or `~/.zshrc.developer`) that the base rc sources if it exists. Aliases and helper functions live once in `~/.shell_aliases`, which both shells source; tool-specific entries are guarded so they do nothing when the tool is absent.

**`PROMPT_COMMAND` invariant (bash).** The base `.bashrc` sets `PROMPT_COMMAND` and a fallback `PS1`, then sources the add-on as its last statement. `oh-my-posh init bash` stores its hook in a `PROMPT_COMMAND` array, so nothing after it may assign `PROMPT_COMMAND` or `PS1`: a later string assignment replaces only element `[0]` and drops the hook. The add-on flattens the array into one string because bash older than 5.1 (RHEL-family 8 ships 4.4) only runs element `[0]`. `test/logic_tests.sh` checks the ordering.

### Log file

Output is also appended to `~/.local/state/profilepilot.log` on Linux and `~/Library/Logs/profilepilot.log` on macOS.

### Idempotency

Re-running is safe. Identical dotfiles are left alone, shell startup lines are appended only once, identities already in `~/.gitconfig.local` are kept, and backups get a per-run timestamp. A re-run is not a no-op: it runs `brew update` and `brew bundle` again, and with `DOTFILES_CONFLICT=overwrite` any file that differs from the profile is replaced again (after a new backup).

## Migrating an Existing Install

- **`~/.bash_environment` is no longer sourced.** Its settings now live in `~/.bashrc.developer`. The script notes this and leaves your file in place.
- **Old `~/.gitconfig` with placeholders.** A real `user.name` or `user.email` in your current `~/.gitconfig` is copied to `~/.gitconfig.local` before the profile is applied (placeholder values like `{FULL NAME}` are not). If you keep your own `~/.gitconfig` and it lacks the `[include]` for `~/.gitconfig.local`, the script tells you to add it.
- **Stale developer add-on on a minimal run.** If `~/.bashrc.developer` or `~/.zshrc.developer` exists from an earlier developer run and you now choose Minimal, it is treated like a conflict: `overwrite` moves it to a timestamped backup, `skip` keeps it (and the run is reported as kept), and per-file mode asks.
- **Stale `shellenv` lines.** A `~/.profile` or `~/.bash_profile` line that runs `shellenv` for a `brew` that does not exist is reported, not edited. Remove or fix it yourself.
- **`includeIf` directory.** Per-directory git identities now apply under `~/projects/gh/` (previously `~/projects/github/`).
- **Log name.** The log is `profilepilot.log` (previously `homebrew-restore.log`).

## Testing and CI

Run the unit tests locally; they need no network, Homebrew or terminal, and use temporary directories as `HOME`:

```bash
bash test/logic_tests.sh
```

Lint locally with `shellcheck --severity=warning bootstrap.sh test/logic_tests.sh test/ci/*.sh`.

CI (`.github/workflows/ci.yml`) runs these jobs:

- **lint**: shellcheck on all scripts and on the bash dotfiles and `.shell_aliases`, `bash -n` on every bash file, `zsh -n` on the zsh files and `.shell_aliases`.
- **tests**: `test/logic_tests.sh` on Ubuntu, and on macOS under the stock `/bin/bash` 3.2 that `bootstrap.sh` must support.
- **smoke-linux**: runs `bootstrap.sh` with the minimal profile as a non-root sudo user in bare `ubuntu:24.04`, `fedora:latest`, `rockylinux/rockylinux:8`, `archlinux:latest` and `opensuse/tumbleweed` containers, where only `sudo` is preinstalled, then checks `brew`, `jq`, `rg`, `tmux`, the git identity, `~/.bashrc` and a clean `bash -ic true`.
- **smoke-tarball**: runs a lone copy of `bootstrap.sh` against the commit under test, which exercises the tarball path with an already installed Homebrew.
- **smoke-developer**: runs the developer profile on Ubuntu, covering the taps and the tflint checksum path.
- **smoke-macos**: runs `bootstrap.sh` end to end under `/bin/bash` 3.2 with the minimal profile and checks a login zsh.

## Maintenance

### Adding or updating packages

Edit `universal/brewfiles/Brewfile-developer` or `Brewfile-minimal`. Use `brew "name"` for formulae and `cask "name"` for applications; guard macOS-only casks with `if OS.mac?` so Linux skips them (some casks, such as `1password-cli`, work on both). Packages are not version-pinned.

### Updating shell configuration

- Base rc: `linux/.bashrc`, `macos/.zshrc`, `macos/.zprofile`
- Developer add-on: `linux/profile-developer/.bashrc.developer`, `macos/profile-developer/.zshrc.developer`
- Aliases and functions for both shells: `universal/.shell_aliases` (keep it portable and guard tool-specific parts)

Keep `bootstrap.sh` compatible with bash 3.2, the stock bash on macOS: no associative arrays and no bash 4+ expansions. The bash dotfiles may use bash 4.4+.

Test shell changes in a real login shell (`bash -l`, or a new SSH session), not only `exec bash`: when `~/.bash_profile` exists, a login bash ignores `~/.profile`. For prompt theme changes, `oh-my-posh debug 2>&1 | grep ERROR` shows template errors that otherwise fail silently.

### Adding new profiles

To add a profile such as `security`:

1. Create `universal/brewfiles/Brewfile-security`.
2. Add `security) echo "Brewfile-security" ;;` to `brewfile_for_profile` in `bootstrap.sh`, and add it to the menu in `select_profile`.
3. If it needs extra shell config, add `macos/profile-security/.zshrc.security` and `linux/profile-security/.bashrc.security`, and teach `shell_addon_name_for` and `shell_addon_for` about them. The base rc must source the add-on last, or the `PROMPT_COMMAND` invariant is lost.
4. If it needs extra directories, list them in `profile_specific_dirs_for`.
5. Add tests to `test/logic_tests.sh`.

## Related Links

- [bootstrap.sh](bootstrap.sh)
- [Homebrew](https://brew.sh)
- [Oh My Posh](https://ohmyposh.dev)
