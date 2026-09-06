###############################################################################
# Homebrew Zsh Completions
###############################################################################
# Add Homebrew-managed Zsh completion scripts to the function search path.
# These enhance autocompletion for tools installed through Homebrew.
if [[ -d "/opt/homebrew/share/zsh/site-functions" ]]; then
    fpath+=('/opt/homebrew/share/zsh/site-functions')
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
