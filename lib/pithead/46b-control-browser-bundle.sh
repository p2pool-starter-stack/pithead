control_collect_browser_bundle() (
    local cdir="$1" id="$2" actor="$3" work container
    work=$(mktemp -d "$cdir/.diag-bundle.XXXXXX") || return 1
    trap 'rm -r -- "$work"' EXIT
    chmod 700 "$work" || return 1
    mkdir -p "$work/results" "$work/audit" "$work/logs" || return 1
    control_diag_doctor "$id" "$actor" "$work" || return 1
    jq -e '.doctor | type == "object"' "$work/results/$id.json" >/dev/null || return 1
    jq '.doctor' "$work/results/$id.json" >"$work/doctor.json" || return 1
    for container in $PITHEAD_DIAG_CONTAINERS; do
        jq -n --arg container "$container" --argjson lines "$PITHEAD_DIAG_MAX_LINES" \
            '{container:$container,lines:$lines}' >"$work/request.json" || return 1
        control_diag_logs "$work/request.json" "$id" "$actor" "$work" || return 1
        jq -e '.status == "applied" and (.lines | type == "string")' "$work/results/$id.json" >/dev/null || return 1
        jq '{key:.container,value:.lines}' "$work/results/$id.json" >"$work/logs/$container.json" || return 1
    done
    jq -s 'from_entries' "$work"/logs/*.json >"$work/logs.json" || return 1
    jq -n --arg id "$id" --arg actor "$actor" --slurpfile doctor "$work/doctor.json" \
        --slurpfile logs "$work/logs.json" \
        '{id:$id,status:"applied",kind:"diag-bundle",actor:$actor,bundle:{doctor:$doctor[0],logs:$logs[0]},ts:(now|floor)}'
)

control_diag_bundle() {
    local file="$1" id="$2" actor="$3" cdir="$4" result
    local auditf="$cdir/audit/control.log"
    if [ -z "$actor" ] || [ "$actor" = untrusted ] ||
        [ "$(jq -r 'keys | sort == ["action","actor","id"]' "$file")" != true ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"Invalid browser bundle request.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" diag-bundle rejected
        return 0
    fi
    control_audit "$auditf" "$id" "$actor" diag-bundle started
    if result=$(control_collect_browser_bundle "$cdir" "$id" "$actor"); then
        control_write_result "$cdir/results" "$id" "$result"
        control_audit "$auditf" "$id" "$actor" diag-bundle applied
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg id "$id" --arg actor "$actor" \
            '{id:$id,actor:$actor,kind:"diag-bundle",status:"failed",error:"A redacted report was not available; no bundle was created.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" diag-bundle failed
    fi
}
