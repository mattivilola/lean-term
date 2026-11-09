# Loaded only by new Lean Term zsh panes with SSH keepalive enabled.
# Restore the original startup directory before continuing the login sequence.
if (( ${+LEANTERM_ORIGINAL_ZDOTDIR} )); then
    export ZDOTDIR=$LEANTERM_ORIGINAL_ZDOTDIR
else
    unset ZDOTDIR
fi
unset LEANTERM_ORIGINAL_ZDOTDIR
if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
    builtin source "${ZDOTDIR-$HOME}/.zshenv"
fi

function _leanterm_ssh_keepalive_setup {
    precmd_functions=( "${(@)precmd_functions:#_leanterm_ssh_keepalive_setup}" )
    unfunction _leanterm_ssh_keepalive_setup
    # Let the user's login files take precedence, including shell plugin aliases.
    if (( ${+aliases[ssh]} || ${+functions[ssh]} )); then
        return 0
    fi
    function ssh {
        emulate -L zsh
        local argument
        # Leave explicit interval settings alone, including attached -o options.
        for argument in "$@"; do
            if [[ ${(L)argument} == *serveraliveinterval* ]]; then
                command ssh "$@"
                return $?
            fi
        done
        if [[ $(whence -p ssh) == /usr/bin/ssh ]]; then
            command /usr/bin/ssh -oServerAliveInterval=30 "$@"
        else
            command ssh "$@"
        fi
    }
}
if [[ -o interactive ]]; then
    typeset -ga precmd_functions
    precmd_functions+=(_leanterm_ssh_keepalive_setup)
fi
