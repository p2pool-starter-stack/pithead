# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# A fresh 40 GiB guest takes the Monero-only answer: Tari merge-mining is an opt-in beta, so Enter
# means off (#3333). Unlike provision, this leg does not override Tari to exercise the rest of the
# all-chain battery.
phase_setup_defaults() {
    local img token jar state cfg code handoff tries password names
    img=$(_build_image v1) || {
        bad "setup defaults image build failed"
        return 1
    }
    _vm_boot_disk "$img" && _wait_ssh 240 && _wait_setup_page 120 || {
        bad "setup defaults guest did not reach the wizard"
        return 1
    }
    local guest_ip="${ip:?_vm_boot_disk must set the guest address}"
    token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
    jar=$(mktemp)
    curl -fsSk -c "$jar" --data-urlencode "token=$token" "https://$guest_ip/auth" -o /dev/null || return 1
    state=$(curl -fsSk -b "$jar" "https://$guest_ip/api/wizard-state") || return 1
    if jq -e '.new_machine and .disk_budget.available_bytes < .disk_budget.local_need_bytes and
        .config.tari.mode == "off" and .config.xvb.enabled == false and
        .config.monero.clearnet_initial_sync == false and .config.tari.clearnet_initial_sync == false and
        .auth_mode == "auto"' <<<"$state" >/dev/null; then
        ok "fresh appliance defaults use the data disk, no Tari, no XvB, Tor and generated login"
    else
        bad "fresh appliance defaults differ from the small-disk contract"
        return 1
    fi
    cfg=$(jq -c --arg m "$HARNESS_WALLET" '.config | .monero.wallet_address = $m' <<<"$state") || return 1
    code=$(curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode auth_mode=auto \
        "https://$guest_ip/submit" -o /dev/null -w '%{http_code}')
    [ "$code" = 200 ] || {
        bad "fresh defaults submit returned HTTP $code"
        return 1
    }
    handoff=""
    for ((tries = 0; tries < 30; tries++)); do
        handoff=$(curl -sSk -b "$jar" -m 5 "https://$guest_ip/api/handoff")
        password=$(jq -r '.password // ""' <<<"$handoff" 2>/dev/null)
        [[ "$password" =~ ^[A-Za-z0-9]{32}$ ]] && break
        sleep 3
    done
    [[ "$password" =~ ^[A-Za-z0-9]{32}$ ]] || {
        bad "fresh defaults did not generate a login card"
        return 1
    }
    ok "fresh appliance defaults generate a 32-character dashboard password"
    code=$(curl -sSk -b "$jar" -X POST "https://$guest_ip/handoff-ack" -o /dev/null -w '%{http_code}')
    rm -f "$jar"
    [ "$code" = 200 ] || {
        bad "fresh defaults handoff acknowledgement failed"
        return 1
    }
    for ((tries = 0; tries < 100; tries++)); do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in *dashboard*caddy* | *caddy*dashboard*) ok "fresh defaults start the appliance dashboard" ;; *)
        bad "fresh defaults did not start the dashboard"
        return 1
        ;;
    esac
    if _ssh "jq -e '.tari.mode == \"off\" and .xvb.enabled == false and
        .monero.clearnet_initial_sync == false and .tari.clearnet_initial_sync == false and
        (.dashboard.auth.password | length) == 32' /data/pithead/config.json" >/dev/null; then
        ok "fresh appliance setup persists all explicit new-install choices"
    else
        bad "fresh appliance setup lost a new-install choice"
    fi
    code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$guest_ip/")
    [ "$code" = 401 ] && ok "fresh default dashboard requires its generated login" || bad "fresh default dashboard is not protected (HTTP $code)"
    code=$(curl -ksS -u "admin:$password" -o /dev/null -w '%{http_code}' -m 8 "https://$guest_ip/")
    [ "$code" = 200 ] && ok "fresh default dashboard accepts the generated login" || bad "fresh generated login does not open the dashboard (HTTP $code)"
    if SSH_TIMEOUT=60 _ssh 'bash -s' <"$SCRIPT_DIR/credential-journals.sh"; then
        ok "fresh default firstboot and system journals contain no bcrypt credential (#3131)"
    else
        bad "fresh default firstboot or system journal contains bcrypt, or could not be checked (#3131)"
    fi
}
