# Security Policy

## Supported versions

Fixes go to `main` and into the next release. Only the latest release and `main` are supported; older tags are not patched.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub instead:

**[Report a vulnerability](https://github.com/aaronpetak/ProfilePilot/security/advisories/new)**

Include what an attacker could do, the steps or input that trigger it, and the ProfilePilot version or commit. The report stays private between you and the maintainer until a fix is published, and you will be credited in the advisory unless you ask not to be.

## Scope

`bootstrap.sh` runs with your user's privileges and `sudo`, downloads code and executes it, and writes to your shell startup files, so these are in scope:

- `bootstrap.sh`: anything that lets a third party run code, replace a file it installs, or read or write outside the intended paths. This includes how it fetches and verifies the repository tarball, the Homebrew installer and the tflint release.
- The dotfiles (`linux/`, `macos/`, `universal/`): anything that is unsafe to source in a shell.
- The CI workflow in `.github/workflows/`.

Out of scope: vulnerabilities in Homebrew itself or in the packages the Brewfiles install. Report those to the upstream project.

The trust model has known limits. The README's [tflint section](README.md#tflint-on-linux) explains them, as does the fact that the default ref, `main`, is unpinned. To run a fixed, reviewed version, pin a release with `DOTFILES_REF`.
