# shellcheck shell=bash
# A sudo that keeps a fixture from rewriting the host's firewall or systemd (#3442).

# <dir> <real-sudo>: no-ops the iptables, nft and systemctl verbs and hands every other command to the real sudo.
make_host_sudo_fence() {
    mkdir -p "$1"
    {
        printf '#!/usr/bin/env bash\nreal=%q\n' "$2"
        cat <<'EOF'
args=("$@")
[ "${1:-}" != -n ] || shift
case "$*" in "iptables-restore "* | "ip6tables-restore "* | "nft -f "*) cat >/dev/null ;; esac
case "${1:-}" in
iptables | iptables-save | iptables-restore | ip6tables | ip6tables-save | ip6tables-restore | nft | systemctl) exit 0 ;;
esac
exec "$real" "${args[@]}"
EOF
    } >"$1/sudo"
    chmod +x "$1/sudo"
}

# Call once SANDBOX exists; a host with no sudo has nothing to fence.
install_host_sudo_fence() {
    local real
    real="$(command -v sudo)" || return 0
    make_host_sudo_fence "$SANDBOX/.run/hostbin" "$real"
    export PATH="$SANDBOX/.run/hostbin:$PATH"
}
