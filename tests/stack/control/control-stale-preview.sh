# shellcheck shell=bash
# Sourced by test-control-core.sh in its sandbox (#3352); leaves dashboard.energy edited, so the
# caller restores its baseline afterwards.
# #3352: two previews from one baseline. B commits a disjoint path; A's older preview must be refused
# as stale rather than replacing B's committed path with A's whole-document copy.
UUID_A="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')"
UUID_B="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')"
for pair in "$UUID_A:.dashboard.energy.cost_per_kwh=0.21" "$UUID_B:.dashboard.energy.currency=\"EUR\""; do
    jq "${pair#*:}" "$C/config.json" |
        jq -n --arg id "${pair%%:*}" --arg actor admin --slurpfile cfg /dev/stdin \
            '{id:$id,action:"preview",actor:$actor,config:$cfg[0]}' >"$REQS/${pair%%:*}.json"
    run_pending >/dev/null
done
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID_B" >"$REQS/$UUID_B.json"
run_pending >/dev/null
assert_eq "second tab's preview commits (#3352)" "$(jq -r '.status' "$RESULTS/$UUID_B.json")" "applied"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID_A" >"$REQS/$UUID_A.json"
run_pending >/dev/null
assert_eq "stale preview commit is rejected (#3352)" "$(jq -r '.status' "$RESULTS/$UUID_A.json")" "rejected"
assert_contains "stale preview asks for a new preview (#3352)" "$(jq -r '.error' "$RESULTS/$UUID_A.json")" "preview again"
assert_eq "stale commit keeps the newer committed path (#3352)" "$(jq -r '.dashboard.energy.currency' "$C/config.json")" "EUR"
[ ! -f "$STAGED/$UUID_A.json" ] && ok "stale staged intent cleared (#3352)" || bad "stale staged intent cleared (#3352)" "still staged"
