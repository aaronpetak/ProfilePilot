## Summary

<!-- What does this change, and why? Link the issue it closes, e.g. "Closes #12". -->

## Checklist

- [ ] `bash test/logic_tests.sh` passes
- [ ] `shellcheck --severity=warning bootstrap.sh test/logic_tests.sh test/ci/*.sh` is clean
- [ ] `bootstrap.sh` changes avoid bash 4+ features (CI runs it under macOS's bash 3.2)
- [ ] README updated if behavior, environment variables or files changed
- [ ] `CHANGELOG.md` updated under "Unreleased" for user-visible changes
