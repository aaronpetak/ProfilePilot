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
        if HOMEBREW_NO_REQUIRE_TAP_TRUST=1 brew bundle --file="$brewfile"; then
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

    local shell_type="${SHELL##*/}"
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

# Install a file or directory to the home directory, backing up any existing version
# Args: $1 - source path, $2 - destination path
apply_item() {
    local src="$1"
    local dest="$2"
    local item_type

    if [[ -f "$src" ]]; then
        item_type="file"
    elif [[ -d "$src" ]]; then
        item_type="directory"
    else
        return
    fi

    if [[ -e "$dest" ]]; then
        log "Backing up $(basename "$dest") to $(basename "$dest").bak"
        # Use a real if/else: `A && B || C` would run C when B fails, clobbering
        # the backup logic (SC2015).
        if [[ -d "$dest" ]]; then
            mv "$dest" "${dest}.bak"
        else
            cp "$dest" "${dest}.bak"
        fi
    fi

    log "Installing $item_type $(basename "$src")"
    if [[ "$item_type" == "directory" ]]; then
        mkdir -p "$(dirname "$dest")"
        cp -r "$src" "$dest"
    else
        cp "$src" "$dest"
    fi
}

# Install all downloaded files to the home directory
# Args: $1 - profile name, $2 - shell type (bash/zsh), $3 - OS directory name
apply_dotfiles() {
    local profile="$1"
    local shell_type="$2"
    local os_dir="$3"
    local profile_dir="$TMPDIR/dotfiles-$os_dir-$profile"

    [[ ! -d "$profile_dir" ]] && { log "Warning: ProfilePilot profile directory not found: $profile_dir"; return; }

    log "Applying profile files for $shell_type shell..."

    for file in $(shell_files_for "$shell_type"); do
        apply_item "$profile_dir/$file" "$HOME/$file"
    done

    for file in $UNIVERSAL_FILES; do
        apply_item "$profile_dir/$file" "$HOME/$file"
    done

    local profile_dirs
    profile_dirs="$(profile_specific_dirs_for "$profile")"
    if [[ -n "$profile_dirs" ]]; then
        for dir in $profile_dirs; do
            apply_item "$profile_dir/$dir" "$HOME/$dir"
        done
    fi

    log "Profile files applied successfully"
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
SHELL_TYPE="${SHELL##*/}"
download_dotfiles "$DOTFILES_PROFILE" "$OS_DOTFILES_DIR"
apply_dotfiles "$DOTFILES_PROFILE" "$SHELL_TYPE" "$OS_DOTFILES_DIR"

###############################################################################
# CLEANUP PACKAGES
###############################################################################

FORMULA_COUNT=$(brew list --formula | wc -l | tr -d ' ')
CASK_COUNT=$(brew list --cask 2>/dev/null | wc -l | tr -d ' ')
TOTAL_PKGS=$((FORMULA_COUNT + CASK_COUNT))

# Cleanup runs automatically (no interactive prompt) so the script can complete
# unattended. It removes any Homebrew package NOT listed in the selected
# Brewfile. Set SKIP_CLEANUP=1 to opt out (useful when other Homebrew packages
# on the machine should be preserved).
if [[ "$TOTAL_PKGS" -eq 0 ]]; then
    log "No packages installed; cleanup unnecessary."
elif [[ -n "${SKIP_CLEANUP:-}" ]]; then
    log "SKIP_CLEANUP set; skipping removal of packages not listed in $BREWFILE."
else
    log "Checking for packages not listed in $BREWFILE ($TOTAL_PKGS currently installed)..."

    # Without --force, `brew bundle cleanup` only lists what it would remove
    # and doesn't touch anything. On a machine that predates ProfilePilot,
    # that removal list can include tools installed manually or by a previous
    # setup that simply aren't part of the selected profile, so log the
    # preview before the destructive pass rather than removing them silently.
    CLEANUP_PREVIEW=$(brew bundle cleanup --file="$TMPDIR/$BREWFILE" 2>&1) || true
    if [[ -n "$CLEANUP_PREVIEW" ]]; then
        log "The following will be removed because they are not listed in $BREWFILE:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "  $line"
        done <<< "$CLEANUP_PREVIEW"
        log "Set SKIP_CLEANUP=1 and re-run this script if you want to keep these instead."
    fi

    log "Cleaning up: removing any packages not listed in $BREWFILE..."
    brew bundle cleanup --file="$TMPDIR/$BREWFILE" --force
    log "Cleanup complete."
fi

###############################################################################
# COMPLETION
###############################################################################

log "Environment restored successfully."
exit 0
