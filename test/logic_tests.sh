#!/usr/bin/env bash
# Fast, deterministic unit tests for the pure helper functions in bootstrap.sh.
#
# bootstrap.sh interleaves top-level provisioning code with its function
# definitions and has no `main`/sourcing guard, so we cannot simply `source` it
# without triggering a real install. Instead each test extracts just the
# function(s) under test by name-range with sed and evaluates them in a
# subshell with log()/fatal() stubbed. This is the same isolation technique the
# functions were developed under; it needs no network, no Homebrew, and no TTY.
#
# Exits non-zero if any assertion fails, so CI can gate on it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/../bootstrap.sh"

pass=0
fail=0

# Extract a function definition (from `name() {` to its closing `}` at column 0)
# out of bootstrap.sh so it can be evaluated in isolation.
extract_fn() {
    sed -n "/^$1() {/,/^}/p" "$BOOTSTRAP"
}

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
# shell_for_os / shell_files_for  (PR #1: dotfile shell follows OS)
# ---------------------------------------------------------------------------
eval "$(extract_fn shell_for_os)"
eval "$(extract_fn shell_files_for)"

check "shell_for_os macos"       "$(shell_for_os macos)"                          "zsh"
check "shell_for_os linux"       "$(shell_for_os linux)"                          "bash"
check "files for macOS shell"    "$(shell_files_for "$(shell_for_os macos)")"     ".zshrc .zprofile"
check "files for linux shell"    "$(shell_files_for "$(shell_for_os linux)")"     ".bashrc .bash_environment"
check "files for unknown shell"  "$(shell_files_for fish)"                        ""

# ---------------------------------------------------------------------------
# brewfile_for_profile  (PR #2: non-interactive PROFILE selection)
# ---------------------------------------------------------------------------
eval "$(extract_fn brewfile_for_profile)"

check "profile developer"        "$(brewfile_for_profile developer)"              "Brewfile-developer"
check "profile minimal"          "$(brewfile_for_profile minimal)"                "Brewfile-minimal"
check "profile unknown"          "$(brewfile_for_profile bastion)"                ""
check "profile empty"            "$(brewfile_for_profile '')"                     ""

# ---------------------------------------------------------------------------
# print_summary exit code  (PR #3: honest end-of-run summary)
# Only unresolved package failures should flip the exit code; kept dotfiles and
# an un-personalized gitconfig are legitimate states that must NOT fail the run.
# ---------------------------------------------------------------------------
summary_rc() {
    local pkg="$1" dot="$2" git="$3"
    (
        log() { :; }
        # These are read by the eval'd print_summary below; shellcheck can't see
        # through the eval, hence the disable.
        # shellcheck disable=SC2034
        STATUS_PACKAGES="$pkg"
        # shellcheck disable=SC2034
        STATUS_DOTFILES="$dot"
        # shellcheck disable=SC2034
        STATUS_GITCONFIG="$git"
        eval "$(extract_fn print_summary)"
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
        eval "$(extract_fn is_identity_placeholder)"
        eval "$(extract_fn migrate_gitconfig_identity)"
        eval "$(extract_fn verify_git_identity)"
        eval "$(extract_fn personalize_gitconfig)"
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
        eval "$(extract_fn find_brew_prefix)"
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
    "$( (HOME=/h; eval "$(extract_fn brew_prefix_candidates)"; brew_prefix_candidates | tr '\n' ' ') )" \
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
        eval "$(extract_fn append_line_once)"
        eval "$(extract_fn setup_brew_path)"
        eval "$(extract_fn ensure_zprofile_brew)"
        eval "$(extract_fn warn_stale_brew_lines)"
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
        eval "$(extract_fn local_checkout_dir)"
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
    "$( (eval "$(extract_fn local_checkout_dir)"; local_checkout_dir "$BOOTSTRAP" >/dev/null && echo local) )" "local"

# unpack_source_tarball: build a codeload-style tarball (single top-level dir
# with an unpredictable name) and unpack it without knowing that name.
tarball_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        log() { :; }
        fatal() { echo "FATAL"; exit 1; }
        eval "$(extract_fn unpack_source_tarball)"
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
    "$(grep -c '^WORKDIR="\$(mktemp -d)"$' "$BOOTSTRAP")" "1"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "-----"
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
