# Host control wrapper for the existing gated Tor recovery (#3118).
control_tor_recover() { # <control-dir> <id> <actor>
    local cdir="$1" id="$2" actor="$3" output status detail
    # Isolate exit-on-contention and require_deployed failures from the request loop.
    if output=$( (tor_recover apply) 2>&1); then
        status=applied
        detail=""
    else
        status=failed
        detail=$(printf '%s\n' "$output" | bundle_redact_log | tail -c 4096)
        [ -n "$detail" ] || detail="Tor recovery refused or failed host verification"
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg status "$status" --arg error "$detail" '{status:$status,action:"tor-recover",error:$error,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" tor-recover "$status"
}

tor_diagnostics_snapshot() {
    local raw changed
    raw=$(timeout 15 docker exec tor /usr/local/bin/tor-diagnostics.sh 2>/dev/null | head -n 5000) || raw=
    changed=$(timeout 10 docker logs --timestamps --tail 20000 tor 2>&1 | grep -F '] Bootstrapped ' | tail -n 1 | cut -d' ' -f1) || changed=
    printf '%s\n' "$raw" | jq -Rnc --arg changed "$changed" '
        def stamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$")
            then sub(" "; "T") + "Z" | fromdateiso8601 else null end;
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
                    then $changed | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 else null end)
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
