# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Clearnet initial sync behind the egress firewall (#2678): each opted-in node keeps its
# flag and gets a narrow firewall exception until its sync marker is written.
# test-tor-network.sh keeps the #941 warning rows and the firewall-off render.
#
# AMBIENT, like test-tor-network.sh sourced just ahead of it: $V, $WALLET, $DOCKER_LOG, seed_env and
# run_sourced come from the validation sandbox built earlier in the run.
# Sourced by tests/stack/run.sh.
: "${V:?}" "${WALLET:?}" "${VALID_TARI:?}" "${DOCKER_LOG:?}"

cnfw_apply() { # <monero-flag> <tari-flag> [network-json] -> applies; output in $out
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":%s}, "tari":{"wallet_address":"%s","clearnet_initial_sync":%s}, %s"p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' \
        "$WALLET" "$1" "$VALID_TARI" "$2" "${3:+\"network\":$3, }" >"$V/config.json"
    out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
}
cnfw_env() { run_sourced "$V" env_get_file "$V/.env" "$1"; }

echo "== black-box: clearnet_initial_sync works while the egress firewall is on (#2678) =="
cnfw_apply true false
assert_eq "monero flag + firewall on: monerod starts clearnet sync" "$(cnfw_env MONERO_CLEARNET_SYNC)" "true"
assert_eq "only Monero receives a public-dial exemption" "$(run_sourced "$V" tor_egress_sync_ips)" "172.28.0.26"
assert_contains "iptables rules allow only opted-in Monero before DROP" "$(run_sourced "$V" tor_egress_rules 172.28.0.0/24 172.28.0.25 172.28.0.26)" "-s 172.28.0.26 -j ACCEPT"
CN_BOOT="$(run_sourced "$V" render_tor_egress_boot_unit /usr/sbin/iptables 172.28.0.0/24 172.28.0.25 172.28.0.26)"
assert_contains "reboot unit checks the spent marker before restoring Monero's exception" "$CN_BOOT" "monero.synced"
assert_contains "reboot unit closes stale Monero exception first" "$CN_BOOT" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.26 -j ACCEPT"
cnfw_apply false true
assert_eq "tari flag + firewall on: tari starts clearnet sync" "$(cnfw_env TARI_CLEARNET_SYNC)" "true"
assert_eq "only Tari receives a public-dial exemption" "$(run_sourced "$V" tor_egress_sync_ips)" "172.28.0.27"
assert_contains "nft rules allow only opted-in Tari before DROP" "$(run_sourced "$V" render_tor_egress_nft 172.28.0.0/24 172.28.0.25 '' 172.28.0.27)" "ip saddr 172.28.0.27 accept"
cnfw_apply true true '{"tor_egress_firewall":false}'
assert_eq "firewall off: the monero flag reaches monerod" "$(cnfw_env MONERO_CLEARNET_SYNC)" "true"
assert_eq "firewall off: the tari flag reaches tari" "$(cnfw_env TARI_CLEARNET_SYNC)" "true"

echo "== live-rule readback: each chain's exception is independently accounted for =="
cnfw_apply true true
CN_RULES=$'-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.26 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.27 -j ACCEPT'
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_RULES"; then
    ok "readback accepts both authorized sync exceptions"
else bad "readback accepts both authorized sync exceptions" "live rule mismatch"; fi
if run_sourced "$V" tor_egress_sync_rules_match iptables "${CN_RULES%%$'\n'*}"; then
    bad "readback refuses a missing Tari exception" "accepted incomplete rule set"
else ok "readback refuses a missing Tari exception"; fi

echo "== black-box: a firewall toggle does not re-arm a completed clearnet sync (#234/#2678) =="
# The re-arm keys on the CONFIGURED flag, not the zeroed .env one: a clearnet sync that already
# completed (marker present) stays spent when the firewall goes back on, or turning it off again
# later would put a synced node back on clearnet.
cnfw_apply true true '{"tor_egress_firewall":false}'
CN_SDIR="$(cnfw_env CLEARNET_STATE_DIR)"
[ -n "$CN_SDIR" ] || CN_SDIR="$V/data/clearnet-state"
mkdir -p "$CN_SDIR" && : >"$CN_SDIR/monero.synced" && : >"$CN_SDIR/tari.synced"
cnfw_apply true true
[ -f "$CN_SDIR/monero.synced" ] && [ -f "$CN_SDIR/tari.synced" ] &&
    ok "firewall back on with the flags set: apply keeps both completed syncs' markers" ||
    bad "firewall back on with the flags set: apply keeps both completed syncs' markers" "a marker was removed"
assert_eq "spent markers close both public-dial exemptions" "$(run_sourced "$V" tor_egress_sync_ips)" ""
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_RULES"; then
    bad "readback refuses stale exceptions after sync" "accepted stale public-dial rule"
else ok "readback refuses stale exceptions after sync"; fi
if run_sourced "$V" tor_egress_sync_rules_match iptables ""; then
    ok "readback accepts both spent exceptions absent"
else bad "readback accepts both spent exceptions absent" "live rule mismatch"; fi
CN_REFRESH_PROBE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090  # the generated CLI is supplied by the stack suite
    source "$STACK"
    set +e
    apply_tor_egress_firewall() { [ "$1" = refresh ] && printf 'refresh\n'; }
    tor_egress_enforced() { printf 'verify\n'; return 1; }
    egress_sync_refresh monero
    printf 'rc=%s\n' "$?"
)
assert_contains "host refresh is requested before live-rule readback" "$CN_REFRESH_PROBE" $'refresh\nverify'
assert_contains "failed readback keeps the transition pending" "$CN_REFRESH_PROBE" "rc=1"

CN_CDIR="$(cnfw_env CONTROL_DIR)"
[ -n "$CN_CDIR" ] || CN_CDIR="$V/data/control"
mkdir -p "$CN_SDIR/requests" "$CN_CDIR/results"
CN_RID=00000000-0000-4000-8000-000000000001
printf '{"id":"%s","action":"egress-sync","chain":"monero"}\n' "$CN_RID" >"$CN_SDIR/requests/$CN_RID.json"
(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    egress_sync_refresh() { return 1; }
    egress_sync_run_pending
)
assert_eq "control-off trigger records a failed refresh" "$(jq -r .status "$CN_CDIR/results/$CN_RID.json")" "failed"
CN_RID=00000000-0000-4000-8000-000000000002
printf '{"id":"%s","action":"egress-sync","chain":"tari"}\n' "$CN_RID" >"$CN_SDIR/requests/$CN_RID.json"
(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    egress_sync_refresh() { [ "$1" = tari ]; }
    egress_sync_run_pending
)
assert_eq "control-off retry records the other chain's success" "$(jq -r .status "$CN_CDIR/results/$CN_RID.json")" "applied"
assert_eq "control-off result names the verified chain" "$(jq -r .chain "$CN_CDIR/results/$CN_RID.json")" "tari"
if run_sourced "$V" clearnet_sync_active; then
    ok "pending refresh keeps the exposure warning active"
else
    bad "pending refresh keeps the exposure warning active" "cleared before Tor restart"
fi
: >"$CN_SDIR/monero.synced.tor"
: >"$CN_SDIR/tari.synced.tor"
if run_sourced "$V" clearnet_sync_active; then
    bad "verified Tor completion clears exposure warning" "still active"
else
    ok "verified Tor completion clears exposure warning"
fi
cnfw_apply false true
[ -f "$CN_SDIR/monero.synced" ] &&
    bad "monero flag off: apply re-arms by removing its marker" "marker kept" ||
    ok "monero flag off: apply re-arms by removing its marker"
[ -f "$CN_SDIR/tari.synced" ] &&
    ok "tari flag still on: its marker stays" ||
    bad "tari flag still on: its marker stays" "marker removed"
rm -f "$CN_SDIR/monero.synced" "$CN_SDIR/tari.synced" "$CN_SDIR/monero.synced.tor" "$CN_SDIR/tari.synced.tor"
cnfw_apply false false
unset -f cnfw_apply cnfw_env
