# Contributing to ProfilePilot

Bug reports, package suggestions and pull requests are welcome. By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

- **Bugs and ideas:** open an [issue](https://github.com/aaronpetak/ProfilePilot/issues/new/choose). For a bug, attach the relevant part of the log (`~/.local/state/profilepilot.log` on Linux, `~/Library/Logs/profilepilot.log` on macOS).
- **Security problems:** do not open an issue; follow [SECURITY.md](SECURITY.md).

## Development setup

```bash
git clone https://github.com/aaronpetak/ProfilePilot.git
cd ProfilePilot
bash test/logic_tests.sh
```

The logic tests need no network, Homebrew or terminal, and use temporary directories as `HOME`, so they are safe to run on your own machine. To lint the same way CI does, install `shellcheck` and `zsh`, then run:

```bash
shellcheck --severity=warning bootstrap.sh test/logic_tests.sh test/ci/*.sh
shellcheck --severity=warning -s bash linux/.bashrc linux/profile-developer/.bashrc.developer universal/.shell_aliases
for f in macos/.zprofile macos/.zshrc macos/profile-developer/.zshrc.developer universal/.shell_aliases; do zsh -n "$f"; done
```

Running `bootstrap.sh` itself changes the machine: it installs packages and rewrites dotfiles. Try end-to-end changes in a throwaway container rather than on your workstation. This is what the CI smoke job does:

```bash
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/test/ci/container-smoke.sh
```

## Rules the code has to keep

The [Maintenance](README.md#maintenance) section of the README covers these in detail. The ones that most often break a change:

- **`bootstrap.sh` must run on bash 3.2**, the stock bash on macOS: no associative arrays, no `${var,,}`, no `mapfile`. CI runs the tests under macOS's `/bin/bash`. The bash dotfiles may use bash 4.4+.
- **The base `.bashrc` sources the developer add-on last**, and nothing after `oh-my-posh init` may assign `PROMPT_COMMAND` or `PS1`.
- **`universal/.shell_aliases` is sourced by both bash and zsh.** Keep it portable, and guard tool-specific entries with `command -v`.
- **macOS-only casks** in a Brewfile go inside `if OS.mac?`.

## Pull requests

1. Branch from `main` with a name like `fix/short-description` or `feat/short-description`.
2. Keep each pull request to one change, and add or update tests in `test/logic_tests.sh` for behavior changes.
3. Write commit messages as `type(scope): subject`, where the type is one of `feat`, `fix`, `docs`, `test`, `ci`, `refactor` or `chore`, matching the existing history.
4. Update the README when behavior, environment variables or files change, and add a line under "Unreleased" in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.
5. CI must pass before merge.

Contributions are accepted under the project's [Apache License 2.0](LICENSE).
