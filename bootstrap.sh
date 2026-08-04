#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ENVIRONMENT VARIABLES - USER CUSTOMIZABLE
###############################################################################

# Repository and download sources
DOTFILES_REPO="https://raw.githubusercontent.com/aaronpetak/ProfilePilot/main"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
DOTFILES_ARCHIVE_URL="https://github.com/aaronpetak/ProfilePilot/archive/refs/heads/main.zip"

# Homebrew installation paths (OS-specific)
HOMEBREW_LINUX_INSTALL_DIR="/home/linuxbrew/.linuxbrew" # Default Linux Homebrew path
HOMEBREW_LINUX_PATH="$HOMEBREW_LINUX_INSTALL_DIR/bin"   # Path to brew executable on Linux
HOMEBREW_MACOS_INSTALL_DIR="/opt/homebrew"              # Default macOS Homebrew path (Apple Silicon)
HOMEBREW_MACOS_PATH="$HOMEBREW_MACOS_INSTALL_DIR/bin"   # Path to brew executable on macOS

# Shell-specific dotfiles to download and apply. Aliases live in the universal
# .shell_aliases file (sourced by both shells), so they are NOT listed here.
#
# NOTE: These lookups are implemented as functions (not associative arrays,
# i.e. `declare -A`) because this script must run on macOS's stock /bin/bash
# (3.2, the last GPLv2 release) before Homebrew's newer bash is available.
# Associative arrays and `[[ -v arr[key] ]]` both require bash 4+.
shell_files_for() {
    case "$1" in
        bash) echo ".bashrc .bash_environment" ;;
        zsh)  echo ".zshrc .zprofile" ;;
        *)    ;;  # unknown shell: no shell-specific files (defensive; see shell_for_os)
    esac
}

# The shell whose dotfiles a given OS ships. The repo is organized one shell per
# OS (macos/ has only .zshrc/.zprofile, linux/ has only .bashrc/.bash_environment),
# so the dotfiles to install are determined by the OS, NOT by the user's login
# shell ($SHELL). Deriving from $SHELL breaks whenever the login shell doesn't
# match the OS's shipped set (e.g. bash login shell on macOS -> looks for a
# nonexistent .bashrc under macos/ and installs nothing).
shell_for_os() {
    case "$1" in
        macos) echo "zsh" ;;
        linux) echo "bash" ;;
    esac
}

# Universal dotfiles (applied to all profiles). .shell_aliases is sourced by
# both bash and zsh; .gitconfig/.gitmessage are the shared git configuration.
UNIVERSAL_FILES=".shell_aliases .gitconfig .gitmessage"

# Profile-specific directories (only installed for specified profiles)
profile_specific_dirs_for() {
    case "$1" in
        profile-developer) echo ".poshthemes" ;;
    esac
}

# Map a profile name (as accepted by the PROFILE env var or the interactive
# menu) to its Brewfile. Single source of truth for the valid profiles, so the
# env override and the menu can never drift apart. Prints nothing for an
# unknown profile, which callers treat as invalid.
brewfile_for_profile() {
    case "$1" in
        developer) echo "Brewfile-developer" ;;
        minimal)   echo "Brewfile-minimal" ;;
    esac
}

###############################################################################
# CONFIGURATION
###############################################################################

TMPDIR="/tmp/brew-bootstrap"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# Cleanup temp directory on exit. Single-quoted so $TMPDIR is expanded when the
# trap fires, not when it is defined (SC2064); TMPDIR is constant here either
# way, but this is the correct form.
trap 'rm -rf "$TMPDIR"' EXIT

# Derived variables
BREWFILES_URL="$DOTFILES_REPO/universal/brewfiles"

# Single timestamp for this run, reused for every dotfile backup so that all
# of a run's backups share one suffix (e.g. .zshrc.bak.20260728-145900) and a
# re-run never overwrites a previous run's backup.
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# How to handle an existing dotfile that differs from the profile version:
#   overwrite - back it up, then install the profile version
#   skip      - keep the existing file, don't install the profile version
#   prompt    - ask interactively (requires a TTY)
# Unset means: prompt when a TTY is available, otherwise skip. Files that don't
# exist yet are always installed; files identical to the profile are left alone.
DOTFILES_CONFLICT="${DOTFILES_CONFLICT:-}"

# How to handle Homebrew packages that are installed but NOT listed in the
# selected Brewfile (e.g. tools the user installed themselves):
#   remove - uninstall them
#   skip   - keep them
#   prompt - ask interactively (requires a TTY)
# Unset means: prompt when a TTY is available, otherwise skip, so packages a
# user installed separately are never uninstalled unattended. The older
# SKIP_CLEANUP=1 opt-out still works and is treated as skip.
CLEANUP="${CLEANUP:-}"

if [[ "$OSTYPE" == darwin* ]]; then
    LOGDIR="$HOME/Library/Logs"
else
    LOGDIR="$HOME/.local/state"
fi

mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/homebrew-restore.log"

###############################################################################
# FUNCTIONS
###############################################################################

# Log a message with timestamp to both stdout and logfile
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# True if we can actually open the controlling terminal to prompt the user.
# `[[ -r /dev/tty ]]` is not sufficient: /dev/tty can look readable yet fail to
# open ("Device not configured" / "No such device or address") when there is no
# controlling terminal (CI, containers, some `curl | bash` invocations). Under
# `set -e` that failed open on the first prompt would abort the whole script, so
# we probe by actually opening it here.
tty_available() {
    { true < /dev/tty; } 2>/dev/null
}

# If PATH is a symlink into a Node modules directory (i.e. a global npm
# install), print the npm package name that owns it — including the scope for
# scoped packages (e.g. @fresh-editor/fresh-editor). Prints nothing for
# anything else (a manual copy, another package manager), so callers can tell a
# resolvable npm duplicate from an unknown file. Args: $1 - the conflicting path.
npm_package_owning() {
    local path="$1" target rest
    [[ -L "$path" ]] || return 0
    target=$(readlink "$path" 2>/dev/null) || return 0
    case "$target" in
        */node_modules/*) ;;
        *) return 0 ;;
    esac
    rest=${target##*/node_modules/}   # e.g. @fresh-editor/fresh-editor/run-fresh.js
    if [[ "$rest" == @* ]]; then
        # Scoped package: name is the first two path segments (@scope/name).
        printf '%s/%s\n' "$(printf '%s' "$rest" | cut -d/ -f1)" "$(printf '%s' "$rest" | cut -d/ -f2)"
    else
        # Unscoped package: name is the first path segment.
        printf '%s\n' "${rest%%/*}"
    fi
}

# Log a fatal error and exit with status 1
fatal() {
    log "FATAL: $*"
    exit 1
}

# Download a Brewfile from the configured repository
# Args: $1 - filename (e.g., Brewfile-developer)
download_brewfile() {
    local file="$1"
    local url="$BREWFILES_URL/$file"
    local dest="$TMPDIR/$file"
    log "Downloading $file from ProfilePilot repo"
    curl -fsSL "$url" -o "$dest" || fatal "Failed to download $file from $url"
}

# Configure Homebrew PATH for the current session.
# .bashrc/.zshrc are overwritten by apply_dotfiles, which already contains the
# shellenv line; we only write to .profile here for non-interactive shells and
# to keep brew available throughout the remainder of this script.
# Args: $1 - path to brew executable (e.g., /opt/homebrew/bin/brew)
setup_brew_path() {
    local brew_path="$1"
    local shellenv_cmd="eval \"\$($brew_path shellenv bash)\""

    # Add to .profile for non-interactive shells, but only once: this branch
    # runs on every invocation where brew isn't yet on PATH, so an unguarded
    # append would stack duplicate lines on repeated runs.
    if ! grep -qsF "$shellenv_cmd" "$HOME/.profile"; then
        echo "$shellenv_cmd" >> "$HOME/.profile"
    fi

    # Update PATH in the current session so brew works immediately
    eval "$shellenv_cmd"
}

# Install Homebrew if not already present, then configure PATH
install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log "Homebrew already installed."
        return
    fi

    # Brew may be installed but not yet in PATH (e.g. re-run after a partial install).
    # Skip the installer and just wire up the PATH.
    if [[ -x "$HOMEBREW_LINUX_PATH/brew" ]]; then
        log "Homebrew already installed, configuring PATH..."
        setup_brew_path "$HOMEBREW_LINUX_PATH/brew"
        return
    elif [[ -x "$HOMEBREW_MACOS_PATH/brew" ]]; then
        log "Homebrew already installed, configuring PATH..."
        setup_brew_path "$HOMEBREW_MACOS_PATH/brew"
        return
    fi

    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL "$HOMEBREW_INSTALL_URL")" ||
        fatal "Failed to install Homebrew from $HOMEBREW_INSTALL_URL"

    if [[ -d "$HOMEBREW_LINUX_INSTALL_DIR" ]]; then
        setup_brew_path "$HOMEBREW_LINUX_PATH/brew"
    elif [[ -d "$HOMEBREW_MACOS_INSTALL_DIR" ]]; then
        setup_brew_path "$HOMEBREW_MACOS_PATH/brew"
    fi
}

# Install build tools required by Homebrew on Linux.
# Detects the distro's package manager and installs the appropriate toolchain.
install_build_tools() {
    if [[ "$OS_TYPE" != "linux" ]]; then
        return
    fi

    # unzip is required to extract Homebrew casks and the tflint release zip.
    # It is NOT preinstalled on Ubuntu 26+ (it was on 24). Ensure it regardless
    # of whether the compiler toolchain is already present, so re-runs and
    # systems that have gcc but not unzip still get it. bubblewrap is a Homebrew
    # sandbox dependency and is ensured here too.
    ensure_linux_packages unzip bubblewrap

    if command -v gcc >/dev/null 2>&1; then
        log "Build tools already installed."
        return
    fi

    log "Installing build tools for Linux..."

    if command -v dnf >/dev/null 2>&1; then
        # Fedora / RHEL / CentOS Stream
        # Try group install first; fall back to explicit packages if the group name differs across versions
        sudo dnf group install -y development-tools 2>/dev/null || \
            sudo dnf install -y gcc gcc-c++ make || fatal "Failed to install build tools via dnf"
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian / Ubuntu
        sudo apt-get install -y build-essential || fatal "Failed to install build-essential"
    else
        fatal "No supported package manager found (tried dnf, apt-get)"
    fi

    if ! command -v gcc >/dev/null 2>&1; then
        fatal "GCC still not available after installing build tools"
    fi
}

# Ensure one or more packages are installed on Linux via the distro package
# manager. Skips any package whose command is already available.
# Args: package names (assumed to match their provided command name)
ensure_linux_packages() {
    local missing=()
    for pkg in "$@"; do
        command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    [[ ${#missing[@]} -eq 0 ]] && return

    log "Installing Linux packages: ${missing[*]}"
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${missing[@]}" || fatal "Failed to install: ${missing[*]}"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update || true
        sudo apt-get install -y "${missing[@]}" || fatal "Failed to install: ${missing[*]}"
    else
        fatal "No supported package manager found (tried dnf, apt-get)"
    fi
}

# Install tflint on Linux.
# tflint is only published as a macOS cask in terraform-linters/tap, so on
# Linux it cannot be installed via Homebrew. We download the official release
# zip directly from GitHub (the same artifact the upstream install script uses)
# and drop the binary into the Homebrew bin dir, which is already on PATH.
# Note: we intentionally do NOT pipe the upstream install_linux.sh into bash —
# it is unpinned and its maintainers have announced its removal on 2026-09-01.
install_tflint_linux() {
    if [[ "$OS_TYPE" != "linux" ]]; then
        return
    fi

    if command -v tflint >/dev/null 2>&1; then
        log "tflint already installed."
        return
    fi

    local arch
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) log "Note: unsupported architecture $(uname -m) for tflint; skipping."; return ;;
    esac

    local url="https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_${arch}.zip"
    local dest_dir="$HOMEBREW_LINUX_PATH"
    local tmp_zip="$TMPDIR/tflint.zip"

    log "Installing tflint (linux_${arch}) from GitHub releases..."
    if ! curl -fsSL -o "$tmp_zip" "$url"; then
        log "Note: failed to download tflint from $url; skipping."
        return
    fi

    unzip -o -q "$tmp_zip" -d "$TMPDIR/tflint" || { log "Note: failed to unzip tflint; skipping."; return; }
    install -m 0755 "$TMPDIR/tflint/tflint" "$dest_dir/tflint" || { log "Note: failed to install tflint binary; skipping."; return; }
    log "tflint installed to $dest_dir/tflint"
}

# Given the "still missing" report from `brew bundle check --verbose`, tell
# apart two very different reasons a formula shows up as missing:
#
#   1. It genuinely isn't installed (a download/tap/network failure) — retrying
#      the bundle is the right move, which the caller already did.
#   2. Its keg IS installed but couldn't be *linked*, so `brew bundle` reports
#      it missing even though the software is on disk. This happens when a file
#      from outside Homebrew (commonly a global npm install, or a manual copy)
#      already occupies the formula's binary path. This is the "overlap" case:
#      it is NOT transient and no amount of retrying fixes it.
#
# For every missing formula whose keg is actually installed, we resolve case 2:
# a plain `brew link` (which never overwrites foreign files) fixes a benign
# unlinked keg automatically. If a real conflict blocks it, the keg is on disk
# but a foreign file owns its binary path. Homebrew's copy is already installed,
# so the fix is to make it the active command with `brew link --overwrite` — we
# OFFER to run that interactively (never unattended, since --overwrite replaces
# the foreign file). When the foreign file is a global npm install we also name
# the package so the user can remove the now-duplicate copy with `npm rm -g`
# themselves; we never uninstall from npm automatically. `brew list`/`brew link`
# accept the tap-qualified name the check report prints, so no alias resolution
# is needed here.
# Args: $1 - the missing-dependencies report captured from `brew bundle check`
resolve_unlinked_formulae() {
    local missing_report="$1"
    local formula link_out conflict_path npm_pkg linked ans

    # Lines look like: "→ Formula sinelaw/fresh/fresh needs to be installed or updated."
    while IFS= read -r formula; do
        [[ -z "$formula" ]] && continue

        # Only kegs that are actually installed are overlap candidates; a
        # genuinely-missing formula falls through to the caller's generic note.
        if ! brew list --formula --versions "$formula" >/dev/null 2>&1; then
            continue
        fi

        log "Overlap detected: Homebrew formula '$formula' is installed but not linked, so brew bundle keeps reporting it as missing."
        # Plain `brew link` is safe — it refuses to clobber files it doesn't
        # own — so it transparently fixes a keg that is merely unlinked.
        if link_out=$(brew link "$formula" 2>&1); then
            log "  Fixed automatically: linked '$formula' (it was installed but unlinked)."
        else
            # Linking is blocked by a pre-existing file from another source.
            conflict_path=$(printf '%s\n' "$link_out" | awk '/^Target /{print $2; exit}')
            log "  '$formula' is installed but cannot be linked because another file already owns its path${conflict_path:+: $conflict_path}."

            # Identify an npm-global duplicate so we can name it precisely.
            npm_pkg=""
            [[ -n "$conflict_path" ]] && npm_pkg=$(npm_package_owning "$conflict_path")
            if [[ -n "$npm_pkg" ]]; then
                log "  That path is owned by the global npm package '$npm_pkg' — the same command installed via npm."
            else
                log "  That file was installed outside Homebrew (a manual copy or another package manager)."
            fi

            # #1: offer to hand the command to Homebrew now. `--overwrite`
            # replaces the foreign file, so we ask first and never do it
            # unattended (no TTY -> just print the manual steps below).
            linked=""
            if tty_available; then
                {
                    echo ""
                    echo "Make Homebrew's '$formula' the active command by overwriting $conflict_path?"
                    echo "  [y] Yes - run: brew link --overwrite $formula"
                    echo "  [N] No  - leave it as-is and print the manual steps"
                } > /dev/tty
                read -rp "Overwrite? [y/N]: " ans < /dev/tty
                if [[ "$(printf '%s' "${ans:-}" | tr 'A-Z' 'a-z')" == "y" ]]; then
                    if brew link --overwrite "$formula" >/dev/null 2>&1; then
                        linked=1
                        log "  Linked Homebrew's '$formula' (ran: brew link --overwrite $formula)."
                        [[ -n "$npm_pkg" ]] && log "  The npm copy is now an unused duplicate; remove it if you like: npm rm -g $npm_pkg"
                    else
                        log "  'brew link --overwrite $formula' did not succeed; see the manual steps below."
                    fi
                fi
            fi

            # #2: if we didn't (or couldn't) link, print the paired manual fix.
            # Homebrew's copy is already installed, so the brew step is `link
            # --overwrite`, not a reinstall.
            if [[ -z "$linked" ]]; then
                log "  To make Homebrew's copy the active command, run:"
                log "    brew link --overwrite $formula"
                if [[ -n "$npm_pkg" ]]; then
                    log "  Then remove the duplicate npm copy (optional):"
                    log "    npm rm -g $npm_pkg"
                fi
            fi
        fi
    done < <(printf '%s\n' "$missing_report" | sed -n 's/.*Formula \([^ ]*\) needs.*/\1/p')
}

# Install packages from a Brewfile, retrying transient failures and continuing
# even if some packages ultimately fail.
# Args: $1 - full path to the Brewfile
#
# Homebrew 6.x installs formulae in parallel, which occasionally produces
# transient failures (a broken pipe on a download, or Cellar lock contention
# between two formulae racing on the same dependency). These almost always
# clear on the next attempt, and `brew bundle` is idempotent: a re-run skips
# already-installed formulae ("Using x") and reattempts only the ones that
# failed, so a short retry loop converges quickly.
#
# We deliberately do NOT fatal on persistent failure. `brew bundle` already
# installs every dependency it can even when some fail, so the correct behavior
# is to report the stragglers and continue to dotfiles/tflint/cleanup rather
# than abort the whole run and force the user to start over.
#
# Tunable via env: BREW_BUNDLE_ATTEMPTS (default 3), BREW_BUNDLE_RETRY_DELAY
# (seconds, default 5).
install_brewfile_packages() {
    local brewfile="$1"
    local attempts="${BREW_BUNDLE_ATTEMPTS:-3}"
    local delay="${BREW_BUNDLE_RETRY_DELAY:-5}"
    local attempt=1

    while (( attempt <= attempts )); do
        log "Installing packages from $(basename "$brewfile") (attempt $attempt/$attempts)..."
        # Third-party tap trust (Homebrew 6.0.0+): the Brewfile marks its taps
        # trusted, but we also set HOMEBREW_NO_REQUIRE_TAP_TRUST as a guaranteed
        # fallback so the untrusted-tap gate can never block the install. The
        # taps involved (oh-my-posh, sinelaw/fresh) are known and intentional.
        if HOMEBREW_NO_REQUIRE_TAP_TRUST=1 brew bundle --file="$brewfile" 2>&1; then
            log "All Brewfile dependencies installed successfully."
            return 0
        fi

        log "Warning: brew bundle attempt $attempt/$attempts reported one or more failures."
        attempt=$((attempt + 1))
        if (( attempt <= attempts )); then
            log "Retrying in ${delay}s (transient failures such as broken pipes and lock contention usually clear on retry)..."
            sleep "$delay"
        fi
    done

    # Retries exhausted. Report exactly what is still missing, then continue.
    log "Warning: some Brewfile dependencies could not be installed after $attempts attempt(s)."
    local missing
    if missing=$(brew bundle check --file="$brewfile" --verbose 2>&1); then
        # A recount says nothing is actually missing (e.g. the failures were
        # non-package steps); treat as success.
        log "Re-check reports all dependencies are present; continuing."
    else
        log "The following dependencies are still missing:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "  $line"
        done <<< "$missing"
        log "Continuing with remaining setup steps despite the missing packages above."

        # Some of those "missing" formulae may actually be installed but
        # unlinked because another install (e.g. a global npm package) owns
        # their binary path. That is not transient and retrying never helps, so
        # resolve it here: auto-link the benign cases and print an exact
        # `brew link --overwrite` recommendation for genuine path conflicts.
        resolve_unlinked_formulae "$missing"
    fi

    return 0
}

# Download all dotfiles for the selected profile and OS
# Args: $1 - profile name (e.g., profile-developer), $2 - OS directory name (macos/linux)
download_dotfiles() {
    local profile="$1"
    local os_dir="$2"
    local dotfiles_dir="$TMPDIR/dotfiles-$os_dir-$profile"

    log "Downloading dotfiles for $os_dir/$profile"
    mkdir -p "$dotfiles_dir"

    local shell_type
    shell_type="$(shell_for_os "$OS_TYPE")"
    for file in $(shell_files_for "$shell_type"); do
        local file_url="$DOTFILES_REPO/$os_dir/$profile/$file"
        local dest="$dotfiles_dir/$file"
        log "Downloading $file from $os_dir/$profile"
        curl -fsSL "$file_url" -o "$dest" 2>/dev/null || log "Note: $file not found in profile (optional)"
    done

    for file in $UNIVERSAL_FILES; do
        local file_url="$DOTFILES_REPO/universal/$file"
        local dest="$dotfiles_dir/$file"
        log "Downloading $file"
        curl -fsSL "$file_url" -o "$dest" 2>/dev/null || log "Note: $file not found in universal (optional)"
    done

    local profile_dirs
    profile_dirs="$(profile_specific_dirs_for "$profile")"
    if [[ -n "$profile_dirs" ]]; then
        for dir in $profile_dirs; do
            log "Downloading $dir"
            download_universal_directory "$dir" "$dotfiles_dir"
        done
    fi

    log "ProfilePilot profile downloaded successfully"
}

# Download and extract a directory from the ProfilePilot repository archive
# Args: $1 - directory name, $2 - parent directory to extract into
download_universal_directory() {
    local dir_name="$1"
    local dest_parent="$2"
    local dest_dir="$dest_parent/$dir_name"
    local temp_extract="$TMPDIR/dotfiles-extract-$$"

    mkdir -p "$temp_extract"

    local zip_file="$temp_extract/dotfiles.zip"
    curl -fsSL "$DOTFILES_ARCHIVE_URL" -o "$zip_file" 2>/dev/null || {
        log "Note: Could not download ProfilePilot archive for $dir_name from $DOTFILES_ARCHIVE_URL (optional)"
        return
    }

    (
        cd "$temp_extract"
        unzip -q "$zip_file" 2>/dev/null || {
            log "Note: Could not extract $dir_name from ProfilePilot archive (optional)"
            return 1
        }

        local root_dir
        root_dir=$(find . -maxdepth 1 -type d ! -name "." | head -1 | sed 's|^\./||')

        if [[ -d "$root_dir/universal/$dir_name" ]]; then
            cp -r "$root_dir/universal/$dir_name" "$dest_dir"
            log "Downloaded $dir_name successfully"
        else
            log "Note: $dir_name not found in ProfilePilot archive (optional)"
        fi
    )

    rm -rf "$temp_extract"
}

# Return 0 if a source file/dir is byte-for-byte identical to an existing
# destination, 1 otherwise. A file-vs-directory type mismatch counts as
# differing. Used to skip files the user already has in the exact profile form.
items_identical() {
    local src="$1" dest="$2"
    if [[ -f "$src" && -f "$dest" ]]; then
        cmp -s "$src" "$dest"
    elif [[ -d "$src" && -d "$dest" ]]; then
        diff -rq "$src" "$dest" >/dev/null 2>&1
    else
        return 1
    fi
}

# Copy a source file or directory to dest. Assumes dest does not already exist
# (callers handle backups first). Args: $1 - source, $2 - destination.
install_item() {
    local src="$1" dest="$2"
    if [[ -d "$src" ]]; then
        log "Installing directory $(basename "$src")"
        mkdir -p "$(dirname "$dest")"
        cp -r "$src" "$dest"
    else
        log "Installing file $(basename "$src")"
        cp "$src" "$dest"
    fi
}

# Back up an existing dotfile/dir to <name>.bak.<RUN_TS>, then install the
# profile version over it. The timestamped suffix means a re-run never clobbers
# a previous backup. Args: $1 - source, $2 - destination.
backup_and_install() {
    local src="$1" dest="$2"
    local backup="${dest}.bak.${RUN_TS}"
    log "Backing up $(basename "$dest") to $(basename "$backup")"
    mv "$dest" "$backup"
    install_item "$src" "$dest"
}

# Resolve the conflict-handling mode into the global CONFLICT_MODE
# (overwrite|skip|perfile). Honors $DOTFILES_CONFLICT; otherwise prompts when a
# TTY is available and defaults to skip when it is not. Sets a global rather
# than echoing so it can use log() freely without polluting a captured result.
CONFLICT_MODE=""
determine_conflict_mode() {
    CONFLICT_MODE=""
    case "$DOTFILES_CONFLICT" in
        overwrite) CONFLICT_MODE="overwrite"; return ;;
        skip)      CONFLICT_MODE="skip"; return ;;
        prompt)    ;;  # fall through to the interactive prompt below
        "")        ;;  # no preference; prompt if we can, else skip
        *)         log "Warning: ignoring unknown DOTFILES_CONFLICT='$DOTFILES_CONFLICT' (expected overwrite|skip|prompt)." ;;
    esac

    # Prompting needs a readable controlling terminal (works under `curl | bash`
    # via /dev/tty, but not in CI/containers that have none).
    if ! tty_available; then
        if [[ "$DOTFILES_CONFLICT" == "prompt" ]]; then
            log "DOTFILES_CONFLICT=prompt was set but no interactive terminal is available; keeping existing files."
        else
            log "No interactive terminal available; keeping existing files. Re-run with DOTFILES_CONFLICT=overwrite to replace them (originals are backed up)."
        fi
        CONFLICT_MODE="skip"
        return
    fi

    {
        echo ""
        echo "How should the differing files above be handled?"
        echo "  [O] Overwrite all - install the profile versions (originals backed up as <name>.bak.$RUN_TS)"
        echo "  [S] Skip all      - keep your existing files, install none of these"
        echo "  [D] Decide per file"
    } > /dev/tty
    local choice
    read -rp "Choose [O/S/D]: " choice < /dev/tty
    case "$(printf '%s' "${choice:-}" | tr 'A-Z' 'a-z')" in
        o) CONFLICT_MODE="overwrite" ;;
        d) CONFLICT_MODE="perfile" ;;
        s) CONFLICT_MODE="skip" ;;
        *) log "Unrecognized choice '${choice:-}'; keeping existing files."; CONFLICT_MODE="skip" ;;
    esac
}

# Interactively resolve one conflicting item: overwrite, skip, or view a diff
# (then re-ask). Assumes a readable /dev/tty (only called in perfile mode).
# Args: $1 - source, $2 - destination.
resolve_one() {
    local src="$1" dest="$2" ans
    while true; do
        read -rp "$(basename "$dest"): [o]verwrite / [s]kip / [d]iff? " ans < /dev/tty
        case "$(printf '%s' "${ans:-}" | tr 'A-Z' 'a-z')" in
            o) backup_and_install "$src" "$dest"; return ;;
            s) log "Keeping existing $(basename "$dest")."; return ;;
            d)
                {
                    echo "--- diff: your $(basename "$dest") (-) vs ProfilePilot (+) ---"
                    # diff exits 1 when files differ; guard so `set -e` doesn't abort.
                    if [[ -d "$src" ]]; then
                        diff -ru "$dest" "$src" || true
                    else
                        diff -u "$dest" "$src" || true
                    fi
                    echo "--- end diff ---"
                } > /dev/tty 2>&1
                ;;
            *) echo "Please answer o, s, or d." > /dev/tty ;;
        esac
    done
}

# Given the list of conflicting item names (existing files that differ from the
# profile), report them, decide a mode, and act. Args: $1 - profile dir,
# $2 - space-separated item names.
resolve_conflicts() {
    local profile_dir="$1" conflicts="$2" item

    log "These existing files differ from the ProfilePilot profile:"
    for item in $conflicts; do
        log "  $item"
    done

    determine_conflict_mode
    case "$CONFLICT_MODE" in
        overwrite)
            log "Overwriting all differing files (originals backed up as .bak.$RUN_TS)."
            for item in $conflicts; do
                backup_and_install "$profile_dir/$item" "$HOME/$item"
            done
            ;;
        skip)
            log "Keeping your existing files; not installing the differing profile files above."
            ;;
        perfile)
            for item in $conflicts; do
                resolve_one "$profile_dir/$item" "$HOME/$item"
            done
            ;;
    esac
}

# Install all downloaded files to the home directory. Two passes: first install
# anything missing and skip anything already identical, collecting only the
# files that exist AND differ; then resolve just those conflicts (once).
# Args: $1 - profile name, $2 - shell type (bash/zsh), $3 - OS directory name
apply_dotfiles() {
    local profile="$1"
    local shell_type="$2"
    local os_dir="$3"
    local profile_dir="$TMPDIR/dotfiles-$os_dir-$profile"

    [[ ! -d "$profile_dir" ]] && { log "Warning: ProfilePilot profile directory not found: $profile_dir"; return; }

    log "Applying profile files for $shell_type shell..."

    # Assemble the full list of item names to consider (dotfile names contain no
    # spaces, so a space-separated string is a safe bash 3.2-compatible list).
    local items="" item
    for item in $(shell_files_for "$shell_type"); do items="$items $item"; done
    for item in $UNIVERSAL_FILES; do items="$items $item"; done
    local profile_dirs
    profile_dirs="$(profile_specific_dirs_for "$profile")"
    if [[ -n "$profile_dirs" ]]; then
        for item in $profile_dirs; do items="$items $item"; done
    fi

    # Pass 1: install missing items, leave identical ones alone, collect the
    # rest (existing but different) as conflicts to resolve together.
    local conflicts="" src dest
    for item in $items; do
        src="$profile_dir/$item"
        dest="$HOME/$item"
        [[ -e "$src" ]] || continue
        if [[ ! -e "$dest" ]]; then
            install_item "$src" "$dest"
        elif items_identical "$src" "$dest"; then
            log "$item already matches the profile; leaving it unchanged."
        else
            conflicts="$conflicts $item"
        fi
    done

    # Pass 2: resolve conflicts, if any.
    if [[ -n "$conflicts" ]]; then
        resolve_conflicts "$profile_dir" "$conflicts"
    fi

    log "Profile files applied successfully"
}

# Fill in the personal fields of the freshly-installed ~/.gitconfig.
#
# The shipped .gitconfig carries placeholders ({FULL NAME}, {GITHUB EMAIL},
# {GITHUB USERNAME}) that used to require a manual edit after the run — easy to
# forget, leaving git commits attributed to "{FULL NAME}". Instead we prompt for
# the values here and substitute them in place.
#
# Values may be supplied via env (GIT_NAME, GIT_EMAIL, GIT_USERNAME) to run
# unattended; any not supplied are prompted for on a TTY. With no TTY and no env
# values we leave the placeholders intact and print how to fix them, rather than
# baking blanks into the config.
personalize_gitconfig() {
    local gitconfig="$HOME/.gitconfig"

    [[ -f "$gitconfig" ]] || { log "Note: ~/.gitconfig not present; skipping git personalization."; return; }

    # Nothing to do if the placeholders are already gone (e.g. a re-run where the
    # user kept their existing, already-personalized .gitconfig).
    if ! grep -q '{FULL NAME}\|{GITHUB EMAIL}\|{GITHUB USERNAME}' "$gitconfig"; then
        log "~/.gitconfig is already personalized; leaving it unchanged."
        return
    fi

    local name="${GIT_NAME:-}" email="${GIT_EMAIL:-}" username="${GIT_USERNAME:-}"

    # Prompt for anything not preset, but only if we can read a terminal.
    if tty_available; then
        {
            echo ""
            echo "Personalize your git identity (written to ~/.gitconfig):"
        } > /dev/tty
        [[ -z "$name" ]]     && read -rp "  Full name: " name < /dev/tty
        [[ -z "$email" ]]    && read -rp "  GitHub email (e.g. you@example.com or the GitHub no-reply address): " email < /dev/tty
        [[ -z "$username" ]] && read -rp "  GitHub username: " username < /dev/tty
    fi

    # If we still have no values (no TTY and no env), don't write blanks over the
    # placeholders — leave them so the config is obviously still incomplete.
    if [[ -z "$name" && -z "$email" && -z "$username" ]]; then
        log "No git identity provided and no interactive terminal; leaving ~/.gitconfig placeholders in place."
        log "Set them later with: git config --global user.name '...'; git config --global user.email '...'; git config --global user.username '...'"
        return
    fi

    # Substitute each provided value in place. We escape the substitution's
    # special characters (&, /, and \) so an address or name containing them
    # can't corrupt the sed replacement. Any field left blank keeps its
    # placeholder, which we report so it isn't silently forgotten.
    local sed_escaped
    sed_escape() { printf '%s' "$1" | sed -e 's/[&/\]/\\&/g'; }

    if [[ -n "$name" ]]; then
        sed_escaped=$(sed_escape "$name")
        sed -i.bak "s/{FULL NAME}/$sed_escaped/" "$gitconfig"
    fi
    if [[ -n "$email" ]]; then
        sed_escaped=$(sed_escape "$email")
        sed -i.bak "s/{GITHUB EMAIL}/$sed_escaped/" "$gitconfig"
    fi
    if [[ -n "$username" ]]; then
        sed_escaped=$(sed_escape "$username")
        sed -i.bak "s/{GITHUB USERNAME}/$sed_escaped/" "$gitconfig"
    fi
    # sed -i on both GNU (Linux) and BSD (macOS) leaves a .bak file; remove it.
    rm -f "$gitconfig.bak"

    log "Personalized ~/.gitconfig."
    if grep -q '{FULL NAME}\|{GITHUB EMAIL}\|{GITHUB USERNAME}' "$gitconfig"; then
        log "Note: some git identity fields were left blank and still contain placeholders in ~/.gitconfig; edit them to finish."
    fi
}

###############################################################################
# OS DETECTION - Determine platform and set appropriate variables
###############################################################################

if [[ "$OSTYPE" == darwin* ]]; then
    OS_TYPE="macos"
    OS_DOTFILES_DIR="macos"
elif [[ "$OSTYPE" == linux-gnu* ]]; then
    OS_TYPE="linux"
    # All Linux distros share a single dotfiles set. Distro-specific behavior
    # (Debian chroot, lesspipe, WSL browser export) is guarded inside those
    # files, so no per-distro directory is needed.
    OS_DOTFILES_DIR="linux"
else
    fatal "Unsupported OS: $OSTYPE"
fi

log "Detected OS: $OS_TYPE ($OS_DOTFILES_DIR)"

###############################################################################
# PROFILE SELECTION - Ask user which environment to bootstrap
###############################################################################

# Profile can be preselected non-interactively via the PROFILE env var
# (developer|minimal), which is required for unattended runs (CI, containers,
# curl|bash with no TTY). Otherwise we present the interactive menu, but only
# when a controlling terminal is actually available: reading from /dev/tty with
# none present fails under `set -e` and would abort the whole run here, before
# any of the non-interactive knobs (DOTFILES_CONFLICT, CLEANUP) could apply.
BREWFILE=""
if [[ -n "${PROFILE:-}" ]]; then
    BREWFILE="$(brewfile_for_profile "$PROFILE")"
    [[ -n "$BREWFILE" ]] || fatal "Invalid PROFILE='$PROFILE' (expected: developer or minimal)."
    log "Profile preselected via PROFILE=$PROFILE"
elif tty_available; then
    echo ""
    echo "Select environment profile:"
    echo "  1) Developer Workstation"
    echo "  2) Minimal Host"
    echo ""

    read -rp "Enter 1 or 2: " choice < /dev/tty

    case "$choice" in
        1) BREWFILE="Brewfile-developer" ;;
        2) BREWFILE="Brewfile-minimal" ;;
        *) fatal "Invalid choice." ;;
    esac
else
    fatal "No profile selected and no interactive terminal available. Set PROFILE=developer or PROFILE=minimal to run unattended."
fi

log "Selected Brewfile: $BREWFILE"

###############################################################################
# DOWNLOAD BREWFILE - Fetch the package manifest for chosen environment
###############################################################################

download_brewfile "$BREWFILE"

###############################################################################
# INSTALL PACKAGE MANAGER & BUILD TOOLS
###############################################################################

install_homebrew
install_build_tools

###############################################################################
# INSTALL PACKAGES
###############################################################################

log "Updating Homebrew..."
brew update

# Install packages, retrying transient failures and continuing past any that
# persist (see install_brewfile_packages). This intentionally never aborts the
# run, so dotfiles, tflint, and cleanup still happen even if a package fails.
install_brewfile_packages "$TMPDIR/$BREWFILE"

# tflint is a macOS-only cask in Homebrew; install it separately on Linux for
# the developer profile.
if [[ "$BREWFILE" == "Brewfile-developer" ]]; then
    install_tflint_linux
fi

###############################################################################
# APPLY ProfilePilot - Download and install shell configs and app settings
###############################################################################

DOTFILES_PROFILE="profile-${BREWFILE#Brewfile-}"
SHELL_TYPE="$(shell_for_os "$OS_TYPE")"
download_dotfiles "$DOTFILES_PROFILE" "$OS_DOTFILES_DIR"
apply_dotfiles "$DOTFILES_PROFILE" "$SHELL_TYPE" "$OS_DOTFILES_DIR"

# Fill in name/email/username in the just-installed ~/.gitconfig interactively,
# so it never gets left with the shipped placeholders.
personalize_gitconfig

###############################################################################
# CLEANUP PACKAGES
###############################################################################

# Resolve how to handle installed packages not listed in the Brewfile into the
# global CLEANUP_MODE (remove|skip). Mirrors the dotfiles conflict handling:
# honors $CLEANUP (remove|skip|prompt), keeps the older $SKIP_CLEANUP=1 working
# as an alias for skip, prompts on a TTY, and defaults to skip when no TTY is
# available so a user's own packages are never uninstalled unattended.
#
# The prompt is intentionally global (Remove all / Keep all) rather than
# per-package: deciding which packages are safe to remove requires Homebrew's
# dependency graph, so the actual removal is delegated to `brew bundle cleanup`
# (which never removes a package still required by one in the Brewfile).
CLEANUP_MODE=""
determine_cleanup_mode() {
    CLEANUP_MODE=""

    local pref="$CLEANUP"
    # Backward compatibility with the original opt-out switch.
    if [[ -z "$pref" && -n "${SKIP_CLEANUP:-}" ]]; then
        pref="skip"
    fi

    case "$pref" in
        remove) CLEANUP_MODE="remove"; return ;;
        skip)   CLEANUP_MODE="skip"; return ;;
        prompt) ;;  # fall through to the interactive prompt below
        "")     ;;  # no preference; prompt if we can, else skip
        *)      log "Warning: ignoring unknown CLEANUP='$pref' (expected remove|skip|prompt)." ;;
    esac

    if ! tty_available; then
        if [[ "$CLEANUP" == "prompt" ]]; then
            log "CLEANUP=prompt was set but no interactive terminal is available; keeping all installed packages."
        else
            log "No interactive terminal available; keeping packages not listed in $BREWFILE. Re-run with CLEANUP=remove to uninstall them."
        fi
        CLEANUP_MODE="skip"
        return
    fi

    {
        echo ""
        echo "The packages listed above are installed but not part of $BREWFILE."
        echo "How should they be handled?"
        echo "  [R] Remove them - uninstall the packages above (cannot be undone; Homebrew keeps no backup)"
        echo "  [K] Keep them   - leave every installed package in place"
    } > /dev/tty
    local choice
    read -rp "Choose [R/K]: " choice < /dev/tty
    case "$(printf '%s' "${choice:-}" | tr 'A-Z' 'a-z')" in
        r) CLEANUP_MODE="remove" ;;
        k) CLEANUP_MODE="skip" ;;
        *) log "Unrecognized choice '${choice:-}'; keeping all packages."; CLEANUP_MODE="skip" ;;
    esac
}

FORMULA_COUNT=$(brew list --formula | wc -l | tr -d ' ')
CASK_COUNT=$(brew list --cask 2>/dev/null | wc -l | tr -d ' ')
TOTAL_PKGS=$((FORMULA_COUNT + CASK_COUNT))

if [[ "$TOTAL_PKGS" -eq 0 ]]; then
    log "No packages installed; cleanup unnecessary."
else
    log "Checking for packages not listed in $BREWFILE ($TOTAL_PKGS currently installed)..."

    # Without --force, `brew bundle cleanup` only reports what it would remove
    # and touches nothing. Use it to preview the candidates so the user (or the
    # log, in non-interactive runs) can see exactly what is at stake before any
    # destructive pass.
    CLEANUP_PREVIEW=$(brew bundle cleanup --file="$TMPDIR/$BREWFILE" 2>&1) || true

    if [[ -z "$CLEANUP_PREVIEW" ]]; then
        log "Nothing to clean up; every installed package is part of $BREWFILE."
    else
        log "The following are installed but not listed in $BREWFILE:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "  $line"
        done <<< "$CLEANUP_PREVIEW"

        determine_cleanup_mode
        if [[ "$CLEANUP_MODE" == "remove" ]]; then
            log "Removing packages not listed in $BREWFILE..."
            brew bundle cleanup --file="$TMPDIR/$BREWFILE" --force
            log "Cleanup complete."
        else
            log "Keeping all installed packages; nothing was removed. (Set CLEANUP=remove to uninstall packages not in the profile.)"
        fi
    fi
fi

###############################################################################
# COMPLETION
###############################################################################

log "Environment restored successfully."
exit 0
