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

check "brew shellenv runs before oh-my-posh init" \
    "$(before "$(line_of "$DEV_BASHENV" '^[[:space:]]*eval .*brew shellenv')" \
              "$(line_of "$DEV_BASHENV" '^[[:space:]]*eval .*oh-my-posh init bash')")" "yes"

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
# Summary
# ---------------------------------------------------------------------------
echo "-----"
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
