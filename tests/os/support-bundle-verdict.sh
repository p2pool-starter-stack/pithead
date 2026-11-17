# shellcheck shell=bash
SB_PROOF_REQUIRED="journal/all.log journal/kernel.log journal/boots.txt host.txt doctor.json status/monerod.json status/tari.json status/p2pool.json tor/control.txt tor/state-guards.txt tor.txt network/ip-addr.txt network/ip-route.txt time/timedatectl.txt containers/ps-a.txt containers/images.txt rauc.txt rauc-detailed.txt network/networkctl.txt network/resolvectl.txt network/nft-ruleset.txt time/sync-units.txt dashboard-history.jsonl boot-slot.txt coredumps.txt caddy/access.log state-markers.txt"

_sb_step_failed() {
    jq -e --arg s "$2" '.failures | map(select(.step == $s and (.status == "failed" or .status == "timeout"))) | length > 0' "$1" >/dev/null 2>&1
}

support_bundle_verdict() {
    local dir="$1" mode="$2" in_mark="$3" before="$4" after="$5" canaries="$6" manifest="$1/manifest.json" rel n=0 line rc=0
    if ! { [ -s "$manifest" ] && jq -e '.manifest_version == 1 and (.files | length > 0)' "$manifest" >/dev/null 2>&1; }; then
        echo "manifest.json is missing, empty or not a version 1 manifest"
        return 1
    fi
    for rel in $SB_PROOF_REQUIRED; do
        [ -s "$dir/$rel" ] || {
            echo "$rel is missing or empty"
            rc=1
        }
        jq -e --arg p "$rel" '.files | map(.path) | index($p) != null' "$manifest" >/dev/null 2>&1 || {
            echo "$rel is not listed in the manifest"
            rc=1
        }
    done
    grep -qF -- "$in_mark" "$dir/journal/all.log" 2>/dev/null || {
        echo "the seeded line inside the window is absent from journal/all.log"
        rc=1
    }
    for line in "$before" "$after"; do
        ! grep -rqF -- "$line" "$dir" 2>/dev/null || {
            echo "a seeded line outside the window is present in the bundle"
            rc=1
        }
    done
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        ! grep -rqF -- "$line" "$dir" 2>/dev/null || {
            echo "seeded secret #$n appears in the bundle"
            rc=1
        }
    done <"$canaries"
    [ "$n" -gt 0 ] || {
        echo "no secret was seeded, so redaction was not tested"
        rc=1
    }
    case "$mode" in
    baseline) ;;
    tor-wedged)
        _sb_step_failed "$manifest" tor/control.txt || {
            echo "the manifest does not record the Tor control step as failed or timed out"
            rc=1
        }
        ;;
    monerod-stopped)
        _sb_step_failed "$manifest" status/monerod.json || {
            echo "the manifest does not record the monerod snapshot as failed"
            rc=1
        }
        jq -e '.reachable == false' "$dir/status/monerod.json" >/dev/null 2>&1 || {
            echo "status/monerod.json does not say the node was unreachable"
            rc=1
        }
        ;;
    *)
        echo "unknown mode $mode"
        rc=1
        ;;
    esac
    return "$rc"
}
