#!/usr/bin/env bash
# Post-run assertions for a Linux bootstrap run, executed as the user that ran
# bootstrap.sh. Usage: assert-linux.sh <repo-dir> [minimal|developer]
# <repo-dir> is the ProfilePilot tree the run installed from.
set -uo pipefail

repo="${1:?usage: assert-linux.sh <repo-dir> [minimal|developer]}"
profile="${2:-minimal}"
failures=0

pass() { echo "ok:   $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# Run a command in a login shell, so ~/.profile / ~/.bash_profile are read.
login() { bash -lc "$1"; }

for tool in brew jq rg tmux; do
    if login "command -v $tool" >/dev/null 2>&1; then
        pass "$tool is on PATH in a login shell"
    else
        fail "$tool is not on PATH in a login shell"
    fi
done

email=$(login 'git config --global --includes user.email' 2>/dev/null)
if [[ "$email" == "ci@example.com" ]]; then
    pass "git user.email resolves through .gitconfig.local"
else
    fail "git user.email is '$email', expected ci@example.com"
fi

if cmp -s "$HOME/.bashrc" "$repo/linux/.bashrc"; then
    pass ".bashrc matches linux/.bashrc"
else
    fail ".bashrc differs from linux/.bashrc"
fi

if [[ "$profile" == "developer" ]]; then
    if cmp -s "$HOME/.bashrc.developer" "$repo/linux/profile-developer/.bashrc.developer"; then
        pass ".bashrc.developer matches the profile add-on"
    else
        fail ".bashrc.developer is missing or differs"
    fi
    if login 'tflint --version' >/dev/null 2>&1; then
        pass "tflint runs"
    else
        fail "tflint --version failed"
    fi
    if login 'command -v oh-my-posh' >/dev/null 2>&1; then
        pass "oh-my-posh is on PATH"
    else
        fail "oh-my-posh is not on PATH"
    fi
fi

# An interactive shell must start without errors. Without a terminal bash prints
# these two job-control notices itself; anything else on stderr is a problem.
noise=$(bash -ic true 2>&1 >/dev/null |
    grep -v -e 'cannot set terminal process group' -e 'no job control in this shell' || true)
if [[ -z "$noise" ]]; then
    pass "bash -ic true is clean"
else
    fail "bash -ic true wrote to stderr:"
    echo "$noise" >&2
fi

if (( failures > 0 )); then
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
echo "all assertions passed"
