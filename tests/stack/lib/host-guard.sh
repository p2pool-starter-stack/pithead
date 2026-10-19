# shellcheck shell=bash

stack_host_guard_init() {
    local sandbox="$1" tool guard_dir
    STACK_FIXTURE_SUDO="${STACK_FIXTURE_SUDO:-$(command -v sudo || true)}"
    export STACK_FIXTURE_SUDO
    export PITHEAD_UNIT_DIR="$sandbox/units"
    export STACK_HOST_GUARD_LOG="$sandbox/host-guard.log"
    mkdir -p "$PITHEAD_UNIT_DIR" "$sandbox/host-guard-bin" "$sandbox/host-guard-sbin"
    for tool in sudo systemctl iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore nft; do
        case "$tool" in
        sudo | systemctl) guard_dir="$sandbox/host-guard-bin" ;;
        *) guard_dir="$sandbox/host-guard-sbin" ;;
        esac
        cat >"$guard_dir/$tool" <<'GUARD'
#!/usr/bin/env bash
tool=${0##*/}
case "$tool:$*" in
systemctl:is-active*|systemctl:is-enabled*|systemctl:is-failed*|systemctl:is-system-running*|systemctl:show\ *|systemctl:status\ *|iptables-save:*|ip6tables-save:*|iptables:-S*|ip6tables:-S*|nft:list\ *|nft:-j\ list\ *)
    exit 1
    ;;
esac
printf '%s\n' "$tool" >>"${STACK_HOST_GUARD_LOG:?}"
printf 'tests: undeclared host command: %s; provide a sandbox fixture\n' "$tool" >&2
exit 125
GUARD
        chmod +x "$guard_dir/$tool"
    done
    export PATH="$sandbox/host-guard-bin:$sandbox/host-guard-sbin:$PATH"
}

stack_host_guard_check() {
    [ ! -s "$STACK_HOST_GUARD_LOG" ] || {
        printf 'tests: undeclared host commands were blocked:\n' >&2
        sort -u "$STACK_HOST_GUARD_LOG" >&2
        return 1
    }
}

stack_sandbox_cleanup() {
    local rc=$?
    stack_host_guard_check || rc=1
    rm -rf "$SANDBOX"
    exit "$rc"
}
