###############################################################################
# Homebrew Environment Initialization (Login Shell Only)
###############################################################################
# Homebrew recommends placing this in .zprofile so that PATH and other
# environment variables are set before .zshrc loads.
# This ensures Homebrew binaries are prioritized correctly at login.
# The prefix differs by CPU (Apple Silicon /opt/homebrew, Intel /usr/local),
# so use the first brew found.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$_brew" ]]; then
        eval "$("$_brew" shellenv zsh)"
        break
    fi
done
unset _brew
