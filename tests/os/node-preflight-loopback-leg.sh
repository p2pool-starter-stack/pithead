# shellcheck shell=bash
#
# #1946: the probe dials from the host namespace, but p2pool — the real consumer of the endpoints
# it validates — is bridge-networked, so a loopback address passes the check and then points at the
# container. A sibling file, not more lines in provision-browser-submit.sh, which sits exactly on
# its recorded file-budget ceiling; that file's `--self-test` sources this one.
node_preflight_loopback_self_test() {
    local loop_response='{"error":"points at the container instead of this machine","node_probe":{"ok":false,"configured":1,"probed":1,"probes":[{"target":"tari","reason":"address","ok":false}]}}'
    local loop_state='{"stage":"setup","config":{"monero":{"wallet_address":"wallet"},"tari":{"remote":{"host":"127.0.0.1"}}}}'
    node_preflight_refused "$loop_response" "$loop_state" wallet 127.0.0.1 address container || return 1
    # The wrong-reason and wrong-stage mutations are the dns fixture's, through this same function.
    ! node_preflight_refused "$loop_response" "$loop_state" wallet 10.20.30.40 address container || return 1
    echo "node-preflight-loopback-leg self-test: loopback refusal and non-loopback control passed"
}
