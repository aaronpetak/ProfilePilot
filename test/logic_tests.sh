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
check "files for linux shell"    "$(shell_files_for "$(shell_for_os linux)")"     ".bashrc"
check "files for unknown shell"  "$(shell_files_for fish)"                        ""
check "add-on name bash"         "$(shell_addon_name_for bash)"                   ".bashrc.developer"
check "add-on name zsh"          "$(shell_addon_name_for zsh)"                    ".zshrc.developer"
check "developer add-on bash"    "$(shell_addon_for profile-developer bash)"      ".bashrc.developer"
check "developer add-on zsh"     "$(shell_addon_for profile-developer zsh)"       ".zshrc.developer"
check "minimal has no add-on"    "$(shell_addon_for profile-minimal bash)"        ""

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

# $1 = STATUS_CLEANUP, $2 = BREW_ADDED_TO_PATH. Prints the Cleanup line, any
# PATH hint lines, and the exit status.
summary_cleanup() {
    (
        log() { echo "$*"; }
        STATUS_PACKAGES=ok STATUS_DOTFILES=applied STATUS_GITCONFIG=already
        BREWFILE=Brewfile-minimal
        STATUS_CLEANUP="$1"
        BREW_ADDED_TO_PATH="$2"
        out=$(print_summary); rc=$?
        printf '%s\n' "$out" | grep -E 'Cleanup:|PATH|shellenv' | sed 's/^ *//' | tr '\n' '|'
        echo "rc=$rc"
    )
}
check "summary: a failed cleanup is reported but does not fail the run" \
    "$(summary_cleanup failed '')" "Cleanup:   some removals failed; see the log above.|rc=0"
check "summary: an unreadable cleanup preview does not fail the run" \
    "$(summary_cleanup unreadable '' | cut -d'|' -f2)" "rc=0"
check "summary: cleanup not run reads 'not attempted'" \
    "$(summary_cleanup unknown '')" "Cleanup:   not attempted.|rc=0"
check "summary: no PATH hint when brew was already on the caller's PATH" \
    "$(summary_cleanup none '' | grep -c shellenv)" "0"
check "summary: a run that added brew to PATH says how to get it in this terminal" \
    "$(summary_cleanup none /home/linuxbrew/.linuxbrew/bin/brew | cut -d'|' -f2-)" \
    "brew is not on this terminal's PATH yet. Open a new terminal, or run:|eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"|rc=0"

# ---------------------------------------------------------------------------
# Linux developer prompt wiring  (oh-my-posh + PROMPT_COMMAND)
#
# `oh-my-posh init bash` stores its _omp_hook in a PROMPT_COMMAND *array*, and
# bash < 5.1 (4.4 ships on RHEL/Rocky/Alma 8) executes only element [0]. Two
# invariants keep the prompt rendering on a login shell there:
#   1. no PROMPT_COMMAND assignment may run after the init, and
#   2. the array must be flattened to a ';'-joined string right after it.
# ---------------------------------------------------------------------------
BASE_BASHRC="$SCRIPT_DIR/../linux/.bashrc"
DEV_ADDON="$SCRIPT_DIR/../linux/profile-developer/.bashrc.developer"
ADDON_SOURCE_RE='^[[:space:]]*\. ~/\.bashrc\.developer$'

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

check "bashrc sets PROMPT_COMMAND before sourcing the developer add-on" \
    "$(before "$(line_of "$BASE_BASHRC" "^PROMPT_COMMAND='history -a'$")" \
              "$(line_of "$BASE_BASHRC" "$ADDON_SOURCE_RE")")" "yes"
check "bashrc sets the fallback PS1 before sourcing the developer add-on" \
    "$(before "$(line_of "$BASE_BASHRC" "^PS1='")" \
              "$(line_of "$BASE_BASHRC" "$ADDON_SOURCE_RE")")" "yes"

# The add-on source must be the last PROMPT_COMMAND/PS1-relevant statement: no
# PROMPT_COMMAND or PS1 assignment below it, and nothing after it but the
# closing fi of its guard.
check "bashrc: no PROMPT_COMMAND or PS1 assignment after the add-on source" \
    "$(before "$(grep -nE '^[[:space:]]*(PROMPT_COMMAND|PS1)=' "$BASE_BASHRC" | tail -n1 | cut -d: -f1)" \
              "$(line_of "$BASE_BASHRC" "$ADDON_SOURCE_RE")")" "yes"
check "bashrc: the add-on source is its last statement" \
    "$(grep -vE '^[[:space:]]*(#|$)' "$BASE_BASHRC" | tail -n2 | sed -e 's/^[[:space:]]*//' | tr '\n' ' ')" \
    ". ~/.bashrc.developer fi "

# Homebrew is detected in .bashrc so it is on PATH before ~/.shell_aliases is
# sourced and before oh-my-posh is initialised (in the add-on).
check "bashrc detects brew before sourcing .shell_aliases" \
    "$(before "$(line_of "$BASE_BASHRC" '^[[:space:]]*eval .*shellenv bash')" \
              "$(line_of "$BASE_BASHRC" '^[[:space:]]*\. ~/\.shell_aliases$')")" "yes"
check "bashrc detects brew before sourcing the developer add-on" \
    "$(before "$(line_of "$BASE_BASHRC" '^[[:space:]]*eval .*shellenv bash')" \
              "$(line_of "$BASE_BASHRC" "$ADDON_SOURCE_RE")")" "yes"
check "developer add-on does not hardcode a Homebrew prefix" \
    "$(grep -c 'linuxbrew\|/opt/homebrew' "$DEV_ADDON")" "0"
check "bashrc no longer sources .bash_environment" \
    "$(grep -c '^[[:space:]]*\. ~/\.bash_environment' "$BASE_BASHRC")" "0"

# Behavioral: source the base .bashrc in an interactive shell with every system
# path redirected into a temp dir, so the result does not depend on this
# machine's git installation. $1 is shell code run in the temp dir first
# (e.g. to plant a fake git-prompt.sh); prints stderr noise, PS1, rendered PS1.
git_prompt_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/home"
        sed -e "s#/usr/#$tmp/usr/#g; s#/etc/#$tmp/etc/#g" "$BASE_BASHRC" > "$tmp/home/.bashrc"
        eval "$1"
        env -u HOMEBREW_PREFIX HOME="$tmp/home" bash --norc -i \
            -c '. ~/.bashrc; printf "%s\n%s\n" "$PS1" "${PS1@P}"' 2>"$tmp/err" | sed "s#$tmp#TMP#g"
        grep -v 'job control\|process group' "$tmp/err" | sed "s#$tmp#TMP#g"
    )
}
# The probe renders PS1 with ${PS1@P} (bash 4.4+) in the bash found on PATH,
# which is the interpreter it spawns, so the guard asks that same bash.
if bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' 2>/dev/null; then
    check "fallback prompt without git-prompt: plain PS1, no __git_ps1, no errors" \
        "$(git_prompt_probe ':' | head -n1)" '\u@\h:\w\$ '
    check "fallback prompt without git-prompt: nothing on stderr" \
        "$(git_prompt_probe ':' | tail -n +3)" ""
    check "fallback prompt with git-prompt: __git_ps1 evaluated per prompt (single-quoted)" \
        "$(git_prompt_probe 'mkdir -p "$tmp/usr/share/git-core/contrib/completion"
            echo "__git_ps1() { printf \" (%s)\" main; }" > "$tmp/usr/share/git-core/contrib/completion/git-prompt.sh"' | head -n1)" \
        '\u@\h:\w$(__git_ps1 " (%s)")\$ '
    check "fallback prompt with git-prompt: the helper's output appears in the rendered prompt" \
        "$(git_prompt_probe 'mkdir -p "$tmp/usr/share/git-core/contrib/completion"
            echo "__git_ps1() { printf \" (%s)\" main; }" > "$tmp/usr/share/git-core/contrib/completion/git-prompt.sh"' | sed -n 2p | sed 's/^[^ ]* //')" \
        "(main)$ "
else
    echo "SKIP: fallback prompt rendering checks need bash 4.4+ (PATH bash is older)"
fi
check "add-on no longer references __git_ps1" "$(grep -c '__git_ps1' "$DEV_ADDON")" "0"

# Behavioral: run the .bashrc detection loop with its candidates redirected to a
# temp dir holding a fake brew, and confirm the first existing one is evaluated.
brew_loop_result() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/b"
        printf '#!/bin/sh\necho "export PICKED=%s"\n' "$tmp/b" > "$tmp/b/brew"
        chmod +x "$tmp/b/brew"
        snippet="$(sed -n '/^for _brew in /,/^unset _brew$/p' "$BASE_BASHRC")"
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
MAC_ADDON="$MAC_DIR/profile-developer/.zshrc.developer"
check "macOS .zprofile uses shellenv zsh"         "$(grep -c 'shellenv zsh' "$MAC_DIR/.zprofile")" "1"
check "macOS .zprofile has no stray percent sign"         "$(grep -c '%$' "$MAC_DIR/.zprofile")" "0"
check "macOS .zshrc does not hardcode /opt/homebrew/share or /bin"         "$(grep -v '^[[:space:]]*#' "$MAC_DIR/.zshrc" | grep -c '/opt/homebrew/\(share\|bin/virtualenv\)')" "0"
check "macOS add-on does not hardcode /opt/homebrew/share or /bin"         "$(grep -v '^[[:space:]]*#' "$MAC_ADDON" | grep -c '/opt/homebrew/\(share\|bin/virtualenv\)')" "0"
check "macOS .zshrc sources the add-on last" \
    "$(grep -vE '^[[:space:]]*(#|$)' "$MAC_DIR/.zshrc" | tail -n3 | tr -s ' \n' ' ')" \
    'if [[ -f "$HOME/.zshrc.developer" ]]; then source "$HOME/.zshrc.developer" fi '
check "old profile-minimal directories are gone" \
    "$(ls -d "$MAC_DIR"/profile-minimal "$SCRIPT_DIR"/../linux/profile-minimal 2>/dev/null | wc -l | tr -d ' ')" "0"

check "PROMPT_COMMAND flatten sits after oh-my-posh init" \
    "$(before "$(line_of "$DEV_ADDON" '^[[:space:]]*eval .*oh-my-posh init bash')" \
              "$(line_of "$DEV_ADDON" '^[[:space:]]*if \[\[ .*declare -p PROMPT_COMMAND')")" "yes"

# The last PROMPT_COMMAND assignment in the file must be the flatten's own; any
# assignment below it would clobber the hook again on bash 4.4.
check "flatten is the last PROMPT_COMMAND assignment" \
    "$(grep -E '^[[:space:]]*PROMPT_COMMAND=' "$DEV_ADDON" | tail -n1 |
       sed -e 's/^[[:space:]]*//')" \
    'PROMPT_COMMAND="$_omp_prompt_command"'

# Behavioral check: run the flatten block itself against a bash 4.4-style
# array, exactly as oh-my-posh would have left it.
flatten() {
    (
        eval "$1"
        eval "$(sed -n '/if \[\[ "\$(declare -p PROMPT_COMMAND/,/^    fi$/p' "$DEV_ADDON")"
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
# $1 is the directory under ~/projects that holds the per-directory config.
includeif_name() {
    identity_env "mkdir -p \"\$HOME/projects/$1/repo\"
        git init -q \"\$HOME/projects/$1/repo\"
        git config --file \"\$HOME/.gitconfig.local\" user.name Local
        printf '[user]\n    name = PerDir\n' > \"\$HOME/projects/$1/.gitconfig\"
        cd \"\$HOME/projects/$1/repo\" && git config user.name"
}
check "includeIf identity for ~/projects/gh overrides .gitconfig.local" \
    "$(includeif_name gh)" "PerDir"
check "includeIf identity for ~/projects/ghe overrides .gitconfig.local" \
    "$(includeif_name ghe)" "PerDir"
check "the old ~/projects/github directory no longer selects an identity" \
    "$(includeif_name github)" "Local"
check ".gitconfig includes .gitconfig.local before any includeIf" \
    "$(grep -n 'gitconfig.local\|includeIf' "$GITCONFIG_SRC" | grep -v '^[0-9]*:#' | head -n1 | cut -d: -f2- | tr -d ' ')" \
    "path=~/.gitconfig.local"

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
check "missing_linux_packages: gawk:awk is satisfied by an awk without gawk" \
    "$(pkg_probe 'awk' gawk:awk)" ""
check "missing_linux_packages: gawk:awk reports gawk when neither exists" \
    "$(pkg_probe 'unzip' gawk:awk)" "gawk "
check "missing_linux_packages: diffutils:cmp reports diffutils when cmp is absent" \
    "$(pkg_probe 'unzip' diffutils:cmp)" "diffutils "
check "missing_linux_packages: diffutils:cmp is satisfied by cmp" \
    "$(pkg_probe 'cmp' diffutils:cmp)" ""
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
        test -e "$tmp/home/.local/state/profilepilot.log" -o -e "$tmp/home/Library/Logs/profilepilot.log" && echo "logged-in-temp-home"
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
    "$(logdir_probe linux-gnu)" "home/.local/state/profilepilot.log dir-exists"
check "init_logging: macOS log under ~/Library/Logs" \
    "$(logdir_probe darwin24)" "home/Library/Logs/profilepilot.log dir-exists"

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

check "the API tarball URL follows DOTFILES_REPO_SLUG and DOTFILES_REF" \
    "$(DOTFILES_REPO_SLUG=acme/dots DOTFILES_REF=v1.2.3 bash -c 'source "$1"; echo "$DOTFILES_API_TARBALL_URL"' _ "$BOOTSTRAP")" \
    "https://api.github.com/repos/acme/dots/tarball/v1.2.3"

# fetch_source_tarball with curl, gh, the prompt and unpacking stubbed. Prints
# the outcome ("unpacked" or the FATAL line), then one line per curl call:
# "<host> hdr=<header curl read on stdin> argv=<clean|TOKEN>". argv=TOKEN means a
# token appeared in curl's arguments, where a process listing would show it.
# "token logged" is printed if a token reached log().
# $1 = HTTP code of the anonymous request (000 = curl itself fails),
# $2 = exit status of the authenticated request, $3 = scenario setup.
# Every test token starts with "tok-".
fetch_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        WORKDIR="$tmp"
        DOTFILES_REPO_SLUG=o/r
        DOTFILES_REF=main
        DOTFILES_TARBALL_URL=https://codeload.github.com/o/r/tar.gz/main
        DOTFILES_API_TARBALL_URL=https://api.github.com/repos/o/r/tarball/main
        unset GH_TOKEN GITHUB_TOKEN
        ANON="$1" AUTH="$2"
        log() { printf '%s\n' "$*" >> "$tmp/log"; }
        unpack_source_tarball() { echo "unpacked"; }
        gh() { return 1; }    # installed but not logged in
        reset_tty() { :; }
        ask_secret() { echo "unexpected prompt" >> "$tmp/calls"; }
        curl() {
            local arg url="" hdr="" argv=clean
            for arg in "$@"; do
                case "$arg" in https://*) url="${arg#https://}" ;; esac
                case "$arg" in *tok-*) argv=TOKEN ;; esac
            done
            case " $* " in *" -H @- "*) hdr="$(cat)" ;; esac
            echo "${url%%/*} hdr=${hdr:-none} argv=$argv" >> "$tmp/calls"
            if [[ "$url" == codeload.* ]]; then
                if [[ "$ANON" == 000 ]]; then
                    echo "curl: (6) Could not resolve host: codeload.github.com" >&2
                    printf '000'
                    return 6
                fi
                printf '%s' "$ANON"
                return 0
            fi
            return "$AUTH"
        }
        eval "$3"
        ( fetch_source_tarball "$tmp/out" )
        cat "$tmp/calls"
        if grep -q 'tok-' "$tmp/log"; then echo "token logged"; fi
    )
}
ANON_CALL="codeload.github.com hdr=none argv=clean"

check "fetch: a public repo downloads anonymously, even when a token is set" \
    "$(fetch_probe 200 0 'GH_TOKEN=tok-env' | tr '\n' ' ')" \
    "unpacked $ANON_CALL "
check "fetch: a 404 retries through the API with GH_TOKEN, sent on stdin" \
    "$(fetch_probe 404 0 'GH_TOKEN=tok-gh; GITHUB_TOKEN=tok-github' | tr '\n' ' ')" \
    "unpacked $ANON_CALL api.github.com hdr=Authorization: Bearer tok-gh argv=clean "
check "fetch: GITHUB_TOKEN is used when GH_TOKEN is unset" \
    "$(fetch_probe 404 0 'GITHUB_TOKEN=tok-github' | tr '\n' ' ')" \
    "unpacked $ANON_CALL api.github.com hdr=Authorization: Bearer tok-github argv=clean "
check "fetch: a logged-in gh CLI supplies the token" \
    "$(fetch_probe 404 0 'gh() { [[ "$*" == "auth token" ]] && echo tok-cli; }' | tr '\n' ' ')" \
    "unpacked $ANON_CALL api.github.com hdr=Authorization: Bearer tok-cli argv=clean "
check "fetch: with no other token, a terminal prompt supplies it" \
    "$(fetch_probe 404 0 'tty_available() { return 0; }; ask_secret() { echo tok-typed; }' | tr '\n' ' ')" \
    "unpacked $ANON_CALL api.github.com hdr=Authorization: Bearer tok-typed argv=clean "
check "fetch: an environment token wins over gh and the prompt" \
    "$(fetch_probe 404 0 'GITHUB_TOKEN=tok-github; gh() { echo tok-cli; }; tty_available() { return 0; }; ask_secret() { echo tok-typed; }' | tr '\n' ' ')" \
    "unpacked $ANON_CALL api.github.com hdr=Authorization: Bearer tok-github argv=clean "
check "fetch: a 404 with no token and no terminal is fatal and names GH_TOKEN" \
    "$(fetch_probe 404 0 '' | tr '\n' ' ')" \
    "FATAL: Failed to download https://codeload.github.com/o/r/tar.gz/main (HTTP 404). If o/r is private, set GH_TOKEN to a GitHub token that can read it; otherwise check DOTFILES_REPO_SLUG and DOTFILES_REF. $ANON_CALL "
check "fetch: an empty answer at the prompt is fatal" \
    "$(fetch_probe 404 0 'tty_available() { return 0; }; ask_secret() { echo; }' | tr '\n' ' ')" \
    "FATAL: Failed to download https://codeload.github.com/o/r/tar.gz/main (HTTP 404). If o/r is private, set GH_TOKEN to a GitHub token that can read it; otherwise check DOTFILES_REPO_SLUG and DOTFILES_REF. $ANON_CALL "
check "fetch: a failed token download is fatal" \
    "$(fetch_probe 404 22 'GH_TOKEN=tok-gh' | tr '\n' ' ')" \
    "FATAL: Failed to download o/r @ main with the GitHub token. Check that the token can read the repository and that the ref exists. $ANON_CALL api.github.com hdr=Authorization: Bearer tok-gh argv=clean "
check "fetch: a network failure is fatal, shows curl's error and asks for no token" \
    "$(fetch_probe 000 0 'GH_TOKEN=tok-gh; tty_available() { return 0; }' | tr '\n' ' ')" \
    "FATAL: Failed to download https://codeload.github.com/o/r/tar.gz/main: curl: (6) Could not resolve host: codeload.github.com $ANON_CALL "
check "fetch: an HTTP error other than 404 is fatal without a token retry" \
    "$(fetch_probe 500 0 'GH_TOKEN=tok-gh' | tr '\n' ' ')" \
    "FATAL: Failed to download https://codeload.github.com/o/r/tar.gz/main (HTTP 500). $ANON_CALL "

# brew stub that records its arguments, one call per line.
packages_probe() {
    (
        OS_TYPE=macos
        BREWFILE="$1"
        BREWFILE_PATH="/x/$1"
        calls=""
        brew() { calls="$calls brew:$1"; [[ "$1" != "update" ]] || return 1; }
        migrate_superseded_packages() { calls="$calls migrate"; }
        install_brewfile_packages() { calls="$calls bundle"; }
        install_tflint_linux() { calls="$calls tflint"; }
        log() { case "$*" in *"brew update failed"*) calls="$calls warned";; esac; }
        install_packages
        echo "$calls"
    )
}
check "install_packages: a failed brew update warns and continues (developer)" \
    "$(packages_probe Brewfile-developer)" " brew:update warned migrate bundle tflint"
check "install_packages: tflint is only for the developer profile" \
    "$(packages_probe Brewfile-minimal)" " brew:update warned migrate bundle"

# ---------------------------------------------------------------------------
# migrate_superseded_packages (old tldr keg, oh-my-posh from the old tap)
# ---------------------------------------------------------------------------
# $1 = Brewfile lines (\n-separated), $2 = `brew list --formula --full-name`
# output, $3 = space-separated brew subcommands that fail. Prints the brew calls
# (other than the listing) and "returned", run under set -e to prove no failure
# aborts the run.
migrate_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        printf '%b\n' "$1" > "$tmp/Brewfile"
        export INSTALLED="$2" FAILING=" ${3:-} "
        brew() {
            if [[ "$1" == "list" ]]; then printf '%s\n' "$INSTALLED"; return 0; fi
            echo "$*" >> "$tmp/calls"
            [[ "$FAILING" != *" $1 "* ]]
        }
        set -e
        migrate_superseded_packages "$tmp/Brewfile"
        echo "returned" >> "$tmp/calls"
        tr '\n' '|' < "$tmp/calls"
    )
}
DEV_LINES='brew "tlrc"\nbrew "oh-my-posh"'
check "migrate: an old tldr keg is unlinked when the Brewfile wants tlrc" \
    "$(migrate_probe "$DEV_LINES" $'git\ntldr')" "unlink tldr|returned|"
check "migrate: a tldr keg from a tap is unlinked too" \
    "$(migrate_probe "$DEV_LINES" 'someone/tap/tldr')" "unlink tldr|returned|"
check "migrate: no tldr keg, nothing to do" \
    "$(migrate_probe "$DEV_LINES" $'git\ntlrc\noh-my-posh')" "returned|"
check "migrate: a Brewfile without tlrc leaves tldr alone" \
    "$(migrate_probe 'brew "git"' 'tldr')" "returned|"
check "migrate: a failed unlink warns and continues" \
    "$(migrate_probe "$DEV_LINES" 'tldr' 'unlink')" "unlink tldr|returned|"
check "migrate: oh-my-posh from the old tap is replaced by homebrew-core's" \
    "$(migrate_probe "$DEV_LINES" 'jandedobbeleer/oh-my-posh/oh-my-posh')" \
    "fetch --formula homebrew/core/oh-my-posh|uninstall --formula oh-my-posh|install --formula homebrew/core/oh-my-posh|returned|"
check "migrate: a failed download keeps the tap's oh-my-posh installed" \
    "$(migrate_probe "$DEV_LINES" 'jandedobbeleer/oh-my-posh/oh-my-posh' 'fetch')" \
    "fetch --formula homebrew/core/oh-my-posh|returned|"
check "migrate: a failed uninstall stops before installing" \
    "$(migrate_probe "$DEV_LINES" 'jandedobbeleer/oh-my-posh/oh-my-posh' 'uninstall')" \
    "fetch --formula homebrew/core/oh-my-posh|uninstall --formula oh-my-posh|returned|"
check "migrate: oh-my-posh already from homebrew-core is left alone" \
    "$(migrate_probe "$DEV_LINES" 'oh-my-posh')" "returned|"
check "migrate: a Brewfile without oh-my-posh leaves the tap's copy alone" \
    "$(migrate_probe 'brew "git"' 'jandedobbeleer/oh-my-posh/oh-my-posh')" "returned|"

# ---------------------------------------------------------------------------
# parse_cleanup_preview / cleanup_packages
# ---------------------------------------------------------------------------
# A preview in the format Homebrew prints when stdout is not a terminal.
PREVIEW_FULL=$'Would uninstall casks:\nfont-x\nWould uninstall formulae:\nfoo\nuser/tap/bar\nWould untap:\njandedobbeleer/oh-my-posh\nWould `brew cleanup`:\nWould remove: /cache/foo--1.0.bottle.tar.gz (1.2MB)\nRun `brew bundle cleanup --force` to make these changes.'
check "parse_cleanup_preview: reads the casks, formulae and taps sections" \
    "$(parse_cleanup_preview "$PREVIEW_FULL" | tr '\n' '|')" \
    "cask font-x|formula foo|formula user/tap/bar|tap jandedobbeleer/oh-my-posh|"
check "parse_cleanup_preview: terminal-style columns are split into names" \
    "$(parse_cleanup_preview $'Would uninstall formulae:\nfoo   bar' | tr '\n' '|')" "formula foo|formula bar|"
check "parse_cleanup_preview: other sections and the hint are skipped" \
    "$(parse_cleanup_preview $'Would uninstall npm packages:\nleftpad\nWould `brew cleanup`:\nWould remove: /x (1MB)\nRun `brew bundle cleanup --force` to make these changes.'; echo "rc=$?")" "rc=0"
check "parse_cleanup_preview: a non-name inside a known section fails" \
    "$(parse_cleanup_preview $'Would uninstall formulae:\nError: No available formula'; echo "rc=$?")" "rc=1"

# $1 = CLEANUP, $2 = preview stdout, $3 = preview stderr, $4 = preview exit
# status, $5 = exit status of the forced cleanup. Runs under set -e and prints
# the brew calls, the logged list lines, STATUS_CLEANUP and "returned".
cleanup_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        WORKDIR="$tmp"
        BREWFILE=Brewfile-minimal
        BREWFILE_PATH=/x/Brewfile-minimal
        CLEANUP="$1"
        export PREVIEW="$2" PREVIEW_ERR="$3" PREVIEW_RC="${4:-0}" FORCE_RC="${5:-0}"
        log() { echo "$*" >> "$tmp/log"; }
        brew() {
            case "$*" in
                *--force*) echo "force" >> "$tmp/calls"; return "$FORCE_RC" ;;
                *) echo "preview: $*" >> "$tmp/calls"
                   printf '%s' "$PREVIEW"; printf '%s' "$PREVIEW_ERR" >&2
                   return "$PREVIEW_RC" ;;
            esac
        }
        set -e
        cleanup_packages
        {
            cat "$tmp/calls"
            grep '^  ' "$tmp/log" || true
            echo "status=$STATUS_CLEANUP"
            echo "returned"
        } | tr '\n' '|'
    )
}
ONE_FORMULA=$'Would uninstall formulae:\nfoo\nRun `brew bundle cleanup --force` to make these changes.'
check "cleanup: the preview is limited to formulae, casks and taps" \
    "$(cleanup_probe skip '' '' 0 | cut -d'|' -f1)" \
    "preview: bundle cleanup --file=/x/Brewfile-minimal --formula --cask --tap"
check "cleanup: an empty preview means nothing to do" \
    "$(cleanup_probe remove '' '' 0 | cut -d'|' -f2-)" "status=none|returned|"
check "cleanup: CLEANUP=remove removes after the preview" \
    "$(cleanup_probe remove "$ONE_FORMULA" '' 1 0 | cut -d'|' -f2-)" "force|  formula: foo|status=removed|returned|"
check "cleanup: a failed removal is reported, not fatal" \
    "$(cleanup_probe remove "$ONE_FORMULA" '' 1 1 | cut -d'|' -f2-)" "force|  formula: foo|status=failed|returned|"
check "cleanup: CLEANUP=skip keeps everything" \
    "$(cleanup_probe skip "$ONE_FORMULA" '' 1 | cut -d'|' -f2-)" "  formula: foo|status=kept|returned|"
check "cleanup: no tty and no preference keeps everything" \
    "$(cleanup_probe '' "$ONE_FORMULA" '' 1 | cut -d'|' -f2-)" "  formula: foo|status=kept|returned|"
check "cleanup: stderr progress and warnings are never listed as packages" \
    "$(cleanup_probe skip $'Would untap:\njandedobbeleer/oh-my-posh' $'==> Downloading Homebrew API data\nWarning: Skipping oh-my-posh: tap formula is not trusted\n' 1 | cut -d'|' -f2-)" \
    "  tap: jandedobbeleer/oh-my-posh|status=kept|returned|"
check "cleanup: a Homebrew error with nothing listed removes nothing" \
    "$(cleanup_probe remove '' $'Error: No available formula with the name "tldr".\n' 1 | cut -d'|' -f2-)" \
    "  Error: No available formula with the name \"tldr\".|status=unreadable|returned|"
check "cleanup: an unreadable preview removes nothing" \
    "$(cleanup_probe remove $'Would uninstall formulae:\n!!garbage' '' 1 | cut -d'|' -f2-)" \
    "  Would uninstall formulae:|  !!garbage|status=unreadable|returned|"
check "cleanup: only a 'brew cleanup' section means nothing to remove" \
    "$(cleanup_probe remove $'Would `brew cleanup`:\nWould remove: /x (1MB)\nRun `brew bundle cleanup --force` to make these changes.' '' 0 | cut -d'|' -f2-)" \
    "status=none|returned|"
check "cleanup: the forced removal cannot read the terminal (no second prompt)" \
    "$(grep -c 'brew_bundle_cleanup --force </dev/null' "$BOOTSTRAP")" "1"

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
# Base + developer add-on: staging and applying  (temp HOME and source tree)
# ---------------------------------------------------------------------------
# Runs a snippet with HOME, SOURCE_DIR and WORKDIR pointing into a temp dir
# holding a minimal source tree for both OSes.
addon_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        HOME="$tmp/home"; SOURCE_DIR="$tmp/src"; WORKDIR="$tmp/work"
        RUN_TS="TS"; OS_TYPE=linux
        mkdir -p "$HOME" "$WORKDIR" "$SOURCE_DIR/universal" "$SOURCE_DIR/linux/profile-developer" \
                 "$SOURCE_DIR/macos/profile-developer"
        echo base > "$SOURCE_DIR/linux/.bashrc"
        echo addon > "$SOURCE_DIR/linux/profile-developer/.bashrc.developer"
        echo zbase > "$SOURCE_DIR/macos/.zshrc"; echo zprof > "$SOURCE_DIR/macos/.zprofile"
        echo zaddon > "$SOURCE_DIR/macos/profile-developer/.zshrc.developer"
        echo aliases > "$SOURCE_DIR/universal/.shell_aliases"
        eval "$1"
    )
}
listing() { (cd "$1" && ls -A | tr '\n' ' '); }

check "stage_dotfiles: linux developer stages base + add-on" \
    "$(addon_probe 'stage_dotfiles profile-developer linux; listing "$WORKDIR/dotfiles-linux-profile-developer"')" \
    ".bashrc .bashrc.developer .shell_aliases "
check "stage_dotfiles: linux minimal stages only the base" \
    "$(addon_probe 'stage_dotfiles profile-minimal linux; listing "$WORKDIR/dotfiles-linux-profile-minimal"')" \
    ".bashrc .shell_aliases "
check "stage_dotfiles: macOS developer stages base + add-on" \
    "$(addon_probe 'OS_TYPE=macos; stage_dotfiles profile-developer macos; listing "$WORKDIR/dotfiles-macos-profile-developer"')" \
    ".shell_aliases .zprofile .zshrc .zshrc.developer "
check "apply_dotfiles: developer installs base + add-on" \
    "$(addon_probe 'stage_dotfiles profile-developer linux; apply_dotfiles profile-developer bash linux; listing "$HOME"')" \
    ".bashrc .bashrc.developer .shell_aliases "

# Stale add-on when applying minimal.
stale_probe() {  # $1 conflict mode, $2 add-on name, $3 shell, $4 os
    addon_probe "DOTFILES_CONFLICT=$1; OS_TYPE=$4
        stage_dotfiles profile-minimal $4 >/dev/null; echo old > \"\$HOME/$2\"
        apply_dotfiles profile-minimal $3 $4
        echo \"status=\$STATUS_DOTFILES\"; listing \"\$HOME\""
}
check "stale add-on, overwrite mode: retired to a timestamped backup" \
    "$(stale_probe overwrite .bashrc.developer bash linux | tr '\n' ' ')" \
    "status=applied .bashrc .bashrc.developer.bak.TS .shell_aliases "
check "stale add-on, skip mode: kept and reported as kept" \
    "$(stale_probe skip .bashrc.developer bash linux | tr '\n' ' ')" \
    "status=kept .bashrc .bashrc.developer .shell_aliases "
check "stale zsh add-on, overwrite mode: retired" \
    "$(stale_probe overwrite .zshrc.developer zsh macos | tr '\n' ' ')" \
    "status=applied .shell_aliases .zprofile .zshrc .zshrc.developer.bak.TS "
check "stale add-on: developer profile does not treat its add-on as stale" \
    "$(addon_probe 'DOTFILES_CONFLICT=skip; stage_dotfiles profile-developer linux >/dev/null; apply_dotfiles profile-developer bash linux; echo "status=$STATUS_DOTFILES"' | tail -n1)" \
    "status=applied"

# Dangling symlinks occupy their path: a conflict, not a missing file.
dangling_probe() {  # $1 conflict mode
    addon_probe "DOTFILES_CONFLICT=$1
        stage_dotfiles profile-minimal linux >/dev/null
        ln -s \"\$HOME/nowhere\" \"\$HOME/.bashrc\"
        apply_dotfiles profile-minimal bash linux
        echo \"status=\$STATUS_DOTFILES\"
        for f in .bashrc .bashrc.bak.TS; do
            if [[ -L \"\$HOME/\$f\" ]]; then echo \"\$f=link\"; elif [[ -f \"\$HOME/\$f\" ]]; then echo \"\$f=file:\$(cat \"\$HOME/\$f\")\"; else echo \"\$f=absent\"; fi
        done"
}
check "dangling symlink, overwrite mode: the link is moved aside, profile file installed" \
    "$(dangling_probe overwrite | tr '\n' ' ')" \
    "status=applied .bashrc=file:base .bashrc.bak.TS=link "
check "dangling symlink, skip mode: the link is kept and reported as kept" \
    "$(dangling_probe skip | tr '\n' ' ')" \
    "status=kept .bashrc=link .bashrc.bak.TS=absent "

# Legacy ~/.bash_environment: noted in the log, never deleted.
check "legacy .bash_environment: noted, left in place" \
    "$(addon_probe 'log() { echo "LOG: $*"; }; stage_dotfiles profile-minimal linux >/dev/null; echo x > "$HOME/.bash_environment"
        apply_dotfiles profile-minimal bash linux | grep -c "bash_environment is no longer sourced"; test -f "$HOME/.bash_environment" && echo kept' | tr '\n' ' ')" \
    "1 kept "
check "no legacy note when .bash_environment is absent" \
    "$(addon_probe 'log() { echo "LOG: $*"; }; stage_dotfiles profile-minimal linux >/dev/null
        apply_dotfiles profile-minimal bash linux | grep -c "bash_environment"')" "0"

# ---------------------------------------------------------------------------
# .shell_aliases: here and tf_init check for their tool when called
# ---------------------------------------------------------------------------
ALIASES="$SCRIPT_DIR/../universal/.shell_aliases"
# Run a snippet in a fresh interactive-style shell ($1 = shell) that sources
# .shell_aliases first, in an empty temp dir. A stub directory $tmp/bin holds
# whatever commands the snippet creates; PATH is only that plus the system dirs.
aliases_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/bin" "$tmp/work"
        cd "$tmp/work" || exit 1
        # PATH keeps system dirs for coreutils; the tools under test are never there.
        TMP="$tmp" ALIASES="$ALIASES" PATH="$tmp/bin:/usr/bin:/bin" "$(command -v "$1")" -c ". \"\$ALIASES\"; $2" 2>&1 | sed "s#$tmp#TMP#g"
    )
}
for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not installed"; continue; }
    check "$sh: here without mkvirtualenv prints an error and fails" \
        "$(aliases_probe "$sh" 'here; echo "rc=$?"' | tr '\n' ' ')" \
        "here: mkvirtualenv not found (install virtualenvwrapper and load virtualenvwrapper.sh). rc=1 "
    check "$sh: here finds mkvirtualenv defined after the aliases were sourced" \
        "$(aliases_probe "$sh" 'mkvirtualenv() { echo "mk $*"; }; here myenv; echo "rc=$?"' | sed "s#$PWD#PWD#" | tr '\n' ' ')" \
        "mk -a TMP/work myenv rc=0 "
    check "$sh: here replaces an older alias of the same name" \
        "$(aliases_probe "$sh" 'alias here="echo shadow"; . "$ALIASES"; alias here 2>/dev/null | wc -l | tr -d " "; type here | head -n1 | grep -c function' | tr '\n' ' ')" "0 1 "
    check "$sh: tf_init without terraform prints an error, creates nothing" \
        "$(aliases_probe "$sh" 'tf_init; echo "rc=$?"; ls | wc -l | tr -d " "' | tr '\n' ' ')" \
        "tf_init: terraform not found on PATH. rc=1 0 "
    check "$sh: tf_init with terraform creates the standard files" \
        "$(aliases_probe "$sh" 'printf "#!/bin/sh\n" > "$TMP/bin/terraform"; chmod +x "$TMP/bin/terraform"; tf_init >/dev/null; LC_ALL=C ls | tr "\n" " "')" \
        "README.md backend.tf locals.tf main.tf outputs.tf providers.tf terraform.tf variables.tf "
    check "$sh: tf_init creates a README skeleton when absent" \
        "$(aliases_probe "$sh" 'printf "#!/bin/sh\n" > "$TMP/bin/terraform"; chmod +x "$TMP/bin/terraform"; tf_init >/dev/null; head -n1 README.md')" "# work"
    check "$sh: tf_init never overwrites an existing README" \
        "$(aliases_probe "$sh" 'printf "#!/bin/sh\n" > "$TMP/bin/terraform"; chmod +x "$TMP/bin/terraform"; echo mine > README.md; tf_init >/dev/null; cat README.md; ls | wc -l | tr -d " "' | tr '\n' ' ')" \
        "mine 8 "
done

# get: pulls origin's default branch (needs git; real PATH, temp HOME and config)
# Builds a bare origin whose default branch is "trunk" with one commit, plus
# three working repos: a clone (origin/HEAD set), an init + remote add + fetch
# repo (no origin/HEAD), and one with no origin. A second commit is then added
# to the origin. Runs $2 in $1's shell inside the repo named by $3
# (clone|nohead|noorigin) and prints its output with temp paths masked.
get_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
        mkdir -p "$HOME"
        git init -q --bare -b trunk "$tmp/origin.git"
        git init -q -b trunk "$tmp/seed"
        git -C "$tmp/seed" remote add origin "$tmp/origin.git"
        echo 1 > "$tmp/seed/f"; git -C "$tmp/seed" add f; git -C "$tmp/seed" commit -q -m one
        git -C "$tmp/seed" push -q origin trunk
        git clone -q "$tmp/origin.git" "$tmp/clone"
        git init -q -b trunk "$tmp/noorigin"
        git init -q -b trunk "$tmp/nohead"
        git -C "$tmp/nohead" remote add origin "$tmp/origin.git"
        git -C "$tmp/nohead" fetch -q origin
        echo 2 > "$tmp/seed/f"; git -C "$tmp/seed" commit -q -am two
        git -C "$tmp/seed" push -q origin trunk
        cd "$tmp/$3" || exit 1
        ALIASES="$ALIASES" "$(command -v "$1")" -c ". \"\$ALIASES\"; $2" 2>&1 | sed "s#$tmp#TMP#g"
    )
}
for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    check "$sh: get in a clone pulls the default branch" \
        "$(get_probe "$sh" 'get >/dev/null 2>&1; echo "rc=$?"; git log --format=%s | tr "\n" ","' clone)" \
        "rc=0
two,one,"
    check "$sh: get without origin/HEAD asks the remote and pulls" \
        "$(get_probe "$sh" 'get >/dev/null 2>&1; echo "rc=$?"; git symbolic-ref --short refs/remotes/origin/HEAD; git log --format=%s | tr "\n" ","' nohead)" \
        "rc=0
origin/trunk
two,one,"
    check "$sh: get with no origin prints an error and fails" \
        "$(get_probe "$sh" 'get; echo "rc=$?"' noorigin)" \
        "get: cannot determine origin's default branch (is there an origin remote?).
rc=1"
    check "$sh: get replaces an older alias of the same name" \
        "$(aliases_probe "$sh" 'alias get="echo shadow"; . "$ALIASES"; alias get 2>/dev/null | wc -l | tr -d " "; type get | head -n1 | grep -c function' | tr '\n' ' ')" "0 1 "
done

# Editor selection: the block in each base rc, run with a stubbed PATH.
# $1 shell, $2 rc file, $3 space-separated stub commands to create,
# $4 extra env assignments. Prints "EDITOR|VISUAL".
editor_probe() {
    (
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/bin"
        for c in $3; do printf '#!/bin/sh\n' > "$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
        block="$(sed -n '/^# Default editor, unless/,/^export VISUAL/p' "$2")"
        # shellcheck disable=SC2086  # $4 is a list of NAME=value words.
        env -i PATH="$tmp/bin" $4 "$(command -v "$1")" -c "$block; printf '%s|%s' \"\$EDITOR\" \"\$VISUAL\""
    )
}
for sh_rc in "bash:$SCRIPT_DIR/../linux/.bashrc" "zsh:$SCRIPT_DIR/../macos/.zshrc"; do
    sh="${sh_rc%%:*}"; rc="${sh_rc#*:}"
    command -v "$sh" >/dev/null 2>&1 || continue
    check "$sh editor: code present, not SSH -> code --wait" \
        "$(editor_probe "$sh" "$rc" "code vim" "")" "code --wait|code --wait"
    check "$sh editor: code present over SSH_CONNECTION -> vim" \
        "$(editor_probe "$sh" "$rc" "code vim" "SSH_CONNECTION=1.2.3.4")" "vim|vim"
    check "$sh editor: code present over SSH_TTY -> vim" \
        "$(editor_probe "$sh" "$rc" "code vim" "SSH_TTY=/dev/pts/1")" "vim|vim"
    check "$sh editor: no code -> vim" \
        "$(editor_probe "$sh" "$rc" "vim" "")" "vim|vim"
    check "$sh editor: neither code nor vim -> vi" \
        "$(editor_probe "$sh" "$rc" "" "")" "vi|vi"
    check "$sh editor: preset EDITOR is kept, VISUAL follows it" \
        "$(editor_probe "$sh" "$rc" "code vim" "EDITOR=nano")" "nano|nano"
    check "$sh editor: preset VISUAL is kept" \
        "$(editor_probe "$sh" "$rc" "vim" "VISUAL=emacs")" "vim|emacs"
done
check "gitconfig no longer sets core.editor" \
    "$(grep -c 'editor' "$SCRIPT_DIR/../universal/.gitconfig")" "0"
check "macOS developer add-on no longer exports EDITOR" \
    "$(grep -c 'EDITOR' "$SCRIPT_DIR/../macos/profile-developer/.zshrc.developer")" "0"

# ---------------------------------------------------------------------------
# Shared helpers: to_lower, detect_pkg_manager, pkg_install, ask_choice
# ---------------------------------------------------------------------------
check "to_lower lowercases" "$(to_lower 'Hello WORLD-1')" "hello world-1"
check "to_lower of empty is empty" "$(to_lower '')" ""
check "bootstrap.sh has no A-Z / a-z tr ranges" "$(grep -c "tr 'A-Z'" "$BOOTSTRAP")" "0"

# Runs $2 with stub package managers named in $1 on PATH (nothing else but the
# stub dir). run_as_root records its arguments to $tmp/calls and, for an install,
# creates a gcc stub so install_build_tools sees its toolchain; when $3 is "group"
# an install that mentions "group" fails, to exercise the explicit-package
# fallback. Prints the recorded calls, one per line, after the snippet's output.
pm_probe() {
    (
        tmp="$(mktemp -d)"
        old_path="$PATH"; mode="${3:-}"
        trap 'PATH="$old_path"; rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/bin"
        # Only the stubs and the few tools the snippets themselves use are on PATH.
        for c in cat rm chmod; do ln -s "$(command -v "$c")" "$tmp/bin/$c"; done
        for c in $1; do printf '#!/bin/sh\n' > "$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
        : > "$tmp/calls"
        PKG_MANAGER=""; APT_UPDATED=""; OS_TYPE=linux
        fatal() { echo "FATAL: $*"; exit 1; }
        run_as_root() {
            echo "$*" >> "$tmp/calls"
            if [[ "$*" == *group* && "$mode" == "group" ]]; then return 1; fi
            if [[ "$*" == *install* ]]; then printf '#!/bin/sh\n' > "$tmp/bin/gcc"; chmod +x "$tmp/bin/gcc"; fi
            return 0
        }
        PATH="$tmp/bin"
        eval "$2"
        echo "--"
        cat "$tmp/calls"
    )
}
check "detect_pkg_manager: apt-get only" \
    "$(pm_probe 'apt-get' 'detect_pkg_manager' | tr '\n' '|')" "apt-get|--|"
check "detect_pkg_manager: dnf wins over apt-get" \
    "$(pm_probe 'apt-get dnf' 'detect_pkg_manager' | head -n1)" "dnf"
check "detect_pkg_manager: pacman, then zypper" \
    "$(pm_probe 'pacman' 'detect_pkg_manager' | head -n1) $(pm_probe 'zypper' 'detect_pkg_manager' | head -n1)" "pacman zypper"
check "detect_pkg_manager: none is fatal" \
    "$(pm_probe '' 'detect_pkg_manager' 2>&1 | head -n1)" \
    "FATAL: No supported package manager found (tried dnf, apt-get, pacman, zypper)"
check "detect_pkg_manager: result is cached" \
    "$(pm_probe 'apt-get' 'detect_pkg_manager >/dev/null; rm "$tmp/bin/apt-get"; detect_pkg_manager' | head -n1)" "apt-get"
check "pkg_install apt-get: one update before the first install only" \
    "$(pm_probe 'apt-get' 'pkg_install a b; pkg_install c' | tr '\n' '|')" \
    "--|apt-get update|apt-get install -y a b|apt-get install -y c|"
check "pkg_install dnf" \
    "$(pm_probe 'dnf' 'pkg_install a b' | tr '\n' '|')" "--|dnf install -y a b|"
check "pkg_install pacman: full upgrade transaction" \
    "$(pm_probe 'pacman' 'pkg_install a' | tr '\n' '|')" "--|pacman -Syu --needed --noconfirm a|"
check "pkg_install zypper: refresh then install" \
    "$(pm_probe 'zypper' 'pkg_install a' | tr '\n' '|')" "--|zypper refresh|zypper install -y a|"
check "ensure_linux_packages routes through pkg_install (apt-get)" \
    "$(pm_probe 'apt-get' 'ensure_linux_packages definitely-missing-a' | tr '\n' '|')" \
    "--|apt-get update|apt-get install -y definitely-missing-a|"
check "install_build_tools on apt: update runs before build-essential" \
    "$(pm_probe 'apt-get' 'ensure_linux_packages() { :; }; install_build_tools' | tr '\n' '|')" \
    "--|apt-get update|apt-get install -y build-essential|"
check "install_build_tools on dnf: group install" \
    "$(pm_probe 'dnf' 'ensure_linux_packages() { :; }; install_build_tools' | tr '\n' '|')" \
    "--|dnf group install -y development-tools|"
check "install_build_tools on dnf: group failure falls back to explicit packages" \
    "$(pm_probe 'dnf' 'ensure_linux_packages() { :; }; install_build_tools' group | tr '\n' '|')" \
    "--|dnf group install -y development-tools|dnf install -y gcc gcc-c++ make|"
check "install_build_tools on zypper: pattern install" \
    "$(pm_probe 'zypper' 'ensure_linux_packages() { :; }; install_build_tools' | tr '\n' '|')" \
    "--|zypper install -y -t pattern devel_basis|"
check "install_build_tools on zypper: pattern failure falls back to explicit packages" \
    "$(pm_probe 'zypper' 'ensure_linux_packages() { :; }; run_as_root() { echo "$*" >> "$tmp/calls"; [[ "$*" != *pattern* ]] && { printf "#!/bin/sh\n" > "$tmp/bin/gcc"; chmod +x "$tmp/bin/gcc"; }; [[ "$*" != *pattern* ]]; }; install_build_tools' | tr '\n' '|')" \
    "--|zypper install -y -t pattern devel_basis|zypper refresh|zypper install -y gcc gcc-c++ make|"

# Prompt sites with ask_choice stubbed: $1 is the answer it returns (already
# lowercased, as the real helper does). No test opens /dev/tty.
ask_probe() {  # $1 answer, $2 snippet
    (
        tty_available() { return 0; }
        reset_tty() { :; }
        ask_choice() { echo "$ASK_ANSWER"; }
        export ASK_ANSWER="$1"
        eval "$2"
    )
}
for ans_mode in "o:overwrite" "s:skip" "d:perfile" "x:skip"; do
    check "determine_conflict_mode: answer '${ans_mode%%:*}' -> ${ans_mode#*:}" \
        "$(ask_probe "${ans_mode%%:*}" 'DOTFILES_CONFLICT=""; determine_conflict_mode; echo "$CONFLICT_MODE"')" "${ans_mode#*:}"
done
for ans_mode in "r:remove" "k:skip" "x:skip"; do
    check "determine_cleanup_mode: answer '${ans_mode%%:*}' -> ${ans_mode#*:}" \
        "$(ask_probe "${ans_mode%%:*}" 'CLEANUP=""; determine_cleanup_mode; echo "$CLEANUP_MODE"')" "${ans_mode#*:}"
done
check "select_profile: menu answer 1 -> developer" \
    "$(ask_probe 1 'unset PROFILE; select_profile; echo "$BREWFILE"')" "Brewfile-developer"
check "select_profile: menu answer 2 -> minimal" \
    "$(ask_probe 2 'unset PROFILE; select_profile; echo "$BREWFILE"')" "Brewfile-minimal"
check "select_profile: any other answer is fatal" \
    "$(ask_probe 9 'unset PROFILE; select_profile' | tail -n1)" "FATAL: Invalid choice."
check "resolve_one: answer o backs up and installs" \
    "$(ask_probe o 'RUN_TS=TS; HOME=$(mktemp -d); echo new > "$HOME/src"; echo old > "$HOME/dest"; resolve_one "$HOME/src" "$HOME/dest"; cat "$HOME/dest" "$HOME/dest.bak.TS" | tr "\n" " "; rm -rf "$HOME"')" "new old "
check "resolve_one: answer s keeps the existing file" \
    "$(ask_probe s 'RUN_TS=TS; HOME=$(mktemp -d); echo new > "$HOME/src"; echo old > "$HOME/dest"; resolve_one "$HOME/src" "$HOME/dest"; cat "$HOME/dest"; rm -rf "$HOME"')" "old"
check "resolve_stale_addon: answer r retires the add-on" \
    "$(ask_probe r 'RUN_TS=TS; HOME=$(mktemp -d); echo a > "$HOME/.bashrc.developer"; resolve_stale_addon .bashrc.developer; ls -A "$HOME" | tr "\n" " "; rm -rf "$HOME"')" ".bashrc.developer.bak.TS "

# ---------------------------------------------------------------------------
# Arch: one full-upgrade transaction, failure is fatal
# ---------------------------------------------------------------------------
# Runs $2 with pacman as the only package manager. run_as_root records its
# arguments; it fails when $1 is "fail". Prints the recorded calls and whether
# the call returned (a fatal() exits the subshell before "returned").
pacman_probe() {
    (
        OS_TYPE=linux
        command() {
            if [[ "$1" == "-v" ]]; then
                case "$2" in dnf|apt-get|zypper|gcc) return 1 ;; pacman) return 0 ;; esac
            fi
            builtin command "$@"
        }
        run_as_root() { echo "root: $*"; [[ "$PACMAN_MODE" != "fail" ]]; }
        export PACMAN_MODE="$1"
        eval "$2"
        echo "returned"
    )
}
check "ensure_linux_packages on Arch: single pacman -Syu with the packages" \
    "$(pacman_probe ok 'ensure_linux_packages definitely-missing-a definitely-missing-b' | tr '\n' '|')" \
    "root: pacman -Syu --needed --noconfirm definitely-missing-a definitely-missing-b|returned|"
check "ensure_linux_packages on Arch: pacman failure is fatal" \
    "$(pacman_probe fail 'ensure_linux_packages definitely-missing-a' | tr '\n' '|')" \
    "root: pacman -Syu --needed --noconfirm definitely-missing-a|FATAL: Failed to install: definitely-missing-a|"
check "install_build_tools on Arch: pacman failure is fatal, no separate -Sy" \
    "$(pacman_probe fail 'ensure_linux_packages() { :; }; install_build_tools' | tr '\n' '|')" \
    "root: pacman -Syu --needed --noconfirm base-devel|FATAL: Failed to install base-devel via pacman|"
check "bootstrap.sh no longer runs a bare pacman -Sy or ignores pacman failure" \
    "$(grep -c 'pacman -Sy --noconfirm\|pacman -S --needed' "$BOOTSTRAP")" "0"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "-----"
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
