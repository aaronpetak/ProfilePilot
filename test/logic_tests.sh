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
# Summary
# ---------------------------------------------------------------------------
echo "-----"
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
