control_tor_recover() { # <control-dir> <id> <actor> [action]
    local cdir="$1" id="$2" actor="$3" action="${4:-tor-recover}" output status detail
    if output=$( (tor_recover apply) 2>&1); then
        status=applied
        detail=""
    else
        status=failed
        detail=$(printf '%s\n' "$output" | bundle_redact_log | tail -c 4096)
        [ -n "$detail" ] || detail="Tor recovery refused or failed host verification"
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg status "$status" --arg action "$action" --arg error "$detail" '{status:$status,action:$action,error:$error,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "$action" "$status"
}

CONTROL_TOR_RESET_COOLDOWN_S=1800

control_tor_reset() { # <control-dir> <id> <actor>
    local cdir="$1" id="$2" actor="$3" stamp="$1/tor-reset-at" last=0 now error=""
    now=$(date +%s)
    if [ -L "$stamp" ]; then
        last=invalid
    elif [ -f "$stamp" ]; then
        read -r last <"$stamp" || last=invalid
    fi
    if ! [[ "$last" =~ ^[0-9]+$ ]]; then
        error="the Reset Tor state record is invalid, so the reset was not attempted"
    elif [ "$last" -le "$now" ] && [ $((now - last)) -lt "$CONTROL_TOR_RESET_COOLDOWN_S" ]; then
        error="Reset Tor state was already requested $(((now - last) / 60)) minutes ago — wait $(((CONTROL_TOR_RESET_COOLDOWN_S - (now - last) + 59) / 60)) more minutes before asking again"
    fi
    if [ -n "$error" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$error" '{status:"rejected",action:"tor-reset",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" tor-reset rejected
    elif ! printf '%s\n' "$now" >"$stamp"; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"failed",action:"tor-reset",error:"the Reset Tor state record could not be written",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" tor-reset failed
    else
        control_tor_recover "$cdir" "$id" "$actor" tor-reset
    fi
}

stack_redial_after_restart() {
    stack_redial_monerod
    if [ -n "$(docker inspect tari --format '{{.State.Running}}' 2>/dev/null)" ]; then
        log "Restarting tari so it starts after Tor is bootstrapped, not alongside it..."
        docker compose restart tari
    fi
}

tor_diagnostics_snapshot() {
    local raw changed
    raw=$(timeout 10 docker exec tor /usr/local/bin/tor-diagnostics.sh 2>/dev/null | head -n 5000) || raw=
    changed=$(timeout 5 docker logs --timestamps --tail 20000 tor 2>&1 | grep -F '] Bootstrapped ' | tail -n 1 | cut -d' ' -f1) || changed=
    printf '%s\n' "$raw" | jq -Rnc --arg changed "$changed" '
        def stamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$")
            then try (sub(" "; "T") + "Z" | fromdateiso8601) catch null else null end;
        def count($k; $re): [.[] | select(.k == $k and (.v | test($re))) | .v] | group_by(.) | map({v: .[0], n: length});
        (now | floor) as $now
        | [inputs | capture("^(?<k>[a-z_]+)=(?<v>.*)$")?] as $kv
        | def one($k; $re): [$kv[] | select(.k == $k and (.v | test($re))) | .v] | first;
        (one("consensus_valid_after"; ".") | stamp) as $after
        | (one("consensus_file_mtime"; "^[0-9]{1,12}$") | if . then tonumber else null end) as $mtime
        | {
            taken_at: $now,
            control: (if one("control"; "^ok$") then "ok" else "unreachable" end),
            version: one("version"; "^[0-9][0-9a-z.-]{0,40}$"),
            bootstrap: {
                progress: (one("bootstrap_progress"; "^[0-9]{1,3}$") | if . then tonumber else null end),
                tag: one("bootstrap_tag"; "^[a-z_]{1,40}$"),
                changed_at: (if $changed | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
                    then try ($changed | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null else null end),
                circuit_established: (one("circuit_established"; "^[01]$") | if . then . == "1" else null end),
                enough_dir_info: (one("enough_dir_info"; "^[01]$") | if . then . == "1" else null end)
            },
            circuits: ($kv | count("circuit"; "^[A-Z_]{1,40} [A-Z_]{1,40}$")
                | map((.v | split(" ")) as $p | {state: $p[0], purpose: $p[1], count: .n})),
            guards: ($kv | count("guard"; "^[a-z-]{1,40}$") | map({key: .v, value: .n}) | from_entries),
            consensus: {
                source: (one("consensus_source"; "^(control|file)$") // "none"),
                valid_after: $after,
                valid_until: (one("consensus_valid_until"; ".") | stamp),
                age_sec: (if $after then $now - $after elif $mtime then $now - $mtime else null end)
            }
        }'
}
