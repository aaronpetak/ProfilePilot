###############################################################################
# Homebrew Zsh Completions
###############################################################################
# Add Homebrew-managed Zsh completion scripts to the function search path.
# These enhance autocompletion for tools installed through Homebrew.
# A non-login zsh (e.g. a nested shell) may not have run .zprofile, so fall back
# to detecting the prefix here when HOMEBREW_PREFIX is not already set.
if [[ -z "${HOMEBREW_PREFIX:-}" ]]; then
    for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$_brew" ]]; then
            eval "$("$_brew" shellenv zsh)"
            break
        fi
    done
    unset _brew
fi
if [[ -n "${HOMEBREW_PREFIX:-}" && -d "$HOMEBREW_PREFIX/share/zsh/site-functions" ]]; then
    fpath+=("$HOMEBREW_PREFIX/share/zsh/site-functions")
fi

# Initialize Zsh’s completion framework.
autoload -Uz compinit
compinit

###############################################################################
# Shell Aliases
###############################################################################
# Load shared aliases and helper functions (portable across shells and OSes).
# The file is optional and kept separate for clarity.
if [[ -f "$HOME/.shell_aliases" ]]; then
    source "$HOME/.shell_aliases"
fi

###############################################################################
# Additional Environment Overrides
###############################################################################
# These are stored separately to keep ~/.zshrc clean.
# The file is optional and used for machine- or user-specific env settings.
if [[ -f "$HOME/.local/bin/env" ]]; then
    . "$HOME/.local/bin/env"
fi

###############################################################################
# Editor
###############################################################################
# Default editor, unless the environment already chose one: VS Code (waiting for
# the file to close, so git commit and crontab -e pause correctly) when it is
# installed and this is not an SSH session, otherwise vim, otherwise vi.
if [ -z "${EDITOR:-}" ]; then
    if command -v code >/dev/null 2>&1 && [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_TTY:-}" ]; then
        EDITOR="code --wait"
    elif command -v vim >/dev/null 2>&1; then
        EDITOR="vim"
    else
        EDITOR="vi"
    fi
fi
export EDITOR
export VISUAL="${VISUAL:-$EDITOR}"

###############################################################################
# Developer Add-on
###############################################################################
# Oh My Posh, virtualenvwrapper and fzf are configured in ~/.zshrc.developer,
# present only for the developer profile. Sourced last.
if [[ -f "$HOME/.zshrc.developer" ]]; then
    source "$HOME/.zshrc.developer"
fi
