# vcfctl shell setup: completions and prompt. Sourced by login shells.
# Bash-only constructs are kept inside eval so the file also parses in POSIX sh.

# Debian's /etc/profile resets PATH in login shells, dropping the image ENV
# entries for the runtime-installed vSphere 8 tools — restore them so login
# shells resolve the same PATH as docker exec / one-shot runs. The dirs may
# not exist yet; listing them anyway is harmless.
case ":$PATH:" in
    *":$HOME/.local/tkgs/bin:"*) ;;
    *) PATH="$HOME/.local/tkgs/bin:$HOME/.local/bin:$PATH"; export PATH ;;
esac

# Supervisor CAs collected by tkgs-login (system roots + endpoint CAs, always a
# superset of system trust). Exported only when the bundle exists — pointing Go
# binaries at a missing SSL_CERT_FILE would degrade root CA loading.
if [ -z "${SSL_CERT_FILE:-}" ] && [ -f "$HOME/.config/vcfctl/tkgs-ca-bundle.crt" ]; then
    export SSL_CERT_FILE="$HOME/.config/vcfctl/tkgs-ca-bundle.crt"
fi

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
