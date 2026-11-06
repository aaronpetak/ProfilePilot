#!/usr/bin/env bash
# Fast, deterministic unit tests for bootstrap.sh and the shipped dotfiles.
#
# bootstrap.sh only defines functions when sourced (main runs only when the file
# is executed), so the tests source it and call the helpers directly. Nothing
# here needs network, Homebrew, or a TTY: log and tty_available are stubbed, and
# anything that touches files runs in a subshell against a mktemp -d HOME.
#
# Exits non-zero if any assertion fails, so CI can gate on it.
# Variables assigned here are read by the sourced bootstrap.sh functions; the
# linter cannot see across the source, hence this file-wide disable.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/../bootstrap.sh"

pass=0
fail=0

# shellcheck source=../bootstrap.sh
source "$BOOTSTRAP"

# Keep the caller's environment from steering the code under test.
unset PROFILE SKIP_CLEANUP GIT_NAME GIT_EMAIL
DOTFILES_CONFLICT=""
CLEANUP=""

# Keep the real log() for the few tests of its behavior, then stub it so no test
# writes a log file or prints. No test may ever open /dev/tty.
REAL_LOG_DEF="$(declare -f log)"
log() { :; }
fatal() { echo "FATAL: $*"; exit 1; }
tty_available() { return 1; }

check() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "PASS: $label"
        pass=$((pass + 1))
    else
        echo "FAIL: $label -> got '$got' want '$want'"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# shell_for_os / shell_files_for  (the dotfile shell follows the OS)
# ---------------------------------------------------------------------------

check "shell_for_os macos"       "$(shell_for_os macos)"                          "zsh"
check "shell_for_os linux"       "$(shell_for_os linux)"                          "bash"
check "files for macOS shell"    "$(shell_files_for "$(shell_for_os macos)")"     ".zshrc .zprofile"
check "files for linux shell"    "$(shell_files_for "$(shell_for_os linux)")"     ".bashrc .bash_environment"
check "files for unknown shell"  "$(shell_files_for fish)"                        ""

# ---------------------------------------------------------------------------
# brewfile_for_profile  (non-interactive PROFILE selection)
# ---------------------------------------------------------------------------

check "profile developer"        "$(brewfile_for_profile developer)"              "Brewfile-developer"
check "profile minimal"          "$(brewfile_for_profile minimal)"                "Brewfile-minimal"
check "profile unknown"          "$(brewfile_for_profile bastion)"                ""
check "profile empty"            "$(brewfile_for_profile '')"                     ""

# ---------------------------------------------------------------------------
# print_summary exit code  (honest end-of-run summary)
# Only unresolved package failures should flip the exit code; kept dotfiles and
# an un-personalized gitconfig are legitimate states that must NOT fail the run.
# ---------------------------------------------------------------------------
summary_rc() {
    local pkg="$1" dot="$2" git="$3"
    (
        log() { :; }
        # Read by print_summary; shellcheck cannot see across the sourced file.
        # shellcheck disable=SC2034
        STATUS_PACKAGES="$pkg"
        # shellcheck disable=SC2034
        STATUS_DOTFILES="$dot"
        # shellcheck disable=SC2034
        STATUS_GITCONFIG="$git"
        print_summary >/dev/null 2>&1
    )
    echo "$?"
}

check "summary all ok -> 0"          "$(summary_rc ok applied personalized)"      "0"
check "summary pkg incomplete -> 1"  "$(summary_rc incomplete applied personalized)" "1"
check "summary dotfiles kept -> 0"   "$(summary_rc ok kept already)"              "0"
check "summary git incomplete -> 0"  "$(summary_rc ok applied incomplete)"        "0"
check "summary not-found/absent -> 0" "$(summary_rc ok not-found absent)"         "0"
check "summary all unknown -> 0"     "$(summary_rc unknown unknown unknown)"      "0"
check "summary pkg fail dominates"   "$(summary_rc incomplete kept incomplete)"   "1"

# ---------------------------------------------------------------------------
# Linux developer prompt wiring  (oh-my-posh + PROMPT_COMMAND)
#
# `oh-my-posh init bash` stores its _omp_hook in a PROMPT_COMMAND *array*, and
# bash < 5.1 (4.4 ships on RHEL/Rocky/Alma 8) executes only element [0]. Two
# invariants keep the prompt rendering on a login shell there:
#   1. no PROMPT_COMMAND assignment may run after the init, and
#   2. the array must be flattened to a ';'-joined string right after it.
# ---------------------------------------------------------------------------
DEV_BASHRC="$SCRIPT_DIR/../linux/profile-developer/.bashrc"
DEV_BASHENV="$SCRIPT_DIR/../linux/profile-developer/.bash_environment"

# First line number matching a regex, or empty when absent. Patterns are
# anchored at the start of the line so the surrounding prose comments (which
# quote the very lines being located) can't be matched by mistake.
line_of() {
    grep -nE -m1 "$2" "$1" | cut -d: -f1
}

# "yes" when both line numbers exist and $1 comes strictly before $2.
before() {
    if [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]; then echo "yes"; else echo "no"; fi
}

check "bashrc sets PROMPT_COMMAND before sourcing .bash_environment" \
    "$(before "$(line_of "$DEV_BASHRC" "^PROMPT_COMMAND='history -a'$")" \
              "$(line_of "$DEV_BASHRC" '^[[:space:]]*\. ~/\.bash_environment$')")" "yes"

# Homebrew is detected in .bashrc (not .bash_environment) so it is on PATH
# before ~/.shell_aliases is sourced and before oh-my-posh is initialised.
MIN_BASHRC="$SCRIPT_DIR/../linux/profile-minimal/.bashrc"
for rc_file in "$DEV_BASHRC" "$MIN_BASHRC"; do
    rc_name="$(basename "$(dirname "$rc_file")")"
    check "$rc_name .bashrc detects brew before sourcing .shell_aliases" \
        "$(before "$(line_of "$rc_file" '^[[:space:]]*eval .*shellenv bash')" \
                  "$(line_of "$rc_file" '^[[:space:]]*\. ~/\.shell_aliases$')")" "yes"
done
check "developer .bashrc detects brew before sourcing .bash_environment" \
    "$(before "$(line_of "$DEV_BASHRC" '^[[:space:]]*eval .*shellenv bash')" \
              "$(line_of "$DEV_BASHRC" '^[[:space:]]*\. ~/\.bash_environment$')")" "yes"
check ".bash_environment no longer hardcodes a Homebrew prefix" \
    "$(grep -c 'linuxbrew\|/opt/homebrew' "$DEV_BASHENV")" "0"

# Behavioral: run the .bashrc detection loop with its candidates redirected to a
# temp dir holding a fake brew, and confirm the first existing one is evaluated.
brew_loop_result() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/b"
        printf '#!/bin/sh\necho "export PICKED=%s"\n' "$tmp/b" > "$tmp/b/brew"
        chmod +x "$tmp/b/brew"
        snippet="$(sed -n '/^for _brew in /,/^unset _brew$/p' "$DEV_BASHRC")"
        snippet="${snippet//\/opt\/homebrew\/bin\/brew/$tmp/a/brew}"
        snippet="${snippet//\/usr\/local\/bin\/brew/$tmp/b/brew}"
        snippet="${snippet//\/home\/linuxbrew\/.linuxbrew\/bin\/brew/$tmp/c/brew}"
        HOME="$tmp/home"
        eval "$snippet"
        echo "${PICKED:-none} ${_brew:-unset}" | sed "s#$tmp#TMP#"
    )
}
check "brew loop evaluates the first brew found and unsets its variable" \
    "$(brew_loop_result)" "TMP/b unset"

# macOS: zsh files must request zsh-flavoured shellenv and not hardcode a prefix.
MAC_DIR="$SCRIPT_DIR/../macos"
for z in minimal developer; do
    check "macOS $z .zprofile uses shellenv zsh"         "$(grep -c 'shellenv zsh' "$MAC_DIR/profile-$z/.zprofile")" "1"
    check "macOS $z .zprofile has no stray percent sign"         "$(grep -c '%$' "$MAC_DIR/profile-$z/.zprofile")" "0"
    check "macOS $z .zshrc does not hardcode /opt/homebrew/share or /bin"         "$(grep -v '^[[:space:]]*#' "$MAC_DIR/profile-$z/.zshrc" | grep -c '/opt/homebrew/\(share\|bin/virtualenv\)')" "0"
done

check "PROMPT_COMMAND flatten sits after oh-my-posh init" \
    "$(before "$(line_of "$DEV_BASHENV" '^[[:space:]]*eval .*oh-my-posh init bash')" \
              "$(line_of "$DEV_BASHENV" '^[[:space:]]*if \[\[ .*declare -p PROMPT_COMMAND')")" "yes"

# The last PROMPT_COMMAND assignment in the file must be the flatten's own; any
# assignment below it would clobber the hook again on bash 4.4.
check "flatten is the last PROMPT_COMMAND assignment" \
    "$(grep -E '^[[:space:]]*PROMPT_COMMAND=' "$DEV_BASHENV" | tail -n1 |
       sed -e 's/^[[:space:]]*//')" \
    'PROMPT_COMMAND="$_omp_prompt_command"'

# Behavioral check: run the flatten block itself against a bash 4.4-style
# array, exactly as oh-my-posh would have left it.
flatten() {
    (
        eval "$1"
        eval "$(sed -n '/if \[\[ "\$(declare -p PROMPT_COMMAND/,/^    fi$/p' "$DEV_BASHENV")"
        declare -p PROMPT_COMMAND
    )
}

check "flatten joins array into one string" \
    "$(flatten 'PROMPT_COMMAND=("history -a" "_omp_hook")')" \
    'declare -- PROMPT_COMMAND="history -a;_omp_hook"'
check "flatten leaves a string untouched" \
    "$(flatten 'PROMPT_COMMAND="history -a;_omp_hook"')" \
    'declare -- PROMPT_COMMAND="history -a;_omp_hook"'

# ---------------------------------------------------------------------------
# Oh My Posh theme
# oh-my-posh does not register config keys as named Go templates, so a
# `{{ template "name" . }}` call always fails with `template not defined` and
# breaks whichever template invokes it. Template logic must be inlined.
# ---------------------------------------------------------------------------
THEME="$SCRIPT_DIR/../universal/.poshthemes/meridian-2.omp.json"

check "theme has no named-template calls" \
    "$(grep -c 'template \\"' "$THEME")" "0"
check "theme sets a console title" \
    "$(grep -c '"console_title_template"' "$THEME")" "1"
if command -v python3 >/dev/null 2>&1; then
    check "theme is valid JSON" \
        "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$THEME" 2>&1)" "ok"
fi

# ---------------------------------------------------------------------------
# Git identity in ~/.gitconfig.local
# Each case runs in a subshell against a throwaway HOME; the real $HOME and
# global git config are never read or written.
# ---------------------------------------------------------------------------
GITCONFIG_SRC="$SCRIPT_DIR/../universal/.gitconfig"

# Run a snippet with identity helpers loaded, a temp HOME seeded with the
# shipped .gitconfig, and no TTY. $1 is the snippet; it may use $HOME.
identity_env() {
    (
        tmp_home="$(mktemp -d)"
        trap 'rm -rf "$tmp_home"' EXIT
        export HOME="$tmp_home"
        unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_NAME GIT_EMAIL
        export GIT_CONFIG_NOSYSTEM=1
        log() { :; }
        tty_available() { return 1; }
        # shellcheck disable=SC2034  # read by the eval-ed helpers.
        STATUS_GITCONFIG="unknown"
        cp "$GITCONFIG_SRC" "$HOME/.gitconfig"
        eval "$1"
    )
}

check "identity written to .gitconfig.local and resolved via include" \
    "$(identity_env 'GIT_NAME="Ada L" GIT_EMAIL="ada@example.com" personalize_gitconfig
        echo "$STATUS_GITCONFIG $(git config --global --includes user.name) $(git config --file "$HOME/.gitconfig.local" user.email)"')" \
    "personalized Ada L ada@example.com"

check "no identity and no tty -> incomplete, nothing written" \
    "$(identity_env 'personalize_gitconfig; echo "$STATUS_GITCONFIG $(test -e "$HOME/.gitconfig.local" && echo file || echo nofile)"')" \
    "incomplete nofile"

check "newline in name is rejected" \
    "$(identity_env 'GIT_NAME="a
b" GIT_EMAIL="x@y.z" personalize_gitconfig; echo "$STATUS_GITCONFIG $(test -e "$HOME/.gitconfig.local" && echo file || echo nofile)"')" \
    "incomplete nofile"

check "sed-special characters are stored verbatim" \
    "$(identity_env 'GIT_NAME="A & B/C\\D" GIT_EMAIL="a+b@x.io" personalize_gitconfig; git config --global --includes user.name')" \
    'A & B/C\D'

check "existing .gitconfig.local identity is kept" \
    "$(identity_env 'git config --file "$HOME/.gitconfig.local" user.name Old
        git config --file "$HOME/.gitconfig.local" user.email old@x.io
        personalize_gitconfig; echo "$STATUS_GITCONFIG $(git config --global --includes user.name)"')" \
    "already Old"

check "old .gitconfig without include -> incomplete" \
    "$(identity_env 'printf "[init]\n    defaultBranch = main\n" > "$HOME/.gitconfig"
        GIT_NAME=N GIT_EMAIL=n@x.io personalize_gitconfig; echo "$STATUS_GITCONFIG"')" \
    "incomplete"

check "migration copies a real identity into .gitconfig.local" \
    "$(identity_env 'printf "[user]\n    name = Real Name\n    email = real@x.io\n" > "$HOME/.gitconfig"
        migrate_gitconfig_identity
        echo "$(git config --file "$HOME/.gitconfig.local" user.name) $(git config --file "$HOME/.gitconfig.local" user.email)"')" \
    "Real Name real@x.io"

check "migration skips placeholder values" \
    "$(identity_env 'printf "[user]\n    name = {FULL NAME}\n    email = {GITHUB EMAIL}\n" > "$HOME/.gitconfig"
        migrate_gitconfig_identity; test -e "$HOME/.gitconfig.local" && echo file || echo nofile')" \
    "nofile"

check "migration does not overwrite an existing .gitconfig.local value" \
    "$(identity_env 'printf "[user]\n    name = Old Name\n" > "$HOME/.gitconfig"
        git config --file "$HOME/.gitconfig.local" user.name Kept
        migrate_gitconfig_identity; git config --file "$HOME/.gitconfig.local" user.name')" \
    "Kept"

# Include order: a per-directory includeIf identity must override the
# ~/.gitconfig.local identity (the include sits at the top of .gitconfig).
check "includeIf identity overrides .gitconfig.local" \
    "$(identity_env 'mkdir -p "$HOME/projects/github/repo"
        git init -q "$HOME/projects/github/repo"
        git config --file "$HOME/.gitconfig.local" user.name Local
        printf "[user]\n    name = PerDir\n" > "$HOME/projects/github/.gitconfig"
        cd "$HOME/projects/github/repo" && git config user.name')" \
    "PerDir"

# ---------------------------------------------------------------------------
# Homebrew prefix detection (find_brew_prefix)
# The candidate list is replaced with temp directories; nothing real is probed.
# ---------------------------------------------------------------------------
brew_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        brew_prefix_candidates() { echo "$tmp/a"; echo "$tmp/b"; echo "$tmp/c"; }
        eval "$1"
        find_brew_prefix | sed "s#$tmp#TMP#"
        echo "rc=${PIPESTATUS[0]}"
    )
}

check "find_brew_prefix: none installed -> rc 1" \
    "$(brew_probe ':' | tr '\n' ' ')" "rc=1 "
check "find_brew_prefix: picks the first candidate with brew" \
    "$(brew_probe 'mkdir -p "$tmp/b/bin" "$tmp/c/bin"; touch "$tmp/b/bin/brew" "$tmp/c/bin/brew"; chmod +x "$tmp/b/bin/brew" "$tmp/c/bin/brew"' | tr '\n' ' ')" "TMP/b rc=0 "
check "find_brew_prefix: ignores a non-executable brew" \
    "$(brew_probe 'mkdir -p "$tmp/a/bin"; touch "$tmp/a/bin/brew"' | tr '\n' ' ')" "rc=1 "
check "brew_prefix_candidates lists the four known prefixes" \
    "$( (HOME=/h; brew_prefix_candidates | tr '\n' ' ') )" \
    "/opt/homebrew /usr/local /home/linuxbrew/.linuxbrew /h/.linuxbrew "

# ---------------------------------------------------------------------------
# Homebrew PATH wiring (setup_brew_path, ensure_zprofile_brew, stale lines)
# All run against a throwaway HOME with a fake brew; nothing real is touched.
# ---------------------------------------------------------------------------
brew_wiring() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        export HOME="$tmp/home"
        mkdir -p "$HOME" "$tmp/prefix/bin"
        printf '#!/bin/sh\necho "export WIRED=1"\n' > "$tmp/prefix/bin/brew"
        chmod +x "$tmp/prefix/bin/brew"
        log() { echo "LOG: $*"; }
        eval "$1" 2>&1 | sed "s#$tmp#TMP#g"
    )
}

check "setup_brew_path on macOS writes no ~/.profile but wires the session" \
    "$(brew_wiring 'OS_TYPE=macos; setup_brew_path "$tmp/prefix/bin/brew"; echo "WIRED=${WIRED:-0} profile=$(test -e "$HOME/.profile" && echo yes || echo no)"')" \
    "WIRED=1 profile=no"
check "setup_brew_path on Linux writes the detected prefix to ~/.profile" \
    "$(brew_wiring 'OS_TYPE=linux; setup_brew_path "$tmp/prefix/bin/brew"; cat "$HOME/.profile"')" \
    'eval "$(TMP/prefix/bin/brew shellenv bash)"'
check "setup_brew_path on Linux is idempotent" \
    "$(brew_wiring 'OS_TYPE=linux; setup_brew_path "$tmp/prefix/bin/brew"; setup_brew_path "$tmp/prefix/bin/brew"; wc -l < "$HOME/.profile" | tr -d " "')" \
    "1"
check "ensure_zprofile_brew appends a zsh shellenv line to a bare file" \
    "$(brew_wiring 'ensure_zprofile_brew "$tmp/prefix/bin/brew" >/dev/null; cat "$HOME/.zprofile"')" \
    'eval "$(TMP/prefix/bin/brew shellenv zsh)"'
check "ensure_zprofile_brew leaves a file that already has shellenv alone" \
    "$(brew_wiring 'echo "eval \"\$(/x/brew shellenv zsh)\"" > "$HOME/.zprofile"; ensure_zprofile_brew "$tmp/prefix/bin/brew" >/dev/null; wc -l < "$HOME/.zprofile" | tr -d " "')" \
    "1"
check "warn_stale_brew_lines flags a shellenv line for a missing brew" \
    "$(brew_wiring 'echo "eval \"\$(/nonexistent/bin/brew shellenv bash)\"" > "$HOME/.profile"; warn_stale_brew_lines')" \
    "LOG: Warning: TMP/home/.profile runs /nonexistent/bin/brew shellenv, but that brew does not exist. Remove or fix that line."
check "warn_stale_brew_lines is silent when the brew exists" \
    "$(brew_wiring 'echo "eval \"\$($tmp/prefix/bin/brew shellenv bash)\"" > "$HOME/.profile"; warn_stale_brew_lines')" \
    ""

# ---------------------------------------------------------------------------
# Source resolution: local checkout vs. one pinned tarball
# ---------------------------------------------------------------------------
# Facts the design relies on: BASH_SOURCE[0] is empty when the script is piped
# in, and must be read with a default so `set -u` does not abort.
check "piped script sees an empty BASH_SOURCE[0] (set -u safe)" \
    "$(printf 'set -u\necho "[${BASH_SOURCE[0]:-}]"\n' | bash)" "[]"

lc_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        eval "$1" | sed "s#$tmp#TMP#g"
        echo "rc=${PIPESTATUS[0]}"
    )
}

check "local_checkout_dir: empty script path -> tarball mode" \
    "$(lc_probe 'local_checkout_dir ""' | tr '\n' ' ')" "rc=1 "
check "local_checkout_dir: script path /dev/fd/63 (bash <(curl)) -> tarball mode" \
    "$(lc_probe 'local_checkout_dir /dev/fd/63' | tr '\n' ' ')" "rc=1 "
check "local_checkout_dir: dir without universal/brewfiles -> tarball mode" \
    "$(lc_probe 'mkdir -p "$tmp/x"; local_checkout_dir "$tmp/x/bootstrap.sh"' | tr '\n' ' ')" "rc=1 "
check "local_checkout_dir: clone with universal/brewfiles -> local mode" \
    "$(lc_probe 'mkdir -p "$tmp/clone/universal/brewfiles"; local_checkout_dir "$tmp/clone/bootstrap.sh"' | tr '\n' ' ')" "TMP/clone rc=0 "
check "local_checkout_dir: the real repo is recognised as a checkout" \
    "$( (local_checkout_dir "$BOOTSTRAP" >/dev/null && echo local) )" "local"

# unpack_source_tarball: build a codeload-style tarball (single top-level dir
# with an unpredictable name) and unpack it without knowing that name.
tarball_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        log() { :; }
        fatal() { echo "FATAL"; exit 1; }
        mkdir -p "$tmp/src/ProfilePilot-abc123/universal/brewfiles"
        eval "$1"
        unpack_source_tarball "$tmp/t.tar.gz" "$tmp/out" 2>/dev/null
        test -f "$tmp/out/universal/brewfiles/Brewfile-minimal" && echo extracted
    )
}

check "unpack_source_tarball strips the top-level dir and finds the sentinel" \
    "$(tarball_probe 'touch "$tmp/src/ProfilePilot-abc123/universal/brewfiles/Brewfile-minimal"; tar -czf "$tmp/t.tar.gz" -C "$tmp/src" ProfilePilot-abc123' | tr '\n' ' ')" "extracted "
check "unpack_source_tarball is fatal when the sentinel is missing" \
    "$(tarball_probe 'tar -czf "$tmp/t.tar.gz" -C "$tmp/src" ProfilePilot-abc123' | tr '\n' ' ')" "FATAL "
check "unpack_source_tarball is fatal on a corrupt archive" \
    "$(tarball_probe 'echo not-a-tarball > "$tmp/t.tar.gz"' | tr '\n' ' ')" "FATAL "

# ---------------------------------------------------------------------------
# Private workspace: bootstrap must use mktemp and never assign TMPDIR
# ---------------------------------------------------------------------------
check "bootstrap never assigns TMPDIR" \
    "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?TMPDIR=' "$BOOTSTRAP")" "0"
check "bootstrap creates its workspace with mktemp -d" \
    "$(grep -c '^[[:space:]]*WORKDIR="\$(mktemp -d)"$' "$BOOTSTRAP")" "1"

# ---------------------------------------------------------------------------
# package:command parsing (missing_linux_packages)
# PATH is restricted to a temp dir of fake executables, so only those commands
# count as installed.
# ---------------------------------------------------------------------------
pkg_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        for c in $1; do printf '#!/bin/sh\n' > "$tmp/$c"; chmod +x "$tmp/$c"; done
        shift
        # Only the fake commands are on PATH while the function runs; the
        # result is collected with builtins and PATH restored before cleanup.
        local_path="$PATH"
        PATH="$tmp"
        out=""
        while IFS= read -r p; do out="$out$p "; done < <(missing_linux_packages "$@")
        PATH="$local_path"
        printf '%s' "$out"
    )
}

check "missing_linux_packages: bare names use the name as the command" \
    "$(pkg_probe 'unzip' unzip gawk)" "gawk "
check "missing_linux_packages: package:command checks the command" \
    "$(pkg_probe 'bwrap' bubblewrap:bwrap)" ""
check "missing_linux_packages: package:command reports the package name" \
    "$(pkg_probe 'unzip' bubblewrap:bwrap unzip)" "bubblewrap "
check "missing_linux_packages: a command named like the package does not satisfy package:command" \
    "$(pkg_probe 'bubblewrap' bubblewrap:bwrap)" "bubblewrap "
check "missing_linux_packages: nothing requested -> nothing missing" \
    "$(pkg_probe '')" ""

# ---------------------------------------------------------------------------
# brew invocation policy (static checks; these steps need a real Homebrew)
# ---------------------------------------------------------------------------
check "brew update failure is tolerated" \
    "$(grep -c '^[[:space:]]*brew update || log ' "$BOOTSTRAP")" "1"
check "tap-trust check is not disabled" \
    "$(grep -c 'HOMEBREW_NO_REQUIRE_TAP_TRUST' "$BOOTSTRAP")" "0"
check "every Brewfile tap declares trusted: true" \
    "$(grep -h '^tap ' "$SCRIPT_DIR"/../universal/brewfiles/Brewfile-* | grep -vc 'trusted: true')" "0"

# ---------------------------------------------------------------------------
# Release checksum verification (verify_release_checksum)
# ---------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
    checksum_probe() {
        (
            tmp="$(mktemp -d)"
            trap 'rm -rf "$tmp"' EXIT
            printf 'payload' > "$tmp/tflint_linux_amd64.zip"
            printf 'other' > "$tmp/tflint_linux_arm64.zip"
            # shellcheck disable=SC2034  # used by the eval-ed snippet.
            good="$(cd "$tmp" && sha256sum tflint_linux_amd64.zip)"
            eval "$1"
            verify_release_checksum "$tmp" tflint_linux_amd64.zip && echo ok || echo bad
        )
    }
    check "verify_release_checksum accepts a matching checksum" \
        "$(checksum_probe 'printf "%s\n" "$good" > "$tmp/checksums.txt"')" "ok"
    check "verify_release_checksum accepts it among other lines" \
        "$(checksum_probe 'printf "%s\n%s\n" "0000  tflint_linux_arm64.zip" "$good" > "$tmp/checksums.txt"')" "ok"
    check "verify_release_checksum rejects a corrupted file" \
        "$(checksum_probe 'printf "%s\n" "$good" > "$tmp/checksums.txt"; printf corrupt > "$tmp/tflint_linux_amd64.zip"')" "bad"
    check "verify_release_checksum rejects a missing checksum line" \
        "$(checksum_probe 'printf "%s\n" "${good%% *}  tflint_linux_arm64.zip" > "$tmp/checksums.txt"')" "bad"
    check "verify_release_checksum rejects a missing checksums file" \
        "$(checksum_probe ':')" "bad"
    check "verify_release_checksum does not match a longer filename suffix" \
        "$(checksum_probe 'printf "%s\n" "${good%% *}  xtflint_linux_amd64.zip" > "$tmp/checksums.txt"')" "bad"
fi

# resolve_latest_release_tag with a stub curl that prints a fixed effective URL.
tag_probe() {
    (
        curl() { printf '%s' "$1"; }
        eval "$2"
        resolve_latest_release_tag terraform-linters/tflint && true
        echo "rc=$?"
    )
}
check "resolve_latest_release_tag extracts the tag from the redirect target" \
    "$(tag_probe '' 'curl() { printf "%s" "https://github.com/terraform-linters/tflint/releases/tag/v0.65.0"; }' | tr '\n' ' ')" "v0.65.0 rc=0 "
check "resolve_latest_release_tag fails when the URL is not a tag page" \
    "$(tag_probe '' 'curl() { printf "%s" "https://github.com/terraform-linters/tflint/releases"; }' | tr '\n' ' ')" "rc=1 "
check "resolve_latest_release_tag fails when curl fails" \
    "$(tag_probe '' 'curl() { return 22; }' | tr '\n' ' ')" "rc=1 "

check "tflint download uses a resolved tag, not releases/latest/download" \
    "$(grep -c 'releases/latest/download' "$BOOTSTRAP")" "0"

# ---------------------------------------------------------------------------
# main() entry point
# The script is run piped, as a file, and sourced, each against a throwaway HOME
# and with a failure forced before anything could be installed (an invalid
# PROFILE, or a stubbed id reporting root). The expected FATAL line proves main
# ran and got as far as that step; nothing is ever installed.
# ---------------------------------------------------------------------------
main_probe() {
    # $1 = mode (pipe|file|fakeroot-pipe)
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/home" "$tmp/bin"
        printf '#!/bin/sh\necho 0\n' > "$tmp/bin/id"
        chmod +x "$tmp/bin/id"
        case "$1" in
            pipe)          env HOME="$tmp/home" PROFILE=bogus bash < "$BOOTSTRAP" 2>&1 ;;
            file)          env HOME="$tmp/home" PROFILE=bogus bash "$BOOTSTRAP" 2>&1 ;;
            fakeroot-pipe) env HOME="$tmp/home" PATH="$tmp/bin:$PATH" PROFILE=minimal bash < "$BOOTSTRAP" 2>&1 ;;
        esac
        echo "rc=$?"
        test -e "$tmp/home/.local/state/homebrew-restore.log" -o -e "$tmp/home/Library/Logs/homebrew-restore.log" && echo "logged-in-temp-home"
    )
}

piped_out="$(main_probe pipe)"
check "piped script reaches main (invalid PROFILE is fatal)" \
    "$(printf '%s\n' "$piped_out" | grep -c "FATAL: Invalid PROFILE='bogus'")" "1"
check "piped script exits non-zero on that fatal" \
    "$(printf '%s\n' "$piped_out" | grep -c '^rc=1$')" "1"
check "piped script logs into the temp HOME" \
    "$(printf '%s\n' "$piped_out" | grep -c '^logged-in-temp-home$')" "1"
check "file run reaches main (invalid PROFILE is fatal)" \
    "$(main_probe file | grep -c "FATAL: Invalid PROFILE='bogus'")" "1"
check "piped script reaches the root guard (stubbed id reports root)" \
    "$(main_probe fakeroot-pipe | grep -c 'FATAL: Do not run this as root')" "1"

# Sourcing must define functions only: no output, no strict mode left behind,
# no workspace created.
check "sourcing bootstrap.sh runs nothing and leaks no set -e" \
    "$(bash -c 'source "$1"; echo "out:[$-]:${WORKDIR:-none}"' _ "$BOOTSTRAP" | sed 's/\[[^e]*\]/[no-e]/')" "out:[no-e]:none"

# ---------------------------------------------------------------------------
# items_identical
# ---------------------------------------------------------------------------
ident_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        eval "$1"
        items_identical "$tmp/src" "$tmp/dest" && echo same || echo different
    )
}

check "items_identical: identical files" \
    "$(ident_probe 'echo a > "$tmp/src"; echo a > "$tmp/dest"')" "same"
check "items_identical: different files" \
    "$(ident_probe 'echo a > "$tmp/src"; echo b > "$tmp/dest"')" "different"
check "items_identical: identical directories" \
    "$(ident_probe 'mkdir -p "$tmp/src/d" "$tmp/dest/d"; echo a > "$tmp/src/d/f"; echo a > "$tmp/dest/d/f"')" "same"
check "items_identical: directories with different content" \
    "$(ident_probe 'mkdir "$tmp/src" "$tmp/dest"; echo a > "$tmp/src/f"; echo b > "$tmp/dest/f"')" "different"
check "items_identical: directories with an extra file" \
    "$(ident_probe 'mkdir "$tmp/src" "$tmp/dest"; echo a > "$tmp/src/f"; echo a > "$tmp/dest/f"; echo x > "$tmp/dest/g"')" "different"
check "items_identical: file source vs directory destination" \
    "$(ident_probe 'echo a > "$tmp/src"; mkdir "$tmp/dest"')" "different"
check "items_identical: directory source vs file destination" \
    "$(ident_probe 'mkdir "$tmp/src"; echo a > "$tmp/dest"')" "different"
check "items_identical: missing destination" \
    "$(ident_probe 'echo a > "$tmp/src"')" "different"

# ---------------------------------------------------------------------------
# determine_conflict_mode / determine_cleanup_mode (no TTY available)
# ---------------------------------------------------------------------------
conflict_mode_for() {
    ( DOTFILES_CONFLICT="$1"; determine_conflict_mode; echo "$CONFLICT_MODE" )
}
check "conflict mode: overwrite"                   "$(conflict_mode_for overwrite)" "overwrite"
check "conflict mode: skip"                        "$(conflict_mode_for skip)"      "skip"
check "conflict mode: prompt without a tty -> skip" "$(conflict_mode_for prompt)"   "skip"
check "conflict mode: unset without a tty -> skip" "$(conflict_mode_for '')"        "skip"
check "conflict mode: unknown value -> skip"       "$(conflict_mode_for bogus)"     "skip"

cleanup_mode_for() {
    ( CLEANUP="$1"; if [[ -n "${2:-}" ]]; then SKIP_CLEANUP="$2"; fi; determine_cleanup_mode; echo "$CLEANUP_MODE" )
}
check "cleanup mode: remove"                        "$(cleanup_mode_for remove)"     "remove"
check "cleanup mode: skip"                          "$(cleanup_mode_for skip)"       "skip"
check "cleanup mode: prompt without a tty -> skip"  "$(cleanup_mode_for prompt)"     "skip"
check "cleanup mode: unset without a tty -> skip"   "$(cleanup_mode_for '')"         "skip"
check "cleanup mode: unknown value -> skip"         "$(cleanup_mode_for bogus)"      "skip"
check "cleanup mode: SKIP_CLEANUP alias -> skip"    "$(cleanup_mode_for '' 1)"       "skip"
check "cleanup mode: CLEANUP=remove beats SKIP_CLEANUP" "$(cleanup_mode_for remove 1)" "remove"

# ---------------------------------------------------------------------------
# npm_package_owning
# ---------------------------------------------------------------------------
npm_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        eval "$1"
        npm_package_owning "$tmp/bin/tool"
    )
}
check "npm_package_owning: scoped package" \
    "$(npm_probe 'mkdir "$tmp/bin"; ln -s ../lib/node_modules/@fresh-editor/fresh-editor/run.js "$tmp/bin/tool"')" "@fresh-editor/fresh-editor"
check "npm_package_owning: unscoped package" \
    "$(npm_probe 'mkdir "$tmp/bin"; ln -s ../lib/node_modules/left-pad/cli.js "$tmp/bin/tool"')" "left-pad"
check "npm_package_owning: symlink outside node_modules" \
    "$(npm_probe 'mkdir "$tmp/bin"; ln -s /usr/bin/true "$tmp/bin/tool"')" ""
check "npm_package_owning: regular file" \
    "$(npm_probe 'mkdir "$tmp/bin"; echo hi > "$tmp/bin/tool"')" ""
check "npm_package_owning: missing path" \
    "$(npm_probe 'mkdir "$tmp/bin"')" ""

# ---------------------------------------------------------------------------
# detect_os / init_logging / log / prepare_workspace
# ---------------------------------------------------------------------------
os_probe() {
    ( OSTYPE="$1"; detect_os; echo "$OS_TYPE $OS_DOTFILES_DIR" )
}
check "detect_os: darwin"            "$(os_probe darwin24.1)"  "macos macos"
check "detect_os: linux-gnu"         "$(os_probe linux-gnu)"   "linux linux"
check "detect_os: bare linux (SUSE)" "$(os_probe linux)"       "linux linux"
check "detect_os: linux-musl is fatal" "$(os_probe linux-musl | head -n1 | cut -c1-33)" "FATAL: Unsupported OS: linux-musl"
check "detect_os: unknown OS is fatal" "$(os_probe freebsd14)" "FATAL: Unsupported OS: freebsd14"

logdir_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        HOME="$tmp/home"
        OSTYPE="$1"
        init_logging
        echo "${LOGFILE#"$tmp"/} $(test -d "$(dirname "$LOGFILE")" && echo dir-exists)"
    )
}
check "init_logging: Linux log under ~/.local/state" \
    "$(logdir_probe linux-gnu)" "home/.local/state/homebrew-restore.log dir-exists"
check "init_logging: macOS log under ~/Library/Logs" \
    "$(logdir_probe darwin24)" "home/Library/Logs/homebrew-restore.log dir-exists"

check "log with no LOGFILE prints to stdout only" \
    "$( (eval "$REAL_LOG_DEF"; LOGFILE=""; log hello) | sed 's/^\[[^]]*\] //')" "hello"
check "log appends to LOGFILE when set" \
    "$( (tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; eval "$REAL_LOG_DEF"; LOGFILE="$tmp/l"; log hello >/dev/null; sed 's/^\[[^]]*\] //' "$tmp/l") )" "hello"

workspace_probe() {
    (
        prepare_workspace
        ls -ld "$WORKDIR" | cut -c1-10
        echo "$WORKDIR" > "$1"
    )
}
ws_file="$(mktemp)"
check "prepare_workspace creates a private (0700) directory" "$(workspace_probe "$ws_file")" "drwx------"
check "prepare_workspace never assigns TMPDIR" "$( (unset TMPDIR; prepare_workspace; echo "${TMPDIR:-unset}") )" "unset"
check "the workspace is removed when the shell exits" \
    "$(test -e "$(cat "$ws_file")" && echo present || echo removed)" "removed"
rm -f "$ws_file"

# ---------------------------------------------------------------------------
# select_profile / resolve_source / install_packages / cleanup_packages
# ---------------------------------------------------------------------------
check "select_profile: PROFILE=developer" \
    "$( (PROFILE=developer; select_profile; echo "$BREWFILE") )" "Brewfile-developer"
check "select_profile: PROFILE=minimal" \
    "$( (PROFILE=minimal; select_profile; echo "$BREWFILE") )" "Brewfile-minimal"
check "select_profile: invalid PROFILE is fatal" \
    "$( (PROFILE=bastion; select_profile) )" "FATAL: Invalid PROFILE='bastion' (expected: developer or minimal)."
check "select_profile: no PROFILE and no tty is fatal" \
    "$( (select_profile) | cut -c1-39)" "FATAL: No profile selected and no inter"

check "resolve_source: the real checkout is used in local mode" \
    "$( (BOOTSTRAP_SCRIPT="$BOOTSTRAP"; BREWFILE=Brewfile-minimal; OS_TYPE=macos
         fetch_source_tarball() { echo "unexpected fetch"; }
         resolve_source; echo "$([[ "$SOURCE_DIR" == "$(cd "$SCRIPT_DIR/.." && pwd)" ]] && echo repo) ${BREWFILE_PATH##*/}") )" "repo Brewfile-minimal"
source_probe() {
    # $1 = with-brewfile | without-brewfile
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        WORKDIR="$tmp/w"
        BOOTSTRAP_SCRIPT=""     # piped: not a checkout
        OS_TYPE=macos           # skips the Linux package step
        BREWFILE=Brewfile-minimal
        MODE="$1"
        fetch_source_tarball() {
            echo "fetch -> ${1#"$tmp"/}"
            mkdir -p "$1/universal/brewfiles"
            if [[ "$MODE" == with-brewfile ]]; then touch "$1/universal/brewfiles/Brewfile-minimal"; fi
        }
        resolve_source
        echo "path -> ${BREWFILE_PATH#"$tmp"/}"
    )
}
check "resolve_source: piped script downloads the tarball into the workspace" \
    "$(source_probe with-brewfile | tr '\n' ' ')" "fetch -> w/source path -> w/source/universal/brewfiles/Brewfile-minimal "
check "resolve_source: a Brewfile missing from the source is fatal" \
    "$(source_probe without-brewfile | tail -n1 | cut -c1-22)" "FATAL: Brewfile not fo"

# brew stub that records its arguments, one call per line.
packages_probe() {
    (
        OS_TYPE=macos
        BREWFILE="$1"
        BREWFILE_PATH="/x/$1"
        calls=""
        brew() { calls="$calls brew:$1"; [[ "$1" != "update" ]] || return 1; }
        install_brewfile_packages() { calls="$calls bundle"; }
        install_tflint_linux() { calls="$calls tflint"; }
        log() { case "$*" in *"brew update failed"*) calls="$calls warned";; esac; }
        install_packages
        echo "$calls"
    )
}
check "install_packages: a failed brew update warns and continues (developer)" \
    "$(packages_probe Brewfile-developer)" " brew:update warned bundle tflint"
check "install_packages: tflint is only for the developer profile" \
    "$(packages_probe Brewfile-minimal)" " brew:update warned bundle"

cleanup_probe() {
    # $1 = CLEANUP value, $2 = preview text brew prints. brew runs inside a
    # command substitution for the preview, so calls are recorded in a file.
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        BREWFILE=Brewfile-minimal
        BREWFILE_PATH=/x/Brewfile-minimal
        CLEANUP="$1"
        PREVIEW="$2"
        brew() {
            case "$*" in
                *--force*) echo force >> "$tmp/calls" ;;
                *) echo preview >> "$tmp/calls"; printf '%s' "$PREVIEW" ;;
            esac
        }
        cleanup_packages
        tr '\n' ' ' < "$tmp/calls"
    )
}
check "cleanup_packages: empty preview means nothing to do (no removal)" \
    "$(cleanup_probe remove '')" "preview "
check "cleanup_packages: CLEANUP=remove removes after the preview" \
    "$(cleanup_probe remove 'Would uninstall formulae: foo')" "preview force "
check "cleanup_packages: CLEANUP=skip keeps everything" \
    "$(cleanup_probe skip 'Would uninstall formulae: foo')" "preview "
check "cleanup_packages: no tty and no preference keeps everything" \
    "$(cleanup_probe '' 'Would uninstall formulae: foo')" "preview "

# ---------------------------------------------------------------------------
# install_tflint_linux (network, unzip and install are stubbed)
# ---------------------------------------------------------------------------
tflint_probe() {
    # $1 = scenario setup, run inside the subshell after the common stubs.
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        WORKDIR="$tmp/work"; mkdir -p "$WORKDIR" "$tmp/prefix/bin"
        OS_TYPE=linux
        STATUS_PACKAGES="ok"
        urls=""
        uname() { echo x86_64; }
        # Pretend tflint is not installed, whatever the host has.
        command() { if [[ "${1:-}" == "-v" && "${2:-}" == "tflint" ]]; then return 1; fi; builtin command "$@"; }
        find_brew_prefix() { echo "$tmp/prefix"; }
        resolve_latest_release_tag() { echo v9.9.9; }
        curl() { urls="$urls ${4##*/}@$(basename "$(dirname "$4")")"; echo data > "$3"; }
        unzip() { mkdir -p "$5"; echo bin > "$5/tflint"; }
        verify_release_checksum() { return 0; }
        eval "$1"
        install_tflint_linux
        echo "status=$STATUS_PACKAGES installed=$(test -x "$tmp/prefix/bin/tflint" && echo yes || echo no)"
        echo "urls=$urls"
    )
}
check "install_tflint_linux: success installs from the resolved tag" \
    "$(tflint_probe ':' | tr '\n' ' ')" "status=ok installed=yes urls= tflint_linux_amd64.zip@v9.9.9 checksums.txt@v9.9.9 "
check "install_tflint_linux: unresolvable tag -> skip and mark incomplete" \
    "$(tflint_probe 'resolve_latest_release_tag() { return 1; }' | head -n1)" "status=incomplete installed=no"
check "install_tflint_linux: download failure -> skip and mark incomplete" \
    "$(tflint_probe 'curl() { return 22; }' | head -n1)" "status=incomplete installed=no"
check "install_tflint_linux: checksum mismatch -> not installed, marked incomplete" \
    "$(tflint_probe 'verify_release_checksum() { return 1; }' | head -n1)" "status=incomplete installed=no"
check "install_tflint_linux: unzip failure -> skip and mark incomplete" \
    "$(tflint_probe 'unzip() { return 1; }' | head -n1)" "status=incomplete installed=no"
check "install_tflint_linux: install failure -> mark incomplete" \
    "$(tflint_probe 'install() { return 1; }' | head -n1)" "status=incomplete installed=no"
check "install_tflint_linux: not touched on macOS" \
    "$(tflint_probe 'OS_TYPE=macos' | head -n1)" "status=ok installed=no"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "-----"
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
