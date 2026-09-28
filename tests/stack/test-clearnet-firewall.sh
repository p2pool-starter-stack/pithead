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

cnfw_apply() { # <monero-flag> <tari-flag> [network-json]
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":%s}, "tari":{"wallet_address":"%s","clearnet_initial_sync":%s}, %s"p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' \
        "$WALLET" "$1" "$VALID_TARI" "$2" "${3:+\"network\":$3, }" >"$V/config.json"
    (cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
}
cnfw_env() { run_sourced "$V" env_get_file "$V/.env" "$1"; }

echo "== black-box: clearnet_initial_sync works while the egress firewall is on (#2678) =="
cnfw_apply true false
assert_eq "monero flag + firewall on: monerod starts clearnet sync" "$(cnfw_env MONERO_CLEARNET_SYNC)" "true"
assert_eq "only Monero receives a public-dial exemption" "$(run_sourced "$V" tor_egress_sync_ips)" "172.28.0.26"
assert_contains "iptables rules allow only opted-in Monero before DROP" "$(run_sourced "$V" tor_egress_rules 172.28.0.0/24 172.28.0.25 172.28.0.26)" "-s 172.28.0.26 -j ACCEPT"
CN_BOOT="$(run_sourced "$V" render_tor_egress_boot_unit /usr/sbin/iptables 172.28.0.0/24 172.28.0.25 172.28.0.26)"
assert_contains "reboot unit checks the spent marker before restoring Monero's exception" "$CN_BOOT" "monero.synced"
assert_contains "reboot unit rejects dangling marker links" "$CN_BOOT" "test ! -L"
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
CN_DROP='-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP'
CN_RULES=$'-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.26 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.27 -j ACCEPT'
CN_RULES+=$'\n'"$CN_DROP"
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_RULES"; then
    ok "readback accepts both authorized sync exceptions"
else bad "readback accepts both authorized sync exceptions" "live rule mismatch"; fi
CN_LATE=$'-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.26 -j ACCEPT\n'"$CN_DROP"$'\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.27 -j ACCEPT'
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_LATE"; then
    bad "readback refuses a Tari exception after the blocking DROP" "accepted ineffective exception"
else ok "readback refuses a Tari exception after the blocking DROP"; fi
CN_NEGATED=$'-A DOCKER-USER -m comment --comment pithead-tor-egress ! -s 172.28.0.26 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.27 -j ACCEPT\n'"$CN_DROP"
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_NEGATED"; then
    bad "readback refuses a negated authorized source" "accepted a broad exception"
else ok "readback refuses a negated authorized source"; fi
CN_COMMENT=$'-A DOCKER-USER -m comment --comment "audit -s 172.28.0.26 -j ACCEPT" -j LOG\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.27 -j ACCEPT\n'"$CN_DROP"
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_COMMENT"; then
    bad "readback refuses rule text forged inside a comment" "accepted a missing exception"
else ok "readback refuses rule text forged inside a comment"; fi
CN_NFT_MONERO='{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":"172.28.0.26"}},{"accept":null}]}}'
CN_NFT_TARI='{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":"172.28.0.27"}},{"accept":null}]}}'
CN_NFT_DROP='{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":"172.28.0.0/24"}},{"drop":null}]}}'
if run_sourced "$V" tor_egress_sync_rules_match nft "{\"nftables\":[$CN_NFT_MONERO,$CN_NFT_TARI,$CN_NFT_DROP]}"; then
    ok "nft readback accepts authorized exceptions before DROP"
else bad "nft readback accepts authorized exceptions before DROP" "live rule mismatch"; fi
if run_sourced "$V" tor_egress_sync_rules_match nft "{\"nftables\":[$CN_NFT_MONERO,$CN_NFT_DROP,$CN_NFT_TARI]}"; then
    bad "nft readback refuses a Tari exception after DROP" "accepted ineffective exception"
else ok "nft readback refuses a Tari exception after DROP"; fi
CN_NFT_NEGATED="${CN_NFT_MONERO/\"op\":\"==\"/\"op\":\"!=\"}"
if run_sourced "$V" tor_egress_sync_rules_match nft "{\"nftables\":[$CN_NFT_NEGATED,$CN_NFT_TARI,$CN_NFT_DROP]}"; then
    bad "nft readback refuses a negated authorized source" "accepted a broad exception"
else ok "nft readback refuses a negated authorized source"; fi
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
mkdir -p "$CN_SDIR"
mkdir "$CN_SDIR/monero.synced"
ln -s "$CN_SDIR/missing-target" "$CN_SDIR/tari.synced"
assert_eq "malformed marker paths never authorize node exemptions" "$(run_sourced "$V" tor_egress_sync_ips)" ""
for entry in "$ROOT/build/monero/entrypoint.sh" "$ROOT/build/tari/entrypoint.sh"; do
    for marker in "$CN_SDIR/monero.synced" "$CN_SDIR/tari.synced"; do
        if (
            export PITHEAD_TEST_SOURCE=1 MONERO_CLEARNET_SYNC=true TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$marker"
            # shellcheck disable=SC1090  # both entrypoints are chosen by the loop above
            source "$entry"
            clearnet_sync_active
        ); then
            bad "malformed node marker keeps Tor" "clearnet active: $entry"
        else ok "malformed node marker keeps Tor"; fi
    done
done
rm -rf "$CN_SDIR/monero.synced" "$CN_SDIR/tari.synced"
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
if run_sourced "$V" tor_egress_sync_rules_match iptables "-A DOCKER-USER -s 172.28.0.26 -p tcp -j ACCEPT"; then
    bad "readback rejects a narrow stale Monero exemption" "accepted extra live ACCEPT"
else ok "readback rejects a narrow stale Monero exemption"; fi
CN_REFRESH_PROBE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090  # the generated CLI is supplied by the stack suite
    source "$STACK"
    set +e
    egress_sync_claim_marker() { return 0; }
    apply_tor_egress_firewall() { [ "$1" = refresh ] && printf 'refresh\n'; }
    tor_egress_enforced() {
        printf 'verify\n'
        return 1
    }
    egress_sync_refresh monero
    printf 'rc=%s\n' "$?"
)
assert_contains "host refresh is requested before live-rule readback" "$CN_REFRESH_PROBE" $'refresh\nverify'
assert_contains "failed readback keeps the transition pending" "$CN_REFRESH_PROBE" "rc=1"

CN_CDIR="$(cnfw_env CONTROL_DIR)"
[ -n "$CN_CDIR" ] || CN_CDIR="$V/data/control"
mkdir -p "$CN_CDIR/requests" "$CN_CDIR/results"
CN_RID=00000000-0000-4000-8000-000000000001
printf '{"id":"%s","action":"egress-sync","chain":"monero"}\n' "$CN_RID" >"$CN_CDIR/requests/$CN_RID.json"
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
printf '{"id":"%s","action":"egress-sync","chain":"tari"}\n' "$CN_RID" >"$CN_CDIR/requests/$CN_RID.json"
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
printf '00000000-0000-4000-8000-000000000001\n' >"$CN_SDIR/monero.synced"
CN_RESTART_PROBE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { case "$1" in inspect) printf '%s\n' "$STARTED" ;; exec) [ "${TOR_CONFIG:-good}" = good ] ;; esac }
    STARTED=old
    egress_sync_record_tor monero
    printf 'before=%s\n' "$([ -f "$CN_CDIR/results/clearnet-monero-tor.json" ] && echo yes || echo no)"
    STARTED=new TOR_CONFIG=bad
    egress_sync_record_tor monero && echo invalid=accepted || echo invalid=rejected
    STARTED=new TOR_CONFIG=good
    egress_sync_record_tor monero
    printf 'after=%s\n' "$(jq -r .status "$CN_CDIR/results/clearnet-monero-tor.json")"
)
assert_contains "old daemon start cannot authorize host completion" "$CN_RESTART_PROBE" "before=no"
assert_contains "bad Tor config after restart is a failed host refresh" "$CN_RESTART_PROBE" "invalid=rejected"
assert_contains "a new daemon start with Tor config permits attestation" "$CN_RESTART_PROBE" "after=verified"
python3 - "$CN_CDIR/results/clearnet-monero-baseline.json" "$CN_CDIR/results/clearnet-monero-tor.json" <<'PYCLEAN'
import os, sys
for path in sys.argv[1:]:
    os.unlink(path)
PYCLEAN
CN_SYMLINK_PROBE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    td=''
    mk_tmpdir td
    printf 'root-readable-secret\n' >"$td/secret"
    ln -s "$td/secret" "$td/monero.synced"
    clearnet_state_dir() { printf '%s' "$td"; }
    egress_sync_started_after_marker() { echo restarted; }
    egress_sync_runtime_on_tor() { return 0; }
    egress_sync_record_tor monero >/dev/null 2>&1 && echo accepted || echo rejected
    rm -rf "$td"
)
assert_eq "root runner refuses a symlinked dashboard marker" "$CN_SYMLINK_PROBE" "rejected"
CN_FIFO_PROBE=$(
    mk_tmpdir td
    mkfifo "$td/monero.synced"
    python3 - "$STACK" "$td/monero.synced" <<'PYFIFO'
import subprocess, sys
try:
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; egress_sync_marker_result "$2" >/dev/null 2>&1',
         "probe", sys.argv[1], sys.argv[2]], timeout=2, check=False)
except subprocess.TimeoutExpired:
    print("blocked")
else:
    print("rejected" if result.returncode else "accepted")
PYFIFO
    rm -rf "$td"
)
assert_eq "FIFO marker cannot block the root runner" "$CN_FIFO_PROBE" "rejected"
CN_STATUS_FIFO_PROBE=$(
    mk_tmpdir td
    mkfifo "$td/monero.synced"
    python3 - "$STACK" "$td" <<'PYFIFOSTATUS'
import os, subprocess, sys
try:
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; clearnet_state_dir() { printf "%s" "$STATE_DIR"; }; clearnet_tor_attested monero',
         "probe", sys.argv[1]], env={**os.environ, "STATE_DIR": sys.argv[2]},
        timeout=2, check=False)
except subprocess.TimeoutExpired:
    print("blocked")
else:
    print("rejected" if result.returncode else "accepted")
PYFIFOSTATUS
    rm -rf "$td"
)
assert_eq "FIFO marker cannot block status or doctor" "$CN_STATUS_FIFO_PROBE" "rejected"
CN_CLAIM_PROBE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    mk_tmpdir td
    printf '00000000-0000-4000-8000-000000000003\n' >"$td/monero.synced"
    clearnet_state_dir() { printf '%s' "$td"; }
    sudo() { if [ "$1" = chown ]; then echo "owner=$2"; else "$@"; fi; } # simulate root
    eval "$(declare -f egress_sync_marker_result | sed '1s/egress_sync_marker_result/real_egress_sync_marker_result/')"
    egress_sync_marker_result() {
        if [ -k "$td" ]; then
            real_egress_sync_marker_result "$1" | jq '.uid=0'
        else real_egress_sync_marker_result "$1"; fi
    }
    egress_sync_claim_marker monero
    printf 'clearnet initial sync complete; node returned to Tor (#234)\n' >"$td/tari.synced"
    egress_sync_claim_marker tari
    grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$td/tari.synced" && echo legacy=migrated
    python3 - "$td" <<'PYCLAIM'
import os, sys
directory = sys.argv[1]
print(f"directory={os.stat(directory).st_mode & 0o7777:o}")
print(f"marker={os.stat(directory + '/monero.synced').st_mode & 0o777:o}")
PYCLAIM
    rm -rf "$td"
)
assert_contains "host claim makes marker directory sticky" "$CN_CLAIM_PROBE" "directory=1777"
assert_contains "host claim makes the directory root-owned" "$CN_CLAIM_PROBE" "owner=root:root"
assert_contains "host claim makes marker non-writable to dashboard" "$CN_CLAIM_PROBE" "marker=644"
assert_contains "host claim migrates a legacy spent marker" "$CN_CLAIM_PROBE" "legacy=migrated"
CN_CLAIM_RACE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    mk_tmpdir td
    printf '00000000-0000-4000-8000-000000000004\n' >"$td/monero.synced"
    clearnet_state_dir() { printf '%s' "$td"; }
    sudo() {
        if [ "$1" = python3 ]; then
            rm "$td/monero.synced"
            mkdir "$td/monero.synced"
        fi
        case "$1" in chown) : ;; *) "$@" ;; esac
    }
    egress_sync_claim_marker monero >/dev/null 2>&1 && echo accepted || echo rejected
    [ -d "$td/monero.synced" ] && echo marker=directory
    rm -rf "$td"
)
assert_contains "directory swap during claim fails closed" "$CN_CLAIM_RACE" $'rejected\nmarker=directory'
CN_NO_RUNNER=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    mk_tmpdir td
    control_unit_dir() { printf '%s' "$td"; }
    env_get() { case "$1" in DASHBOARD_CONTROL_ENABLED) echo false ;; *_CLEARNET_SYNC) echo false ;; esac }
    systemctl() {
        echo called
        return 1
    }
    provision_egress_sync_runner && echo idle=ok || echo idle=failed
    [ ! -e "$td/pithead-egress-sync.path" ] && echo unit=absent
    rm -rf "$td"
)
assert_contains "no clearnet flags: no host request runner needed" "$CN_NO_RUNNER" $'idle=ok\nunit=absent'
CN_FAILED_REFRESH=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    mk_tmpdir td
    clearnet_state_dir() { printf '%s' "$td"; }
    egress_sync_claim_marker() { return 1; }
    apply_tor_egress_firewall() { printf 'refresh:%s\n' "$(tor_egress_sync_ips | tr '\n' ' ')"; }
    tor_egress_enforced() { echo verified; }
    egress_sync_refresh monero && echo accepted || echo pending
    rm -rf "$td"
)
assert_contains "failed claim still closes Monero and verifies live firewall" "$CN_FAILED_REFRESH" "refresh:172.28.0.27"
assert_contains "failed claim keeps the transition pending" "$CN_FAILED_REFRESH" $'verified\npending'
CN_ATTEST_PROBE=$(
    cd "$V" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    egress_sync_claim_marker() { return 0; }
    apply_tor_egress_firewall() { [ "$1" = refresh ]; }
    tor_egress_enforced() { return 0; }
    docker() { case "$1" in inspect) [ "$TOR_ACTIVE" = 1 ] && echo new || echo old ;; exec) return 0 ;; esac }
    egress_sync_runtime_on_tor() { [ "$TOR_ACTIVE" = 1 ]; }
    TOR_ACTIVE=0
    egress_sync_refresh monero
    printf 'before=%s\n' "$([ -f "$CN_CDIR/results/clearnet-monero-tor.json" ] && echo yes || echo no)"
    TOR_ACTIVE=1
    egress_sync_refresh monero
    printf 'after=%s\n' "$(jq -r '.status + ":" + .marker' "$CN_CDIR/results/clearnet-monero-tor.json")"
)
assert_contains "host does not attest before the daemon starts on Tor" "$CN_ATTEST_PROBE" "before=no"
assert_contains "host attests only after live Tor and firewall readback" "$CN_ATTEST_PROBE" "after=verified:00000000-0000-4000-8000-000000000001"
assert_eq "matching host attestation clears the transition" "$(run_sourced "$V" clearnet_tor_attested monero && echo yes)" "yes"
printf '00000000-0000-4000-8000-000000000002\n' >"$CN_SDIR/monero.synced"
if run_sourced "$V" clearnet_tor_attested monero; then
    bad "stale host result cannot complete a new transition" "accepted prior marker"
else ok "stale host result cannot complete a new transition"; fi
if run_sourced "$V" clearnet_sync_active; then
    ok "pending refresh keeps the exposure warning active"
else
    bad "pending refresh keeps the exposure warning active" "cleared before Tor restart"
fi
: >"$CN_SDIR/monero.synced.tor"
: >"$CN_SDIR/tari.synced.tor"
if run_sourced "$V" clearnet_sync_active; then
    ok "dashboard-writable completion files cannot clear the warning"
else
    bad "dashboard-writable completion files cannot clear the warning" "forged result accepted"
fi
printf '00000000-0000-4000-8000-000000000002\n' >"$CN_SDIR/tari.synced"
for chain in monero tari; do
    python3 - "$CN_SDIR/$chain.synced" "$CN_CDIR/results/clearnet-$chain-tor.json" <<'PYFIXTURE'
import json, os, sys
st = os.stat(sys.argv[1])
with open(sys.argv[1]) as fh:
    marker = fh.read().strip()
with open(sys.argv[2], "w") as fh:
    json.dump({"status": "verified", "marker": marker, "inode": st.st_ino,
               "ctime_ns": st.st_ctime_ns}, fh)
PYFIXTURE
done
if run_sourced "$V" clearnet_sync_active; then
    bad "verified Tor completion clears exposure warning" "still active"
else ok "verified Tor completion clears exposure warning"; fi
# The sandbox's sudo normally no-ops every command. Model the host-owned marker cleanup here.
cp "$V/bin/sudo" "$V/bin/sudo.before-clearnet"
printf '#!/usr/bin/env bash\n[ "$1" != rm ] || exec "$@"\nexit 0\n' >"$V/bin/sudo"
cnfw_apply false true
[ -f "$CN_SDIR/monero.synced" ] &&
    bad "monero flag off: apply re-arms by removing its marker" "marker kept" ||
    ok "monero flag off: apply re-arms by removing its marker"
[ -f "$CN_SDIR/tari.synced" ] &&
    ok "tari flag still on: its marker stays" ||
    bad "tari flag still on: its marker stays" "marker removed"
rm -f "$CN_SDIR/monero.synced" "$CN_SDIR/tari.synced" "$CN_SDIR/monero.synced.tor" "$CN_SDIR/tari.synced.tor"
cnfw_apply false false
mv "$V/bin/sudo.before-clearnet" "$V/bin/sudo"
unset -f cnfw_apply cnfw_env
