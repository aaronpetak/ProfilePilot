#!/usr/bin/env bash
# Runs as root inside a bare distro container (see the smoke-linux CI job).
# Creates an unprivileged sudo user and runs bootstrap.sh as that user with the
# minimal profile, then asserts the result. The repository is mounted read-only
# at /src.
#
# Only sudo and what is needed to create a user are installed here. Everything
# else bootstrap.sh needs (curl, git, tar, gzip, build tools, unzip, gawk,
# bubblewrap) is deliberately left for bootstrap.sh to install, so this run
# exercises its own prerequisite handling.
set -euo pipefail

SRC=/src
CI_USER=ci
CI_HOME=/home/ci
REPO="$CI_HOME/ProfilePilot"

install_setup_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y sudo passwd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y sudo shadow-utils
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm sudo shadow
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install sudo shadow
    else
        echo "No supported package manager in this image" >&2
        exit 1
    fi
}

install_setup_packages

useradd --create-home --home-dir "$CI_HOME" --shell /bin/bash "$CI_USER"
mkdir -p /etc/sudoers.d
echo "$CI_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$CI_USER"
chmod 0440 "/etc/sudoers.d/$CI_USER"

cp -R "$SRC" "$REPO"
chown -R "$CI_USER" "$REPO"

sudo -u "$CI_USER" -H env \
    PROFILE=minimal \
    DOTFILES_CONFLICT=overwrite \
    CLEANUP=skip \
    GIT_NAME='CI Bot' \
    GIT_EMAIL=ci@example.com \
    bash "$REPO/bootstrap.sh"

sudo -u "$CI_USER" -H bash "$REPO/test/ci/assert-linux.sh" "$REPO"
