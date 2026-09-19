# shellcheck shell=bash
#
# #1946: the node probe dials from the host namespace, but p2pool — the real consumer of every
# endpoint it validates — is bridge-networked, so a loopback address passes a bare host-namespace
# connect check and then points at the container, not the operator's machine. node_preflight_refused
# (provision-browser-submit.sh) is generic over host/reason/message; this sibling just fixtures the
# loopback shape, sourced by that file's `--self-test` the same way it already sources the setup
# and approval legs, because that file sits exactly on its recorded file-budget ceiling.
node_preflight_loopback_self_test() {
    local loop_response='{"error":"points at the container instead of this machine","node_probe":{"ok":false,"configured":1,"probed":1,"probes":[{"target":"tari","reason":"address","ok":false}]}}'
    local loop_state='{"stage":"setup","config":{"monero":{"wallet_address":"wallet"},"tari":{"remote":{"host":"127.0.0.1"}}}}'
    node_preflight_refused "$loop_response" "$loop_state" wallet 127.0.0.1 address container || return 1
    # The mutation branches this would share with the dns fixture (wrong reason, wrong stage) are
    # proven there through the same generic function. New here: the address reason, and this control
    # that a non-loopback host does not match the refused one.
    ! node_preflight_refused "$loop_response" "$loop_state" wallet 10.20.30.40 address container || return 1
    echo "node-preflight-loopback-leg self-test: loopback refusal and non-loopback control passed"
}
