# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

ProfilePilot is a machine provisioning tool. The entire project is `bootstrap.sh` — a single Bash script that installs Homebrew, applies a selected Brewfile, and deploys OS- and profile-specific dotfiles to a fresh macOS or Linux machine.

## Running Bootstrap

**From a local clone:**
```bash
bash bootstrap.sh
```

**Remotely (how users actually run it):**
```bash
curl -fsSL -o /tmp/profile-pilot.sh https://raw.githubusercontent.com/aaronpetak/ProfilePilot/main/bootstrap.sh && bash /tmp/profile-pilot.sh
```

**Non-interactive overrides** (for automation or testing without a TTY):

| Variable | Values | Default when no TTY |
|---|---|---|
| `DOTFILES_CONFLICT` | `overwrite` / `skip` / `prompt` | `skip` |
| `CLEANUP` | `remove` / `skip` / `prompt` | `skip` |
| `GIT_NAME` | string | prompts if TTY |
| `GIT_EMAIL` | string | prompts if TTY |
| `GIT_USERNAME` | string | prompts if TTY |
| `BREW_BUNDLE_ATTEMPTS` | integer | `3` |
| `BREW_BUNDLE_RETRY_DELAY` | seconds | `5` |

There is no build step, test suite, or linter for this repository.

## Architecture

**Three layers:**

1. **`bootstrap.sh`** — the entire provisioning orchestrator (~975 lines). Execution order: OS detection → profile selection (Developer/Minimal) → Homebrew install → Linux build tools → `brew bundle` with retry loop → tflint binary install on Linux → dotfile download and apply → git personalization → optional package cleanup.

2. **`universal/`** — cross-platform configs shared by all OS/profile combinations: Brewfiles, `.shell_aliases`, `.gitconfig` (with `{PLACEHOLDER}` fields), `.gitmessage`, and the Oh My Posh theme.

3. **OS-specific dotfiles** (`macos/` and `linux/`) — organized by profile (`profile-developer/`, `profile-minimal/`). A single `.bashrc` serves all Linux distros using in-file guards.

**How dotfiles are deployed:** `bootstrap.sh` downloads files from the GitHub raw URL at runtime (not from the local clone). It does a two-pass conflict check: missing files are installed immediately; differing files are queued and resolved per `DOTFILES_CONFLICT`.

**Git personalization:** After dotfiles are installed, `bootstrap.sh` substitutes `{FULL NAME}`, `{GITHUB EMAIL}`, and `{GITHUB USERNAME}` placeholders inside the deployed `~/.gitconfig`.

## Critical Constraint: Bash 3.2 Compatibility

**`bootstrap.sh` must remain compatible with macOS's stock `/bin/bash` (version 3.2).** This means:

- No associative arrays (`declare -A`) — use functions with `case` statements instead. See `shell_files_for()` and `profile_specific_dirs_for()` as the canonical examples.
- No `[[ -v arr[key] ]]` syntax.
- No bashisms added after Bash 3.2.

Dotfiles deployed to the user's machine target Zsh (macOS) or Bash 4+ (Linux, via Homebrew), so those files can use modern shell features freely.

## Key Conventions

- **Idempotent by design.** Re-running bootstrap is always safe: identical dotfiles are skipped, differing files get a timestamped backup (e.g., `~/.zshrc.bak.20260728-145900`), never silently overwritten.
- **Never destructive by default.** Without a TTY, the script defaults to `skip` for both dotfile conflicts and package cleanup.
- **Single-file cross-platform dotfiles.** OS- or tool-specific blocks are always guarded with `[ -x /path ]`, `[ -r /path ]`, or `command -v tool` — never with raw `uname` strings in a way that would fail on the other OS.
- **tflint on Linux** cannot be installed via Homebrew (macOS-only cask); `bootstrap.sh` downloads its binary directly from GitHub releases into the Linuxbrew bin dir.
- **`HOMEBREW_NO_REQUIRE_TAP_TRUST=1`** is set when running `brew bundle`; taps are marked `trusted: true` in Brewfiles.
- **`Brewfile-bastion`** exists in `universal/brewfiles/` but is not yet wired into `bootstrap.sh`.

## Commit Message Format

From `.gitmessage`:
```
[<ticket #>] <type>: <subject>   ← max 50 chars
<blank line>
<body>                           ← max 80 chars per line
```

Types: `chore`, `docs`, `feat`, `fix`, `refactor`, `rem`, `style`, `test`, `wip`. WIP commits must not be pushed to shared branches.
