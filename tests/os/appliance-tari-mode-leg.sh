#!/usr/bin/env bash
# Day-two tari.mode switching from the dashboard on a live appliance (#1929). Sourced by
# tests/os/run.sh; --self-test covers the pure verdicts without a guest.
#
# WHAT ONLY THIS TIER CAN PROVE. Tier 1 proves the gate commits the key and that .env re-renders;
# it runs against docker STUBS, so it cannot see whether the container actually went away, whether
# ~150 GB of Tari chain survived the switch, or whether p2pool came back up still mining Monero.
# Those three are the operator's actual requirements for "turn Tari off", and all three are
# invisible below this tier.
#
# THE TIER IS THE ASSERTION. Every request here goes through the PLAIN dashboard_control_request
# route with a typed APPLY and NO Telegram fixture. That is deliberate: if TARI_MODE ever slips
# back out of CONTROL_DASHBOARD_CONFIRM_KEYS, these commits start failing with "Telegram approval",
# which is exactly the regression #1929 exists to prevent — an appliance operator with no Telegram
# channel cannot turn merge-mining off at all. A fixture here would hide that.
#
# The appliance provisions with tari.mode=local and a Tari payout address
# (provision-browser-submit.sh), so the off->on direction is reachable at this tier; a machine
# provisioned with "off" has no address, and turning Tari ON there is an approval-tier change by
# design (the wizard's own note says so). That asymmetry is asserted, not assumed.

tari_env() { _ssh "sed -n 's/^$1=//p' /data/pithead/.env" 2>/dev/null | tr -d '\r'; }

# A stable fingerprint of the Tari chain directory: entry count plus total bytes. The POINT of
# switching off is that this does not change — the container is removed, the data is not.
tari_data_fingerprint() {
    _ssh 'set -eu
d=$(sed -n "s/^TARI_DATA_DIR=//p" /data/pithead/.env)
[ -n "$d" ] || d=/data/pithead/data/tari
if [ -d "$d" ]; then printf "%s %s" "$(find "$d" | wc -l | tr -d " ")" "$(du -sk "$d" | cut -f1)"; else printf missing; fi' 2>/dev/null | tr -d '\r'
}

tari_container_present() { _ssh "podman ps -a --format '{{.Names}}' | grep -qx tari" 2>/dev/null; }

# p2pool's launch argv, as the container is ACTUALLY running it — not the rendered .env. #1903's
# entrypoint drops the --merge-mine triple on TARI_MODE=off, and only the live argv shows it.
p2pool_merge_mine_argv() {
    _ssh "podman inspect p2pool --format '{{json .Config.Cmd}}' | jq -r 'index(\"--merge-mine\") // \"none\"'" 2>/dev/null | tr -d '\r'
}

# Pure: did a commit result land, and land WITHOUT being bounced to the approval tier? Separated so
# --self-test can exercise the verdict with no appliance in the room.
tari_commit_verdict() { # <result-json>
    printf '%s' "$1" | jq -e '.status == "applied"' >/dev/null 2>&1
}
tari_approval_bounce() { # <result-json> — true when the gate demanded a second identity
    printf '%s' "$1" | jq -e '.status == "rejected" and (.error | test("Telegram|approval"))' >/dev/null 2>&1
}

tari_mode_commit() { # <proposed-config-json> -> prints the commit result
    local preview rid
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$1")") || return 1
    rid=$(printf '%s' "$preview" | jq -r '.id // ""')
    [ -n "$rid" ] || return 1
    dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')" 420
}

# SC2034: DASH_USER/DASH_PASS are read by dashboard_curl out of THIS frame, by dynamic scope —
# the same contract every other provision leg uses. SC2154: $ip is a global the assembled runner
# sets before any phase runs.
# shellcheck disable=SC2034,SC2154
phase_provision_tari_mode_switch() { # <dashboard-user> <dashboard-password> <phase-rc>
    local DASH_USER="$1" DASH_PASS="$2" phase_rc="${3:-0}"
    local live proposed result before after origin rc=0 tries restored unexercised=bad
    # A PRECONDITION FAILURE IS NOT A VERDICT ON TARI SWITCHING (#2059's contract, learned here the
    # same way). When the phase is already red this leg cannot run, and saying "bad" would put a
    # tari-shaped label on somebody else's defect: its first bench run reported "live config could
    # not be read" because #2060's known hostname-approval row had left the dashboard unreadable,
    # which reads exactly like day-two switching being broken. On a HEALTHY phase an unreadable
    # dashboard is still a real failure, so the verdict follows the phase.
    [ "$phase_rc" -eq 0 ] || unexercised=info

    # Retry rather than single-shot: the leg that runs before this one recreates the dashboard
    # container, so one curl the instant it returns is a race, not a measurement.
    for tries in 1 2 3 4 5 6; do
        live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) && break
        sleep 5
    done
    if [ -z "${live:-}" ]; then
        "$unexercised" "the dashboard config was unreadable — day-two tari.mode switching was NOT exercised (#1929)"
        return 0
    fi
    origin=$(printf '%s' "$live" | jq -r '.tari.mode // "local"')
    if [ "$origin" != "local" ]; then
        bad "tari.mode switch: expected a provisioned local Tari node, found mode=$origin"
        return 1
    fi
    before=$(tari_data_fingerprint)
    case "$before" in missing | "")
        bad "tari.mode switch: no Tari data directory to protect"
        return 1
        ;;
    esac

    # --- local -> off, on the plain route -------------------------------------------------------
    proposed=$(printf '%s' "$live" | jq -c '.tari.mode = "off"')
    result=$(tari_mode_commit "$proposed") || {
        bad "tari.mode off: the commit never returned a terminal result"
        return 1
    }
    if tari_approval_bounce "$result"; then
        bad "tari.mode off was bounced to the approval tier — TARI_MODE/COMPOSE_PROFILES left the confirm allowlist (#1929)"
        return 1
    fi
    if ! tari_commit_verdict "$result"; then
        bad "tari.mode off did not apply: $(printf '%s' "$result" | jq -r '.error // .status')"
        return 1
    fi
    ok "turning Tari off commits from the dashboard with a typed APPLY and no second identity"

    # PAST THIS POINT THE MACHINE IS MODIFIED, so nothing below may return early: every later phase
    # of the battery runs against whatever state this leaves behind, and a leg that bails between
    # the switch and the restore hands them a machine with merge-mining silently off. Failures are
    # recorded in $rc and the restore at the bottom always runs — the same discipline
    # appliance-config-approval-leg.sh gets from approval_restore_pending.
    [ "$(tari_env TARI_MODE)" = "off" ] &&
        ! printf '%s' "$(tari_env COMPOSE_PROFILES)" | grep -q local_tari &&
        [ "$(tari_env TARI_REQUIRED)" = "false" ] &&
        ok "off renders TARI_MODE=off, drops local_tari and releases the sync gate" || {
        bad "off did not render as off (mode=$(tari_env TARI_MODE) profiles=$(tari_env COMPOSE_PROFILES) required=$(tari_env TARI_REQUIRED))"
        rc=1
    }

    tries=0
    while [ "$tries" -lt 30 ] && tari_container_present; do
        tries=$((tries + 1))
        sleep 4
    done
    if tari_container_present; then
        bad "the tari container survived the switch to off — a deactivated profile left it running"
        rc=1
    else
        ok "the tari container is stopped and removed"
    fi

    # THE OPERATOR'S OWN REQUIREMENT, and the one a careless implementation gets wrong: the chain
    # stays on disk. A re-sync is ~150 GB and days; "off" must cost neither.
    after=$(tari_data_fingerprint)
    if [ "$after" = "$before" ]; then
        ok "the Tari chain data is untouched by the switch ($before)"
    else
        bad "turning Tari off changed the chain directory: [$before] -> [$after]"
        rc=1
    fi

    if [ "$(p2pool_merge_mine_argv)" = "none" ]; then
        ok "p2pool relaunched with no --merge-mine argument (#1903)"
    else
        bad "p2pool is still being handed --merge-mine on an off machine"
        rc=1
    fi
    if _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | grep -qx p2pool; then
        ok "a machine that declined Tari keeps mining Monero"
    else
        bad "p2pool is not running after Tari was turned off — the sync gate never released"
        rc=1
    fi

    # --- and back on, which is what makes it a switch rather than a one-way door -----------------
    # Also the RESTORE: the battery continues on this machine, so leaving Tari off is not an option
    # even when the assertions above already failed.
    # No early return in here either, for the same reason and one more: the chain-survival check
    # at the bottom is about the DATA, which is still worth reading when the restore itself failed —
    # "Tari is off AND the chain is gone" and "Tari is off but the chain is intact" are different
    # incidents, and an early return here reports only the first line of either.
    restored=0
    if live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) &&
        proposed=$(printf '%s' "$live" | jq -c --arg m "$origin" '.tari.mode = $m') &&
        result=$(tari_mode_commit "$proposed") && tari_commit_verdict "$result"; then
        restored=1
    else
        bad "tari.mode could not be restored to $origin ($(printf '%s' "${result:-}" | jq -r '.error // .status // "no result"' 2>/dev/null)) — the machine is left NOT merge-mining"
        rc=1
    fi
    if [ "$restored" -eq 1 ]; then
        tries=0
        while [ "$tries" -lt 45 ] && ! tari_container_present; do
            tries=$((tries + 1))
            sleep 4
        done
        if tari_container_present && [ "$(tari_env TARI_MODE)" = "$origin" ]; then
            ok "turning Tari back on restores the bundled node from the dashboard"
        else
            bad "Tari did not come back on (mode=$(tari_env TARI_MODE), container present: $(tari_container_present && echo yes || echo no))"
            rc=1
        fi
    fi
    # Resumed, not re-synced: the directory it came back to is the one it left.
    after=$(tari_data_fingerprint)
    case "$after" in
    missing)
        bad "the Tari data directory is gone — the chain was destroyed by the switch"
        rc=1
        ;;
    *) ok "the chain survived the whole cycle and is reused, not re-synced ($after)" ;;
    esac
    return "$rc"
}

_tari_mode_self_test() {
    local f=0
    tari_commit_verdict '{"status":"applied"}' || f=$((f + 1))
    tari_commit_verdict '{"status":"rejected","error":"nope"}' && f=$((f + 1))
    # The bounce verdict is the regression detector; both spellings the gate can produce must hit,
    # and an UNRELATED refusal must not — else the leg would blame the tier for any failure at all.
    tari_approval_bounce '{"status":"rejected","error":"Telegram approval is unavailable because the bot token is not configured"}' || f=$((f + 1))
    tari_approval_bounce '{"status":"rejected","error":"sensitive changes need typed payout confirmations followed by host-verified Telegram approval"}' || f=$((f + 1))
    tari_approval_bounce '{"status":"rejected","error":"this change is disruptive (x) — type APPLY in the dashboard to confirm."}' && f=$((f + 1))
    tari_approval_bounce '{"status":"applied"}' && f=$((f + 1))
    # The leg is wired into the provision phase; a leg nobody calls proves nothing.
    grep -Fq 'phase_provision_tari_mode_switch "$pv_user" "$pv_pass" "$rc"' \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phases/provision-initial.sh" || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-tari-mode-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-tari-mode-leg self-test passed\n'
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _tari_mode_self_test
fi
