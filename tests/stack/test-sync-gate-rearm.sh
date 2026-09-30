# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# `apply` re-arms the #35 sync gate when a required chain moves to another node (#2763): it plants
# the dashboard's `sync-gate-reset` marker (#2626) on a monero/tari mode or remote-endpoint change,
# and on nothing else. The dashboard side of the marker is proven in test_data_service_sync_gate.py.
build_val_sandbox
RG_MARK="$V/data/dashboard/sync-gate-reset"
rg_marked() { if [ -e "$RG_MARK" ]; then echo marked; else echo none; fi; }
rg_apply() { # <monero-json> <tari-json> <pool>
    printf '{ "monero": {"wallet_address":"%s","node_username":"u","node_password":"p",%s}, "tari":{"wallet_address":"'"$VALID_TARI"'"%s}, "p2pool":{"pool":"%s"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' \
        "$WALLET" "$1" "$2" "$3" >"$V/config.json"
    (cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
    echo "rc=$? $(rg_marked)" # the apply must succeed AND leave the gate as wanted
}

echo "== black-box: apply re-arms the sync gate on a node change (#2763) =="
seed_env
assert_eq "local baseline applies" "$(rg_apply '"mode":"local"' '' main | cut -d" " -f1)" "rc=0"
rm -f "$RG_MARK"
assert_eq "unchanged re-apply leaves the gate alone" "$(rg_apply '"mode":"local"' '' main)" "rc=0 none"
assert_eq "a change that keeps both nodes leaves the gate alone" "$(rg_apply '"mode":"local"' '' mini)" "rc=0 none"
assert_eq "monero local -> remote re-arms the gate" "$(rg_apply '"mode":"remote","remote":{"host":"node.example"}' '' mini)" "rc=0 marked"
rm -f "$RG_MARK"
assert_eq "a new monero remote port re-arms the gate" "$(rg_apply '"mode":"remote","remote":{"host":"node.example","rpc_port":28081}' '' mini)" "rc=0 marked"
rm -f "$RG_MARK"
assert_eq "monero remote -> local re-arms the gate" "$(rg_apply '"mode":"local"' '' mini)" "rc=0 marked"
rm -f "$RG_MARK"
assert_eq "tari local -> remote re-arms the gate" "$(rg_apply '"mode":"local"' ',"mode":"remote","remote":{"host":"tari.example.com"}' mini)" "rc=0 marked"
rm -f "$RG_MARK"
assert_eq "a new tari remote host re-arms the gate" "$(rg_apply '"mode":"local"' ',"mode":"remote","remote":{"host":"tari2.example.com"}' mini)" "rc=0 marked"
rm -f "$RG_MARK"
assert_eq "tari remote -> local re-arms the gate" "$(rg_apply '"mode":"local"' '' mini)" "rc=0 marked"
rm -f "$RG_MARK"
# A recreate that failed after the commit is retried on an unchanged .env: the retry marker carries
# the re-arm, so the retry still plants it; a retry with nothing to re-arm plants nothing.
printf 'rearm-sync-gate\n' >"$V/.env.apply-incomplete"
assert_eq "a retried recreate keeps the re-arm" "$(rg_apply '"mode":"local"' '' mini)" "rc=0 marked"
assert_eq "the successful retry clears its retry marker" "$([ -e "$V/.env.apply-incomplete" ] && echo kept || echo none)" none
rm -f "$RG_MARK"
: >"$V/.env.apply-incomplete"
assert_eq "a retry with no node change leaves the gate alone" "$(rg_apply '"mode":"local"' '' mini)" "rc=0 none"
# A symlink planted at the marker path (the dashboard's uid owns the directory) is replaced, never
# followed: its target keeps its content, and the gate is still re-armed by a regular file.
printf 'keep\n' >"$V/rg-target"
ln -s "$V/rg-target" "$RG_MARK"
assert_eq "a planted marker symlink is replaced on re-arm" "$(rg_apply '"mode":"remote","remote":{"host":"node.example"}' '' mini)" "rc=0 marked"
assert_eq "the planted symlink's target is unchanged" "$(cat "$V/rg-target")" keep
assert_eq "the re-armed marker is a regular file" "$([ -f "$RG_MARK" ] && [ ! -L "$RG_MARK" ] && echo regular || echo other)" regular
rm -f "$RG_MARK"
# A directory at the marker path cannot be replaced: apply fails closed and keeps the re-arm for its retry.
mkdir -p "$RG_MARK/keep"
assert_eq "a directory at the marker path fails the apply" "$(rg_apply '"mode":"local"' '' mini | cut -d" " -f1)" "rc=1"
assert_eq "the failed re-arm is kept for the retry" "$(cat "$V/.env.apply-incomplete" 2>/dev/null)" rearm-sync-gate
assert_eq "the planted directory is untouched" "$(ls "$RG_MARK")" keep
rm -rf "$RG_MARK" "$V/.env.apply-incomplete"
