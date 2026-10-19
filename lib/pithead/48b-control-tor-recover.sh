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
