#!/usr/bin/env bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== unit: gate_tor_transport_verdict reads tor's OWN transport state from its healthcheck (#4049) =="
_bnv_verdict() {
    (
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-boot-stack-health"
        docker() {
            case "$*" in
            "compose ps -aq tor") printf '%s' "$BNV_PS" ;;
            inspect*) printf '%s' "$BNV_INSPECT" ;;
            esac
        }
        gate_tor_transport_verdict
    )
}
assert_eq "tor running with a passing healthcheck is up" \
    "$(BNV_PS='torcid
' BNV_INSPECT='running healthy' _bnv_verdict)" "up"
assert_eq "tor running but stuck short of bootstrapped (unhealthy) is wedged — the #3052 stall, not a crash" \
    "$(BNV_PS='torcid
' BNV_INSPECT='running unhealthy' _bnv_verdict)" "wedged"
assert_eq "tor running but still starting is wedged too (the gate cannot know it will ever pass)" \
    "$(BNV_PS='torcid
' BNV_INSPECT='running starting' _bnv_verdict)" "wedged"
assert_eq "a tor with no healthcheck at all is down, never wedged (the wedge verdict needs the probe)" \
    "$(BNV_PS='torcid
' BNV_INSPECT='running none' _bnv_verdict)" "down"
assert_eq "an exited tor is down: an engine or slot fault, and the fallback stays worth spending" \
    "$(BNV_PS='torcid
' BNV_INSPECT='exited unhealthy' _bnv_verdict)" "down"
assert_eq "no tor container is down" \
    "$(BNV_PS='' BNV_INSPECT='running healthy' _bnv_verdict)" "down"
assert_eq "a failing docker inspect is down, never a guess" \
    "$(BNV_PS='torcid
' BNV_INSPECT='' _bnv_verdict)" "down"

echo "== unit: gate_blocked_only_by_network commits only on faults the previous version carries too (#4049) =="
BNV_BRANCH_CHAINM="Monero node is NOT following the chain; mining sits on a stale tip: 0 outgoing peers in 10 min — next: check the network"
BNV_BRANCH_SAT="Tor's circuit-build-time history is saturated and clearnet egress is down. When auto-heal is enabled, its final step requests host-gated state recovery."
BNV_BRANCH_DOWNM="monerod is down (created) — a chain node down means the slot is not healthy to commit"
BNV_BRANCH_NOTRW="wallet-rpc is not ready (Up 2 minutes (starting)) — a chain node must be up and healthy to commit"
BNV_BRANCH_EGRESS="Egress firewall rules are MISSING — clearnet escapes around Tor are possible"
BNV_BRANCH_CERT="The dashboard certificate does not cover: fd00::1"
BNV_BRANCH_P2U="p2pool is running but unhealthy (Up 3 hours (unhealthy))"
BNV_BRANCH_TORLINE="container tor: running but UNHEALTHY (Tor health: bootstrap progress=95 tag=circuit_create.)"
_bnv_dj() {
    local checks="" s m
    while [ $# -ge 2 ]; do
        s=$1
        m=$2
        shift 2
        checks="$checks${checks:+,}{\"status\":\"$s\",\"message\":\"$m\"}"
    done
    printf '{"version":"t","exit":1,"summary":{"ok":0,"warn":0,"fail":0},"checks":[%s]}\n' "$checks"
}
mk_tmpdir _BNV
_bnv_net() {
    if [ "$4" = NOFILE ]; then rm -f "$_BNV/doctor.json"; else printf '%s\n' "$3" >"$_BNV/doctor.json"; fi
    (
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$_BNV/doctor.json"
        gate_blocked_only_by_network "$1" "$2" && printf 'advisory:%s\n' "$GATE_NETWORK_ADVISORY" || echo not
    )
}
_BNV_OUT=$(_bnv_net wedged "container monerod: created
$BNV_BRANCH_TORLINE" "$(_bnv_dj fail "$BNV_BRANCH_DOWNM" fail "$BNV_BRANCH_SAT")" J)
assert_contains "wedged tor: chain nodes down and the saturated history are the network, not the slot" "$_BNV_OUT" "advisory:"
assert_contains "the advisory names the saturated tor history" "$_BNV_OUT" "saturated and clearnet egress is down"
assert_contains "the advisory names the down chain node" "$_BNV_OUT" "monerod is down"
assert_contains "the advisory carries the unhealthy tor row" "$_BNV_OUT" "container tor: running but UNHEALTHY"
assert_eq "the chain verdict is the network even with tor up (this box has no peers, nothing is crashed)" \
    "$(_bnv_net up '' "$(_bnv_dj fail "$BNV_BRANCH_CHAINM")" J)" "advisory:$BNV_BRANCH_CHAINM"
assert_eq "the wallet-rpc not-ready shape is allowed while wedged (it waits on monerod, tor waits on nothing)" \
    "$(_bnv_net wedged '' "$(_bnv_dj fail "$BNV_BRANCH_NOTRW")" J)" "advisory:$BNV_BRANCH_NOTRW"
assert_eq "a chain node down with tor UP is the slot (crash loop, network up: the fallback must still fire)" \
    "$(_bnv_net up '' "$(_bnv_dj fail "$BNV_BRANCH_DOWNM")" J)" "not"
assert_eq "a chain node down with tor DOWN is the slot (nothing network is proven when the engine is dead)" \
    "$(_bnv_net down '' "$(_bnv_dj fail "$BNV_BRANCH_DOWNM")" J)" "not"
assert_eq "the saturated history with tor down is not advice (tor not running is never the wedge)" \
    "$(_bnv_net down '' "$(_bnv_dj fail "$BNV_BRANCH_SAT")" J)" "not"
assert_eq "the saturated history with tor wedged is the network" \
    "$(_bnv_net wedged '' "$(_bnv_dj fail "$BNV_BRANCH_SAT")" J)" "advisory:$BNV_BRANCH_SAT"
assert_eq "a wedged box with a MISSING egress firewall still falls back (fail-open privacy is the slot's)" \
    "$(_bnv_net wedged '' "$(_bnv_dj fail "$BNV_BRANCH_SAT" fail "$BNV_BRANCH_EGRESS")" J)" "not"
assert_eq "a wedged box whose certificate does not cover a name still falls back (#1265 owns that path)" \
    "$(_bnv_net wedged '' "$(_bnv_dj fail "$BNV_BRANCH_SAT" fail "$BNV_BRANCH_CERT")" J)" "not"
assert_eq "p2pool running-but-unhealthy while wedged still falls back (a miner crash is not tor's gate)" \
    "$(_bnv_net wedged '' "$(_bnv_dj fail "$BNV_BRANCH_SAT" fail "$BNV_BRANCH_P2U")" J)" "not"
assert_eq "the tor row alone while wedged is enough to advise (doctor may hold no fail at all)" \
    "$(_bnv_net wedged "$BNV_BRANCH_TORLINE" "$(_bnv_dj)" J)" "advisory:$BNV_BRANCH_TORLINE"
assert_eq "the tor row while tor is UP is a contradiction, not advice" \
    "$(_bnv_net up "$BNV_BRANCH_TORLINE" "$(_bnv_dj)" J)" "not"
assert_eq "one non-network row vetoes the whole window (caddy exited is the slot)" \
    "$(_bnv_net wedged "$BNV_BRANCH_TORLINE
container caddy: exited" "$(_bnv_dj fail "$BNV_BRANCH_SAT")" J)" "not"
assert_eq "a crash-looping p2pool row vetoes the window even while wedged" \
    "$(_bnv_net wedged "container p2pool: restarting (possible crash loop — check logs)" "$(_bnv_dj fail "$BNV_BRANCH_SAT")" J)" "not"
assert_eq "no fails and no blocking rows leaves nothing to advise (a healthy gate passes on its own)" \
    "$(_bnv_net wedged '' "$(_bnv_dj)" J)" "not"
assert_eq "warns are not fails: nothing to advise" \
    "$(_bnv_net wedged '' "$(_bnv_dj ok 'a' warn 'b')" J)" "not"
assert_eq "no doctor file at all refuses the advisory commit" \
    "$(_bnv_net wedged '' '' NOFILE)" "not"
assert_eq "a malformed doctor file refuses the advisory commit" \
    "$(_bnv_net wedged '' 'not json' J)" "not"
_BNV_LONG=$(printf 'x%.0s' $(seq 700))
assert_eq "the advisory is bounded so one wall of text cannot flood the banner" \
    "$(_bnv_net wedged '' "$(_bnv_dj fail "${BNV_BRANCH_SAT}${_BNV_LONG}")" J | awk '{print length($0) - 9}')" "480"

echo "== unit: doctor's own messages stay word-for-word what the classifier matches (#4049) =="
assert_eq "the Monero chain FAIL the classifier allows is doctor's message, verbatim at source" \
    "$(grep -c 'dr_fail "Monero node is NOT following the chain; mining sits on a stale tip:' "$ROOT/lib/pithead/05-doctor-checks.sh")" "1"
assert_eq "the Tari chain FAIL the classifier allows is doctor's message, verbatim at source" \
    "$(grep -c 'dr_fail "Tari node is NOT following the chain; merge-mined Tari work is wasted:' "$ROOT/lib/pithead/05-doctor-checks.sh")" "1"
assert_eq "the saturated-history FAIL both arms of which the classifier allows is doctor's message at source" \
    "$(grep -c "dr_fail_surface \"Tor's circuit-build-time history is saturated and clearnet egress is down" "$ROOT/lib/pithead/21-doctor-stack-checks.sh")" "1"
assert_eq "the down shape the classifier allows is the revenue verdict's own" \
    "$(grep -c "printf 'fail:%s is down (%s) — a chain node down means the slot is not healthy to commit" "$ROOT/lib/pithead/21-doctor-stack-checks.sh")" "1"
assert_eq "the not-ready half of that shape, pinned too" \
    "$(grep -c "printf 'fail:%s is not ready (%s) — a chain node must be up and healthy to commit" "$ROOT/lib/pithead/21-doctor-stack-checks.sh")" "1"
assert_eq "the classifier's wedged name set is doctor's chain-container set, one list not two" \
    "$(grep -c "container tor: '\\* | 'container monerod: '\\* | 'container tari: '\\* | 'container wallet-rpc: '\\* | 'container tari-wallet: '\\*" "$ROOT/os/overlay/pithead-boot-stack-health")" "1"
assert_eq "the source of that name set stays what doctor itself declares" \
    "$(grep -c 'REVENUE_CHAIN_CONTAINERS="monerod tari wallet-rpc tari-wallet"' "$ROOT/lib/pithead/21-doctor-stack-checks.sh")" "1"

echo "== unit: boot's own blocker render feeds the classifier without restating it (#4049) =="
mk_tmpdir _BNV2
cat >"$_BNV2/status.log" <<EOF
  ✓ dashboard  running
  ✗ monero chain  NOT following the chain: 0 outgoing peers in 10 min — next: check tor
EOF
printf '%s\n' "$(_bnv_dj fail "$BNV_BRANCH_CHAINM")" >"$_BNV2/doctor.json"
_BNV_PIPE=$(
    (
        cd "$_BNV2" || exit 1
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-boot-stack-health"
        BOOT_STATUS_LOG="$_BNV2/status.log"
        BOOT_DOCTOR_JSON="$_BNV2/doctor.json"
        _blocked=$(boot_status_blocking)
        gate_blocked_only_by_network up "$_blocked" && echo "advisory:$GATE_NETWORK_ADVISORY" || echo not
    )
)
assert_contains "the chain row as boot renders it classifies as the network (sed render bound to the matcher)" "$_BNV_PIPE" "container monero: chain"
assert_contains "the render keeps the detail text the matcher stops before" "$_BNV_PIPE" "NOT following the chain"
cat >>"$_BNV2/status.log" <<EOF
  ⚠ tor  running but UNHEALTHY (Tor health: bootstrap progress=95 tag=circuit_create.)
EOF
printf '%s\n' "$(_bnv_dj)" >"$_BNV2/doctor.json"
_BNV_PIPE2=$(
    (
        cd "$_BNV2" || exit 1
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-boot-stack-health"
        BOOT_STATUS_LOG="$_BNV2/status.log"
        BOOT_DOCTOR_JSON="$_BNV2/doctor.json"
        _blocked=$(boot_status_blocking)
        gate_blocked_only_by_network wedged "$_blocked" && echo "advisory:$GATE_NETWORK_ADVISORY" || echo not
    )
)
assert_contains "with tor wedged the rendered tor row is network too" "$_BNV_PIPE2" "container tor: running but UNHEALTHY"
printf '%s\n' "  ✗ wallet-rpc  created" >"$_BNV2/status.log"
_BNV_PIPE3=$(
    (
        cd "$_BNV2" || exit 1
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-boot-stack-health"
        BOOT_STATUS_LOG="$_BNV2/status.log"
        BOOT_DOCTOR_JSON="$_BNV2/doctor.json"
        _blocked=$(boot_status_blocking)
        gate_blocked_only_by_network up "$_blocked" && echo "advisory:$GATE_NETWORK_ADVISORY" || echo not
    )
)
assert_eq "with tor UP a created wallet-rpc is the slot, and the real render reaches the matcher" "$_BNV_PIPE3" "not"
rm -rf "$_BNV2"

echo "== unit: gate_network_advisory_commit commits the slot and names the fault; anything else stays uncommitted (#4049) =="
_bnv_commit() {
    (
        cd "$_BNV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$_BNV/doctor.json"
        BOOT_STATUS_LOG="$_BNV/status.log"
        OS_INFLIGHT="$_BNV/in-flight.json"
        OS_STATE_DIR="$_BNV/state"
        hold_chain=0
        migration_fingerprint=
        rauc() { printf 'rauc %s\n' "$*" >>"$_BNV/rauc.log"; }
        curl() {
            cat >/dev/null
            printf '%s %s' "$BNV_CODE" "$BNV_SIZE"
        }
        docker() {
            case "$*" in
            "compose ps -aq tor") printf 'torcid\n' ;;
            inspect*) printf 'running unhealthy\n' ;;
            esac
        }
        gate_network_advisory_commit
    )
}
_bnv_commit_reset() {
    rm -f "$_BNV/rauc.log" "$_BNV/in-flight.json" "$_BNV/.boot-gate-failures"
    rm -rf "$_BNV/state"
    printf '9.9.9\n' >"$_BNV/VERSION"
    printf 'HOST_IP=localhost\nDASHBOARD_AUTH_HASH_B64=hash\nDASHBOARD_DATA_DIR=%s/dash\n' "$_BNV" >"$_BNV/.env"
    mkdir -p "$_BNV/dash"
    cat >"$_BNV/pithead" <<'STUB'
#!/usr/bin/env bash
stamp_config_version() { :; }
[ "${BASH_SOURCE[0]}" != "$0" ] && exit 0
case "$1" in
doctor)
    cat doctor-fixture.json
    grep -q '"status":"fail"' doctor-fixture.json && exit 1
    ;;
status)
    cat status-fixture.log
    grep -q '✗\|UNHEALTHY' status-fixture.log && exit 1
    ;;
esac
exit 0
STUB
    chmod +x "$_BNV/pithead"
}
_bnv_wedge_setup() {
    _bnv_commit_reset
    printf '%s\n' "$(_bnv_dj fail "$BNV_BRANCH_DOWNM" fail "$BNV_BRANCH_SAT")" >"$_BNV/doctor-fixture.json"
    printf '✗ monerod  created\n⚠ tor  running but UNHEALTHY (Tor health: bootstrap progress=95 tag=circuit_create.)\n' >"$_BNV/status-fixture.log"
    printf '{"from":"1.0.0","to":"9.9.9"}\n' >"$_BNV/in-flight.json"
    : >"$_BNV/.boot-gate-failures"
}
_bnv_wedge_setup
_BNV_OUT=$(BNV_CODE=401 BNV_SIZE=0 _bnv_commit)
assert_rc "wedged network, dashboard serving: the boot commits instead of spending the fallback" "$?" "0"
assert_contains "the commit names the fault on the console so the journal does too" "$_BNV_OUT" "this machine's network, not the slot"
assert_contains "the console line says the slot commits with the fault recorded as advisory" "$_BNV_OUT" "commits with the fault recorded as advisory"
assert_eq "the booted slot is committed (rauc mark-good ran)" "$(cat "$_BNV/rauc.log")" "rauc status mark-good"
assert_eq "the update verdict outcome is updated (the OS update landed through the wedge)" \
    "$(jq -r '.verdict.outcome' "$_BNV/state/os-update-state.json")" "updated"
assert_contains "the update verdict carries the network fault as advisory" \
    "$(jq -r '.verdict.advisory[0]' "$_BNV/state/os-update-state.json")" "saturated and clearnet egress is down"
assert_eq "the in-flight flag is consumed" "$(test -f "$_BNV/in-flight.json" && echo yes || echo no)" "no"
assert_eq "the boot-failure counter is cleared, so a later real fault still gets its one reboot" \
    "$(test -f "$_BNV/.boot-gate-failures" && echo yes || echo no)" "no"
_bnv_wedge_setup
_BNV_OUT=$(BNV_CODE=000 BNV_SIZE=0 _bnv_commit)
assert_rc "no dashboard answer means no commit, whatever the network story (serving is a product promise)" "$?" "1"
assert_eq "rauc never ran" "$(test -f "$_BNV/rauc.log" && echo yes || echo no)" "no"
assert_eq "the in-flight flag survives a refused commit (fail_boot still gets to name it)" \
    "$(test -f "$_BNV/in-flight.json" && echo yes || echo no)" "yes"
_bnv_commit_reset
printf '%s\n' "$(_bnv_dj fail "$BNV_BRANCH_SAT" fail "$BNV_BRANCH_EGRESS")" >"$_BNV/doctor-fixture.json"
printf '⚠ tor  running but UNHEALTHY (x)\n' >"$_BNV/status-fixture.log"
BNV_CODE=401 BNV_SIZE=0 _bnv_commit >/dev/null
assert_rc "a wedged box with a slot-class fail among the blockers stays uncommitted" "$?" "1"
assert_eq "rauc never ran there either" "$(test -f "$_BNV/rauc.log" && echo yes || echo no)" "no"
_bnv_commit_reset
printf '%s\n' "$(_bnv_dj ok 'all good')" >"$_BNV/doctor-fixture.json"
: >"$_BNV/status-fixture.log"
BNV_CODE=200 BNV_SIZE=120 _bnv_commit >/dev/null
assert_rc "a world with no failing check has nothing to advise: the ordinary gate pass owns it, not this path" "$?" "1"
assert_eq "and nothing is committed on that path" "$(test -f "$_BNV/rauc.log" && echo yes || echo no)" "no"
_bnv_commit_reset
printf '%s\n' "$(_bnv_dj fail "$BNV_BRANCH_SAT")" >"$_BNV/doctor-fixture.json"
printf '⚠ tor  running but UNHEALTHY (x)\n' >"$_BNV/status-fixture.log"
BNV_CODE=401 BNV_SIZE=0 _bnv_commit >/dev/null
assert_rc "with no in-flight update flag the commit still stands and publishes no verdict" "$?" "0"
assert_eq "and no verdict file is written outside an update" "$(test -f "$_BNV/state/os-update-state.json" && echo yes || echo no)" "no"
rm -rf "$_BNV"

echo "== unit: boot_publish_os_update_verdict keeps the success-half semantics it was extracted with (#4049) =="
mk_tmpdir _BNV3
_bnv_publish() {
    (
        cd "$_BNV3" || exit 1
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-boot-stack-health"
        OS_INFLIGHT="$_BNV3/in-flight.json"
        OS_STATE_DIR="$_BNV3/state"
        boot_publish_os_update_verdict "$2"
    )
}
printf '9.9.9\n' >"$_BNV3/VERSION"
printf '{"from":"1.0.0","to":"9.9.9"}\n' >"$_BNV3/in-flight.json"
_bnv_publish x 'the fault' >/dev/null
assert_eq "the verdict names the update landed" "$(jq -r '.verdict.outcome' "$_BNV3/state/os-update-state.json")" "updated"
assert_eq "the advisory array carries the fault" "$(jq -r '.verdict.advisory[0]' "$_BNV3/state/os-update-state.json")" "the fault"
printf '{"from":"1.0.0","to":"9.9.9"}\n' >"$_BNV3/in-flight.json"
_bnv_publish x '' >/dev/null
assert_eq "no advisory stays an empty array (the healthy pass is unchanged)" \
    "$(jq -c '.verdict.advisory' "$_BNV3/state/os-update-state.json")" "[]"
assert_eq "the flag is consumed whatever the advisory" "$(test -f "$_BNV3/in-flight.json" && echo yes || echo no)" "no"
printf '{"from":"1.0.0","to":"8.0.0"}\n' >"$_BNV3/in-flight.json"
rm -rf "$_BNV3/state"
_bnv_publish x '' >/dev/null
assert_eq "an in-flight flag naming another version publishes no updated verdict (unchanged semantics)" \
    "$(test -f "$_BNV3/state/os-update-state.json" && echo yes || echo no)" "no"
assert_eq "and that flag is still consumed (unchanged semantics)" "$(test -f "$_BNV3/in-flight.json" && echo yes || echo no)" "no"
rm -f "$_BNV3/in-flight.json"
_bnv_publish x '' >/dev/null
assert_rc "no in-flight flag is a silent no-op" "$?" "0"
rm -rf "$_BNV3"

echo "== wiring: both fail paths consult the network advisory before spending the fallback (#4049) =="
_BNV_TAIL=$(tail -n 2 "$ROOT/os/overlay/pithead-boot")
assert_eq "the 16-minute window ends in the classifier, and only then in fail_boot" \
    "$_BNV_TAIL" \
    'if [ "$(gate_tor_transport_verdict)" = wedged ] && gate_network_advisory_commit; then exit 0; fi
fail_boot "the stack never became healthy (serving + doctor + status)"'
_BNV_UPF=$(sed -n '/^boot_up_failed()/,/^}/p' "$ROOT/os/overlay/pithead-boot")
_BNV_L1=$(printf '%s\n' "$_BNV_UPF" | grep -n fail_boot_contended | head -1 | cut -d: -f1)
_BNV_L2=$(printf '%s\n' "$_BNV_UPF" | grep -n gate_network_advisory_commit | head -1 | cut -d: -f1)
_BNV_L3=$(printf '%s\n' "$_BNV_UPF" | grep -n '    fail_boot ' | head -1 | cut -d: -f1)
assert_eq "an up failure still exits for contention before anything else" \
    "$([ "$_BNV_L1" -lt "$_BNV_L2" ] && echo before)" "before"
assert_eq "an up failure consults the wedge before fail_boot" \
    "$([ "$_BNV_L2" -lt "$_BNV_L3" ] && echo before)" "before"
assert_eq "the healthy pass publishes its verdict through the shared function, so both halves cannot drift" \
    "$(grep -c 'boot_publish_os_update_verdict "\$gate_advisory"' "$ROOT/os/overlay/pithead-boot")" "1"
assert_eq "both gate exits, up-failure and window-timeout, carry the classifier" \
    "$(grep -c 'gate_network_advisory_commit' "$ROOT/os/overlay/pithead-boot")" "2"
assert_eq "the certificate-only trigger stays exactly as #1265 wrote it (this change adds no other mid-loop advisory)" \
    "$(grep -c 'gate_blocked_only_by_cert; then' "$ROOT/os/overlay/pithead-boot")" "1"
assert_eq "the boot gate's three-signal pass path is unchanged by this change (regression pin)" \
    "$(grep -c 'if gate_ready "${code:-000}" "${size:-0}"; then' "$ROOT/os/overlay/pithead-boot")" "1"

unset -f _bnv_verdict _bnv_dj _bnv_net _bnv_commit _bnv_commit_reset _bnv_wedge_setup _bnv_publish
unset _BNV _BNV2 _BNV3 _BNV_OUT _BNV_PIPE _BNV_PIPE2 _BNV_PIPE3 _BNV_TAIL _BNV_UPF _BNV_L1 _BNV_L2 _BNV_L3 _BNV_LONG
unset BNV_PS BNV_INSPECT BNV_CODE BNV_SIZE BNV_BRANCH_CHAINM BNV_BRANCH_SAT BNV_BRANCH_DOWNM BNV_BRANCH_NOTRW
unset BNV_BRANCH_EGRESS BNV_BRANCH_CERT BNV_BRANCH_P2U BNV_BRANCH_TORLINE
