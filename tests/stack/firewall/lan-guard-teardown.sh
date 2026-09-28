# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# LAN-only sources, the teardown and restart half (#2749): down, the backup stop, uninstall and
# config-reset keep the rule when the nodes' marker cannot be deleted or a node may still run, and
# `pithead restart` checks the live rule under the lock. Runs in firewall/lan-guard.sh's sandbox
# (LGD, lg, the stubs), sourced right after it by test-host-firewall.sh.

echo "== teardown keeps the rule when the marker cannot go, or the nodes may still run (#2749) =="
export LG_IPT_LOG="$LGD/ipt.log"
lg_undeletable() { rm -f "$LGD/data/lan-guard/enforced" && mkdir -p "$LGD/data/lan-guard/enforced/x"; } # rm -f fails, even as root
lg_rule_removed() { grep -c -- '-F PITHEAD-LAN' "$LG_IPT_LOG" 2>/dev/null || true; }
lg_undeletable
: >"$LG_IPT_LOG"
lg_rc=0
lg remove_lan_guard >/dev/null || lg_rc=$?
assert_eq "remove_lan_guard fails when the marker cannot be deleted" "$([ "$lg_rc" != 0 ] && echo failed)" "failed"
assert_eq "...and leaves the rule in place" "$(lg_rule_removed)" "0"
lg_out="$(lg 'mutation_lock_acquire() { :; }; docker() { :; }; stack_down' 2>&1)"
assert_contains "down stops and says why when the marker cannot be deleted" "$lg_out" "down stopped:"
assert_eq "...with the rule still in place" "$(lg_rule_removed)" "0"
lg_out="$(lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { [ "$2" = config ] && echo monerod; :; }; stack_down_except_caddy' 2>&1)"
assert_contains "the backup stop goes on (nodes stopped) and keeps the rule with the marker" "$lg_out" "lan-guard:marker-kept"
assert_eq "...rule in place" "$(lg_rule_removed)" "0"
rm -rf "$LGD/data/lan-guard/enforced"
LG_LIVE=1 lg apply_lan_guard >/dev/null
cp "$LGD/.env" "$LGD/.env.keep"
: >"$LG_IPT_LOG"
lg_out="$(lg 'detect_os() { :; }; provision_control_runner() { :; }; docker() { case "$1 $2" in "compose down") return 1 ;; "ps --format") echo monerod ;; esac; }; stack_uninstall -y' 2>&1)"
assert_contains "uninstall stops when compose down fails and a LAN node may still run" "$lg_out" "uninstall stopped:"
assert_eq "...before removing the rule" "$(lg_rule_removed)" "0"
assert_eq "...the marker" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" "present"
assert_eq "...or the boot units" "$(test -e "$LG_UNIT" && test -e "$LG_HOLD" && echo present)" "present"
lg_out="$(lg 'detect_os() { :; }; provision_control_runner() { :; }; docker() { case "$1 $2" in "compose down") return 1 ;; "ps --format") return 1 ;; esac; }; stack_uninstall -y' 2>&1)"
assert_contains "an engine that cannot say what runs is not a confirmed stop" "$lg_out" "uninstall stopped:"
lg_out="$(lg 'set +e; detect_os() { :; }; provision_control_runner() { :; }; docker() { case "$1 $2" in "compose down") return 1 ;; "ps --format") echo caddy ;; esac; }; stack_uninstall -y' 2>&1)"
assert_contains "a failed down with both nodes confirmed stopped goes on" "$lg_out" "Uninstalled."
assert_eq "...removing the boot units" "$(test -e "$LG_UNIT" && echo present)" ""
mv "$LGD/.env.keep" "$LGD/.env"
LG_LIVE=1 lg apply_lan_guard >/dev/null
: >"$LG_IPT_LOG"
lg_out="$(lg 'touch config.json; mutation_lock_acquire() { :; }; docker() { case "$1 $2" in "compose down") return 1 ;; "ps --format") echo tari ;; esac; }; config_reset -y' 2>&1)"
assert_contains "config-reset stops the same way" "$lg_out" "config-reset stopped:"
assert_eq "...before removing the rule or the config" "$(lg_rule_removed) $(test -e "$LGD/.env" && echo env-kept)" "0 env-kept"
unset LG_IPT_LOG

echo "== a restart, which bypasses compose_up, needs the live rule first (#2749) =="
lg_rc=0
LG_LIVE=0 lg lan_guard_ready >/dev/null || lg_rc=$?
assert_eq "a published port without its live rule is not ready" "$([ "$lg_rc" != 0 ] && echo refused)" "refused"
lg_rc=0
LG_LIVE=1 lg lan_guard_ready >/dev/null || lg_rc=$?
assert_eq "...with it, ready" "$lg_rc" "0"
# The reported interleaving: a `down` or backup holds the lock and removes the rule while restart
# waits for it. The check has to see the state after the lock, not before.
lg_out="$(LG_LIVE=1 lg 'mutation_lock_acquire() { export LG_LIVE=0; }; docker() { echo "ran: docker $*"; }; stack_restart monerod')"
assert_contains "restart refuses when the rule went away while it waited for the lock" "$lg_out" "not in place"
assert_not_contains "...and restarts nothing" "$lg_out" "ran: docker compose restart"
lg_out="$(LG_LIVE=1 lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { echo "ran: docker $*"; }; stack_restart monerod')"
assert_contains "with the rule still live after the lock, it restarts" "$lg_out" "ran: docker compose restart monerod"
