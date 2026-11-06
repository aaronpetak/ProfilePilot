# ~/.bashrc: executed by bash(1) for non-login shells.
#
# Shared base for every profile and every Linux distro. The developer profile
# adds ~/.bashrc.developer, which is sourced last (see the end of this file).
# Distro-specific blocks are guarded and no-op where inapplicable.

# Homebrew: put the first Homebrew install found on PATH. Done first, before
# ~/.shell_aliases is sourced, so its command -v guards can see Homebrew tools.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    if [ -x "$_brew" ]; then
        eval "$("$_brew" shellenv bash)"
        break
    fi
done
unset _brew

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

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

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# Append commands to the history every time a prompt is shown,
# instead of after closing the session.
#
# This assignment and the fallback PS1 below must stay ABOVE the source of
# ~/.bashrc.developer at the bottom of this file: that is where
# `oh-my-posh init bash` runs, and the init has to be the last thing that
# touches PROMPT_COMMAND (it stores its hook in a PROMPT_COMMAND array, and a
# later string assignment would overwrite only element [0] and drop the hook).
# Nothing after that source may touch PROMPT_COMMAND or PS1.
PROMPT_COMMAND='history -a'

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# Default prompt: user@host:dir. A plain PS1 is always set so a prompt exists
# even when no prompt theme is configured.
PS1='\u@\h:\w\$ '

# Add the git branch to the prompt, but only if git's prompt helper exists:
# __git_ps1 ships with git (or its bash completion), not with bash. Load it from
# the first known location if it is not already defined.
if ! type __git_ps1 >/dev/null 2>&1; then
    for _git_prompt in \
        "${HOMEBREW_PREFIX:-/nonexistent}/etc/bash_completion.d/git-prompt.sh" \
        /usr/share/git-core/contrib/completion/git-prompt.sh \
        /usr/lib/git-core/git-sh-prompt \
        /etc/bash_completion.d/git-prompt \
        /usr/share/git/completion/git-prompt.sh; do
        if [ -r "$_git_prompt" ]; then
            # shellcheck source=/dev/null
            . "$_git_prompt"
            break
        fi
    done
    unset _git_prompt
fi
if type __git_ps1 >/dev/null 2>&1; then
    # Single-quoted so the command substitution runs for every prompt instead of
    # being evaluated once, here.
    PS1='\u@\h:\w$(__git_ps1 " (%s)")\$ '
fi

# Load GNU dircolors so `ls --color` output is themed. The listing/grep aliases
# themselves live in ~/.shell_aliases (single source of truth), not here.
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
fi

# Shared aliases and helper functions (portable across shells and OSes).
if [ -f ~/.shell_aliases ]; then
    # shellcheck source=/dev/null
    . ~/.shell_aliases
fi

# enable programmable completion features
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Developer add-on (oh-my-posh, virtualenvwrapper, Go, ...), present only for
# the developer profile. Keep this the LAST statement in the file so its prompt
# setup is the final writer of PROMPT_COMMAND and PS1.
if [ -f ~/.bashrc.developer ]; then
    # shellcheck source=/dev/null
    . ~/.bashrc.developer
fi
