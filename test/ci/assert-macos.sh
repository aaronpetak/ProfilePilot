#!/usr/bin/env bash
# Post-run assertions for a macOS bootstrap run. Usage: assert-macos.sh <repo-dir>
set -uo pipefail

repo="${1:?usage: assert-macos.sh <repo-dir>}"
failures=0

pass() { echo "ok:   $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

for tool in brew jq rg; do
    if zsh -lic "command -v $tool" >/dev/null 2>&1; then
        pass "$tool is on PATH in a login zsh"
    else
        fail "$tool is not on PATH in a login zsh"
    fi
done

for f in .zprofile .zshrc; do
    if cmp -s "$HOME/$f" "$repo/macos/$f"; then
        pass "$f matches macos/$f"
    else
        fail "$f differs from macos/$f"
    fi
done

if (( failures > 0 )); then
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
echo "all assertions passed"
