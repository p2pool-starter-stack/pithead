# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Node entrypoints and compose binds must honor the LAN marker and IPv4-only rule.

echo "== the node entrypoints refuse a LAN bind without a current marker, however started (#2749) =="
printf 'boot-1\n' >"$LGD/marker"
lg_gate() { # <marker content or -> <bind>...  (entrypoint in $lg_ep)
    local m="$1"
    shift
    [ "$m" = - ] && rm -f "$LGD/marker" || printf '%s\n' "$m" >"$LGD/marker"
    (
        PITHEAD_TEST_SOURCE=1 LAN_GUARD_MARKER="$LGD/marker" BOOT_ID_FILE="$LGD/boot_id" bash -c \
            'source "$1"; shift; lan_guard_gate "$@"; echo started' _ "$ROOT/$lg_ep" "$@" 2>&1
        echo "rc=$?"
    )
}
for lg_ep in build/monero/entrypoint.sh build/tari/entrypoint.sh; do
    assert_contains "$lg_ep: a loopback bind starts without a marker" "$(lg_gate - 127.0.0.1)" "started"
    assert_contains "$lg_ep: a LAN bind with no marker exits 78 before the daemon" "$(lg_gate - 0.0.0.0)" "rc=78"
    assert_not_contains "...and never reaches it" "$(lg_gate - 0.0.0.0)" "started"
    assert_contains "$lg_ep: a marker from an earlier boot is refused too" "$(lg_gate boot-0 127.0.0.1 0.0.0.0)" "rc=78"
    assert_contains "$lg_ep: this boot's marker lets a LAN bind start" "$(lg_gate boot-1 0.0.0.0)" "started"
    assert_contains "$lg_ep: an unreadable boot id never matches a missing marker" \
        "$(
            mv "$LGD/boot_id" "$LGD/boot_id.off" && lg_gate - 0.0.0.0
            mv "$LGD/boot_id.off" "$LGD/boot_id"
        )" "rc=78"
    assert_eq "$lg_ep: the gate runs before the daemon starts" \
        "$(grep -nE '^lan_guard_gate |^exec monerod|^run_node ' "$ROOT/$lg_ep" | head -n 1 | cut -d: -f2 | cut -c1-14)" "lan_guard_gate"
done
assert_eq "compose hands each node its binds and the marker dir, read-only" \
    "$(grep -cE '^      - (MONERO_RPC_BIND=\$\{MONERO_RPC_BIND:-127\.0\.0\.1\}|MONERO_ZMQ_BIND=\$\{MONERO_ZMQ_BIND:-127\.0\.0\.1\}|TARI_GRPC_BIND=\$\{TARI_GRPC_BIND:-127\.0\.0\.1\}|\./data/lan-guard:/lan-guard:ro)$' "$ROOT/docker-compose.yml")" "5"

echo "== every publish of 18081, 18083 and 18142 is an explicit IPv4 bind (#2616) =="
# The rule is IPv4 only. `[::]:P:P` or a bare `P:P` would also listen on IPv6, where nothing limits
# the source, so a change of either shape, or of an engine default behind one, has to fail here.
for kp in MONERO_RPC_BIND:18081 MONERO_ZMQ_BIND:18083 TARI_GRPC_BIND:18142; do
    k="${kp%%:*}" p="${kp#*:}"
    assert_eq "compose publishes $p only as \${$k:-127.0.0.1}" \
        "$(grep -E "^ *- *\"?[^ \"=]*\b$p(:$p)?(/tcp)?\"? *$" "$ROOT/docker-compose.yml" | sed 's/^ *//' | tr '\n' '|')" \
        "- \"\${$k:-127.0.0.1}:$p:$p\"|"
    assert_eq "quadlet publishes $p only from $k" \
        "$(grep -E "PublishPort=.*:$p(:|$)" "$ROOT/lib/pithead/36-quadlet-units.sh" | tr '\n' '|')" \
        "PublishPort=\$(_qenv $k):$p:$p|"
done
assert_eq "render_env assigns the three binds only IPv4 literals" \
    "$(grep -E '(rpc|zmq|tari_grpc)_bind="' "$ROOT/lib/pithead/33-render-env.sh" | grep -oE '_bind="[^"]*"' | sort -u | tr '\n' '|')" \
    '_bind="0.0.0.0"|_bind="127.0.0.1"|'
