# shellcheck shell=bash
# A sudo and PATH stubs that keep a fixture from rewriting the host's firewall or systemd (#3442).

HOST_FENCED_TOOLS="iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore nft systemctl"
HOST_FENCE_DRAIN='"iptables-restore "* | "ip6tables-restore "* | "nft -f "*'

# <dir> <real-sudo>: no-ops the fenced verbs and hands every other command to the real sudo.
make_host_sudo_fence() {
    mkdir -p "$1"
    cat >"$1/sudo" <<EOF
#!/usr/bin/env bash
real=$(printf %q "$2")
args=("\$@")
[ "\${1:-}" != -n ] || shift
case "\$*" in $HOST_FENCE_DRAIN) cat >/dev/null ;; esac
case "\${1:-}" in ${HOST_FENCED_TOOLS// / | }) exit 0 ;; esac
exec "\$real" "\${args[@]}"
EOF
    chmod +x "$1/sudo"
}

# <dir> <log> <tool>...: a recording no-op per tool, so a PATH lookup, including one a fixture's own
# pass-through sudo makes, never reaches the host's binary.
make_host_tool_stubs() {
    local dir="$1" log="$2" tool
    shift 2
    mkdir -p "$dir"
    : >"$log"
    for tool in "$@"; do
        cat >"$dir/$tool" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\${0##*/}" "\$*" >>$(printf %q "$log")
case "\${0##*/} \$*" in $HOST_FENCE_DRAIN) cat >/dev/null ;; esac
exit 0
EOF
        chmod +x "$dir/$tool"
    done
}

# Prints each fenced tool that PATH resolves past its stub in $HOST_FENCE_DIR.
host_fence_leaks() {
    local t
    hash -r
    for t in $HOST_FENCED_TOOLS; do
        [ ! -e "$HOST_FENCE_DIR/$t" ] || [ "$(command -v "$t")" = "$HOST_FENCE_DIR/$t" ] || printf '%s\n' "$t"
    done
}

# Call once SANDBOX exists. A tool the host lacks stays absent, so presence checks answer as before.
install_host_fence() {
    local real t tools=""
    HOST_FENCE_DIR="$SANDBOX/.run/hostbin"
    for t in $HOST_FENCED_TOOLS; do
        ! command -v "$t" >/dev/null 2>&1 || tools="$tools $t"
    done
    # shellcheck disable=SC2086
    make_host_tool_stubs "$HOST_FENCE_DIR" "$HOST_FENCE_DIR/calls.log" $tools
    real="$(command -v sudo)" && make_host_sudo_fence "$HOST_FENCE_DIR" "$real"
    export PATH="$HOST_FENCE_DIR:$PATH"
}

# Run last in each block: a fragment that moved PATH left every later fixture unfenced.
host_fence_final_check() {
    local leaks
    leaks="$(host_fence_leaks | tr '\n' ' ')"
    if [ -z "$leaks" ]; then ok "the host firewall and systemctl stubs still lead PATH"; else bad "the host firewall and systemctl stubs still lead PATH" "resolved past the fence: $leaks"; fi
}
