# Explicit recovery for saturated Tor circuit history. Never called by clearnet probing.
TOR_RECOVERY_COOLDOWN_SEC=21600

# monerod's get_info with the REAL outgoing count (#2921). The published RPC is restricted and answers 0
# for the connection counts, so the count is taken from the in-container helper (which reads the admin
# listener on the container's loopback, with the login from the container's environment) and replaces
# the redacted field. When the helper gives no reading the field is null: neither the "0 outgoing" of the
# signature nor the "> 0" of the verification is then true, so an unavailable count never reads as either.
tor_recovery_info() {
    local user pass url body peers out
    user=$(env_get MONERO_NODE_USERNAME) || return 1
    pass=$(env_get MONERO_NODE_PASSWORD) || return 1
    url=$(env_get MONERO_RPC_URL) || return 1
    [ -n "$url" ] || url=http://127.0.0.1:18081
    if [ -n "$user" ]; then
        body=$(printf 'user = %s\n' "$(printf '%s:%s' "$user" "$pass" | jq -Rs .)" |
            curl -fsS --max-time 8 --max-filesize 65536 --digest --config - "$url/get_info") || return 1
    else
        body=$(curl -fsS --max-time 8 --max-filesize 65536 "$url/get_info") || return 1
    fi
    peers=$(docker exec monerod /usr/local/bin/monerod-peers.sh 2>/dev/null) || peers=
    out=$(printf '%s' "$peers" | jq -c 'if (.outgoing | type) == "number" and .outgoing >= 0 then .outgoing else null end' 2>/dev/null) || out=null
    [ -n "$out" ] || out=null
    printf '%s' "$body" | jq -c --argjson out "$out" '.outgoing_connections_count = $out'
}

tor_recovery_state_saturated() { # <state file>
    local state="$1"
    sudo test -f "$state" && sudo test ! -L "$state" || return 1
    sudo grep -qx 'CircuitBuildAbandonedCount 1000' "$state" || return 1
    sudo grep -qx 'TotalBuildTimes 1000' "$state" || return 1
    ! sudo grep -q '^CircuitBuildTimeBin ' "$state" || return 1
}

tor_recovery_signature() { # <state file> <first Monero get_info> <second get_info>
    local first="$2" second="$3"
    tor_recovery_state_saturated "$1" || return 1
    jq -e --argjson next "$second" '
        .status == "OK" and .synchronized == false and
        (.outgoing_connections_count == 0) and
        ($next.status == "OK") and ($next.synchronized == false) and
        ($next.outgoing_connections_count == 0) and
        (.height == $next.height) and (.height | type == "number")
    ' <<<"$first" >/dev/null
}

tor_recovery_mount() { # print the one canonical live Tor data mount, else refuse
    local expected actual label count
    expected=$(env_get TOR_DATA_DIR) || return 1
    [ -n "$expected" ] && [ -d "$expected" ] && [ ! -L "$expected" ] || return 1
    [ "$(realpath -ms -- "$expected")" = "$(realpath -m -- "$expected")" ] || return 1
    label=$(docker inspect tor --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null) || return 1
    [ "$label" = tor ] || return 1
    count=$(docker inspect tor --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tor"}}x{{end}}{{end}}' 2>/dev/null) || return 1
    [ "$count" = x ] || return 1
    actual=$(docker inspect tor --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tor"}}{{.Source}}{{end}}{{end}}' 2>/dev/null) || return 1
    [ "$actual" = "$(realpath -e -- "$expected")" ] || return 1
    sudo test ! -L "$actual/state" || return 1
    printf '%s\n' "$actual"
}

tor_recovery_identities() { # hash retained onion identity keys, refusing missing or symlinked keys
    local dir="$1" keys
    keys=$(sudo find "$dir" -mindepth 2 -name hs_ed25519_secret_key -print) || return 1
    keys=$(printf '%s\n' "$keys" | LC_ALL=C sort)
    [ -n "$keys" ] || return 1
    while IFS= read -r key; do
        sudo test -f "$key" && sudo test ! -L "$key" || return 1
        sudo sha256sum -- "$key" || return 1
    done <<<"$keys"
}

tor_recovery_stop_changed_identity() {
    docker compose stop tor || docker compose stop tor || true
    if [ "$(docker inspect tor --format '{{.State.Running}}' 2>/dev/null)" != false ]; then
        warn "Tor identity changed and the container could not be confirmed stopped; stop it immediately."
        return 1
    fi
    warn "Tor identity changed; Tor is stopped. Restore the identity before starting Tor."
}

tor_recovery_redial_monerod() {
    # A real Tor restart can leave a local node holding dead SOCKS peers.
    if docker inspect monerod --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
        docker compose restart monerod || warn "Monero re-dial failed; restart monerod manually."
    fi
}

tor_recovery_restore_start() { # <data dir> <original identity hashes>; recover after failed state operation
    local dir="$1" identities="$2"
    if [ "$(tor_recovery_identities "$dir")" != "$identities" ]; then
        tor_recovery_stop_changed_identity || true
        return 1
    fi
    docker compose start tor || docker compose start tor || true
    if [ "$(docker inspect tor --format '{{.State.Running}}' 2>/dev/null)" != true ]; then
        warn "Tor could not be restarted; start it manually after resolving the failure."
        return 1
    fi
    if [ "$(tor_recovery_identities "$dir")" != "$identities" ]; then
        tor_recovery_stop_changed_identity || true
        return 1
    fi
    tor_recovery_redial_monerod
}

tor_recover() { # check | apply; explicit operator action only
    local mode="$1" dir state first second stamp now last backup healthy=0 info identities started_before started_after i
    case "$mode" in check | apply) ;; *) error "Usage: ./pithead tor-recover check|apply" ;; esac
    require_deployed
    # An active host operation is a refusal, not a queued mutation against changing state.
    PITHEAD_LOCK_TIMEOUT=0 mutation_lock_acquire tor-recover || return 1
    [ "${_PITHEAD_LOCK_OWNED:-0}" = 1 ] || {
        warn "Tor recovery refused: the host mutation lock is unavailable."
        return 1
    }
    dir=$(tor_recovery_mount) || {
        warn "Tor recovery refused: live container or data mount is ambiguous."
        mutation_lock_release
        return 1
    }
    state="$dir/state"
    stamp="$(env_get CONTROL_DIR)/tor-recovery-at"
    [ ! -L "$stamp" ] || {
        warn "Tor recovery refused: cooldown record is a symlink."
        mutation_lock_release
        return 1
    }
    now=$(date +%s)
    last=0
    if [ -f "$stamp" ]; then
        read -r last <"$stamp"
        [[ "$last" =~ ^[0-9]+$ ]] || {
            warn "Tor recovery refused: invalid cooldown record."
            mutation_lock_release
            return 1
        }
    fi
    if [ "$mode" = apply ] && [ $((now - last)) -lt "$TOR_RECOVERY_COOLDOWN_SEC" ]; then
        warn "Tor recovery refused: the persistent six-hour cooldown is active."
        mutation_lock_release
        return 1
    fi
    if ! tor_recovery_state_saturated "$state"; then
        warn "Tor recovery refused: circuit history is not saturated."
        mutation_lock_release
        return 1
    fi
    if [ "$(docker inspect monerod --format '{{.State.Running}}' 2>/dev/null)" != true ]; then
        warn "Tor recovery refused: a running local Monero node is required for chain evidence."
        mutation_lock_release
        return 1
    fi
    first=$(tor_recovery_info) || {
        warn "Tor recovery refused: Monero RPC unavailable."
        mutation_lock_release
        return 1
    }
    sleep 180
    second=$(tor_recovery_info) || {
        warn "Tor recovery refused: second Monero reading unavailable."
        mutation_lock_release
        return 1
    }
    if ! tor_recovery_signature "$state" "$first" "$second"; then
        warn "Tor recovery refused: saturated circuit history and stalled, peerless Monero are not both established."
        mutation_lock_release
        return 1
    fi
    log "Tor circuit history is saturated; local Monero stayed peerless and at one height across three minutes."
    identities=$(tor_recovery_identities "$dir") || {
        warn "Tor recovery refused: onion identities cannot be verified."
        mutation_lock_release
        return 1
    }
    if [ "$mode" = check ]; then
        log "Read-only check passed; onion identities are readable. Run './pithead tor-recover apply' to back up circuit state and restart Tor."
        mutation_lock_release
        return 0
    fi
    backup="$dir/state.backup.$now"
    sudo test ! -e "$backup" && sudo test ! -L "$backup" || {
        warn "Tor recovery refused: circuit-state backup target already exists."
        mutation_lock_release
        return 1
    }
    # Stamp before disruption: a failed attempt must not become an unbounded retry loop.
    printf '%s\n' "$now" >"$stamp" || {
        mutation_lock_release
        return 1
    }
    control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "started"
    started_before=$(docker inspect tor --format '{{.State.StartedAt}}' 2>/dev/null) || started_before=
    if ! docker compose stop tor; then
        if [ "$(tor_recovery_identities "$dir")" != "$identities" ]; then
            tor_recovery_stop_changed_identity || true
        else
            case "$(docker inspect tor --format '{{.State.Running}}' 2>/dev/null)" in
            false) tor_recovery_restore_start "$dir" "$identities" || true ;;
            true)
                started_after=$(docker inspect tor --format '{{.State.StartedAt}}' 2>/dev/null) || started_after=
                if [ -z "$started_before" ] || [ -z "$started_after" ]; then
                    warn "Tor start time is unknown; check Monero peers before retrying recovery."
                elif [ "$started_before" != "$started_after" ]; then
                    tor_recovery_redial_monerod
                fi
                ;;
            *) warn "Tor stop status is unknown; check Tor before retrying recovery." ;;
            esac
        fi
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "failed"
        mutation_lock_release
        return 1
    fi
    if [ "$(tor_recovery_mount)" != "$dir" ] || ! sudo test -f "$state" || sudo test -L "$state" ||
        ! tor_recovery_signature "$state" "$first" "$second" ||
        ! sudo mv -n -- "$state" "$backup" || sudo test -e "$state" || ! sudo test -f "$backup"; then
        warn "Tor recovery could not back up circuit state; starting Tor again."
        tor_recovery_restore_start "$dir" "$identities" || true
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "failed"
        mutation_lock_release
        return 1
    fi
    if [ "$(tor_recovery_identities "$dir")" != "$identities" ]; then
        tor_recovery_stop_changed_identity || true
        warn "Tor recovery failed before restart; circuit-state backup retained."
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "failed"
        mutation_lock_release
        return 1
    fi
    if ! docker compose start tor; then
        warn "Tor did not start; backup retained. Retrying start."
        tor_recovery_restore_start "$dir" "$identities" || true
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "failed"
        mutation_lock_release
        return 1
    fi
    if [ "$(tor_recovery_identities "$dir")" != "$identities" ]; then
        tor_recovery_stop_changed_identity || true
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "failed"
        mutation_lock_release
        return 1
    fi
    tor_recovery_redial_monerod
    for ((i = 0; i < 60; i++)); do
        if [ "$(docker inspect tor --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ]; then
            info=$(tor_recovery_info) || info='{}'
            if jq -e '.status == "OK" and .outgoing_connections_count > 0' <<<"$info" >/dev/null; then
                healthy=1
                break
            fi
        fi
        sleep 10
    done
    if [ "$healthy" -eq 1 ]; then
        log "Tor healthy; Monero has outgoing peers. Circuit-state backup retained."
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "applied"
    else
        warn "Tor or Monero connectivity is not verified; backup retained and Tor left running."
        control_audit "$(env_get CONTROL_DIR)/audit/control.log" "" "operator" "tor-recover" "failed"
    fi
    mutation_lock_release
    [ "$healthy" -eq 1 ]
}
