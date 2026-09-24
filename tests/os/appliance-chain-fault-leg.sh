#!/usr/bin/env bash
# A chain service that fails AFTER a migrating slot commits (#2588, V10 of #1129). Sourced by
# tests/os/run.sh and called by the provision phase's migration leg once the release line is in the
# journal and the pending marker is gone; --self-test exercises the pure verdicts without a guest.
#
# WHY THIS ROW EXISTS. The release path's own failure (`up` never succeeds) is a FAULT line in the
# boot journal, proven at tier 1 by test-appliance-boot-release.sh. The failure a one-way chain
# migration actually risks is different: `up` succeeds, the node starts, and the migration then
# kills it (disk, OOM, a crash). pithead-boot has exited 0 by then, so nothing in the boot path
# reports it. What must report it is what the operator reads: `pithead status`, `pithead doctor`
# and the dashboard. With the marker consumed, none of them may excuse a stopped chain node as the
# migration hold any more.
#
# HOW THE FAULT IS MADE. The node is stopped by its compose service label (#2556), not by name.
# A stop leaves it exited, as a node that died on its migration does; restart:unless-stopped does
# not revive a manual stop, so the fault holds still while three surfaces are read. A SIGKILL would
# be restarted by podman within seconds and prove nothing about reporting. The recovery is the one
# the boot path's FAULT line documents: `./pithead up` from /data/pithead.
#
# THE DASHBOARD HALF HAS A PRECONDITION. Its `Tari DOWN` badge is debounced (90 s unreachable) and
# fires only for a node the dashboard has reached at least once since it started (NodeHealthMonitor's
# ever-up guard). The migration hold kept Tari away until the release, so the leg first waits until
# the dashboard has read the released node: both containers up for two poll intervals, with no
# `Tari gRPC GetTipInfo error` in the dashboard's log over that window. Without that wait a missing
# badge would say nothing about reporting.

CHAIN_FAULT_SERVICE=tari
# Two dashboard polls (UPDATE_INTERVAL 30 s) plus slack.
CHAIN_FAULT_READ_WINDOW=75
CHAIN_FAULT_REVENUE_OK="Revenue containers are healthy or holding for sync — none crashed."

# The service's row in `pithead status`'s health list, colour stripped. The compose table above the
# list also names the service, but only the health rows are indented under a status glyph. The
# FIRST such row: the chain sync-progress lines that follow the list use the same glyph and name.
chain_fault_status_row() { # <status-output> <service>
    printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "^  (✓|⚠|✗|…) $2 " | head -n 1
}

# faulted: status exits non-zero and the service's row is a fault (✗, or ⚠ running but UNHEALTHY).
# The migration hold's own row is a ⚠ with "intentionally held" and must NOT pass: that excuse is
# exactly what a consumed marker withdraws. recovered: the row is ✓ running.
chain_fault_status_verdict() { # <status-output> <status-rc> <service> <faulted|recovered>
    local row
    row=$(chain_fault_status_row "$1" "$3")
    case "$4" in
    faulted)
        [ "$2" -ne 0 ] || return 1
        case "$row" in
        "  ✗ $3 "*) return 0 ;;
        "  ⚠ $3 "*"running but UNHEALTHY"*) return 0 ;;
        esac
        return 1
        ;;
    recovered) [[ "$row" =~ ^\ \ ✓\ $3\ +running$ ]] ;;
    *) return 1 ;;
    esac
}

# faulted: doctor exits non-zero with the revenue check's FAIL row for the service, and no
# migration-pending note (the hold would judge a stopped chain node ok). recovered: no FAIL row for
# the service and the revenue check's OK row present. Doctor's overall exit is not the recovery
# verdict: this row owns the chain service, not every other check on the box.
chain_fault_doctor_verdict() { # <doctor-json> <service> <faulted|recovered>
    case "$3" in
    faulted)
        printf '%s' "$1" | jq -e --arg s "$2" '
            (.exit | type == "number") and .exit > 0 and
            any(.checks[]?; .status == "fail" and
                ((.message | startswith("\($s) is down")) or (.message | startswith("\($s) is not ready")))) and
            (any(.checks[]?; .message | startswith("A data migration is pending")) | not)' >/dev/null 2>&1
        ;;
    recovered)
        printf '%s' "$1" | jq -e --arg s "$2" --arg okmsg "$CHAIN_FAULT_REVENUE_OK" '
            (.checks | type == "array") and
            (any(.checks[]; .status == "fail" and (.message | startswith("\($s) "))) | not) and
            any(.checks[]; .status == "ok" and .message == $okmsg)' >/dev/null 2>&1
        ;;
    *) return 1 ;;
    esac
}

# faulted: /api/state carries the `Tari DOWN` badge (docs/dashboard.md, Node status & failover) and
# does not show Tari connected for merge-mining. recovered: a readable state with a badge list and
# no `Tari DOWN` in it; an unreadable dashboard is never a recovery.
chain_fault_dashboard_verdict() { # <api-state-json> <faulted|recovered>
    case "$2" in
    faulted)
        printf '%s' "$1" | jq -e 'any(.badges[]?; .text == "Tari DOWN") and (.tari.connected != true)' >/dev/null 2>&1
        ;;
    recovered)
        printf '%s' "$1" | jq -e 'any(.badges[]; .text == "Tari DOWN") | not' >/dev/null 2>&1
        ;;
    *) return 1 ;;
    esac
}

# The precondition, judged from one guest reading: "<tari-started> <dashboard-started> <now>
# <grpc-errors>" (unix seconds from podman ps, and the count of the dashboard's Tari gRPC errors
# over the read window). Both containers must be up for the whole window and the dashboard must
# have reached the node on every poll in it.
chain_fault_dashboard_reached() { # <probe>
    local tari dash now errors latest
    read -r tari dash now errors <<<"$1"
    [[ "$tari" =~ ^[0-9]+$ && "$dash" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$errors" =~ ^[0-9]+$ ]] || return 1
    [ "$tari" -gt 0 ] && [ "$dash" -gt 0 ] || return 1
    latest=$((tari > dash ? tari : dash))
    [ $((now - latest)) -ge "$CHAIN_FAULT_READ_WINDOW" ] && [ "$errors" -eq 0 ]
}

chain_fault_probe() {
    SSH_TIMEOUT=30 _ssh "started() { podman ps --filter label=com.docker.compose.service=\$1 --format '{{.StartedAt}}' 2>/dev/null | head -n1; }
printf '%s %s %s %s\n' \"\$(started $CHAIN_FAULT_SERVICE)\" \"\$(started dashboard)\" \"\$(date +%s)\" \
    \"\$(podman logs --since ${CHAIN_FAULT_READ_WINDOW}s dashboard 2>&1 | grep -c 'Tari gRPC GetTipInfo error')\"" 2>/dev/null | tr -d '\r'
}

chain_fault_status() { _ssh "cd /data/pithead && ./pithead status 2>&1"; }
chain_fault_doctor() { _ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json 2>/dev/null"; }
# SC2154: $ip is a global the assembled runner sets before any phase runs.
# shellcheck disable=SC2154
chain_fault_state() { dashboard_curl -fsSk -m 8 "https://$ip/api/state" 2>/dev/null; }

# What each surface said, one line, for a red row.
chain_fault_evidence() { # <status-output> <doctor-json> <api-state-json>
    local row doc badges
    row=$(chain_fault_status_row "$1" "$CHAIN_FAULT_SERVICE")
    doc=$(printf '%s' "$2" | jq -r --arg s "$CHAIN_FAULT_SERVICE" \
        '"exit=\(.exit) " + ([.checks[]? | select(.message | startswith($s) or startswith("Revenue") or startswith("A data migration")) | "\(.status): \(.message)"] | join("; "))' 2>/dev/null) || doc="unparseable"
    badges=$(printf '%s' "$3" | jq -r '[.badges[]?.text] | join(", ") + " | tari.connected=\(.tari.connected)"' 2>/dev/null) || badges="unreadable"
    printf 'status row [%s]; doctor [%.300s]; dashboard badges [%s]' "${row:-none}" "${doc:-none}" "${badges:-none}"
}

# SC2034: DASH_USER/DASH_PASS are read by dashboard_curl out of THIS frame, by dynamic scope.
# shellcheck disable=SC2034
phase_provision_chain_fault_after_release() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" svc="$CHAIN_FAULT_SERVICE" probe="" cid status_out status_rc doctor state tries
    info "post-commit chain fault — stop $svc after 'chain services released', read status, doctor and the dashboard, recover"
    # The release `up` holds the mutation lock through its tor-health wait; a fault injected under it
    # races the boot path, and the recovery `up` would queue behind it.
    if ! provisioning_settled 900; then
        bad "post-commit $svc fault: pithead-boot never settled after the release — the fault was not injected"
        return 1
    fi
    for tries in $(seq 72); do
        probe=$(chain_fault_probe)
        chain_fault_dashboard_reached "$probe" && break
        sleep 5
    done
    if ! chain_fault_dashboard_reached "$probe"; then
        bad "post-commit $svc fault: the dashboard never read the released $svc node (probe '${probe:-none}': $svc-started dashboard-started now gRPC-errors) — the fault was not injected"
        return 1
    fi
    ok "post-commit $svc fault: the dashboard reads the $svc node the release started"

    cid=$(_ssh "podman ps -q --filter label=com.docker.compose.service=$svc" 2>/dev/null | head -n1 | tr -d '\r')
    if [ -z "$cid" ] || ! _ssh "podman stop -t 10 $cid >/dev/null 2>&1"; then
        bad "post-commit $svc fault: could not stop a running $svc (container '${cid:-none}') — the fault was not injected"
        return 1
    fi
    ok "post-commit $svc fault: $svc stopped after 'chain services released' with the migration marker gone"

    status_out=$(chain_fault_status)
    status_rc=$?
    doctor=$(chain_fault_doctor)
    # The badge is debounced 90 s; allow two more polls and slack.
    for tries in $(seq 60); do
        state=$(chain_fault_state)
        chain_fault_dashboard_verdict "$state" faulted && break
        sleep 5
    done
    if chain_fault_status_verdict "$status_out" "$status_rc" "$svc" faulted; then
        ok "post-commit $svc fault: pithead status reports it ($(chain_fault_status_row "$status_out" "$svc" | sed 's/^ *//'), exit $status_rc)"
    else
        bad "post-commit $svc fault: pithead status did not report the stopped $svc (exit $status_rc; $(chain_fault_evidence "$status_out" "$doctor" "$state"))"
    fi
    if chain_fault_doctor_verdict "$doctor" "$svc" faulted; then
        ok "post-commit $svc fault: pithead doctor FAILs the revenue check on it, with no migration hold excusing it"
    else
        bad "post-commit $svc fault: pithead doctor did not FAIL on the stopped $svc ($(chain_fault_evidence "$status_out" "$doctor" "$state"))"
    fi
    if chain_fault_dashboard_verdict "$state" faulted; then
        ok "post-commit $svc fault: the dashboard shows Tari DOWN and not connected for merge-mining"
    else
        bad "post-commit $svc fault: the dashboard never showed Tari DOWN within 5 minutes ($(chain_fault_evidence "$status_out" "$doctor" "$state"))"
    fi

    # The documented supported start: the boot path's FAULT line names exactly this command.
    if _ssh "cd /data/pithead && ./pithead up >/dev/null 2>&1"; then
        ok "post-commit $svc fault: ./pithead up from /data/pithead ran to completion"
    else
        bad "post-commit $svc fault: ./pithead up failed — the documented recovery did not run"
    fi
    # Healthcheck start_period is 90 s and the badge clears after 60 s of reachability.
    for tries in $(seq 120); do
        status_out=$(chain_fault_status)
        status_rc=$?
        doctor=$(chain_fault_doctor)
        state=$(chain_fault_state)
        chain_fault_status_verdict "$status_out" "$status_rc" "$svc" recovered &&
            chain_fault_doctor_verdict "$doctor" "$svc" recovered &&
            chain_fault_dashboard_verdict "$state" recovered && break
        sleep 5
    done
    if chain_fault_status_verdict "$status_out" "$status_rc" "$svc" recovered; then
        ok "post-commit $svc fault: pithead status shows $svc running again"
    else
        bad "post-commit $svc fault: $svc did not recover in pithead status within 10 minutes ($(chain_fault_evidence "$status_out" "$doctor" "$state"))"
    fi
    if chain_fault_doctor_verdict "$doctor" "$svc" recovered; then
        ok "post-commit $svc fault: pithead doctor passes the revenue check again"
    else
        bad "post-commit $svc fault: pithead doctor still fails the revenue check after the recovery ($(chain_fault_evidence "$status_out" "$doctor" "$state"))"
    fi
    if chain_fault_dashboard_verdict "$state" recovered; then
        ok "post-commit $svc fault: the dashboard cleared Tari DOWN"
    else
        bad "post-commit $svc fault: the dashboard did not clear Tari DOWN after the recovery ($(chain_fault_evidence "$status_out" "$doctor" "$state"))"
    fi
}

_chain_fault_self_test() {
    local f=0 held down up unhealthy starting doc_down doc_hold doc_ok doc_other
    down=$'NAME  IMAGE  STATUS\ntari  minotari  Exited (0)\n\n==> Service health check:\n  \e[0;32m✓\e[0m monerod       running\n  \e[0;31m✗\e[0m tari          exited'
    held=$'  ⚠ tari          exited — intentionally held until this slot commits its data migration'
    unhealthy=$'  ⚠ tari          running but UNHEALTHY'
    starting=$'  … tari          starting (health check pending)'
    up=$'NAME  IMAGE  STATUS\ntari  minotari  Up 2m\n  ✓ tari-wallet   running\n  ✓ tari          running'
    # stack_status prints the chain sync lines after the health list, same glyph, same name.
    down+=$'\n==> Chain sync in progress — the miner is held until it completes:\n  … tari          discovering the target height…'
    up+=$'\n  … tari          12% (1200 / 10000 blocks, 8800 to go)'
    chain_fault_status_verdict "$down" 1 tari faulted || f=$((f + 1))
    chain_fault_status_verdict "$unhealthy" 1 tari faulted || f=$((f + 1))
    chain_fault_status_verdict "$down" 0 tari faulted && f=$((f + 1))
    chain_fault_status_verdict "$held" 1 tari faulted && f=$((f + 1))
    chain_fault_status_verdict "$starting" 1 tari faulted && f=$((f + 1))
    chain_fault_status_verdict "$up" 1 tari faulted && f=$((f + 1))
    # The tari-wallet row must not stand in for tari, either way.
    chain_fault_status_verdict $'  ✗ tari-wallet   exited\n  ✓ tari          running' 1 tari faulted && f=$((f + 1))
    chain_fault_status_verdict $'  ✓ tari          running\n  ✗ tari-wallet   exited' 1 tari faulted && f=$((f + 1))
    chain_fault_status_verdict "$up" 0 tari recovered || f=$((f + 1))
    chain_fault_status_verdict "$starting" 0 tari recovered && f=$((f + 1))
    chain_fault_status_verdict "$down" 1 tari recovered && f=$((f + 1))
    chain_fault_status_verdict $'  ✓ tari-wallet   running\n  ✗ tari          exited' 1 tari recovered && f=$((f + 1))
    chain_fault_status_verdict "" 1 tari recovered && f=$((f + 1))

    doc_down='{"exit":1,"checks":[{"status":"ok","message":"x"},{"status":"fail","message":"tari is down (Exited (0) 5 seconds ago) — a chain node down means the slot is not healthy to commit"}]}'
    doc_hold='{"exit":1,"checks":[{"status":"info","message":"A data migration is pending — chain services are deliberately held until this slot commits."},{"status":"fail","message":"tari is down (Exited (0))"}]}'
    doc_ok=$(jq -nc --arg m "$CHAIN_FAULT_REVENUE_OK" '{exit:0,checks:[{status:"ok",message:$m}]}')
    doc_other=$(jq -nc --arg m "$CHAIN_FAULT_REVENUE_OK" '{exit:1,checks:[{status:"ok",message:$m},{status:"fail",message:"Tor exits failing"}]}')
    chain_fault_doctor_verdict "$doc_down" tari faulted || f=$((f + 1))
    chain_fault_doctor_verdict '{"exit":1,"checks":[{"status":"fail","message":"tari is not ready (Up 5s (starting)) — a chain node must be up and healthy to commit"}]}' tari faulted || f=$((f + 1))
    chain_fault_doctor_verdict "${doc_down/\"exit\":1/\"exit\":0}" tari faulted && f=$((f + 1))
    chain_fault_doctor_verdict "$doc_hold" tari faulted && f=$((f + 1))
    chain_fault_doctor_verdict '{"exit":1,"checks":[{"status":"fail","message":"tari-wallet is down (Exited)"}]}' tari faulted && f=$((f + 1))
    chain_fault_doctor_verdict "$doc_ok" tari faulted && f=$((f + 1))
    chain_fault_doctor_verdict "" tari faulted && f=$((f + 1))
    chain_fault_doctor_verdict "$doc_ok" tari recovered || f=$((f + 1))
    chain_fault_doctor_verdict "$doc_other" tari recovered || f=$((f + 1))
    chain_fault_doctor_verdict "$doc_down" tari recovered && f=$((f + 1))
    chain_fault_doctor_verdict '{"exit":0,"checks":[{"status":"ok","message":"Containers"}]}' tari recovered && f=$((f + 1))
    chain_fault_doctor_verdict "$(printf '%s' "$doc_ok" | jq -c '.checks += [{status:"fail",message:"tari is not ready (Up 5s (starting))"}]')" tari recovered && f=$((f + 1))
    chain_fault_doctor_verdict "" tari recovered && f=$((f + 1))

    chain_fault_dashboard_verdict '{"badges":[{"text":"Tari DOWN","variant":"bad"}],"tari":{"connected":false}}' faulted || f=$((f + 1))
    chain_fault_dashboard_verdict '{"badges":[{"text":"Tari DOWN","variant":"bad"}],"tari":{"connected":true}}' faulted && f=$((f + 1))
    chain_fault_dashboard_verdict '{"badges":[{"text":"monerod DOWN"}],"tari":{"connected":false}}' faulted && f=$((f + 1))
    chain_fault_dashboard_verdict '' faulted && f=$((f + 1))
    chain_fault_dashboard_verdict '{"badges":[{"text":"Miner held (sync)"}],"tari":{"connected":false}}' recovered || f=$((f + 1))
    chain_fault_dashboard_verdict '{"badges":[{"text":"Tari DOWN"}]}' recovered && f=$((f + 1))
    chain_fault_dashboard_verdict '' recovered && f=$((f + 1))
    chain_fault_dashboard_verdict '{"error":"unauthorized"}' recovered && f=$((f + 1))
    chain_fault_dashboard_verdict '<html>login</html>' recovered && f=$((f + 1))

    chain_fault_dashboard_reached '1000 900 1075 0' || f=$((f + 1))
    chain_fault_dashboard_reached '1000 900 1074 0' && f=$((f + 1))
    chain_fault_dashboard_reached '900 1000 1074 0' && f=$((f + 1))
    chain_fault_dashboard_reached '1000 900 2000 1' && f=$((f + 1))
    chain_fault_dashboard_reached ' 900 2000 0' && f=$((f + 1))
    chain_fault_dashboard_reached '0 900 2000 0' && f=$((f + 1))
    chain_fault_dashboard_reached '' && f=$((f + 1))

    # The live leg: a guest whose three surfaces report the fault and then the recovery must read
    # all green; one whose status keeps excusing the stopped node as the hold must read red.
    (
        ip=fixture
        _ssh_log=$(mktemp)
        stopped=0
        _ssh() {
            printf '%s\n' "$*" >>"$_ssh_log"
            case "$*" in
            *'podman ps -q --filter'*) printf 'abc123\n' ;;
            *'podman stop'*) stopped=1 ;;
            *'pithead up'*) stopped=0 ;;
            *'pithead status'*)
                if [ "$stopped" = 1 ]; then
                    printf '%s\n' "${STATUS_DOWN:-$down}"
                    return 1
                fi
                printf '%s\n' "$up"
                ;;
            *'doctor --json'*) if [ "$stopped" = 1 ]; then printf '%s' "$doc_down"; else printf '%s' "$doc_ok"; fi ;;
            *) return 1 ;;
            esac
        }
        chain_fault_probe() { printf '1000 900 2000 0'; }
        dashboard_curl() {
            if [ "$stopped" = 1 ]; then printf '{"badges":[{"text":"Tari DOWN"}],"tari":{"connected":false}}'; else printf '{"badges":[],"tari":{"connected":false}}'; fi
        }
        provisioning_settled() { return 0; }
        sleep() { :; }
        info() { :; }
        PASS=0 FAIL=0
        ok() { PASS=$((PASS + 1)); }
        bad() { FAIL=$((FAIL + 1)); }
        phase_provision_chain_fault_after_release u p >/dev/null
        green="$PASS/$FAIL"
        PASS=0 FAIL=0
        STATUS_DOWN="$held"
        phase_provision_chain_fault_after_release u p >/dev/null
        red="$PASS/$FAIL"
        rm -f "$_ssh_log"
        [ "$green" = 9/0 ] && [ "$red" = 8/1 ]
    ) || f=$((f + 1))

    # The leg is wired into the migration leg AFTER the marker check and BEFORE the floor fallback.
    local mig
    mig="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phases/provision-migration.sh"
    awk '/the migration-pending marker was consumed/ {m = NR}
         /phase_provision_chain_fault_after_release "\$pv_user" "\$pv_pass"/ {c = NR}
         /phase_provision_floor_fallback_leg/ {l = NR}
         END {exit !(m && c && l && m < c && c < l)}' "$mig" || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-chain-fault-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-chain-fault-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _chain_fault_self_test
fi
