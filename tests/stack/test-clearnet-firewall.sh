# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Clearnet initial sync behind the egress firewall (#2649): what the render does with a
# clearnet_initial_sync flag while network.tor_egress_firewall is on.
#
# The firewall drops every clearnet dial, and a clearnet monerod has no Tor proxy left, so with both
# on the node had no peers, never reported synchronized and never switched back to Tor. render_env
# now passes a flag to the daemons only while the firewall is off. These rows pin that, and the
# marker re-arm that has to follow the configured flag instead of the zeroed .env one.
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

echo "== black-box: clearnet_initial_sync is ignored while the egress firewall is on (#2649) =="
cnfw_apply true false
assert_eq "monero flag + firewall on: monerod stays on Tor (.env flag false)" "$(cnfw_env MONERO_CLEARNET_SYNC)" "false"
assert_not_contains "monero flag + firewall on: no clearnet-exposure preview" "$out" "CLEARNET initial sync ENABLED"
cnfw_apply false true
assert_eq "tari flag + firewall on: tari stays on Tor (.env flag false)" "$(cnfw_env TARI_CLEARNET_SYNC)" "false"
cnfw_apply true true '{"tor_egress_firewall":false}'
assert_eq "firewall off: the monero flag reaches monerod" "$(cnfw_env MONERO_CLEARNET_SYNC)" "true"
assert_eq "firewall off: the tari flag reaches tari" "$(cnfw_env TARI_CLEARNET_SYNC)" "true"

echo "== black-box: a firewall toggle does not re-arm a completed clearnet sync (#234/#2649) =="
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
cnfw_apply false true
[ -f "$CN_SDIR/monero.synced" ] &&
    bad "monero flag off: apply re-arms by removing its marker" "marker kept" ||
    ok "monero flag off: apply re-arms by removing its marker"
[ -f "$CN_SDIR/tari.synced" ] &&
    ok "tari flag still on: its marker stays" ||
    bad "tari flag still on: its marker stays" "marker removed"
rm -f "$CN_SDIR/monero.synced" "$CN_SDIR/tari.synced"
cnfw_apply false false
unset -f cnfw_apply cnfw_env
