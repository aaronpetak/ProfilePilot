#!/usr/bin/env bash
# Nothing runs at load time except defining functions and defaults, so the file
# can be sourced (by the tests) without side effects. main() at the bottom does
# the work, and enables strict mode itself so sourcing does not leak it.

# The path this script was loaded from. Empty when piped (curl | bash), which
# means "not a checkout": the tarball is used instead. Captured here, with a
# default, because BASH_SOURCE[0] is unset-sensitive under set -u.
BOOTSTRAP_SCRIPT="${BASH_SOURCE[0]:-}"

###############################################################################
# ENVIRONMENT VARIABLES - USER CUSTOMIZABLE
###############################################################################

# Repository source. When this script is run from a ProfilePilot checkout it
# installs from that checkout. Otherwise (e.g. piped from curl) it downloads ONE
# tarball of $DOTFILES_REF from $DOTFILES_REPO_SLUG, so every file comes from the
# same snapshot. Set DOTFILES_REPO_SLUG to use a fork, DOTFILES_REF (branch, tag
# or commit) to pin a version. A private repository also needs a token: see
# fetch_source_tarball and github_token (GH_TOKEN or GITHUB_TOKEN).
DOTFILES_REPO_SLUG="${DOTFILES_REPO_SLUG:-aaronpetak/ProfilePilot}"
DOTFILES_REF="${DOTFILES_REF:-main}"
DOTFILES_TARBALL_URL="https://codeload.github.com/$DOTFILES_REPO_SLUG/tar.gz/$DOTFILES_REF"
# The same snapshot through the GitHub API, which accepts a token. Used only
# after the anonymous download above gets a 404, as it does for a private repo.
DOTFILES_API_TARBALL_URL="https://api.github.com/repos/$DOTFILES_REPO_SLUG/tarball/$DOTFILES_REF"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# Shell-specific base dotfiles, shared by every profile (they live directly under
# <os>/). Aliases live in the universal .shell_aliases file (sourced by both
# shells), so they are NOT listed here. The developer profile adds one extra
# file, see shell_addon_name_for.
#
# NOTE: These lookups are implemented as functions (not associative arrays,
# i.e. `declare -A`) because this script must run on macOS's stock /bin/bash
# (3.2, the last GPLv2 release) before Homebrew's newer bash is available.
# Associative arrays and `[[ -v arr[key] ]]` both require bash 4+.
shell_files_for() {
    case "$1" in
        bash) echo ".bashrc" ;;
        zsh)  echo ".zshrc .zprofile" ;;
        *)    ;;  # unknown shell: no shell-specific files (defensive; see shell_for_os)
    esac
}

# Name of the developer add-on file for a shell. The base rc sources it last if
# it exists. Printed regardless of profile, so a minimal run can recognise a
# stale add-on left by an earlier developer run.
shell_addon_name_for() {
    case "$1" in
        bash) echo ".bashrc.developer" ;;
        zsh)  echo ".zshrc.developer" ;;
        *)    ;;
    esac
}

# The add-on file the given profile installs for a shell (nothing for minimal).
# It lives in <os>/<profile>/. Args: $1 profile, $2 shell.
shell_addon_for() {
    case "$1" in
        profile-developer) shell_addon_name_for "$2" ;;
    esac
}

# The shell whose dotfiles a given OS ships. The repo is organized one shell per
# OS (macos/ has only .zshrc/.zprofile, linux/ has only .bashrc),
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

# Private scratch directory, created by prepare_workspace.
WORKDIR=""

# Single timestamp for this run, reused for every dotfile backup so that all
# of a run's backups share one suffix (e.g. .zshrc.bak.20260728-145900) and a
# re-run never overwrites a previous run's backup.
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# End-of-run status. Each major step records its outcome here so the final
# summary reflects what actually happened. Package failures are a real failure
# (the install step deliberately continues past them instead of aborting), so
# they flip the exit code;
# kept dotfiles and un-personalized gitconfig are legitimate, non-error states
# that are reported but do not fail the run. Values are set at each step's
# decision point; "unknown" means the step did not run.
STATUS_PACKAGES="unknown"   # ok | incomplete
STATUS_DOTFILES="unknown"   # applied | kept | not-found
STATUS_GITCONFIG="unknown"  # personalized | already | incomplete | absent
STATUS_CLEANUP="unknown"    # none | kept | removed | failed | unreadable

# The brew executable whose shellenv this run had to add to its own PATH (set by
# setup_brew_path). Non-empty means the shell that started the run cannot run
# brew yet, so the summary says how to fix that.
BREW_ADDED_TO_PATH=""

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
# user installed separately are never uninstalled unattended. SKIP_CLEANUP=1 is
# also accepted and treated as skip.
CLEANUP="${CLEANUP:-}"

# Log file path, set by init_logging. Empty means log to stdout only.
LOGFILE=""

# Set once by detect_os before anything uses them.
OS_TYPE=""
OS_DOTFILES_DIR=""

# Chosen Brewfile name and its full path (set by select_profile / resolve_source)
# and the directory the dotfiles and Brewfiles are read from.
BREWFILE=""
BREWFILE_PATH=""
SOURCE_DIR=""

###############################################################################
# FUNCTIONS
###############################################################################

# Log a message with timestamp to both stdout and logfile
log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "$LOGFILE" ]]; then
        echo "$line" | tee -a "$LOGFILE"
    else
        echo "$line"
    fi
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

# Restore sane terminal settings. Some subprocesses -- notably `brew bundle`'s
# parallel installers drawing progress spinners -- can leave the controlling
# terminal mangled if a job dies mid-draw: output "staircases" because ONLCR is
# disabled, and later prompts stop echoing keystrokes (ECHO/ICANON disabled) so
# the user cannot type an answer. Reset to a known-good state. Guarded so it is a
# no-op when there is no controlling terminal, and `|| true` so a failure under
# `set -e` can never abort the run.
reset_tty() {
    tty_available || return 0
    stty sane < /dev/tty 2>/dev/null || true
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

# Refuse to run as root. Homebrew hard-refuses to install as root ("Don't run
# this as root!") and offers no override, so a root shell can never complete
# provisioning. Catch it up front -- before we install distro packages or touch
# anything -- with actionable guidance, rather than failing deep inside the
# Homebrew installer. Elevation for the distro package steps is handled by
# run_as_root (sudo), so the script only ever needs to be a normal sudo user.
require_non_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        fatal "Do not run this as root: Homebrew cannot be installed as root. Re-run as a normal user with sudo access (e.g. 'useradd -m -G wheel dev && passwd dev', then run this as that user)."
    fi
}

# Run a command with root privileges. The script itself always runs as a
# non-root user (enforced by require_non_root), so this prepends sudo; if sudo
# is missing we fail with a clear reason rather than a bare "sudo: command not
# found" from deep in a package-manager call. Resolved once and cached.
SUDO_RESOLVED=""
run_as_root() {
    if [[ -z "$SUDO_RESOLVED" ]]; then
        command -v sudo >/dev/null 2>&1 ||
            fatal "This step needs root, but sudo is not installed. Install sudo and re-run."
        SUDO_RESOLVED="yes"
    fi
    sudo "$@"
}

# Lowercase the argument. The explicit [:upper:] / [:lower:] classes follow the
# locale, unlike the A-Z / a-z ranges. Prints no trailing newline.
# Args: $1 - text
to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Show a menu on the terminal and read one answer from it. Every menu prompt
# goes through here. Callers must have checked tty_available first.
# Prints the answer lowercased (empty if the user just pressed enter).
# Args: $1 - the read prompt, $2... - menu lines printed before the prompt
ask_choice() {
    local prompt="$1" line answer
    shift
    if [[ $# -gt 0 ]]; then
        for line in "$@"; do
            printf '%s\n' "$line"
        done > /dev/tty
    fi
    read -rp "$prompt" answer < /dev/tty
    to_lower "${answer:-}"
}

# Read one line from the terminal without echoing it, for secrets. Unlike
# ask_choice the answer keeps its case. Callers must have checked tty_available.
# Prints the answer (empty if the user just pressed enter or input ended).
# Args: $1 - the read prompt
ask_secret() {
    local answer=""
    read -rsp "$1" answer < /dev/tty || answer=""
    echo >&2
    printf '%s' "$answer"
}

# The distro's package manager: dnf, apt-get, pacman or zypper, in that order.
# Fatal when none is found. Cached in PKG_MANAGER; call it directly (not in a
# command substitution) so the cache persists, and use $PKG_MANAGER afterwards.
PKG_MANAGER=""
detect_pkg_manager() {
    if [[ -z "$PKG_MANAGER" ]]; then
        local pm
        for pm in dnf apt-get pacman zypper; do
            if command -v "$pm" >/dev/null 2>&1; then
                PKG_MANAGER="$pm"
                break
            fi
        done
        [[ -n "$PKG_MANAGER" ]] ||
            fatal "No supported package manager found (tried dnf, apt-get, pacman, zypper)" >&2
    fi
    echo "$PKG_MANAGER"
}

# Install packages with the detected package manager. Returns the install's
# status so callers decide what a failure means. apt-get update runs once per
# run, before the first apt install.
# Args: package names
APT_UPDATED=""
pkg_install() {
    detect_pkg_manager >/dev/null
    case "$PKG_MANAGER" in
        dnf)
            run_as_root dnf install -y "$@"
            ;;
        apt-get)
            if [[ -z "$APT_UPDATED" ]]; then
                run_as_root apt-get update || true
                APT_UPDATED="yes"
            fi
            run_as_root apt-get install -y "$@"
            ;;
        pacman)
            # -Syu refreshes the sync databases (empty on a fresh Arch/Manjaro
            # system, where a bare -S fails "target not found") and upgrades in
            # the same transaction, since Arch does not support partial
            # upgrades. --needed skips packages already present.
            run_as_root pacman -Syu --needed --noconfirm "$@"
            ;;
        zypper)
            run_as_root zypper refresh || true
            run_as_root zypper install -y "$@"
            ;;
    esac
}

# Append a line to a shell startup file unless it is already there. Guarding on
# content (not on a marker) keeps repeated bootstrap runs from stacking
# duplicate lines. Creates the file if absent.
# Args: $1 - file, $2 - line
append_line_once() {
    local file="$1" line="$2"
    if ! grep -qsF "$line" "$file"; then
        echo "$line" >> "$file"
    fi
}

# Configure Homebrew PATH for the current session.
# .bashrc/.zshrc are overwritten by apply_dotfiles, which already contains the
# shellenv detection; on Linux we also write to the login-shell startup files
# here for non-interactive shells and to keep brew available throughout the
# rest of this script. macOS needs no ~/.profile entry: zsh reads ~/.zprofile,
# which ensure_zprofile_brew handles after the dotfiles are applied.
# Args: $1 - path to brew executable (e.g., /opt/homebrew/bin/brew)
setup_brew_path() {
    local brew_path="$1"
    local shellenv_cmd="eval \"\$($brew_path shellenv bash)\""

    if [[ "$OS_TYPE" != "macos" ]]; then
        append_line_once "$HOME/.profile" "$shellenv_cmd"

        # A bash login shell reads ~/.bash_profile *instead of* ~/.profile
        # whenever the former exists -- and on RHEL-family systems
        # (RHEL/Rocky/Alma/Fedora) ~/.bash_profile is created by default.
        # Writing only to ~/.profile there means the shellenv line never runs on
        # an SSH login and brew is missing from PATH. Mirror the line into
        # ~/.bash_profile when it exists.
        if [[ -f "$HOME/.bash_profile" ]]; then
            append_line_once "$HOME/.bash_profile" "$shellenv_cmd"
        fi
    fi

    # Update PATH in the current session so brew works immediately. Only this
    # process sees it; the caller's shell does not (see print_summary).
    eval "$shellenv_cmd"
    BREW_ADDED_TO_PATH="$brew_path"
}

# macOS: make sure ~/.zprofile evaluates brew shellenv. The profile's
# .zprofile does this, but it may not have been applied (the user kept their own
# file), in which case a login zsh would have no brew on PATH. Append a zsh
# shellenv line only when the file has no shellenv at all.
# Args: $1 - path to brew executable
ensure_zprofile_brew() {
    local brew_path="$1" zprofile="$HOME/.zprofile"
    if grep -qs 'shellenv' "$zprofile"; then
        return 0
    fi
    log "Adding Homebrew shellenv to ~/.zprofile."
    append_line_once "$zprofile" "eval \"\$($brew_path shellenv zsh)\""
}

# Warn about shellenv lines in ~/.profile and ~/.bash_profile that point at a
# brew which does not exist (e.g. written for a different prefix). They fail
# with "No such file" at every login; we only report them, never edit the
# user's startup files.
warn_stale_brew_lines() {
    local file brew_path
    for file in "$HOME/.profile" "$HOME/.bash_profile"; do
        [[ -f "$file" ]] || continue
        while IFS= read -r brew_path; do
            [[ -n "$brew_path" && ! -x "$brew_path" ]] || continue
            log "Warning: $file runs $brew_path shellenv, but that brew does not exist. Remove or fix that line."
        done < <(sed -n 's/^eval "\$(\(.*\) shellenv[^)]*)"$/\1/p' "$file")
    done
    return 0
}

# Homebrew's possible install prefixes, one per line, in detection order:
# Apple Silicon, Intel macOS / legacy, the Linux default, and a per-user Linux
# install.
brew_prefix_candidates() {
    echo "/opt/homebrew"
    echo "/usr/local"
    echo "/home/linuxbrew/.linuxbrew"
    echo "$HOME/.linuxbrew"
}

# Print the first candidate prefix that contains an executable bin/brew.
# Returns 1 (printing nothing) when Homebrew is not installed anywhere known.
find_brew_prefix() {
    local prefix
    while IFS= read -r prefix; do
        if [[ -x "$prefix/bin/brew" ]]; then
            echo "$prefix"
            return 0
        fi
    done < <(brew_prefix_candidates)
    return 1
}

# Install Homebrew if not already present, then configure PATH
install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log "Homebrew already installed."
        return
    fi

    # Brew may be installed but not yet in PATH (e.g. re-run after a partial install).
    # Skip the installer and just wire up the PATH.
    local prefix
    if prefix=$(find_brew_prefix); then
        log "Homebrew already installed, configuring PATH..."
        setup_brew_path "$prefix/bin/brew"
        return
    fi

    # Homebrew's own installer shells out to git/curl/tar/gzip to fetch and
    # unpack its portable Ruby. Minimal Linux images (notably SUSE) may ship
    # without tar/gzip, so ensure them before running the installer -- otherwise
    # it fails with "tar: command not found" before our build-tools step runs.
    if [[ "$OS_TYPE" == "linux" ]]; then
        ensure_linux_packages git curl tar gzip
    fi

    # Download the installer to a file first. `/bin/bash -c "$(curl ...)"` exits
    # 0 when curl fails (the substitution is empty), so a failed download would
    # look like a successful install.
    log "Installing Homebrew..."
    local installer="$WORKDIR/homebrew-install.sh"
    curl -fsSL "$HOMEBREW_INSTALL_URL" -o "$installer" ||
        fatal "Failed to download the Homebrew installer from $HOMEBREW_INSTALL_URL"
    /bin/bash "$installer" ||
        fatal "The Homebrew installer failed."

    # Never wire shellenv for a brew that is not there.
    prefix=$(find_brew_prefix) ||
        fatal "Homebrew installer finished but no brew executable was found under any known prefix."
    setup_brew_path "$prefix/bin/brew"
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
    # sandbox dependency and is ensured here too; its command is bwrap, hence
    # the package:command form.
    #
    # An awk (any implementation; the package is gawk, but the command checked
    # is awk, since busybox-gawk on openSUSE provides awk and conflicts with
    # gawk) is used by Homebrew's ca-certificates formula in its post-install
    # step to locate the system CA bundle and link openssl's
    # cert.pem. Minimal Fedora images ship without awk; when it is absent that
    # post-install silently fails, leaving a broken cert.pem that makes every
    # TLS-using Homebrew tool (brew update, brew's curl/git, tflint download)
    # fail with "unable to get local issuer certificate". Ensure it up front.
    #
    # diffutils provides cmp and diff, which items_identical uses to compare
    # existing dotfiles with the source before apply_dotfiles runs. Minimal
    # images (Rocky 8) lack it, which makes every existing file look different.
    ensure_linux_packages unzip bubblewrap:bwrap gawk:awk diffutils:cmp

    if command -v gcc >/dev/null 2>&1; then
        log "Build tools already installed."
        return
    fi

    log "Installing build tools for Linux..."

    detect_pkg_manager >/dev/null
    case "$PKG_MANAGER" in
        dnf)
            # Fedora / RHEL / CentOS Stream. Try the group first; fall back to
            # explicit packages if the group name differs across versions.
            run_as_root dnf group install -y development-tools 2>/dev/null ||
                pkg_install gcc gcc-c++ make || fatal "Failed to install build tools via dnf"
            ;;
        apt-get)
            # Debian / Ubuntu
            pkg_install build-essential || fatal "Failed to install build-essential"
            ;;
        pacman)
            # Arch / Manjaro. base-devel is a package group; a failure is fatal.
            pkg_install base-devel || fatal "Failed to install base-devel via pacman"
            ;;
        zypper)
            # openSUSE. The "devel_basis" pattern is the build-tool bundle.
            run_as_root zypper install -y -t pattern devel_basis 2>/dev/null ||
                pkg_install gcc gcc-c++ make || fatal "Failed to install build tools via zypper"
            ;;
    esac

    if ! command -v gcc >/dev/null 2>&1; then
        fatal "GCC still not available after installing build tools"
    fi
}

# Print, one per line, the package names from the arguments whose command is not
# on PATH. Each argument is either "package" (the command has the same name) or
# "package:command" for packages that ship a differently named command, e.g.
# bubblewrap:bwrap. Uses parameter expansion (bash 3.2 safe).
missing_linux_packages() {
    local item pkg cmd
    for item in "$@"; do
        pkg="${item%%:*}"
        cmd="${item#*:}"   # equals the whole item when there is no colon
        command -v "$cmd" >/dev/null 2>&1 || echo "$pkg"
    done
}

# Ensure one or more packages are installed on Linux via the distro package
# manager. Skips any package whose command is already available.
# Args: "package" or "package:command" items (see missing_linux_packages)
ensure_linux_packages() {
    local missing=() pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && missing+=("$pkg")
    done < <(missing_linux_packages "$@")

    [[ ${#missing[@]} -eq 0 ]] && return

    log "Installing Linux packages: ${missing[*]}"
    pkg_install "${missing[@]}" || fatal "Failed to install: ${missing[*]}"
}

# Repair a ca-certificates install whose post-install step failed because awk
# was missing (common on minimal Fedora images). The symptom is a broken
# openssl cert.pem symlink, which makes every TLS operation through Homebrew's
# openssl -- brew update, brew's bundled curl/git, the tflint download, and the
# dotfile downloads -- fail with "unable to get local issuer certificate".
#
# On a fresh run install_build_tools has just ensured gawk, so re-running the
# post-install now succeeds. This makes an already-broken machine self-heal on
# the next run instead of requiring the user to reinstall from scratch.
repair_ca_certificates() {
    [[ "$OS_TYPE" == "linux" ]] || return 0
    command -v brew >/dev/null 2>&1 || return 0

    # Only act if openssl@3 is installed but its cert.pem is a broken symlink.
    local prefix
    prefix=$(brew --prefix 2>/dev/null) || return 0
    local cert_pem="$prefix/etc/openssl@3/cert.pem"
    brew list ca-certificates >/dev/null 2>&1 || return 0
    if [[ -e "$cert_pem" ]]; then
        return 0
    fi

    log "Repairing ca-certificates (its post-install failed, leaving a broken CA bundle)..."
    brew postinstall ca-certificates 2>/dev/null ||
        log "Note: brew postinstall ca-certificates did not complete; TLS through Homebrew may still fail."
}

# Verify one downloaded release file against a sha256 checksums file, using the
# line "<sha256>  <file>" for that exact filename. Linux-only (sha256sum).
# This protects against a corrupted or tampered download or mirror; it does not
# protect against a compromised upstream release, because the checksums are
# published alongside the artifacts.
# Args: $1 - directory holding both files, $2 - the file to verify,
#       $3 - checksums file name (default checksums.txt)
verify_release_checksum() {
    local dir="$1" file="$2" sums="${3:-checksums.txt}"
    (
        cd "$dir" || exit 1
        grep " $file\$" "$sums" 2>/dev/null | sha256sum -c - >/dev/null 2>&1
    )
}

# Print the release tag the GitHub "latest" redirect points at, e.g. v0.65.0.
# The redirect target ends in /releases/tag/<tag>. Resolving the tag once keeps
# the zip and checksums.txt from the same release even if a new one is published
# mid-run. Returns 1 when no tag can be resolved.
# Args: $1 - repository slug (e.g. terraform-linters/tflint)
resolve_latest_release_tag() {
    local url tag
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest") || return 1
    tag="${url##*/}"
    case "$url" in
        */releases/tag/?*) echo "$tag" ;;
        *) return 1 ;;
    esac
}

# Install tflint on Linux.
# tflint is only published as a macOS cask in terraform-linters/tap, so on
# Linux it cannot be installed via Homebrew. We download the official release
# zip directly from GitHub and verify it against the release's checksums.txt
# before dropping the binary into the Homebrew bin dir, which is already on
# PATH. We intentionally do NOT pipe the upstream install_linux.sh into bash:
# it is unpinned and its maintainers have announced its removal.
# Any failure is logged, skips the install, and marks the package step
# incomplete so the end-of-run summary and exit status report it.
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

    local prefix dest_dir
    prefix=$(find_brew_prefix) || { log "Note: could not determine the Homebrew prefix; skipping tflint."; STATUS_PACKAGES="incomplete"; return; }
    dest_dir="$prefix/bin"

    local tag
    tag=$(resolve_latest_release_tag "terraform-linters/tflint") || {
        log "Note: could not resolve the latest tflint release; skipping tflint."
        STATUS_PACKAGES="incomplete"
        return
    }

    local zip_name="tflint_linux_${arch}.zip"
    local base_url="https://github.com/terraform-linters/tflint/releases/download/$tag"
    local dl_dir="$WORKDIR/tflint-dl"
    mkdir -p "$dl_dir"

    log "Installing tflint $tag (linux_${arch}) from GitHub releases..."
    if ! curl -fsSL -o "$dl_dir/$zip_name" "$base_url/$zip_name" ||
       ! curl -fsSL -o "$dl_dir/checksums.txt" "$base_url/checksums.txt"; then
        log "Note: failed to download tflint $tag or its checksums from $base_url; skipping tflint."
        STATUS_PACKAGES="incomplete"
        return
    fi

    if ! verify_release_checksum "$dl_dir" "$zip_name"; then
        log "Note: tflint checksum verification failed for $zip_name; not installing it."
        STATUS_PACKAGES="incomplete"
        return
    fi

    if ! unzip -o -q "$dl_dir/$zip_name" -d "$WORKDIR/tflint"; then
        log "Note: failed to unzip tflint; skipping tflint."
        STATUS_PACKAGES="incomplete"
        return
    fi
    if ! install -m 0755 "$WORKDIR/tflint/tflint" "$dest_dir/tflint"; then
        log "Note: failed to install the tflint binary; skipping tflint."
        STATUS_PACKAGES="incomplete"
        return
    fi
    log "tflint $tag installed to $dest_dir/tflint"
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

            # Offer to hand the command to Homebrew now. `--overwrite`
            # replaces the foreign file, so we ask first and never do it
            # unattended (no TTY -> just print the manual steps below).
            linked=""
            if tty_available; then
                ans=$(ask_choice "Overwrite? [y/N]: " \
                    "" \
                    "Make Homebrew's '$formula' the active command by overwriting $conflict_path?" \
                    "  [y] Yes - run: brew link --overwrite $formula" \
                    "  [N] No  - leave it as-is and print the manual steps")
                if [[ "$ans" == "y" ]]; then
                    if brew link --overwrite "$formula" >/dev/null 2>&1; then
                        linked=1
                        log "  Linked Homebrew's '$formula' (ran: brew link --overwrite $formula)."
                        [[ -n "$npm_pkg" ]] && log "  The npm copy is now an unused duplicate; remove it if you like: npm rm -g $npm_pkg"
                    else
                        log "  'brew link --overwrite $formula' did not succeed; see the manual steps below."
                    fi
                fi
            fi

            # If we didn't (or couldn't) link, print the paired manual fix.
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
        # Third-party tap trust (Homebrew 6.0.0+) is declared per tap in the
        # Brewfile (trusted: true), so the tap-trust check stays enabled.
        #
        # HOMEBREW_DOWNLOAD_CONCURRENCY=1 forces serial downloads (default is
        # auto = 2x CPU cores). Parallel downloads draw multiple live progress
        # spinners at once, which interleave into staircased/cascading output on
        # some terminals, and race on shared cache temp files (a "go process
        # has already locked" cellar race, an ".incomplete manifest" rmdir
        # race). Serializing trades a little download speed for readable output
        # and far fewer transient failures. HOMEBREW_NO_EMOJI drops the success badge that is
        # part of the same spinner drawing.
        if HOMEBREW_DOWNLOAD_CONCURRENCY=1 \
            HOMEBREW_NO_EMOJI=1 \
            brew bundle --file="$brewfile" 2>&1; then
            # brew bundle's progress spinners can leave the terminal mangled
            # (staircased output, no keystroke echo at later prompts) if a job
            # dies mid-draw. Restore it before we move on to interactive prompts.
            reset_tty
            log "All Brewfile dependencies installed successfully."
            STATUS_PACKAGES="ok"
            return 0
        fi

        reset_tty
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
        STATUS_PACKAGES="ok"
    else
        STATUS_PACKAGES="incomplete"
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

# Print the checkout directory when this script sits inside a ProfilePilot
# clone (its directory contains universal/brewfiles); return 1 otherwise.
# Args: $1 - the script path, i.e. ${BASH_SOURCE[0]:-}. It is empty when the
# script is piped (curl | bash, bash < file) and a /dev/fd path for bash <(...);
# neither is a checkout, so both fall through to the tarball.
local_checkout_dir() {
    local src="${1:-}" dir
    [[ -n "$src" ]] || return 1
    dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || return 1
    [[ -d "$dir/universal/brewfiles" ]] || return 1
    echo "$dir"
}

# Unpack a ProfilePilot tarball into a directory and check it looks right. The
# top-level directory name inside the archive is deliberately never computed:
# --strip-components=1 drops it, then a sentinel file proves the layout.
# Args: $1 - tarball path, $2 - destination directory
unpack_source_tarball() {
    local tarball="$1" dest="$2"
    mkdir -p "$dest"
    tar -xzf "$tarball" -C "$dest" --strip-components=1 ||
        fatal "Failed to extract the ProfilePilot tarball."
    [[ -f "$dest/universal/brewfiles/Brewfile-minimal" ]] ||
        fatal "The downloaded archive does not look like ProfilePilot (universal/brewfiles/Brewfile-minimal is missing). Check DOTFILES_REPO_SLUG and DOTFILES_REF."
}

# Print a GitHub token for downloading a private repository. Sources, in order:
# GH_TOKEN, GITHUB_TOKEN, `gh auth token` (when the GitHub CLI is installed and
# logged in), then a hidden prompt when a terminal is available. Returns 1 when
# none of them gives a token.
github_token() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null)" || token=""
    fi
    if [[ -z "$token" ]] && tty_available; then
        reset_tty
        token="$(ask_secret "  GitHub token that can read $DOTFILES_REPO_SLUG (input hidden, Enter to skip): ")"
    fi
    [[ -n "$token" ]] || return 1
    printf '%s\n' "$token"
}

# Run curl with a GitHub token in an Authorization header. The header goes in on
# stdin (-H @-) rather than as an argument, so the token never shows up in a
# process listing. curl does not resend a custom Authorization header when it
# follows a redirect to another host; GitHub's redirect to codeload carries its
# own short-lived token instead.
# Args: $1 - token, then the curl arguments
curl_with_token() {
    local token="$1"
    shift
    printf 'Authorization: Bearer %s\n' "$token" | curl -H @- "$@"
}

# Download the single pinned tarball and unpack it. The first request is
# anonymous, so a public repository never needs a token. GitHub answers 404 to an
# anonymous request for a private repository, so a 404 (and only a 404) is
# retried once through the API with a token from github_token.
# Args: $1 - destination directory
fetch_source_tarball() {
    local dest="$1" tarball="$WORKDIR/source.tar.gz" err="$WORKDIR/download.err" code token
    log "Downloading ProfilePilot ($DOTFILES_REPO_SLUG @ $DOTFILES_REF)..."
    code="$(curl -sSL -w '%{http_code}' -o "$tarball" "$DOTFILES_TARBALL_URL" 2>"$err")" ||
        fatal "Failed to download $DOTFILES_TARBALL_URL: $(cat "$err" 2>/dev/null)"
    case "$code" in
        200) ;;
        404)
            log "No anonymous access to $DOTFILES_REPO_SLUG @ $DOTFILES_REF (HTTP 404). The repository may be private; retrying with a GitHub token."
            token="$(github_token)" ||
                fatal "Failed to download $DOTFILES_TARBALL_URL (HTTP 404). If $DOTFILES_REPO_SLUG is private, set GH_TOKEN to a GitHub token that can read it; otherwise check DOTFILES_REPO_SLUG and DOTFILES_REF."
            curl_with_token "$token" -fsSL -o "$tarball" "$DOTFILES_API_TARBALL_URL" ||
                fatal "Failed to download $DOTFILES_REPO_SLUG @ $DOTFILES_REF with the GitHub token. Check that the token can read the repository and that the ref exists."
            log "Downloaded with a GitHub token."
            ;;
        *)
            fatal "Failed to download $DOTFILES_TARBALL_URL (HTTP $code)."
            ;;
    esac
    unpack_source_tarball "$tarball" "$dest"
}

# Copy the dotfiles for the selected profile and OS from the source tree into a
# staging directory laid out the way apply_dotfiles expects. Files and
# directories absent from the source are skipped.
# Args: $1 - profile name (e.g., profile-developer), $2 - OS directory name (macos/linux)
stage_dotfiles() {
    local profile="$1"
    local os_dir="$2"
    local dotfiles_dir="$WORKDIR/dotfiles-$os_dir-$profile"
    local file dir

    log "Staging dotfiles for $os_dir/$profile"
    mkdir -p "$dotfiles_dir"

    local shell_type
    shell_type="$(shell_for_os "$OS_TYPE")"
    for file in $(shell_files_for "$shell_type"); do
        if [[ -f "$SOURCE_DIR/$os_dir/$file" ]]; then
            cp "$SOURCE_DIR/$os_dir/$file" "$dotfiles_dir/$file"
        else
            log "Note: $file not present in $os_dir (optional)"
        fi
    done

    for file in $(shell_addon_for "$profile" "$shell_type"); do
        if [[ -f "$SOURCE_DIR/$os_dir/$profile/$file" ]]; then
            cp "$SOURCE_DIR/$os_dir/$profile/$file" "$dotfiles_dir/$file"
        else
            log "Note: $file not present in $os_dir/$profile (optional)"
        fi
    done

    for file in $UNIVERSAL_FILES; do
        if [[ -f "$SOURCE_DIR/universal/$file" ]]; then
            cp "$SOURCE_DIR/universal/$file" "$dotfiles_dir/$file"
        else
            log "Note: $file not present in universal (optional)"
        fi
    done

    local profile_dirs
    profile_dirs="$(profile_specific_dirs_for "$profile")"
    if [[ -n "$profile_dirs" ]]; then
        for dir in $profile_dirs; do
            if [[ -d "$SOURCE_DIR/universal/$dir" ]]; then
                cp -R "$SOURCE_DIR/universal/$dir" "$dotfiles_dir/$dir"
            else
                log "Note: $dir not present in universal (optional)"
            fi
        done
    fi

    log "ProfilePilot profile staged successfully"
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

    # Defensively restore the terminal in case an earlier subprocess left it in
    # a state where keystrokes are not echoed, which would make this prompt
    # appear frozen.
    reset_tty

    local choice
    choice=$(ask_choice "Choose [O/S/D]: " \
        "" \
        "How should the differing files above be handled?" \
        "  [O] Overwrite all - install the profile versions (originals backed up as <name>.bak.$RUN_TS)" \
        "  [S] Skip all      - keep your existing files, install none of these" \
        "  [D] Decide per file")
    case "$choice" in
        o) CONFLICT_MODE="overwrite" ;;
        d) CONFLICT_MODE="perfile" ;;
        s) CONFLICT_MODE="skip" ;;
        *) log "Unrecognized choice '$choice'; keeping existing files."; CONFLICT_MODE="skip" ;;
    esac
}

# Interactively resolve one conflicting item: overwrite, skip, or view a diff
# (then re-ask). Assumes a readable /dev/tty (only called in perfile mode).
# Args: $1 - source, $2 - destination.
resolve_one() {
    local src="$1" dest="$2" ans
    while true; do
        ans=$(ask_choice "$(basename "$dest"): [o]verwrite / [s]kip / [d]iff? ")
        case "$ans" in
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

# Retire a stale developer add-on by moving it aside to <name>.bak.<RUN_TS>.
# Args: $1 - add-on file name (relative to $HOME).
retire_stale_addon() {
    local name="$1" backup="$HOME/$1.bak.$RUN_TS"
    log "Retiring stale developer add-on $name (moved to $name.bak.$RUN_TS)."
    mv "$HOME/$name" "$backup"
}

# Ask whether to keep or retire a stale add-on. Assumes a readable /dev/tty
# (only called in perfile mode). Args: $1 - add-on file name.
resolve_stale_addon() {
    local name="$1" ans
    while true; do
        ans=$(ask_choice "$name is left over from the developer profile: [k]eep / [r]etire? ")
        case "$ans" in
            r) retire_stale_addon "$name"; return ;;
            k) log "Keeping $name; developer settings remain active."; STATUS_DOTFILES="kept"; return ;;
            *) echo "Please answer k or r." > /dev/tty ;;
        esac
    done
}

# Given the list of conflicting item names (existing files that differ from the
# profile) and any stale add-on to retire, report them, decide a mode, and act.
# Args: $1 - profile dir, $2 - space-separated conflicting item names,
# $3 - stale add-on name (optional).
resolve_conflicts() {
    local profile_dir="$1" conflicts="$2" stale="${3:-}" item

    if [[ -n "$conflicts" ]]; then
        log "These existing files differ from the ProfilePilot profile:"
        for item in $conflicts; do
            log "  $item"
        done
    fi
    if [[ -n "$stale" ]]; then
        log "This profile has no developer add-on, but one exists from an earlier run:"
        log "  $stale"
    fi

    determine_conflict_mode
    case "$CONFLICT_MODE" in
        overwrite)
            log "Overwriting all differing files (originals backed up as .bak.$RUN_TS)."
            for item in $conflicts; do
                backup_and_install "$profile_dir/$item" "$HOME/$item"
            done
            for item in $stale; do
                retire_stale_addon "$item"
            done
            ;;
        skip)
            log "Keeping your existing files; not installing the differing profile files above."
            for item in $stale; do
                log "Keeping $item; developer settings remain active."
            done
            STATUS_DOTFILES="kept"
            ;;
        perfile)
            for item in $conflicts; do
                resolve_one "$profile_dir/$item" "$HOME/$item"
            done
            for item in $stale; do
                resolve_stale_addon "$item"
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
    local profile_dir="$WORKDIR/dotfiles-$os_dir-$profile"

    [[ ! -d "$profile_dir" ]] && { log "Warning: ProfilePilot profile directory not found: $profile_dir"; STATUS_DOTFILES="not-found"; return; }

    log "Applying profile files for $shell_type shell..."

    # Assemble the full list of item names to consider (dotfile names contain no
    # spaces, so a space-separated string is a safe bash 3.2-compatible list).
    local items="" item
    for item in $(shell_files_for "$shell_type"); do items="$items $item"; done
    for item in $(shell_addon_for "$profile" "$shell_type"); do items="$items $item"; done
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
        # A dangling symlink is not -e but is still occupying the path: treat
        # it as an existing item so it is handled as a conflict (backup_and_install
        # moves the link itself), never installed over.
        if [[ ! -e "$dest" && ! -L "$dest" ]]; then
            install_item "$src" "$dest"
        elif items_identical "$src" "$dest"; then
            log "$item already matches the profile; leaving it unchanged."
        else
            conflicts="$conflicts $item"
        fi
    done

    # A profile without an add-on (minimal) must not leave an earlier run's
    # add-on active: the base rc would still source it. Retiring it is resolved
    # together with the other conflicts, under the same mode.
    local stale="" addon
    addon="$(shell_addon_name_for "$shell_type")"
    if [[ -n "$addon" && -z "$(shell_addon_for "$profile" "$shell_type")" && -e "$HOME/$addon" ]]; then
        stale="$addon"
    fi

    # ~/.bashrc does not source ~/.bash_environment; tell users who have one.
    if [[ "$shell_type" == "bash" && -e "$HOME/.bash_environment" ]]; then
        # shellcheck disable=SC2088  # display text, not a path to expand.
        log "Note: ~/.bash_environment is no longer sourced by ~/.bashrc; its settings now live in ~/.bashrc.developer (developer profile). The old file was left in place."
    fi

    # Pass 2: resolve conflicts, if any. resolve_conflicts sets STATUS_DOTFILES
    # to "kept" when the user chose to keep differing files; otherwise this run
    # applied the profile.
    STATUS_DOTFILES="applied"
    if [[ -n "$conflicts" || -n "$stale" ]]; then
        resolve_conflicts "$profile_dir" "$conflicts" "$stale"
    fi

    log "Profile files applied successfully"
}

# Git identity lives in ~/.gitconfig.local, not in ~/.gitconfig.
#
# The shipped .gitconfig has no [user] section; it includes ~/.gitconfig.local
# at the top, so per-directory includeIf identities still override it. Keeping
# the identity in a separate, never-shipped file means re-applying the profile
# can never overwrite it, and no placeholder substitution is needed.

# Placeholder strings that a ~/.gitconfig from an earlier ProfilePilot may hold.
is_identity_placeholder() {
    case "$1" in
        "{FULL NAME}"|"{GITHUB EMAIL}"|"{GITHUB USERNAME}") return 0 ;;
        *) return 1 ;;
    esac
}

# Before the profile is applied (and may replace ~/.gitconfig), carry a real
# identity from the live ~/.gitconfig into ~/.gitconfig.local when the latter
# does not already have one. Placeholder values are never copied.
migrate_gitconfig_identity() {
    local gitconfig="$HOME/.gitconfig" local_cfg="$HOME/.gitconfig.local"
    local key value
    [[ -f "$gitconfig" ]] || return 0
    for key in user.name user.email; do
        value=$(git config --file "$gitconfig" "$key" 2>/dev/null) || value=""
        [[ -n "$value" ]] || continue
        is_identity_placeholder "$value" && continue
        if [[ -z "$(git config --file "$local_cfg" "$key" 2>/dev/null)" ]]; then
            if git config --file "$local_cfg" "$key" "$value"; then
                log "Migrated $key from ~/.gitconfig to ~/.gitconfig.local."
            fi
        fi
    done
    return 0
}

# Confirm git resolves the identity via the global config (which must include
# ~/.gitconfig.local). Sets STATUS_GITCONFIG to $3 on success, else incomplete.
# Args: $1 - expected user.name, $2 - expected user.email, $3 - success status
verify_git_identity() {
    local got_name got_email
    got_name=$(git config --global --includes user.name 2>/dev/null) || got_name=""
    got_email=$(git config --global --includes user.email 2>/dev/null) || got_email=""
    if [[ "$got_name" == "$1" && "$got_email" == "$2" ]]; then
        STATUS_GITCONFIG="$3"
    else
        log "Note: git does not read ~/.gitconfig.local from your ~/.gitconfig (it likely predates the include)."
        log "Add this to the top of ~/.gitconfig: [include] path = ~/.gitconfig.local"
        STATUS_GITCONFIG="incomplete"
    fi
}

# Write the git identity into ~/.gitconfig.local.
#
# Values may be supplied via env (GIT_NAME, GIT_EMAIL) to run unattended; any
# not supplied and not already present are prompted for on a TTY. With no TTY
# and no values we write nothing and print how to fix it. Values containing a
# newline are rejected. After writing, we verify that git actually resolves the
# identity through ~/.gitconfig; if the user kept an older ~/.gitconfig without
# the include, we say so instead of claiming success.
personalize_gitconfig() {
    local gitconfig="$HOME/.gitconfig" local_cfg="$HOME/.gitconfig.local"

    [[ -f "$gitconfig" ]] || { log "Note: ~/.gitconfig not present; skipping git personalization."; STATUS_GITCONFIG="absent"; return; }

    local name="${GIT_NAME:-}" email="${GIT_EMAIL:-}"
    local have_name have_email
    have_name=$(git config --file "$local_cfg" user.name 2>/dev/null) || have_name=""
    have_email=$(git config --file "$local_cfg" user.email 2>/dev/null) || have_email=""

    # An identity already in ~/.gitconfig.local is kept unless env overrides it.
    if [[ -z "$name" && -z "$email" && -n "$have_name" && -n "$have_email" ]]; then
        # shellcheck disable=SC2088  # display text, not a path to expand.
        log "Git identity already set in ~/.gitconfig.local; leaving it unchanged."
        verify_git_identity "$have_name" "$have_email" "already"
        return
    fi

    # Prompt for whatever is still missing, but only if we can read a terminal.
    if tty_available; then
        {
            echo ""
            echo "Personalize your git identity (written to ~/.gitconfig.local):"
        } > /dev/tty
        if [[ -z "$name" && -z "$have_name" ]]; then read -rp "  Full name: " name < /dev/tty; fi
        if [[ -z "$email" && -z "$have_email" ]]; then read -rp "  GitHub email (e.g. you@example.com or the GitHub no-reply address): " email < /dev/tty; fi
    fi

    local nl=$'\n'
    if [[ "$name" == *"$nl"* || "$email" == *"$nl"* ]]; then
        log "Note: git identity values must not contain newlines; not writing ~/.gitconfig.local."
        STATUS_GITCONFIG="incomplete"
        return
    fi

    if [[ -n "$name" ]]; then
        git config --file "$local_cfg" user.name "$name" || { log "Note: could not write user.name to ~/.gitconfig.local."; STATUS_GITCONFIG="incomplete"; return; }
    fi
    if [[ -n "$email" ]]; then
        git config --file "$local_cfg" user.email "$email" || { log "Note: could not write user.email to ~/.gitconfig.local."; STATUS_GITCONFIG="incomplete"; return; }
    fi

    have_name=$(git config --file "$local_cfg" user.name 2>/dev/null) || have_name=""
    have_email=$(git config --file "$local_cfg" user.email 2>/dev/null) || have_email=""

    if [[ -z "$have_name" || -z "$have_email" ]]; then
        log "No complete git identity provided; ~/.gitconfig.local is missing user.name and/or user.email."
        log "Set them later with: git config --file ~/.gitconfig.local user.name '...'; git config --file ~/.gitconfig.local user.email '...'"
        STATUS_GITCONFIG="incomplete"
        return
    fi

    log "Wrote git identity to ~/.gitconfig.local."
    verify_git_identity "$have_name" "$have_email" "personalized"
}

# Resolve how to handle installed packages not listed in the Brewfile into the
# global CLEANUP_MODE (remove|skip). Mirrors the dotfiles conflict handling:
# honors $CLEANUP (remove|skip|prompt), treats $SKIP_CLEANUP=1 as skip, prompts
# on a TTY, and defaults to skip when no TTY is available so a user's own
# packages are never uninstalled unattended.
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

    local choice
    choice=$(ask_choice "Choose [R/K]: " \
        "" \
        "The packages listed above are installed but not part of $BREWFILE." \
        "How should they be handled?" \
        "  [R] Remove them - uninstall the packages above (cannot be undone; Homebrew keeps no backup)" \
        "  [K] Keep them   - leave every installed package in place")
    case "$choice" in
        r) CLEANUP_MODE="remove" ;;
        k) CLEANUP_MODE="skip" ;;
        *) log "Unrecognized choice '$choice'; keeping all packages."; CLEANUP_MODE="skip" ;;
    esac
}

# Print an end-of-run summary reflecting what each step actually did, and return
# a non-zero status if anything genuinely failed. Only unresolved package
# failures count as a failure: the package step deliberately continues past them
# rather than aborting. Kept dotfiles and an un-personalized gitconfig are
# legitimate user/environment states, so they are reported but do not fail the
# run. Returns 0 on success, 1 if packages are incomplete.
print_summary() {
    local rc=0
    log "----- Summary -----"

    case "$STATUS_PACKAGES" in
        ok)         log "  Packages:  all Brewfile dependencies installed." ;;
        incomplete) log "  Packages:  FAILED - some dependencies could not be installed (see log above)."; rc=1 ;;
        *)          log "  Packages:  not attempted." ;;
    esac

    case "$STATUS_DOTFILES" in
        applied)   log "  Dotfiles:  applied." ;;
        kept)      log "  Dotfiles:  kept your existing files; profile versions not installed (set DOTFILES_CONFLICT=overwrite to apply them)." ;;
        not-found) log "  Dotfiles:  profile directory not found; none applied." ;;
        *)         log "  Dotfiles:  not attempted." ;;
    esac

    case "$STATUS_GITCONFIG" in
        personalized) log "  Gitconfig: identity written to ~/.gitconfig.local." ;;
        already)      log "  Gitconfig: identity already in ~/.gitconfig.local; left unchanged." ;;
        incomplete)   log "  Gitconfig: git identity incomplete or not read by ~/.gitconfig; see the notes above (needs user.name/user.email in ~/.gitconfig.local and an include in ~/.gitconfig)." ;;
        absent)       log "  Gitconfig: ~/.gitconfig not present; skipped." ;;
        *)            log "  Gitconfig: not attempted." ;;
    esac

    # Leftover packages do not stop the machine from working, so no cleanup
    # outcome fails the run.
    case "$STATUS_CLEANUP" in
        none)       log "  Cleanup:   nothing to remove." ;;
        kept)       log "  Cleanup:   kept packages not in $BREWFILE (set CLEANUP=remove to uninstall them)." ;;
        removed)    log "  Cleanup:   removed packages not in $BREWFILE." ;;
        failed)     log "  Cleanup:   some removals failed; see the log above." ;;
        unreadable) log "  Cleanup:   skipped; Homebrew's cleanup preview could not be read (see the log above)." ;;
        *)          log "  Cleanup:   not attempted." ;;
    esac

    if [[ "$rc" -eq 0 ]]; then
        log "Environment restored successfully."
    else
        log "Environment restored with errors; see the summary above."
    fi

    # setup_brew_path only changed this process's PATH. The shell that started
    # the run still has no brew until it reads the updated startup files.
    if [[ -n "$BREW_ADDED_TO_PATH" ]]; then
        log "brew is not on this terminal's PATH yet. Open a new terminal, or run:"
        log "  eval \"\$($BREW_ADDED_TO_PATH shellenv)\""
    fi
    return "$rc"
}

# Create the private scratch directory (mode 0700, unique per run) and remove it
# on exit. TMPDIR itself is never assigned: that would redirect every child
# process's temp files. The trap is single-quoted so $WORKDIR expands when it
# fires.
prepare_workspace() {
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
}

# Choose the log file and make sure its directory exists.
init_logging() {
    local logdir
    if [[ "$OSTYPE" == darwin* ]]; then
        logdir="$HOME/Library/Logs"
    else
        logdir="$HOME/.local/state"
    fi
    mkdir -p "$logdir"
    LOGFILE="$logdir/profilepilot.log"
}

# Determine the platform once, setting OS_TYPE and OS_DOTFILES_DIR.
detect_os() {
    if [[ "$OSTYPE" == darwin* ]]; then
        OS_TYPE="macos"
        OS_DOTFILES_DIR="macos"
    elif [[ "$OSTYPE" == linux-musl* ]]; then
        # musl-based distros (Alpine and derivatives) are intentionally out of
        # scope: this whole script is built on Homebrew, and Homebrew on Linux
        # requires glibc. Fail with a clear reason rather than the generic one.
        fatal "Unsupported OS: $OSTYPE. This installer requires a glibc-based Linux (Homebrew does not support musl/Alpine)."
    elif [[ "$OSTYPE" == linux-gnu* || "$OSTYPE" == linux ]]; then
        # Most distros' bash reports OSTYPE=linux-gnu, but some (notably SUSE)
        # report a bare "linux". The musl case is excluded above, so a bare
        # "linux" here is glibc. All glibc Linux distros share one dotfiles set.
        OS_TYPE="linux"
        OS_DOTFILES_DIR="linux"
    else
        fatal "Unsupported OS: $OSTYPE"
    fi
    log "Detected OS: $OS_TYPE ($OS_DOTFILES_DIR)"
}

# Pick the Brewfile, setting BREWFILE. The profile can be preselected with the
# PROFILE env var (developer|minimal), which unattended runs (CI, containers,
# curl|bash with no TTY) need. Otherwise show the menu, but only when a
# controlling terminal is actually available: reading /dev/tty with none present
# would abort the run before the non-interactive knobs (DOTFILES_CONFLICT,
# CLEANUP) could apply. Menu choices map through brewfile_for_profile so the
# valid profiles are defined in one place.
select_profile() {
    local profile choice
    BREWFILE=""
    if [[ -n "${PROFILE:-}" ]]; then
        BREWFILE="$(brewfile_for_profile "$PROFILE")"
        [[ -n "$BREWFILE" ]] || fatal "Invalid PROFILE='$PROFILE' (expected: developer or minimal)."
        log "Profile preselected via PROFILE=$PROFILE"
    elif tty_available; then
        choice=$(ask_choice "Enter 1 or 2: " \
            "" \
            "Select environment profile:" \
            "  1) Developer Workstation" \
            "  2) Minimal Host" \
            "")

        case "$choice" in
            1) profile="developer" ;;
            2) profile="minimal" ;;
            *) fatal "Invalid choice." ;;
        esac
        BREWFILE="$(brewfile_for_profile "$profile")"
    else
        fatal "No profile selected and no interactive terminal available. Set PROFILE=developer or PROFILE=minimal to run unattended."
    fi

    log "Selected Brewfile: $BREWFILE"
}

# Locate the files to install from: the local checkout, or one pinned tarball.
# Sets SOURCE_DIR and BREWFILE_PATH.
resolve_source() {
    if SOURCE_DIR="$(local_checkout_dir "$BOOTSTRAP_SCRIPT")"; then
        log "Installing from local checkout: $SOURCE_DIR"
    else
        # curl, tar and gzip are needed to fetch and unpack the tarball.
        if [[ "$OS_TYPE" == "linux" ]]; then
            ensure_linux_packages curl tar gzip
        fi
        SOURCE_DIR="$WORKDIR/source"
        fetch_source_tarball "$SOURCE_DIR"
    fi

    BREWFILE_PATH="$SOURCE_DIR/universal/brewfiles/$BREWFILE"
    [[ -f "$BREWFILE_PATH" ]] || fatal "Brewfile not found: $BREWFILE_PATH"
}

# True when the Brewfile $1 has a `brew "<name>"` entry for formula $2.
brewfile_lists_formula() {
    grep -Eq "^[[:space:]]*brew[[:space:]]+\"$2\"" "$1"
}

# Finish package moves that an earlier ProfilePilot install left half done,
# before brew bundle runs. brew bundle cannot finish either of them itself:
#
#   tldr -> tlrc: homebrew-core removed the tldr formula, and tlrc installs the
#     same bin/tldr. An old tldr keg still owns that link, so tlrc fails to link
#     on every run and the package step ends FAILED. The old keg is only
#     unlinked, which is reversible; cleanup then lists it like any other
#     package that is not in the Brewfile.
#
#   oh-my-posh: it used to come from the jandedobbeleer/oh-my-posh tap and now
#     comes from homebrew-core. brew bundle accepts the tap's keg because the
#     name matches, so it is never replaced, and the tap's formula is no longer
#     trusted, so it is never upgraded. While that keg is installed, cleanup
#     cannot untap the tap either. The core bottle is downloaded first, so a
#     failed download leaves the working copy in place.
#
# Each move is skipped unless the Brewfile wants the replacement. A failure is
# logged and the run continues; brew bundle reports whatever is still missing.
# Args: $1 - full path to the Brewfile
migrate_superseded_packages() {
    local brewfile="$1" installed

    # Captured rather than piped into `grep -q`: under pipefail, grep exiting at
    # the first match can kill brew with SIGPIPE and fail the whole test.
    installed=$(brew list --formula --full-name 2>/dev/null) || installed=""

    if brewfile_lists_formula "$brewfile" tlrc &&
        grep -Eqx '([^/]+/[^/]+/)?tldr' <<< "$installed"; then
        log "Unlinking the old tldr formula (removed from Homebrew) so tlrc can provide the tldr command..."
        brew unlink tldr >/dev/null 2>&1 ||
            log "Warning: could not unlink tldr; tlrc may fail to link. Run: brew unlink tldr"
    fi

    if brewfile_lists_formula "$brewfile" oh-my-posh &&
        grep -qx 'jandedobbeleer/oh-my-posh/oh-my-posh' <<< "$installed"; then
        log "Moving oh-my-posh from the jandedobbeleer/oh-my-posh tap to homebrew-core..."
        if ! brew fetch --formula homebrew/core/oh-my-posh >/dev/null 2>&1; then
            log "Warning: could not download oh-my-posh from homebrew-core; keeping the tap's copy for now."
        elif brew uninstall --formula oh-my-posh && brew install --formula homebrew/core/oh-my-posh; then
            log "oh-my-posh now comes from homebrew-core."
        else
            log "Warning: moving oh-my-posh to homebrew-core did not finish; brew bundle will install it next."
        fi
    fi
}

# Update Homebrew and install the selected Brewfile's packages.
install_packages() {
    log "Updating Homebrew..."
    brew update || log "Warning: brew update failed; continuing with the package index already on this machine."

    migrate_superseded_packages "$BREWFILE_PATH"

    # Retries transient failures and continues past any that persist (see
    # install_brewfile_packages), so dotfiles, tflint and cleanup still happen.
    install_brewfile_packages "$BREWFILE_PATH"

    # tflint is a macOS-only cask in Homebrew; install it separately on Linux
    # for the developer profile.
    if [[ "$BREWFILE" == "Brewfile-developer" ]]; then
        install_tflint_linux
    fi
}

# Stage and apply the profile's dotfiles, then set up git identity.
apply_profile() {
    local dotfiles_profile shell_type
    dotfiles_profile="profile-${BREWFILE#Brewfile-}"
    shell_type="$(shell_for_os "$OS_TYPE")"
    stage_dotfiles "$dotfiles_profile" "$OS_DOTFILES_DIR"
    # Preserve an identity from a pre-existing ~/.gitconfig before it can be replaced.
    migrate_gitconfig_identity
    apply_dotfiles "$dotfiles_profile" "$shell_type" "$OS_DOTFILES_DIR"
    if [[ "$OS_TYPE" == "macos" ]]; then
        ensure_zprofile_brew "$(brew --prefix)/bin/brew"
    fi

    # Write the git identity to ~/.gitconfig.local (prompting if needed) and
    # verify git can read it through ~/.gitconfig.
    personalize_gitconfig
}

# Log each non-empty line of $1, indented.
log_lines() {
    local line
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            log "  $line"
        fi
    done <<< "$1"
    return 0
}

# Run `brew bundle cleanup` for the selected Brewfile, limited to Homebrew
# formulae, casks and taps. Without the type flags it also covers every bundle
# extension (npm, go, cargo, uv, VS Code, krew, flatpak, Mac App Store), so a
# forced run would also uninstall, for example, global npm packages that the
# Brewfile never mentions.
brew_bundle_cleanup() {
    brew bundle cleanup --file="$BREWFILE_PATH" --formula --cask --tap "$@"
}

# Print what a `brew bundle cleanup` preview (its stdout) would remove, one
# "<kind> <name>" line each, where kind is formula, cask or tap. Only those three
# sections are read. Any other section is skipped (for example "Would `brew
# cleanup`:", whose lines are cache files), as is the closing "Run `brew bundle
# cleanup --force`" hint. Returns 1 if a line inside one of the three sections
# is not a plausible package name: the preview is then not understood, and
# nothing should be removed on the strength of it.
# Args: $1 - the preview's stdout
parse_cleanup_preview() {
    local line kind="" word
    local -a words
    local name_re='^[A-Za-z0-9@][A-Za-z0-9@+._/-]*$'
    while IFS= read -r line; do
        case "$line" in
            "Would uninstall formulae:") kind="formula"; continue ;;
            "Would uninstall casks:")    kind="cask"; continue ;;
            "Would untap:")              kind="tap"; continue ;;
            "Would "*":"|'Run `brew bundle cleanup'*) kind=""; continue ;;
        esac
        [[ -n "$kind" && "$line" =~ [^[:space:]] ]] || continue
        # Homebrew prints one name per line when stdout is not a terminal, and
        # columns when it is; splitting on whitespace reads both.
        read -r -a words <<< "$line"
        for word in "${words[@]}"; do
            [[ "$word" =~ $name_re ]] || return 1
            echo "$kind $word"
        done
    done <<< "$1"
    return 0
}

# Offer to uninstall packages that are installed but not in the Brewfile, and
# record the outcome in STATUS_CLEANUP.
#
# The preview (no --force) changes nothing. It exits 1 whenever it lists
# something, so its status alone is not an error. Only its stdout is parsed:
# stderr carries progress lines and warnings, which must never be presented as
# packages to remove. If the preview cannot be read, nothing is removed.
#
# The removal re-runs `brew bundle cleanup`, which recomputes the same list and
# keeps Homebrew's own safeguards (it never removes a dependency of something in
# the Brewfile). Its failure is reported, never fatal, so the summary prints.
cleanup_packages() {
    local preview preview_rc=0 candidates kind name
    local err_file="$WORKDIR/cleanup-preview.err"
    log "Checking for packages not listed in $BREWFILE..."
    preview=$(brew_bundle_cleanup 2>"$err_file") || preview_rc=$?

    if ! candidates=$(parse_cleanup_preview "$preview"); then
        log "Could not read Homebrew's cleanup preview, so nothing will be removed. It printed:"
        log_lines "$preview"
        STATUS_CLEANUP="unreadable"
        return 0
    fi

    if [[ -z "$candidates" ]]; then
        if [[ "$preview_rc" -ne 0 ]]; then
            # A failure with nothing listed is a Homebrew error, for example a
            # Brewfile entry it cannot resolve.
            log "Homebrew could not work out what to clean up, so nothing will be removed. It reported:"
            log_lines "$(cat "$err_file" 2>/dev/null)"
            STATUS_CLEANUP="unreadable"
            return 0
        fi
        log "Nothing to clean up; every installed package is part of $BREWFILE."
        STATUS_CLEANUP="none"
        return 0
    fi

    log "The following are installed but not listed in $BREWFILE:"
    while read -r kind name; do
        log "  $kind: $name"
    done <<< "$candidates"

    determine_cleanup_mode
    if [[ "$CLEANUP_MODE" != "remove" ]]; then
        log "Keeping all installed packages; nothing was removed. (Set CLEANUP=remove to uninstall packages not in the profile.)"
        STATUS_CLEANUP="kept"
        return 0
    fi

    log "Removing packages not listed in $BREWFILE..."
    # stdin is /dev/null so Homebrew cannot stop to ask a second question: the
    # list above is what was approved. In particular `brew untap` would
    # otherwise offer to uninstall formulae that a removed tap still provides,
    # which were never shown. Without a terminal it refuses instead, and that
    # failure is reported below.
    if brew_bundle_cleanup --force </dev/null; then
        log "Cleanup complete."
        STATUS_CLEANUP="removed"
    else
        log "Warning: Homebrew could not remove everything listed above; see its messages."
        STATUS_CLEANUP="failed"
    fi
}

main() {
    set -euo pipefail

    prepare_workspace
    init_logging
    detect_os

    # Homebrew refuses to install as root, so bail early with guidance.
    require_non_root

    select_profile
    resolve_source

    install_homebrew
    warn_stale_brew_lines
    install_build_tools

    # Heal a prior run that installed ca-certificates before awk was available.
    # Must run after install_build_tools (which ensures gawk) and before any TLS
    # operation through Homebrew, starting with brew update.
    repair_ca_certificates

    install_packages
    apply_profile
    cleanup_packages

    # Report what actually happened. print_summary returns non-zero if packages
    # failed to install, so the exit status reflects real failures. Used as an
    # `if` condition so `set -e` does not abort before we pick the exit status.
    if print_summary; then
        exit 0
    else
        exit 1
    fi
}

# Run main only when executed (as a file, via bash <(...), or piped), not when
# sourced. When piped, BASH_SOURCE[0] is empty and $0 is "bash", so fall back to
# $0 (plain ${BASH_SOURCE[0]} would be unbound under set -u).
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
