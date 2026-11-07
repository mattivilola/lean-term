# Shell integration

Lean Term can jump between prompts (**Terminal** menu: Previous Prompt
⌘↑, Next Prompt ⌘↓) and select the output of a command (**Edit › Select Command Output**, ⇧⌘A) so
that ⌘C or ⌥⌘C copies it. These commands need your shell to mark where prompts, input and output
start, using the OSC 133 "semantic prompt" sequences. Without them the menu items stay disabled.

Lean Term never installs or edits shell hooks for you. Add one of the snippets below to your own
startup file if you want the feature. They only print invisible escape sequences.

| Sequence | Meaning |
| --- | --- |
| `ESC ] 133 ; A BEL` | the prompt starts |
| `ESC ] 133 ; B BEL` | the prompt ends, your input starts |
| `ESC ] 133 ; C BEL` | the command runs, its output starts |
| `ESC ] 133 ; D ; status BEL` | the command finished with an exit status |

## zsh (`~/.zshrc`)

```zsh
autoload -Uz add-zsh-hook
__lean_preexec() { print -n '\e]133;C\a' }
__lean_precmd()  { print -n "\e]133;D;$?\a" }
add-zsh-hook preexec __lean_preexec
add-zsh-hook precmd __lean_precmd
# Mark the prompt itself: A before it, B after it.
PS1=$'%{\e]133;A\a%}'"$PS1"$'%{\e]133;B\a%}'
```

Run this after your prompt framework (oh-my-zsh, starship, powerlevel10k) has set `PS1`. If your
prompt tool already supports OSC 133 or "shell integration", enable that instead.

## bash (`~/.bashrc`)

```bash
__lean_prompt_command() { printf '\e]133;D;%s\a' "$?"; }
PROMPT_COMMAND="__lean_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS1='\[\e]133;A\a\]'"$PS1"'\[\e]133;B\a\]'
PS0='\[\e]133;C\a\]'
```

`PS0` needs bash 4.4 or newer (macOS ships bash 3.2; use a Homebrew bash, or zsh). Add these lines
after the code that sets your final `PS1`.

## fish (`~/.config/fish/config.fish`)

```fish
function __lean_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end
function __lean_postexec --on-event fish_postexec
    printf '\e]133;D;%s\a' $status
end
functions -c fish_prompt __lean_original_prompt
function fish_prompt
    printf '\e]133;A\a'
    __lean_original_prompt
    printf '\e]133;B\a'
end
```

Some fish releases may already emit OSC 133 themselves; if the menu items are enabled without the
snippet, you do not need it, and having both can mark prompts twice.

## Check that it works

Run a command or two, then open the **Terminal** menu: Previous Prompt and Next Prompt are enabled
once Lean Term has seen a prompt mark. Settings › Behavior › Shell integration links to this page.
