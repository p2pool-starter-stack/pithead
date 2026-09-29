# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Docker adds the FORWARD jump when its first network is created (#2847).

echo "== a first Docker network holds LAN nodes until live rule readback (#2847) =="
: >"$LG_COMPOSE"
rm -f "$LG_JUMP_FILE"
rm -f "$LGD/data/lan-guard/enforced"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=after lg 'compose_up -d')"
assert_not_contains "first network adds the FORWARD jump: no fallback" "$lg_out" "lan-guard:not-installed"
assert_eq "...first starts on loopback, then recreates with the LAN bind" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ncompose-bind=127.0.0.1\ncompose-bind=0.0.0.0'
assert_eq "...and marks this boot before the LAN pass" "$(cat "$LGD/data/lan-guard/enforced" 2>/dev/null)" "boot-1"
: >"$LG_COMPOSE"
rm -f "$LG_JUMP_FILE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=after LG_LAN_UP_FAIL=1 lg 'compose_up -d')"
lg_rc=$?
assert_rc "a failed LAN pass returns failure after loopback rollback" "$lg_rc" "1"
assert_eq "...stops the node and restores the loopback bind" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ncompose-bind=127.0.0.1\ncompose-bind=0.0.0.0\ndocker-stop=cid123\ncompose-bind=127.0.0.1'
assert_eq "...and clears the marker" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
: >"$LG_COMPOSE"
LG_LIVE=1 LG_FORWARD_JUMP=never LG_IDS='cid123 cid456' lg 'compose_up -d' >/dev/null
assert_contains "both a canonical and interrupted replacement are stopped" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ndocker-stop=cid456'
assert_contains "only this Compose project's Tari nodes are selected" "$(cat "$LG_QUERY_LOG")" 'label=com.docker.compose.project=pithead --filter label=com.docker.compose.service=tari'
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=never lg 'compose_up -d')"
assert_contains "engine with no FORWARD jump: warn after compose (#2847)" "$lg_out" "nothing jumps from FORWARD to DOCKER-USER"
assert_eq "...stop before starting the node on loopback" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ncompose-bind=127.0.0.1'
assert_eq "...and keep the start marker absent" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=never LG_STOP_RC=1 lg 'compose_up -d')"
lg_rc=$?
assert_contains "a stop failure is reported as exposure, not a successful fallback" "$lg_out" "its ports may still be exposed"
assert_rc "...and returns a failing status" "$lg_rc" "1"
assert_not_contains "...and never starts compose while the old node may run" "$(cat "$LG_COMPOSE")" "compose-bind="
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=never LG_PS_RC=1 lg 'compose_up -d')"
assert_contains "unreadable engine cannot be called an empty running set" "$lg_out" "cannot check running LAN nodes"
assert_not_contains "...and cannot start compose" "$(cat "$LG_COMPOSE")" "compose-bind="
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=never lg 'lan_guard_unmark() { return 1; }; compose_up -d')"
assert_contains "a marker that cannot be cleared refuses startup" "$lg_out" "could not delete"
assert_not_contains "...and cannot start compose" "$(cat "$LG_COMPOSE")" "compose-bind="

: >"$LG_COMPOSE"
: >"$LG_ARGS_LOG"
lg_out="$(LG_LIVE=0 lg 'compose_up --pull always -d tor')"
assert_contains "a scoped fallback keeps the node on loopback" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ncompose-bind=127.0.0.1'
assert_contains "...and restarts that node alongside tor" "$(cat "$LG_ARGS_LOG")" " tor tari"
: >"$LG_COMPOSE"
: >"$LG_ARGS_LOG"
rm -f "$LG_JUMP_FILE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=after lg 'compose_up -d tor')"
assert_eq "a scoped staged up restarts the node on both passes" "$(cat "$LG_ARGS_LOG" | grep -c ' tor tari')" "2"
assert_eq "...with loopback before the LAN bind" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ncompose-bind=127.0.0.1\ncompose-bind=0.0.0.0'
: >"$LG_COMPOSE"
rm -f "$LG_JUMP_FILE" "$LGD/data/lan-guard/enforced" "$LG_FAIL_FILE"
lg_out="$(LG_LIVE=1 LG_FORWARD_JUMP=after LG_FIRST_UP_FAIL=1 lg 'compose_up -d')"
lg_rc=$?
assert_rc "a failed first pass returns failure" "$lg_rc" "1"
assert_eq "...restarts stopped nodes on loopback without a LAN-bound pass" "$(cat "$LG_COMPOSE")" $'docker-stop=cid123\ncompose-bind=127.0.0.1\ncompose-bind=127.0.0.1'
assert_eq "...and never marks the boot" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
assert_contains "...the recovery pass targets the stopped node" "$(tail -n 1 "$LG_ARGS_LOG")" " -d tari"
lg_out="$(lg 'lan_guard_scoped_up --attach tari -d && echo scoped || echo full')"
assert_eq "an option value is not a Compose service scope" "$lg_out" "full"
lg_out="$(lg 'lan_guard_scoped_up --menu tor && echo scoped || echo full')"
assert_eq "a boolean option still leaves the named service in scope" "$lg_out" "scoped"
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=0 lg 'apply_tor_egress_firewall() { return 1; }; clearnet_sync_active() { return 0; }; compose_up -d tor')"
lg_rc=$?
assert_rc "a failed required Tor egress gate refuses the scoped up" "$lg_rc" "1"
assert_eq "...and keeps the LAN node stopped while egress is unsafe" "$(cat "$LG_COMPOSE")" "docker-stop=cid123"
