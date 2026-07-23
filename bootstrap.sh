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

# Shell-specific dotfiles to download and apply
declare -A SHELL_FILES
SHELL_FILES[bash]=".bashrc .bash_aliases .bash_environment"
SHELL_FILES[zsh]=".zshrc .zsh_aliases .zprofile"

# Universal dotfiles (applied to all profiles)
UNIVERSAL_FILES=".gitconfig .gitmessage"

# Profile-specific directories (only installed for specified profiles)
declare -A PROFILE_SPECIFIC_DIRS
PROFILE_SPECIFIC_DIRS[profile-developer]=".poshthemes"

###############################################################################
# CONFIGURATION
###############################################################################

TMPDIR="/tmp/brew-bootstrap"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# Cleanup temp directory on exit
trap "rm -rf \"$TMPDIR\"" EXIT

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

# Configure Homebrew PATH in shell configuration files and current session
# This ensures brew is available in both interactive shells and scripts
# Args: $1 - path to brew executable (e.g., /opt/homebrew/bin/brew)
setup_brew_path() {
    local brew_path="$1"
    local shellenv_cmd="eval \"\$($brew_path shellenv bash)\""

    # Add shellenv to interactive shell rc files if they exist
    for rc_file in .bashrc .zshrc; do
        [[ -f "$HOME/$rc_file" ]] && { echo "" >> "$HOME/$rc_file"; echo "$shellenv_cmd" >> "$HOME/$rc_file"; }
    done

    # Add to .profile for non-interactive shells
    echo "$shellenv_cmd" >> "$HOME/.profile"

    # Update PATH in the current session so brew works immediately
    eval "$shellenv_cmd"
}

# Install Homebrew if not already present, then configure PATH
install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log "Homebrew already installed."
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
        sudo dnf install -y bubblewrap || fatal "Failed to install bubblewrap"
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian / Ubuntu
        sudo apt-get update || true
        sudo apt-get install -y build-essential || fatal "Failed to install build-essential"
    else
        fatal "No supported package manager found (tried dnf, apt-get)"
    fi

    if ! command -v gcc >/dev/null 2>&1; then
        fatal "GCC still not available after installing build tools"
    fi
}

# Download all dotfiles for the selected profile and OS
# Args: $1 - profile name (e.g., profile-developer), $2 - OS directory name (macos/ubuntu/fedora)
download_dotfiles() {
    local profile="$1"
    local os_dir="$2"
    local dotfiles_dir="$TMPDIR/dotfiles-$os_dir-$profile"

    log "Downloading dotfiles for $os_dir/$profile"
    mkdir -p "$dotfiles_dir"

    local shell_type="${SHELL##*/}"
    for file in ${SHELL_FILES[$shell_type]}; do
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

    if [[ -v PROFILE_SPECIFIC_DIRS[$profile] ]]; then
        for dir in ${PROFILE_SPECIFIC_DIRS[$profile]}; do
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
        [[ -d "$dest" ]] && mv "$dest" "${dest}.bak" || cp "$dest" "${dest}.bak"
    fi

    log "Installing $item_type $(basename "$src")"
    [[ "$item_type" == "directory" ]] && mkdir -p "$(dirname "$dest")" || true
    [[ "$item_type" == "directory" ]] && cp -r "$src" "$dest" || cp "$src" "$dest"
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

    for file in ${SHELL_FILES[$shell_type]}; do
        apply_item "$profile_dir/$file" "$HOME/$file"
    done

    for file in $UNIVERSAL_FILES; do
        apply_item "$profile_dir/$file" "$HOME/$file"
    done

    if [[ -v PROFILE_SPECIFIC_DIRS[$profile] ]]; then
        for dir in ${PROFILE_SPECIFIC_DIRS[$profile]}; do
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
    # Detect specific Linux distro to select the right dotfiles directory
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            fedora) OS_DOTFILES_DIR="fedora" ;;
            *)      OS_DOTFILES_DIR="ubuntu" ;;
        esac
    else
        OS_DOTFILES_DIR="ubuntu"
    fi
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

log "Installing packages from $BREWFILE..."
brew bundle --file="$TMPDIR/$BREWFILE" || fatal "brew bundle failed"

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

if [[ "$TOTAL_PKGS" -eq 0 ]]; then
    log "No packages installed; cleanup unnecessary."
else
    echo ""
    echo "Homebrew currently has $TOTAL_PKGS installed package(s)."
    echo "Cleanup will remove packages NOT listed in $BREWFILE."
    echo ""
    read -rp "Proceed with cleanup? (y/n): " yn < /dev/tty
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        log "Performing cleanup..."
        brew bundle cleanup --file="$TMPDIR/$BREWFILE" --force
        log "Cleanup complete."
    else
        log "Cleanup skipped."
    fi
fi

###############################################################################
# COMPLETION
###############################################################################

log "Environment restored successfully."
exit 0
