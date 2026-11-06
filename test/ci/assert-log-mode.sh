#!/usr/bin/env bash
# Check which source mode a bootstrap run used, from its captured output.
# Usage: assert-log-mode.sh <logfile> tarball|local
set -uo pipefail

log="${1:?usage: assert-log-mode.sh <logfile> tarball|local}"
mode="${2:?usage: assert-log-mode.sh <logfile> tarball|local}"

case "$mode" in
    tarball)
        if grep -q 'Downloading ProfilePilot' "$log" &&
           ! grep -q 'Installing from local checkout' "$log"; then
            echo "ok:   source mode is tarball"
        else
            echo "FAIL: expected tarball mode" >&2
            exit 1
        fi
        ;;
    local)
        if grep -q 'Installing from local checkout' "$log" &&
           ! grep -q 'Downloading ProfilePilot' "$log"; then
            echo "ok:   source mode is local checkout"
        else
            echo "FAIL: expected local checkout mode" >&2
            exit 1
        fi
        ;;
    *)
        echo "unknown mode: $mode" >&2
        exit 2
        ;;
esac
