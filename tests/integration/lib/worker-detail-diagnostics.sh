# shellcheck shell=bash
capture_worker_detail_failure() { # <rig> <judged-state> <judged-detail>
    local sample
    # Fixed typed projections, as in the selected-rig capture; no names or free text.
    sample="$(printf '%s\0%s' "$2" "$3" | timeout 5 jq -Rsc --arg n "$1" '
        def bool: if type == "boolean" then . else null end;
        def status: if . == "online" or . == "offline" then . else null end;
        def rf: (if type == "object" then . else {} end) as $r |
            {present:(type == "object"), version_present:($r.version != null),
            stale:($r.stale | bool),
            version_withheld_as_stale:(if $r.stale == true and $r.version == null then true
                elif $r.stale == false then false else null end),
            generated_at:($r.generated_at | if type == "string" then
                if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else null end
                else null end)};
        (split("\u0000") | map(try fromjson catch null)) as $reads |
        (if ($reads[0] | type) == "object" then $reads[0] else {} end) as $s |
        (if ($reads[1] | type) == "object" then $reads[1] else {} end) as $d |
        (if ($s.workers | type) == "array" then
            first($s.workers[] | objects | select(.name == $n)) // null else null end) as $w |
        {state:{valid:(($reads[0] | type) == "object"), worker_found:($w != null),
            status:($w.status | status), api_ok:($w.api_ok | bool), rigforge:($w.rigforge | rf)},
         detail:{valid:(($reads[1] | type) == "object"), found:($d.found | bool),
            status:($d.status | status), rigforge:($d.rigforge | rf)}}' 2>/dev/null)" || {
        it_warn "worker detail diagnostics projection failed"
        return 1
    }
    printf '%s\n' "$sample" >"$OUT_DIR/worker-detail.failure.json" || {
        it_warn "worker detail diagnostics could not be retained"
        return 1
    }
}
