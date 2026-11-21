# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"
OS_RESERVED_NODE_CONSUMER=0
# shellcheck source=tests/os/realupgrade-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../realupgrade-helpers.sh"
# shellcheck source=tests/os/realupgrade-legs.sh
source "$(dirname "${BASH_SOURCE[0]}")/../realupgrade-legs.sh"

RU_PORT=8932
RU_HOST_NAME="realupgrade-box"
RU_STRATUM_PORT=3344
RU_NEW_PASS="Realupgrade-$(printf '%s' "$$$RANDOM" | sha256sum | cut -c1-16)"
RU_WORK=""
RU_SRV_PID=""
RU_STRATUM_PID=""
RU_TAG=""
RU_EVIDENCE=""
RU_WITH_SOAK=0

_ru_state() { dashboard_curl -sSk -m 10 "https://$ip/api/state" 2>/dev/null; }
_ru_os() { _ru_state | jq -c '.os_update // {}' 2>/dev/null; }
_ru_stop_helpers() {
    [ -z "$RU_SRV_PID" ] || kill "$RU_SRV_PID" 2>/dev/null || true
    [ -z "$RU_STRATUM_PID" ] || kill "$RU_STRATUM_PID" 2>/dev/null || true
    RU_SRV_PID="" RU_STRATUM_PID=""
}
_ru_cleanup() {
    _ru_stop_helpers
    [ -z "$RU_WORK" ] || rm -rf "$RU_WORK"
    RU_WORK=""
}

_ru_fetch_old_image() {
    local dir="$1" base tags asset
    local ver
    ver=$(tr -d ' \t\r\n' <VERSION)
    if [ -n "${PITHEAD_REALUPGRADE_OLD_TAG:-}" ]; then
        RU_TAG="$PITHEAD_REALUPGRADE_OLD_TAG"
    else
        tags=$(curl -fsSL --retry 3 "https://api.github.com/repos/$REALUPGRADE_REPO/releases?per_page=30" | jq -r '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name') || return 1
        # shellcheck disable=SC2086
        RU_TAG=$(realupgrade_old_tag "$ver" $tags) || return 1
    fi
    asset="pithead-os-$RU_TAG.img.xz"
    base="https://github.com/$REALUPGRADE_REPO/releases/download/$RU_TAG"
    curl -fsSL --retry 3 -o "$dir/$asset" "$base/$asset" &&
        curl -fsSL --retry 3 -o "$dir/$asset.sha256" "$base/$asset.sha256" || return 1
    (cd "$dir" && sha256sum -c "$asset.sha256" >/dev/null) || return 1
    RU_OLD_SHA=$(sha256sum "$dir/$asset" | cut -d' ' -f1)
    xz -dk "$dir/$asset" || return 1
    RU_OLD_IMG="$dir/pithead-os-$RU_TAG.img"
    [ -s "$RU_OLD_IMG" ]
}

_ru_save_failure() {
    rollback_evidence "$SERIAL.realupgrade-$1"
    {
        printf '== api os_update\n'
        _ru_os
        printf '\n== api state\n'
        _ru_state
    } >>"$SERIAL.realupgrade-$1" 2>&1 || true
    info "realupgrade failure evidence kept at $SERIAL.realupgrade-$1 (pithead-boot journal, verdict, grubenv, doctor)"
}

_ru_wait_state() {
    local deadline=$(($(date +%s) + $1))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ru_state | jq -e '.os_update.step' >/dev/null 2>&1 && return 0
        sleep 10
    done
    return 1
}

_ru_config_commit() {
    local live proposed rid result
    live=$(sensitive_live_config) || return 1
    proposed=$(printf '%s' "$live" | jq -c "$1")
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    rid=$APPROVAL_REQUEST_ID
    result=$(approval_commit "$rid") || true
    printf '%s' "$result" | jq -c . 2>/dev/null || printf '%s\n' "$result"
}

_ru_tls_snapshot() {
    local pem fp sans
    pem=$(echo | openssl s_client -connect "$ip:443" 2>/dev/null | openssl x509 2>/dev/null) || return 1
    fp=$(printf '%s' "$pem" | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
    sans=$(printf '%s' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n')
    printf '%s|%s' "$fp" "$sans"
}

_ru_start_stratum_client() {
    (
        while :; do
            if exec 9<>"/dev/tcp/$1/$2" 2>/dev/null; then
                printf 'connected %s\n' "$(date +%s)" >>"$3"
                printf '{"id":1,"jsonrpc":"2.0","method":"login","params":{"login":"%s","pass":"x","agent":"realupgrade"}}\n' "$HARNESS_WALLET" >&9
                cat <&9 >>"$3.rx" 2>/dev/null
                printf 'dropped %s\n' "$(date +%s)" >>"$3"
                exec 9<&-
            fi
            sleep 5
        done
    ) >/dev/null 2>&1 &
    RU_STRATUM_PID=$!
}

_ru_prepare() {
    local bundle host_addr size
    RU_WORK=$(mktemp -d "${TMPDIR:-/tmp}/realupgrade.XXXXXX") || return 1
    RU_EVIDENCE="$SERIAL.realupgrade-evidence"
    : >"$RU_EVIDENCE"
    realupgrade_stamp setup fetch-old-image
    _ru_fetch_old_image "$RU_WORK" || {
        bad "could not fetch and verify the published N-2 appliance image (tag '${RU_TAG:-unresolved}')"
        return 1
    }
    ok "published $RU_TAG appliance image fetched and its .sha256 verified ($RU_OLD_SHA)"
    printf 'old_tag=%s\nold_sha256=%s\n' "$RU_TAG" "$RU_OLD_SHA" >>"$RU_EVIDENCE"

    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -q
    realupgrade_stamp setup build-candidate
    bundle=$(_build_bundle candidate) || {
        bundle_build_evidence
        bad "candidate bundle build failed (/tmp/os-fault-bundle.log)"
        return 1
    }
    [ -s "$bundle" ] || {
        bad "candidate bundle build produced no .raucb"
        return 1
    }
    ok "built the exact-SHA candidate bundle: $(basename "$bundle")"
    RU_BUNDLE="$bundle"

    RU_SRV="$RU_WORK/srv"
    mkdir -p "$RU_SRV"
    RU_NEW_TAG="v$(tr -d ' \t\r\n' <VERSION)"
    cp "$bundle" "$RU_SRV/pithead-os-$RU_NEW_TAG.raucb" || {
        bad "could not stage the candidate bundle for the bench release server"
        return 1
    }
    size=$(wc -c <"$RU_SRV/pithead-os-$RU_NEW_TAG.raucb" | tr -d ' ')
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$RU_NEW_TAG" "$RU_NEW_TAG" "$size" >"$RU_SRV/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    RU_BASE="http://$host_addr:$RU_PORT"

    realupgrade_stamp setup patch-old-image
    realupgrade_bundle_cert "$RU_BUNDLE" "$RU_WORK/signer.pem" || {
        bad "could not read the signing certificate out of the candidate bundle"
        return 1
    }
    realupgrade_attach_and_patch "$RU_OLD_IMG" "$RU_WORK/signer.pem" "$RU_BASE" "$RU_WORK/patch-manifest.json" || {
        bad "could not patch the scratch copy of the published image (no mount, or the root is integrity-protected) — stop and report, never fall back to a nightly image"
        return 1
    }
    cat "$RU_WORK/patch-manifest.json" >>"$RU_EVIDENCE"
    ok "scratch copy patched: test trust added beside the release keyring; planted paths recorded ($(jq -c .planted "$RU_WORK/patch-manifest.json"))"
}

_ru_boot_aged_guest() {
    local cfg_out rc
    RU_SRV_PID=$(_serve_update_dir "$RU_SRV" "$RU_PORT") || {
        bad "the bench release server never answered on :$RU_PORT (harness, not product)"
        return 1
    }

    realupgrade_stamp setup boot-old-guest
    _vm_boot_disk "$RU_OLD_IMG" || {
        bad "the patched $RU_TAG guest never got a lease"
        return 1
    }
    ok "patched published $RU_TAG guest booted ($ip)"
    _wizard_provision_capture 0 || {
        bad "provisioning the $RU_TAG guest through its wizard failed (${WIZ_FAIL_REASON:-no reason})"
        return 1
    }
    ok "$RU_TAG guest provisioned through the wizard"
    _ru_wait_state 1500 || {
        bad "the $RU_TAG dashboard never served an authenticated /api/state with os_update"
        return 1
    }
    ok "$RU_TAG dashboard serves /api/state with os_update"

    cfg_out=$(_ru_config_commit ".dashboard.host = \"$RU_HOST_NAME\" | .p2pool.stratum_port = $RU_STRATUM_PORT | .dashboard.auth.password = \"$RU_NEW_PASS\"") && rc=0 || rc=$?
    DASH_PASS="$RU_NEW_PASS"
    if [ "$rc" -eq 0 ] && _ru_wait_state 600 &&
        [ "$(dashboard_curl -sSk -m 10 "https://$ip/api/config" | jq -r '.dashboard.host')" = "$RU_HOST_NAME" ] &&
        [ "$(dashboard_curl -sSk -m 10 "https://$ip/api/config" | jq -r '.p2pool.stratum_port')" = "$RU_STRATUM_PORT" ]; then
        ok "aged config committed through the dashboard API (pinned host name, stratum port $RU_STRATUM_PORT, changed password)"
    else
        bad "the aged-config commit did not land through the dashboard (rc=$rc, result: $(printf '%s' "$cfg_out" | cut -c1-200))"
        return 1
    fi
    realupgrade_stamp setup aged-ready
}

_ru_install_candidate() {
    local leg="$1" out
    out=$(_os_step '{"action":"check"}' 120)
    [ "$(printf '%s' "$out" | jq -r '.status')" = "checked" ] && [ "$(printf '%s' "$out" | jq -r '.version')" = "$RU_NEW_TAG" ] || {
        bad "$leg: check did not derive $RU_NEW_TAG (got: $(printf '%s' "$out" | cut -c1-200))"
        return 1
    }
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$RU_NEW_TAG\"}" 1200)
    [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ] || {
        bad "$leg: download did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
        return 1
    }
    out=$(_os_step '{"action":"verify"}' 180)
    [ "$(printf '%s' "$out" | jq -r '.status')" = "verified" ] || {
        bad "$leg: the $RU_TAG slot refused the test-signed bundle at verify (got: $(printf '%s' "$out" | cut -c1-200))"
        return 1
    }
    out=$(_os_step '{"action":"install"}' 1500)
    [ "$(printf '%s' "$out" | jq -r '.status')" = "installed" ] || {
        bad "$leg: install did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
        return 1
    }
    _ru_os | jq -e '.step == "reboot-pending"' >/dev/null 2>&1 || {
        bad "$leg: the persisted step is not reboot-pending after install"
        return 1
    }
    ok "$leg: check, download, verify and install completed through the dashboard; reboot-pending"
}

_ru_order_reboot() {
    local t0 out
    t0=$(date +%s)
    RU_REBOOT_T0="$t0"
    out=$(_os_step '{"action":"reboot"}' 30 2>/dev/null || true)
    [ "$(printf '%s' "$out" | jq -r '.status // ""' 2>/dev/null)" != rejected ] || {
        bad "$1: the dashboard rejected the ordered reboot: $(printf '%s' "$out" | cut -c1-200)"
        return 1
    }
    sleep 20
    _wait_ssh 900 || {
        bad "$1: the candidate slot never answered SSH after the ordered reboot"
        return 1
    }
    RU_BOOT_ID=$(_boot_id) || RU_BOOT_ID=""
    ok "$1: the ordered reboot landed on the candidate slot (marker $(_marker))"
}

_ru_upgrade_leg() {
    local os_json t_commit budget deadline
    realupgrade_stamp upgrade start
    _ru_install_candidate upgrade || {
        _ru_save_failure upgrade
        return 1
    }
    TLS_BEFORE=$(_ru_tls_snapshot) || TLS_BEFORE=""
    [ -n "$TLS_BEFORE" ] && ok "TLS fingerprint and SANs captured before the update" || bad "could not read the old version's TLS certificate"
    _ru_start_stratum_client "$ip" "$RU_STRATUM_PORT" "$RU_WORK/stratum.log"
    realupgrade_stamp upgrade reboot-ordered
    _ru_order_reboot upgrade || {
        _ru_save_failure upgrade
        return 1
    }
    budget=$(realupgrade_commit_budget_s "$REALUPGRADE_BOOT_GATE_S")
    deadline=$((RU_REBOOT_T0 + budget))
    os_json=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        os_json=$(_ru_os)
        [ -z "$os_json" ] || realupgrade_no_offer_while_verifying "$os_json" || bad "upgrade: a reboot was offered while the new slot was verifying"
        realupgrade_verdict_updated "$os_json" && break
        sleep 15
    done
    t_commit=$(($(date +%s) - RU_REBOOT_T0))
    if realupgrade_verdict_updated "$os_json"; then
        ok "upgrade: outcome=updated and the slot committed (no rolled_back)"
    else
        bad "upgrade: no updated verdict within the budget (last: $(printf '%s' "$os_json" | jq -c '.verdict // .step' 2>/dev/null | cut -c1-200))"
        _ru_save_failure upgrade
        return 1
    fi
    if realupgrade_within_budget "$t_commit" "$budget"; then
        ok "upgrade: time-to-commit ${t_commit}s is within the budget ${budget}s (boot gate ${REALUPGRADE_BOOT_GATE_S}s + 50%)"
    else
        bad "upgrade: time-to-commit ${t_commit}s exceeded the budget ${budget}s"
    fi
    case "$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')" in
    *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*) ok "upgrade: the candidate slot is committed in grubenv" ;;
    *) bad "upgrade: grubenv does not show a committed slot" ;;
    esac
    [ -n "$RU_BOOT_ID" ] && [ "$(_boot_id)" = "$RU_BOOT_ID" ] && ok "upgrade: no reboot other than the ordered one before the commit" ||
        bad "upgrade: the guest rebooted again between the ordered reboot and the commit"
    realupgrade_stamp upgrade finished
}

_ru_leg_run() {
    local before=$FAIL
    _ru_boot_aged_guest && "$1"
    [ "$FAIL" -le "$before" ] || _ru_save_failure "$1"
    _ru_stop_helpers
}

_ru_run() {
    local legs="$1"
    info "phase: realupgrade, legs $legs (a published appliance image aged, then upgraded through the dashboard to the candidate built from HEAD)"
    realupgrade_legs_valid "$legs" || {
        bad "realupgrade legs '$legs' is not a comma list of upgrade, soak, negctl (soak needs upgrade)"
        return
    }
    _ru_prepare || {
        _ru_cleanup
        return
    }
    if realupgrade_leg_enabled upgrade "$legs"; then
        RU_WITH_SOAK=0
        realupgrade_leg_enabled soak "$legs" && RU_WITH_SOAK=1
        _ru_leg_run _ru_upgrade_and_soak
    fi
    if realupgrade_leg_enabled negctl "$legs"; then
        _ru_leg_run _ru_negctl_leg
    fi
    _ru_cleanup
}

_ru_upgrade_and_soak() {
    _ru_upgrade_leg || return 1
    [ "$RU_WITH_SOAK" = 1 ] && _ru_soak_leg
}

phase_realupgrade() { _ru_run "${PITHEAD_REALUPGRADE_LEGS:-$REALUPGRADE_LEGS_DEFAULT}"; }
phase_realupgrade_main() { _ru_run upgrade,soak; }
phase_realupgrade_negctl() { _ru_run negctl; }
