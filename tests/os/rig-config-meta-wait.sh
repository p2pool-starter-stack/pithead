# shellcheck shell=bash
# RigForge publishes the sister feed on a 15-second timer, independently of control status.
# Wait for valid provenance, and for the applied change ID before capturing the pre-reboot baseline.
rig_config_meta_wait() { # <token> [expected change_id]; stdout is only validated metadata
    local token=$1 expected=${2:-} attempt meta
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
    [ -z "$expected" ] || [[ "$expected" =~ ^[0-9a-f]{16}$ ]] || return 1
    for attempt in {1..12}; do
        meta=$(_ssh "curl -fsS -m 5 -H 'Authorization: Bearer $token' http://127.0.0.1:8081/2/summary" 2>/dev/null |
            jq -ec --arg expected "$expected" '.rigforge.config_meta
                | select((.revision | type == "string" and test("^[0-9a-f]{16}$"))
                    and (.last_change_id | type == "string" and test("^[0-9a-f]{16}$")))
                | select($expected == "" or .last_change_id == $expected)
                | {revision, last_change_id}' 2>/dev/null) && {
            printf '%s\n' "$meta"
            return 0
        }
        [ "$attempt" = 12 ] || sleep 5
    done
    return 1
}
