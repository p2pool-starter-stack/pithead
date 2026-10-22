# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

coordinator_saved_state_valid() {
    printf '%s' "$1" | jq -e --argjson expected "$2" '
        .stage == "setup" and .saved_role == {role: "pithead"} and
        .new_machine == false and
        (.config as $config | all($expected | paths(scalars);
          . as $p | ($config | getpath($p)) == ($expected | getpath($p)))) and
        ([.config | paths(scalars) as $p |
          select($p[-1] | test("password|token|view_key|spend_public_key|private_key")) |
          getpath($p)] | all(. == "" or . == null)) and
        ([.config.monero.node_username, .config.healthchecks.ping_url,
          .config.notifications.ntfy.url, .config.xvb.standby.source] |
          all(. == "" or . == null))' >/dev/null 2>&1
}

_coordinator_setup_answers() {
    _ssh 'cd /data/pithead && jq -Sc "del(.dashboard.auth,.dashboard.workers,.workers,.telegram,.healthchecks,.notifications,.ssh,.tari.spend_public_key,.dashboard.control.enabled,.dashboard.onion.enabled,.monero.node_username,.monero.node_password,.monero.view_key,.tari.view_key,.p2pool.stratum_password,.xvb.standby.source)" config.json' 2>/dev/null
}

_coordinator_setup_snapshot() {
    _ssh 'cd /data/pithead && sha256sum config.json .env Caddyfile machine-role' 2>/dev/null
}

_coordinator_setup_identity() {
    local identity
    identity=$(_ssh 'sha256sum /etc/machine-id /data/ssh/ssh_host_ed25519_key && podman exec tor cat /var/lib/tor/monero/hostname' 2>/dev/null) || return 1
    printf '%s\n' "$identity" | tail -1 | grep -Eq '^[a-z2-7]{56}\.onion$' || return 1
    printf '%s\n' "$identity"
}

_coordinator_setup_ready() {
    local deadline height state response code=000 crc=0 height_ready=no state_ready=no setup_ready=no
    provisioning_settled 900 && ! provisioning_setup_failed || {
        info "coordinator setup-again readiness: provisioning did not finish successfully"
        return 1
    }
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
        height=$(_monerod_height) || height=""
        crc=0
        response=$(dashboard_curl -fsSk -m 10 --max-filesize 1048576 -w '\n%{http_code}' "https://$ip/api/state" 2>/dev/null) || crc=$?
        code=${response##*$'\n'}
        [[ $code =~ ^[0-9]{3}$ ]] || code=000
        state=${response%$'\n'*}
        height_ready=no state_ready=no setup_ready=no
        [[ $height =~ ^[0-9]+$ ]] && [ "$height" -ge "$coord_height" ] && height_ready=yes
        if [ "$crc" -eq 0 ] && [ "$code" = 200 ] && printf '%s' "$state" | jq -e '
            (.sync.monero | type == "object") and
            (.sync.monero.state | type == "string" and length > 0)' >/dev/null 2>&1; then
            state_ready=yes
        fi
        if [ "${1:-}" != setup ] || _ssh 'systemctl is-active --quiet pithead-setup-again && test "$(systemctl show pithead-setup-again -p Result --value)" = success' >/dev/null 2>&1; then
            setup_ready=yes
        fi
        [ "$height_ready:$state_ready:$setup_ready" != yes:yes:yes ] || return 0
        sleep 5
    done
    info "coordinator setup-again readiness timed out: height_ready=$height_ready dashboard_http=$code curl_exit=$crc state_ready=$state_ready setup_ready=$setup_ready"
    return 1
}

_coordinator_setup_prefill() {
    wizard_state_poll "$ip" "$jar" '.' &&
        coordinator_saved_state_valid "$WIZ_STATE" "$coord_answers" || {
        bad "coordinator setup-again: saved pithead role and safe prefill did not match the saved answers"
        return 1
    }
    ok "coordinator setup-again: saved pithead role and prefilled answers carry no secrets"
}

_coordinator_setup_preserved() {
    local identity answers
    identity=$(_coordinator_setup_identity) || return 1
    answers=$(_coordinator_setup_answers) || return 1
    [ "$answers" = "$coord_answers" ] && [ -n "$identity" ] && [ "$identity" = "$coord_identity" ] &&
        _ssh 'cd /data/pithead && test "$(cat data/monero/.kvm-setup-again)" = coordinator-chain && test "$(cat data/tari/.kvm-setup-again)" = coordinator-chain && test "$(cat machine-role)" = pithead' >/dev/null 2>&1
}

_coordinator_setup_again_body() {
    local coord_answers coord_snapshot coord_identity coord_height="" deadline handoff code current
    local DASH_USER="$1" DASH_PASS="$2"
    coord_stage=baseline
    coord_answers=$(_coordinator_setup_answers) || return 1
    printf '%s' "$coord_answers" | jq -e 'type == "object" and (.monero.wallet_address | length > 0)' >/dev/null 2>&1 || return 1
    _ssh 'cd /data/pithead && jq -e ".p2pool.stratum_password | type == \"string\" and length > 0" config.json >/dev/null' || return 1
    coord_snapshot=$(_coordinator_setup_snapshot) || return 1
    coord_identity=$(_coordinator_setup_identity) || return 1
    [ -n "$coord_snapshot" ] && [ -n "$coord_identity" ] || return 1
    deadline=$((SECONDS + 300))
    while [ "$SECONDS" -lt "$deadline" ]; do
        coord_height=$(_monerod_height) || coord_height=""
        [[ $coord_height =~ ^[0-9]+$ ]] && [ "$coord_height" -gt 0 ] && break
        sleep 5
    done
    [[ $coord_height =~ ^[0-9]+$ ]] && [ "$coord_height" -gt 0 ] || return 1
    _coordinator_setup_ready || return 1
    _ssh 'cd /data/pithead && test -d data/monero && test -d data/tari && printf coordinator-chain > data/monero/.kvm-setup-again && printf coordinator-chain > data/tari/.kvm-setup-again' || return 1
    ok "coordinator setup-again: provisioned baseline has a working login, chains and onion identity"

    coord_stage=keep
    _setup_again_boot 300 && _setup_again_session && _coordinator_setup_prefill || return 1
    code=$(curl -sSk -b "$jar" -m 20 -X POST "https://$ip/keep-role" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$code" = 200 ] || return 1
    if _coordinator_setup_ready setup && _coordinator_setup_preserved &&
        current=$(_coordinator_setup_snapshot) && [ "$current" = "$coord_snapshot" ] &&
        _ssh 'test ! -e /data/pithead/data/firstboot/keep-role && systemctl is-active --quiet pithead-setup-again' >/dev/null 2>&1; then
        ok "coordinator Keep it: original login, configuration, chains and onion identity survive"
    else
        bad "coordinator Keep it: original login, configuration, chains or identity changed"
        return 1
    fi
    rm -f "$jar"
    jar=""

    coord_stage=resubmit
    _setup_again_boot 300 && _setup_again_session && _coordinator_setup_prefill || return 1
    code=$(curl -sSk -b "$jar" -m 30 --data-urlencode "config=$(printf '%s' "$WIZ_STATE" | jq -c '.config')" \
        --data-urlencode auth_mode=auto "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$code" = 200 ] || return 1
    deadline=$((SECONDS + 120))
    handoff=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        handoff=$(curl -fsSk -b "$jar" -m 5 --max-filesize 1048576 "https://$ip/api/handoff" 2>/dev/null) || handoff=""
        printf '%s' "$handoff" | jq -e '.username | type == "string" and length > 0' >/dev/null 2>&1 &&
            printf '%s' "$handoff" | jq -e '.password | type == "string" and length > 0' >/dev/null 2>&1 && break
        sleep 5
    done
    DASH_USER=$(printf '%s' "$handoff" | jq -er '.username | select(length > 0)') &&
        DASH_PASS=$(printf '%s' "$handoff" | jq -er '.password | select(length > 0)') || return 1
    code=$(curl -sSk -b "$jar" -m 20 -X POST "https://$ip/handoff-ack" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$code" = 200 ] || return 1
    if _coordinator_setup_ready setup && _coordinator_setup_preserved; then
        ok "coordinator resubmit: card login works, chain height resumes and chains and onion identity survive"
    else
        bad "coordinator resubmit: login, chain height, chain data or onion identity did not survive"
        return 1
    fi
}

phase_coordinator_setup_again() {
    local jar="" token="" rc=0 coord_stage=baseline
    _coordinator_setup_again_body "$@" || rc=$?
    [ -z "$jar" ] || rm -f "$jar"
    _ssh 'rm -f /data/pithead/data/monero/.kvm-setup-again /data/pithead/data/tari/.kvm-setup-again' >/dev/null 2>&1 || rc=1
    if [ "$rc" -ne 0 ]; then
        bad "coordinator setup-again did not complete both Keep it and coordinator resubmit (stage: $coord_stage)"
    fi
    return "$rc"
}
