# shellcheck shell=bash
# shellcheck source=tests/os/support-bundle-verdict.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/support-bundle-verdict.sh"

SB_PROOF_LIMIT=300

_sb_guest() { SSH_TIMEOUT=240 _ssh "bash -s -- $1 $2" <"$SCRIPT_DIR/support-bundle-guest-seed.sh"; }

_sb_export() {
    local resp status deadline body attempt=0 err
    SB_ERR=""
    while :; do
        attempt=$((attempt + 1))
        resp=$(dashboard_control_post support-bundle "$(jq -nc --arg s "$1" --arg u "$2" '{since:$s,until:$u}')" 45)
        SB_RID=$(printf '%s' "$resp" | sed '$d' | jq -r '.id // ""' 2>/dev/null)
        if [ -z "$SB_RID" ] || [ "$(printf '%s' "$resp" | tail -n1)" != 202 ]; then
            SB_ERR="the request was not accepted ($(printf '%s' "$resp" | tail -n1))"
            return 1
        fi
        deadline=$(($(date +%s) + SB_PROOF_LIMIT))
        status=pending
        while [ "$(date +%s)" -lt "$deadline" ]; do
            body=$(dashboard_curl -sSk -m 8 "https://$ip/api/control/support-bundle-result?id=$SB_RID" 2>/dev/null)
            status=$(printf '%s' "$body" | jq -r '.status // "pending"' 2>/dev/null)
            case "$status" in applied | failed | rejected) break ;; esac
            sleep 3
        done
        err=$(printf '%s' "$body" | jq -r '.error // ""' 2>/dev/null)
        if [ "$status" = rejected ] && [ "$attempt" -lt 6 ] && [[ "$err" == *"less than a minute"* ]]; then
            sleep 20
            continue
        fi
        break
    done
    [ "$status" = applied ] || {
        SB_ERR="the request ended as '$status' within ${SB_PROOF_LIMIT}s ($err)"
        return 1
    }
    dashboard_curl -fsSk -m 120 -o "$3/bundle.zip" "https://$ip/api/control/support-bundle-download?id=$SB_RID" || {
        SB_ERR="the dashboard download failed"
        return 1
    }
    python3 -I -m zipfile -e "$3/bundle.zip" "$3/x" >/dev/null 2>&1 || {
        SB_ERR="the download is not a readable zip"
        return 1
    }
    SB_ROOT="$3/x/bundle"
}

_sb_round() {
    local t0=$SECONDS reasons
    mkdir -p "$7/$2"
    if ! _sb_export "$3" "$4" "$7/$2"; then
        bad "support bundle ($1): $SB_ERR"
        return 1
    fi
    if reasons=$(support_bundle_verdict "$SB_ROOT" "$2" "sbproof-in-$5" "sbproof-before-$5" "sbproof-after-$5" "$6"); then
        ok "support bundle ($1): complete, window-bounded and redacted in $((SECONDS - t0))s (limit ${SB_PROOF_LIMIT}s)"
    else
        bad "support bundle ($1): $(printf '%s' "$reasons" | tr '\n' ';')"
        return 1
    fi
}

_sb_dashboard_up() {
    local tries=0
    while [ "$tries" -lt 40 ]; do
        dashboard_curl -fsSk -m 8 -o /dev/null "https://$ip/api/state" 2>/dev/null && return 0
        tries=$((tries + 1))
        sleep 3
    done
    return 1
}

_sb_control_off() {
    SB_STAGE=drain
    _control_requests_drained || return 1
    SB_STAGE=snapshot
    approval_capture_restore_snapshot || return 1
    SB_STAGE=apply
    _ssh 'cd /data/pithead && jq ".dashboard.control.enabled = false" config.json >config.sbproof && install -m 600 config.sbproof config.json && rm -f config.sbproof && ./pithead apply -y >/dev/null' || return 1
    SB_STAGE=dashboard
    _sb_dashboard_up || return 1
    SB_STAGE=dotenv
    _ssh 'grep -Eq "^DASHBOARD_CONTROL_ENABLED=.?false.?$" /data/pithead/.env'
}

phase_provision_support_bundle_proof() {
    # shellcheck disable=SC2034
    local ip="$1" DASH_USER="$2" DASH_PASS="$3" tag dir canaries out since until code off=0
    tag=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
    dir=$(mktemp -d)
    canaries="$dir/canaries"
    if _sb_control_off; then
        off=1
        ok "support bundle proof runs with the dashboard control channel switched off"
    else
        bad "support bundle proof: could not switch the control channel off (stage: $SB_STAGE; guest stderr: $(tail -c 400 "$SSH_ERR" 2>/dev/null | tr '\r\n' '  '))"
    fi
    if [ "$off" = 1 ] && out=$(_sb_guest "$tag" window); then
        printf '%s\n' "$out" | sed -n 's/^CANARY //p' >"$canaries"
        read -r since until <<<"$(printf '%s\n' "$out" | sed -n 's/^WINDOW //p')"
    else
        bad "support bundle proof: seeding the window and the secrets on the guest failed ($(tail -c 300 "$SSH_ERR" 2>/dev/null | tr '\r\n' '  '))"
        since=""
    fi
    if [ -n "$since" ] && _sb_round "baseline" baseline "$since" "$until" "$tag" "$canaries" "$dir"; then
        info "support bundle listing: $(python3 -I -m zipfile -l "$dir/baseline/bundle.zip" 2>/dev/null | awk 'NR > 1 {print $1}' | tr '\n' ' ')"
        code=$(curl -sSk -m 15 -o /dev/null -w '%{http_code}' "https://$ip/api/control/support-bundle-download?id=$SB_RID")
        case "$code" in
        401 | 403) ok "an unauthenticated download of the support bundle is refused (HTTP $code)" ;;
        *) bad "an unauthenticated download of the support bundle answered HTTP ${code:-none}" ;;
        esac
        code=$(curl -sSk -m 15 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Pithead-Control: 1' --data '{}' "https://$ip/api/control/support-bundle")
        case "$code" in
        401 | 403) ok "an unauthenticated support bundle request is refused (HTTP $code)" ;;
        *) bad "an unauthenticated support bundle request answered HTTP ${code:-none}" ;;
        esac
        _sb_guest "$tag" wedge-tor || bad "support bundle proof: could not wedge Tor on the guest"
        _sb_round "Tor wedged" tor-wedged "$since" "$until" "$tag" "$canaries" "$dir" || true
        _sb_guest "$tag" release-tor || bad "support bundle proof: Tor did not recover after the wedge"
        if _sb_guest "$tag" has-monerod; then
            if _sb_guest "$tag" stop-monerod; then
                _sb_round "monerod stopped" monerod-stopped "$since" "$until" "$tag" "$canaries" "$dir" || true
            else
                bad "support bundle proof: could not stop monerod on the guest ($(tail -c 300 "$SSH_ERR" 2>/dev/null | tr '\r\n' '  '))"
            fi
            _sb_guest "$tag" start-monerod || bad "support bundle proof: monerod did not start again"
        else
            info "support bundle proof: no local monerod on this guest; the monerod-stopped round is skipped"
        fi
    fi
    [ "$off" = 0 ] || _sb_guest "$tag" cleanup || bad "support bundle proof: cleanup of the seeded fixtures failed"
    if approval_restore_pending && sensitive_live_config >/dev/null; then
        ok "support bundle proof restored the control channel and the original configuration"
    else
        bad "support bundle proof: could not restore the original configuration"
    fi
    rm -rf "$dir"
}
