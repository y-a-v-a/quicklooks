#!/usr/bin/env zsh
# Shell startup file: comments, $variables, NAME= assignments, keywords.
export PATH="$HOME/.local/bin:$PATH"
export EDITOR=vim
HISTSIZE=100000
setopt HIST_IGNORE_DUPS   # trailing comment
alias ll='ls -lah'
echo "issue #42 is not a comment" url#anchor ${PWD:-/} $# $?

if [[ -d "$HOME/.cargo" ]]; then
  source "$HOME/.cargo/env"
fi

for f in ~/.zsh/*.zsh; do source "$f"; done
it's an apostrophe, not a string
