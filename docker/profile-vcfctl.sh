# vcfctl shell setup: completions and prompt. Sourced by login shells.
# Bash-only constructs are kept inside eval so the file also parses in POSIX sh.
if [ -n "${BASH_VERSION:-}" ]; then
    # shellcheck disable=SC1091
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    fi
    command -v kubectl >/dev/null && eval '. <(kubectl completion bash)'
    command -v vcf >/dev/null && eval '. <(vcf completion bash)'
    alias k=kubectl
    eval 'complete -o default -F __start_kubectl k 2>/dev/null'
    PS1='\[\e[1;36m\]vcfctl\[\e[0m\]:\w\$ '
fi
