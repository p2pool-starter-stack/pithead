# shellcheck shell=bash
# The dashboard password is physical-presence-only. Preview must name that boundary too, not
# merely reject it as an otherwise generic sensitive config change.
jq '.dashboard.auth={username:"admin"} | .dashboard.control={enabled:false}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "auth-disable preview is refused, not previewed as committable" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "auth-disable preview names the physical-presence path" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "configuration stick"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "dashboard-login disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "auth-disable refusal names the physical-presence path" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "configuration stick"
assert_eq "config.json keeps the dashboard password" "$(jq -r '.dashboard.auth.password' "$C/config.json")" "a control passphrase"
