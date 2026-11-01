CONTROL_WUA_MAX_RIGS=20

control_worker_upgrade_all() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade-all" "started"
    local version rigs total i=0 sub rigf out
    version=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$version" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"malformed or missing '"'"'version'"'"' in the upgrade request.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade-all" "rejected"
        return 0
    fi
    if ! jq -e '(.workers | type == "array") and (.workers | length >= 1 and length <= 100) and
        all(.workers[]; type == "string") and ((.workers | length) == (.workers | unique | length))' "$file" >/dev/null 2>&1; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"'"'"'workers'"'"' must be 1 to 100 distinct rig names.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade-all" "rejected"
        return 0
    fi
    if [ "${CONTROL_WU_BUDGET:-0}" -le 0 ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"another worker upgrade is already in this cycle — retry in a moment.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade-all" "rejected"
        return 0
    fi
    rigs=$(jq -c --argjson max "$CONTROL_WUA_MAX_RIGS" \
        '[.workers | to_entries[] | {name: .value, status: (if .key < $max then "pending" else "not_started" end),
            reason: (if .key < $max then null else "over the per-run limit of \($max) rigs — run Update all again" end)}]' "$file")
    total=$(jq 'length' <<<"$rigs")
    _wua_write() { # <run-status>
        control_write_result "$results" "$id" "$(jq -n --arg s "$1" --arg v "$version" --argjson r "$rigs" \
            '{status:$s,action:"worker-upgrade-all",version:$v,total:($r|length),rigs:$r,
              counts:($r | group_by(.status) | map({key: .[0].status, value: length}) | from_entries),ts:(now|floor)}')"
    }
    _wua_write running
    while [ "$i" -lt "$total" ] && [ "$i" -lt "$CONTROL_WUA_MAX_RIGS" ]; do
        sub="$id-$i"
        rigf="$cdir/staged/.$sub.rig"
        rigs=$(jq -c --argjson i "$i" '.[$i].status = "running"' <<<"$rigs")
        _wua_write running
        jq -n --arg w "$(jq -r --argjson i "$i" '.workers[$i]' "$file")" --arg v "$version" '{worker:$w,version:$v}' >"$rigf"
        CONTROL_WU_BUDGET=1
        control_worker_upgrade "$rigf" "$sub" "$actor" "$cdir"
        rm -f "$rigf"
        out=$(jq -c '{status: (.status // "failed"), change_id: (.change_id // null), reason: ((.reason // .error // .note // null) | if . == null then null else tostring | .[:500] end)}' \
            "$results/$sub.json" 2>/dev/null) || out='{"status":"failed","reason":"the rig upgrade left no result"}'
        rm -f "$results/$sub.json"
        rigs=$(jq -c --argjson i "$i" --argjson o "$out" '.[$i] |= (. + $o)' <<<"$rigs")
        i=$((i + 1))
    done
    CONTROL_WU_BUDGET=0
    _wua_write completed
    control_audit "$auditf" "$id" "$actor" "worker-upgrade-all" "completed"
}
