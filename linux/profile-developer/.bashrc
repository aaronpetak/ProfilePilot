# ~/.bashrc: executed by bash(1) for non-login shells.
#
# Shared across all Linux distros (Debian/Ubuntu and Fedora/RHEL). Distro-
# specific blocks below are guarded by file/executable tests, so this single
# file works unchanged on both families.

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

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# Append commands to the history every time a prompt is shown,
# instead of after closing the session.
#
# This assignment must stay ABOVE the `. ~/.bash_environment` source at the
# bottom of this file: that is where `oh-my-posh init bash` runs, and the init
# has to be the last thing that touches PROMPT_COMMAND (it stores its hook in a
# PROMPT_COMMAND array, and a later string assignment would overwrite only
# element [0] and drop the hook). See the invariant note in .bash_environment.
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

# Source .bash_environment for environment variables
if [ -f ~/.bash_environment ]; then
    # shellcheck source=/dev/null
    . ~/.bash_environment
fi
