# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# `apply` re-arms the #35 sync gate when a required chain moves to another node (#2763): it plants
# the dashboard's `sync-gate-reset` marker (#2626) on a monero/tari mode or remote-endpoint change,
# and on nothing else. The dashboard side of the marker is proven in test_data_service_sync_gate.py.
build_val_sandbox
RG_MARK="$V/data/dashboard/sync-gate-reset"
rg_apply() { # <monero-json> <tari-json> <pool>
    printf '{ "monero": {"wallet_address":"%s","node_username":"u","node_password":"p",%s}, "tari":{"wallet_address":"'"$VALID_TARI"'"%s}, "p2pool":{"pool":"%s"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' \
        "$WALLET" "$1" "$2" "$3" >"$V/config.json"
    (cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
}
rg_marked() { if [ -e "$RG_MARK" ]; then echo marked; else echo none; fi; }

echo "== black-box: apply re-arms the sync gate on a node change (#2763) =="
seed_env
rg_apply '"mode":"local"' '' main
assert_rc "local baseline applies" "$?" "0"
rm -f "$RG_MARK"
rg_apply '"mode":"local"' '' main
assert_eq "unchanged re-apply leaves the gate alone" "$(rg_marked)" none
rg_apply '"mode":"local"' '' mini
assert_eq "a change that keeps both nodes leaves the gate alone" "$(rg_marked)" none
rg_apply '"mode":"remote","remote":{"host":"node.example"}' '' mini
assert_eq "monero local -> remote re-arms the gate" "$(rg_marked)" marked
rm -f "$RG_MARK"
rg_apply '"mode":"remote","remote":{"host":"node.example","rpc_port":28081}' '' mini
assert_eq "a new monero remote port re-arms the gate" "$(rg_marked)" marked
rm -f "$RG_MARK"
rg_apply '"mode":"local"' '' mini
assert_eq "monero remote -> local re-arms the gate" "$(rg_marked)" marked
rm -f "$RG_MARK"
rg_apply '"mode":"local"' ',"mode":"remote","remote":{"host":"tari.example.com"}' mini
assert_eq "tari local -> remote re-arms the gate" "$(rg_marked)" marked
rm -f "$RG_MARK"
rg_apply '"mode":"local"' ',"mode":"remote","remote":{"host":"tari2.example.com"}' mini
assert_eq "a new tari remote host re-arms the gate" "$(rg_marked)" marked
rm -f "$RG_MARK"
rg_apply '"mode":"local"' '' mini
assert_eq "tari remote -> local re-arms the gate" "$(rg_marked)" marked
rm -f "$RG_MARK"
