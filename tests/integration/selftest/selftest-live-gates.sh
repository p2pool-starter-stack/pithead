#!/usr/bin/env bash
# Small pure-logic check for live-gates.sh; no server required.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The modules resolve their own siblings off $HERE, which is the harness root, not selftest/.
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"
# run-safety.sh carries the suite guard; this self-test IS a suite consumer of it.
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-safety.sh
source "$HERE/lib/run-safety.sh"

if python3 "$HERE/lib/xvb-egress-probe.py" --self-test; then
    it_pass "XvB socket guard self-test"
else
    it_fail "XvB socket guard self-test" "probe accepted non-Tor DNS or socket egress"
fi
if python3 "$HERE/lib/migration-state-probe.py" --self-test; then
    it_pass "durable migration-state probe self-test"
else
    it_fail "durable migration-state probe self-test"
fi

baseline=$'dashboard\t/data\t/shared/dashboard\tbind\ndashboard\t/clearnet-state\t/old/data/clearnet-state\tbind'
candidate=$'dashboard\t/data\t/shared/dashboard\tbind\ndashboard\t/clearnet-state\t/new/data/clearnet-state\tbind'
assert_eq "mount comparison permits only the modeled per-release internal-state move" \
    "$(normalized_stateful_mounts /old "$baseline")" "$(normalized_stateful_mounts /new "$candidate")"
if normalized_stateful_mounts /wrong "$candidate" >/dev/null 2>&1; then
    it_fail "mount comparison rejects an internal-state source outside the exact release dir"
else
    it_pass "mount comparison rejects an internal-state source outside the exact release dir"
fi

if (
    _pred_proxy_route() { [ "$1 $2" = "XVB pool.example:1234" ]; }
    rx() { [[ "$1" == *"timestamp > ? AND v_xvb > 0"*" 123" ]] && echo 1; }
    _pred_fresh_xvb_history_on_route 123 pool.example:1234
); then
    it_pass "XvB work proof requires a fresh positive route-specific history row"
else
    it_fail "XvB work proof requires a fresh positive route-specific history row"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir "$td/bin" "$td/src1" "$td/src2" "$td/.pithead-live-src1-n" "$td/.pithead-live-src2-n"
    printf candidate >"$td/src1/value"
    printf candidate >"$td/src2/value"
    printf baseline >"$td/.pithead-live-src1-n/value"
    printf baseline >"$td/.pithead-live-src2-n/value"
    printf '%s\n' '#!/bin/sh' '[ "$1" != -n ] || shift' 'exec "$@"' >"$td/bin/sudo"
    printf '%s\n' '#!/bin/sh' 'shift 3; case "$1" in *src2*) exit 1;; esac' 'exec /bin/cp -R "$1" "$2"' >"$td/bin/cp"
    printf '%s\n' '#!/bin/sh' 'printf x >>"$MV_LOG"' 'exec /bin/mv "$@"' >"$td/bin/mv"
    chmod +x "$td/bin/"*
    export PATH="$td/bin:$PATH" MV_LOG="$td/moves"
    rx() { bash -c "$1"; }
    UPGRADE_STATE_SNAPSHOTS="$td/src1"$'\t'"$td/.pithead-live-src1-n"$'\n'"$td/src2"$'\t'"$td/.pithead-live-src2-n"
    UPGRADE_STATE_OLD_DIRS=""
    ! restore_state_snapshots && [ "$(cat "$td/src1/value")" = candidate ] && [ ! -e "$MV_LOG" ]
); then
    it_pass "an nth-snapshot copy failure performs no source swaps"
else
    it_fail "an nth-snapshot copy failure performs no source swaps"
fi

# The mid-swap gap: `mv source old` lands, `mv replacement source` fails, and the inner recovery
# `mv old source` fails too — so the live path is GONE and the only copy is at $old. The entry has
# to be on the rollback list for that to be undoable, which is why it is recorded BEFORE the swap.
# The fixture lets the recovery move succeed on its SECOND attempt, so a run that never recorded
# the entry leaves src2 absent, and one that did puts it back.
if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir "$td/bin" "$td/src1" "$td/src2" "$td/.pithead-live-src1-n" "$td/.pithead-live-src2-n"
    printf candidate >"$td/src1/value"
    printf candidate >"$td/src2/value"
    printf baseline >"$td/.pithead-live-src1-n/value"
    printf baseline >"$td/.pithead-live-src2-n/value"
    printf '%s\n' '#!/bin/sh' '[ "$1" != -n ] || shift' 'exec "$@"' >"$td/bin/sudo"
    printf '%s\n' '#!/bin/sh' 'shift 3' 'exec /bin/cp -R "$1" "$2"' >"$td/bin/cp"
    printf '%s\n' '#!/bin/sh' \
        'src="$2"; dst="$3"' \
        'case "$dst" in */src2)' \
        '  case "$src" in' \
        '    *.pithead-restore-*) exit 1 ;;' \
        '    *.pithead-old-*) if [ ! -f "$RECOVER_ONCE" ]; then : >"$RECOVER_ONCE"; exit 1; fi ;;' \
        '  esac ;;' \
        'esac' \
        'exec /bin/mv "$@"' >"$td/bin/mv"
    chmod +x "$td/bin/"*
    export PATH="$td/bin:$PATH" RECOVER_ONCE="$td/recover-once"
    rx() { bash -c "$1"; }
    UPGRADE_STATE_SNAPSHOTS="$td/src1"$'\t'"$td/.pithead-live-src1-n"$'\n'"$td/src2"$'\t'"$td/.pithead-live-src2-n"
    UPGRADE_STATE_OLD_DIRS=""
    ! restore_state_snapshots &&
        [ "$(cat "$td/src2/value" 2>/dev/null)" = candidate ] &&
        [ "$(cat "$td/src1/value" 2>/dev/null)" = candidate ]
); then
    it_pass "a swap whose own recovery fails is still rolled back (the live path comes back)"
else
    it_fail "a swap whose own recovery fails is still rolled back (the live path comes back)"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then printf "tor\\np2pool\\nxmrig-proxy\\n"; exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo cid; exit 0; fi' \
        'exit 125' >"$td/docker" && chmod +x "$td/docker"
    out="$(PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" tor --dir "$td" --polls 1 --interval 0 2>&1)"
    rc=$?
    [ "$rc" = 2 ] && [[ "$out" == *INCONCLUSIVE* ]] && [[ "$out" != *"[verify-egress] OK"* ]]
); then
    it_pass "egress verifier fails inconclusive when live sockets are unreadable"
else
    it_fail "egress verifier fails inconclusive when live sockets are unreadable"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/usr/bin/env python3' 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' >"$td/setsid" && chmod +x "$td/setsid"
    : >"$td/heartbeat"
    PATH="$td:$PATH" bash "$HERE/live-supervised-run.sh" "$td/result" "$td/heartbeat" 60 bash -c 'exit 7'
    [ "$?" = 7 ] && [ "$(cat "$td/result")" = 7 ] || exit 1
    rm "$td/result"
    PATH="$td:$PATH" bash "$HERE/live-supervised-run.sh" "$td/result" "$td/heartbeat" 60 true
    [ "$?" = 0 ] && [ "$(cat "$td/result")" = 0 ]
); then
    it_pass "durable runner publishes fast zero and nonzero exit status"
else
    it_fail "durable runner publishes fast zero and nonzero exit status"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/usr/bin/env python3' 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' >"$td/setsid" && chmod +x "$td/setsid"
    : >"$td/heartbeat"
    PATH="$td:$PATH" bash "$HERE/live-supervised-run.sh" "$td/result" "$td/heartbeat" 1 bash -c 'trap "touch \"$1\"" EXIT; sleep 10' _ "$td/restored"
    [ "$?" = 124 ] && [ "$(cat "$td/result")" = 124 ] && [ -f "$td/restored" ]
); then
    it_pass "durable runner bounds the payload and lets its EXIT rollback finish"
else
    it_fail "durable runner bounds the payload and lets its EXIT rollback finish"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir "$td/bin"
    printf '%s\n' 'TOR_EGRESS_TAG=pithead-tor-egress' 'container_engine() { echo docker; }' 'env_get() { :; }' \
        'tor_egress_rules() { printf "%s\n" "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "-s 172.28.0.25 -j ACCEPT" "-s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT" "-s 172.28.0.0/24 -d 172.16.0.0/12 -j ACCEPT" "-s 172.28.0.0/24 -d 192.168.0.0/16 -j ACCEPT" "-s 172.28.0.0/24 -d 100.64.0.0/10 -j ACCEPT" "-s 172.28.0.0/24 -j DROP"; }' 'apply_tor_egress_firewall() { :; }' \
        'error() { exit 1; }' 'main() { apply_tor_egress_firewall; printf "%s" "$1" > called; }' >"$td/pithead"
    printf '%s\n' '#!/bin/sh' 'shift; [ "$1 $2" != "iptables -S" ] || printf "%s\n" "-A DOCKER-USER -m comment --comment pithead-tor-egress -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT" "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT" "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -d 172.16.0.0/12 -j ACCEPT" "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -d 192.168.0.0/16 -j ACCEPT" "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -d 100.64.0.0/10 -j ACCEPT" "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"' >"$td/bin/sudo"
    chmod +x "$td/bin/sudo"
    IT_REMOTE_DIR="$td" PATH="$td/bin:$PATH"
    rx() { (cd "$IT_REMOTE_DIR" && bash -c "$1"); }
    for cmd in apply up upgrade; do
        strict_pithead "$cmd" && [ "$(cat "$td/called")" = "$cmd" ] || exit 1
    done
); then
    it_pass "strict firewall wrapper dispatches apply, up, and upgrade"
else
    it_fail "strict firewall wrapper dispatches apply, up, and upgrade"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then echo tor; exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo cid; exit 0; fi' \
        'if [ "$1" = exec ]; then printf "  sl  local_address rem_address st\\n"; exit 0; fi' \
        'exit 125' >"$td/docker" && chmod +x "$td/docker"
    out="$(PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" tor --dir "$td" --polls 1 --interval 0 2>&1)"
    rc=$?
    [ "$rc" = 2 ] && [[ "$out" == *INCONCLUSIVE* ]] && [[ "$out" != *"[verify-egress] OK"* ]]
); then
    it_pass "egress verifier rejects an empty app profile and idle Tor"
else
    it_fail "egress verifier rejects an empty app profile and idle Tor"
fi

# #563 stops Tor on purpose and still needs the app verdict. The waiver must turn ONLY that
# control off — so the pair below runs the SAME fixture (one live app, no public sockets, Tor
# stopped) both ways: inconclusive without the flag, clean with it. Without the negative half a
# waiver that silently passed everything would look identical.
tor_down_fixture() { # <extra flags...> -> rc, output on stdout
    td="$(mktemp -d)"
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then printf "monerod\ntor\n"; exit 0; fi' \
        'if [ "$1 $2 $3 $4" = "compose ps -q tor" ]; then exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo cid; exit 0; fi' \
        'if [ "$1" = exec ]; then printf "  sl  local_address rem_address st\\n"; exit 0; fi' \
        'exit 125' >"$td/docker" && chmod +x "$td/docker"
    PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" tor --dir "$td" --polls 1 --interval 0 "$@" 2>&1
    rc=$?
    rm -rf "$td"
    return "$rc"
}
out="$(tor_down_fixture)"
strict_rc=$?
if [ "$strict_rc" = 2 ] && [[ "$out" == *INCONCLUSIVE* ]]; then
    it_pass "a stopped Tor is INCONCLUSIVE by default (the positive control still holds)"
else
    it_fail "a stopped Tor is INCONCLUSIVE by default (the positive control still holds)" "rc=$strict_rc"
fi
out="$(tor_down_fixture --allow-tor-down)"
waived_rc=$?
if [ "$waived_rc" = 0 ] && [[ "$out" != *INCONCLUSIVE* ]]; then
    it_pass "--allow-tor-down waives ONLY that control and still grades the apps (#563)"
else
    it_fail "--allow-tor-down waives ONLY that control and still grades the apps (#563)" "rc=$waived_rc"
fi

# The Tor-egress verifier gates whether the gate will start containers at all, so a version that
# cannot fail is as bad as one that cannot pass. `iptables -C` answers with iptables' own rule
# equality; these arms drive a stubbed iptables so both directions are pinned. Arm 1 is the control
# that the fixture itself can pass — without it, arms 2-4 are green for the wrong reason.
fw_arm() { # <rules the stub reports installed...> -> rc of verify_tor_egress_firewall
    (
        td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
        printf '%s\n' "$@" >"$td/installed"
        printf '%s\n' '#!/bin/sh' \
            '[ "$1" != -n ] || shift' \
            'case "$1 $2" in' \
            '  "iptables -C") shift 2; case "$1" in FORWARD) exit 0;; esac' \
            '     spec="$*"; grep -Fqx -- "$spec" "$INSTALLED" && exit 0 || exit 1 ;;' \
            '  "iptables -S") grep -c . "$INSTALLED" >/dev/null; sed "s|^|-A DOCKER-USER |" "$INSTALLED"; exit 0 ;;' \
            'esac' \
            'exit 0' >"$td/sudo" && chmod +x "$td/sudo"
        export PATH="$td:$PATH" INSTALLED="$td/installed"
        env_get() { case "$1" in NETWORK_SUBNET) echo 172.28.0.0/24 ;; NETWORK_PREFIX) echo 172.28.0 ;; esac }
        container_engine() { echo docker; }
        # The real one lives in pithead (lib/pithead/02-tor-egress.sh); the selftest does not source
        # the CLI, so mirror its output. Kept byte-identical to that function's printf list.
        tor_egress_rules() {
            printf '%s\n' "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "-s $2 -j ACCEPT" \
                "-s $1 -d 10.0.0.0/8 -j ACCEPT" "-s $1 -d 172.16.0.0/12 -j ACCEPT" \
                "-s $1 -d 192.168.0.0/16 -j ACCEPT" "-s $1 -d 100.64.0.0/10 -j ACCEPT" "-s $1 -j DROP"
        }
        # shellcheck disable=SC2034 # read by the eval'd verifier, which shellcheck cannot follow into
        TOR_EGRESS_TAG=pithead-tor-egress
        eval "$(firewall_verifier_script)"
        verify_tor_egress_firewall
    )
}
# The exact specs the applier installs, in order.
FW_OK=()
while IFS= read -r r; do FW_OK+=("DOCKER-USER -m comment --comment pithead-tor-egress $r"); done < <(
    printf '%s\n' "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "-s 172.28.0.25 -j ACCEPT" \
        "-s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT" "-s 172.28.0.0/24 -d 172.16.0.0/12 -j ACCEPT" \
        "-s 172.28.0.0/24 -d 192.168.0.0/16 -j ACCEPT" "-s 172.28.0.0/24 -d 100.64.0.0/10 -j ACCEPT" \
        "-s 172.28.0.0/24 -j DROP"
)
fw_arm "${FW_OK[@]}" && it_pass "egress firewall verifier ACCEPTS the canonical ruleset (control: the fixture can pass)" ||
    it_fail "egress firewall verifier ACCEPTS the canonical ruleset (control: the fixture can pass)"
fw_arm "${FW_OK[@]:0:6}" && it_fail "a missing canonical rule is refused" || it_pass "a missing canonical rule is refused"
fw_arm "${FW_OK[@]}" "DOCKER-USER -m comment --comment pithead-tor-egress -s 10.9.9.9 -j ACCEPT" &&
    it_fail "a stray extra tagged rule is refused" || it_pass "a stray extra tagged rule is refused"
fw_arm "${FW_OK[@]:6:1}" "${FW_OK[@]:0:6}" && it_fail "the subnet DROP ahead of the ACCEPTs is refused" ||
    it_pass "the subnet DROP ahead of the ACCEPTs is refused"

echo "== image-upgrade continuity verdicts =="
OLD_SHA=0123456789abcdef0123456789abcdef01234567
valid_full_sha "$OLD_SHA" && it_pass "full commit accepted" || it_fail "full commit accepted"
revision_matches_sha 0123456789ab "$OLD_SHA" && it_fail "short image revision rejected" || it_pass "short image revision rejected"
revision_matches_sha 0123456-dirty "$OLD_SHA" && it_fail "dirty image revision rejected" || it_pass "dirty image revision rejected"
revision_matches_sha deadbee "$OLD_SHA" && it_fail "different image revision rejected" || it_pass "different image revision rejected"
height_continues 120 123 && it_pass "chain height may advance" || it_fail "chain height may advance"
height_continues 123 120 && it_fail "chain height may not regress" || it_pass "chain height may not regress"
chain_tip_valid "2840000 $(printf '%064d' 1)" && it_pass "direct Monero tip accepted" || it_fail "direct Monero tip accepted"
chain_tip_valid "0 $(printf '%064d' 1)" && it_fail "zero Monero tip rejected" || it_pass "zero Monero tip rejected"

fp_stub() { printf '%064d\n' 0; }
rx() { fp_stub; }
[ "$(upgrade_secret_fingerprints | wc -l | tr -d ' ')" = 6 ] && it_pass "six secret categories fingerprinted" || it_fail "six secret categories fingerprinted"
rx() { case "$1" in *TOR_DATA_DIR*) return 1 ;; *) fp_stub ;; esac }
upgrade_secret_fingerprints >/dev/null && it_fail "missing or unreadable onion member fails closed" || it_pass "missing or unreadable onion member fails closed"

revs="tor $OLD_SHA
p2pool $OLD_SHA
xmrig-proxy $OLD_SHA
dashboard $OLD_SHA"
revisions_match_sha "$revs" "$OLD_SHA" && it_pass "all required first-party revisions match" || it_fail "all required first-party revisions match"
revisions_match_sha "${revs/dashboard */dashboard deadbee}" "$OLD_SHA" && it_fail "one stale first-party revision fails" || it_pass "one stale first-party revision fails"

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir -p "$td/src/pithead" "$td/out" && printf ok >"$td/src/pithead/pithead" &&
        COPYFILE_DISABLE=1 tar -czf "$td/safe.tar.gz" -C "$td/src" pithead &&
        extract_candidate_archive "$td/safe.tar.gz" "$td/out" &&
        [ "$(cat "$td/out/pithead/pithead")" = ok ]
); then
    it_pass "candidate extraction accepts regular pithead members"
else
    it_fail "candidate extraction accepts regular pithead members"
fi
if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir -p "$td/src/pithead" "$td/out" && ln -s /tmp "$td/src/pithead/escape" &&
        COPYFILE_DISABLE=1 tar -czf "$td/unsafe.tar.gz" -C "$td/src" pithead &&
        extract_candidate_archive "$td/unsafe.tar.gz" "$td/out" >/dev/null 2>&1
); then
    it_fail "candidate extraction rejects links"
else
    it_pass "candidate extraction rejects links"
fi

refs="tor repo/tor@sha256:$(printf '%064d' 1)
monerod repo/monero@sha256:$(printf '%064d' 2)
p2pool repo/p2pool@sha256:$(printf '%064d' 3)
xmrig-proxy repo/xmrig@sha256:$(printf '%064d' 4)
dashboard repo/dashboard@sha256:$(printf '%064d' 5)"
pinned_refs_valid "$refs" && it_pass "all first-party refs are digest-pinned" || it_fail "all first-party refs are digest-pinned"
telemetry_rows_continue $'blocks -\nblocks aaa\ndisk_growth -' $'blocks -\nblocks aaa\nblocks bbb\ndisk_growth -' && it_pass "permanent telemetry rows continue" || it_fail "permanent telemetry rows continue"
telemetry_rows_continue $'blocks -\nblocks aaa' $'blocks -\nblocks bbb' && it_fail "telemetry row replacement fails" || it_pass "telemetry row replacement fails"

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    IT_MODE=local IT_REMOTE_DIR="$td/current" UPGRADE_STAGE_DIR="$td/stage"
    rx() { [ "$1" = 'pwd -P' ] && (cd "$IT_REMOTE_DIR" && pwd -P); }
    mkdir -p "$td/pithead-v1.0.0/data/control" "$UPGRADE_STAGE_DIR/pithead"
    ln -s pithead-v1.0.0 "$td/current"
    printf old >"$td/pithead-v1.0.0/kept"
    printf '{}\n' >"$td/pithead-v1.0.0/config.json"
    printf 'SECRET=value\n' >"$td/pithead-v1.0.0/.env"
    printf audit >"$td/pithead-v1.0.0/data/control/audit"
    printf new >"$UPGRADE_STAGE_DIR/pithead/added"
    printf '2.0.0\n' >"$UPGRADE_STAGE_DIR/pithead/VERSION"
    prepare_baseline_install && prepare_candidate_install && [ "$(cat "$td/pithead-v1.0.0/kept")" = old ] && [ ! -e "$td/pithead-v2.0.0/kept" ] &&
        [ "$(cat "$td/pithead-v2.0.0/added")" = new ] && [ "$(cat "$td/pithead-v2.0.0/data/control/audit")" = audit ] &&
        [ "$IT_REMOTE_DIR" = "$(cd "$td/pithead-v2.0.0" && pwd -P)" ]
); then
    it_pass "upgrade staging leaves the immutable old version tree untouched"
else
    it_fail "upgrade staging leaves the immutable old version tree untouched"
fi

if (
    RUN_IMAGE_UPGRADE=0 RUN_XVB_ROUTING=1 SAFETY_BACKUP=0
    it_err() { :; }
    validate_live_gate_args
); then
    it_fail "XvB gate requires a safety backup"
else
    [ "$?" = 2 ] && it_pass "XvB gate requires a safety backup" || it_fail "XvB gate requires a safety backup"
fi

if (
    restore_calls=0 foreign_called=0
    restore_upgrade_baseline() {
        restore_calls=$((restore_calls + 1))
        _UPGRADE_RESTORE_ARMED=0
    }
    trap 'foreign_called=1' EXIT
    arm_upgrade_abort_restore
    upgrade_abort_restore
    _UPGRADE_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 1 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "upgrade abort restores baseline and composes the prior EXIT handler"
else
    it_fail "upgrade abort restores baseline and composes the prior EXIT handler"
fi

if (
    restore_calls=0 foreign_called=0 SAFETY_ARCHIVE=archive SAFETY_RESTORE_FAILED=0
    safety_restore_exact() {
        restore_calls=$((restore_calls + 1))
        _SAFETY_RESTORE_ARMED=0
    }
    trap 'foreign_called=1' EXIT
    arm_safety_abort_restore
    safety_abort_restore
    _SAFETY_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 1 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "run-level abort restores the safety archive and composes the lock trap"
else
    it_fail "run-level abort restores the safety archive and composes the lock trap"
fi

# A rollback's FIRST act is `pithead down`. These two arms pin what happens when the rest of it
# then fails — measured on a real box, where the stack was left stopped and the exit trap stopped
# it a second time after the in-run restore had already put it back.
if (
    downs=0 ups=0
    SAFETY_ARCHIVE=/tmp/a.tar.gz SAFETY_RESTORE_FAILED=0 BASELINE_CONFIG='{}' BASELINE_EXACT_SECRET_FP=fp
    pithead() {
        case "$1" in down) downs=$((downs + 1)) ;; up) ups=$((ups + 1)) ;; restore) return 1 ;; esac
        return 0
    }
    strict_pithead() { return 0; }
    wait_status_ok() { return 0; }
    rx() { printf '{}'; }
    upgrade_secret_fingerprints() { printf fp; }
    it_log() { :; }
    safety_restore_exact
    rc=$?
    [ "$rc" -ne 0 ] && [ "$downs" -eq 1 ] && [ "$ups" -eq 1 ]
); then
    it_pass "a FAILED rollback still brings the stack back up rather than leaving it stopped"
else
    it_fail "a FAILED rollback still brings the stack back up rather than leaving it stopped"
fi

if (
    restore_calls=0 foreign_called=0
    # A restore already failed this run, so the exit trap must NOT run a second `pithead down`.
    _SAFETY_RESTORE_ARMED=1 SAFETY_RESTORE_FAILED=1 SAFETY_ARCHIVE=/tmp/a.tar.gz _SAFETY_FOREIGN_TRAP=""
    safety_restore_exact() { restore_calls=$((restore_calls + 1)); }
    it_warn() { :; }
    trap 'foreign_called=1' EXIT
    arm_safety_abort_restore
    SAFETY_RESTORE_FAILED=1
    safety_abort_restore
    _SAFETY_RESTORE_ARMED=0 _SAFETY_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 0 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "the exit trap does NOT retry a rollback that already failed (and still chains the prior trap)"
else
    it_fail "the exit trap does NOT retry a rollback that already failed (and still chains the prior trap)"
fi

if (
    restore_calls=0 foreign_called=0 BASELINE_CONFIG='{}' _XVB_SECRET_FP_BEFORE=fp
    # shellcheck disable=SC2034 # live-gates writes this cross-module restoration marker
    SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0
    restore_xvb_or_safety() {
        restore_calls=$((restore_calls + 1))
        _XVB_RESTORE_ARMED=0
    }
    it_warn() { :; }
    rx() { printf '{}'; }
    upgrade_secret_fingerprints() { printf fp; }
    trap 'foreign_called=1' EXIT
    arm_xvb_abort_restore
    xvb_abort_restore
    _XVB_RESTORE_ARMED=0
    _XVB_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 1 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "XvB abort restore composes the prior EXIT handler"
else
    it_fail "XvB abort restore composes the prior EXIT handler"
fi

[ "$IT_FAIL" -eq 0 ]
