# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== control channel: worker-upgrade-all rolls the fleet one rig at a time (#3823) =="
WUA="$SANDBOX/ctrl3823"
mkdir -p "$WUA/staged" "$WUA/results" "$WUA/audit" "$WUA/bin"
printf 'v9.9.9' >"$WUA/staged/.rigforge-latest-tag"
cat >"$WUA/config.json" <<'EOF2'
{ "workers": { "list": [
    { "name": "rig-a", "host": "192.0.2.1", "control_port": 8082, "token": "tok-a" },
    { "name": "rig-b", "host": "192.0.2.2", "control_port": 8082, "token": "tok-b" },
    { "name": "rig-c", "host": "192.0.2.3", "control_port": 8082, "token": "tok-c" },
    { "name": "rig-d", "host": "192.0.2.4" }
] } }
EOF2
cat >"$WUA/bin/curl" <<EOF2
#!/usr/bin/env bash
cat >/dev/null
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
echo "\$url" >>"$WUA/dials.log"
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
http://192.0.2.2:*/status) printf '{"change_id":"chg-9","status":"failed","reason":"build broke"}' >"\$out"; printf '200' ;;
http://192.0.2.3:*/status) printf '{"change_id":"chg-9","status":"noop","reason":"already on v9.9.9"}' >"\$out"; printf '200' ;;
*/status) printf '{"change_id":"chg-9","status":"applied"}' >"\$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF2
printf '#!/usr/bin/env bash\n:\n' >"$WUA/bin/sleep"
chmod +x "$WUA/bin/curl" "$WUA/bin/sleep"
wua_run() { # <uuid> <intent-json> [budget]
    printf '%s\n' "$2" >"$WUA/req.json"
    PATH="$WUA/bin:$PATH" CONTROL_WU_BUDGET="${3:-1}" PITHEAD_CONFIG_FILE="$WUA/config.json" \
        run_sourced_e "$SANDBOX" control_process_request "$WUA/req.json" "$WUA" >/dev/null 2>&1
}
wua1="45454545-4545-4545-9545-454545454545"
wua_run "$wua1" "{\"id\":\"$wua1\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":[\"rig-a\",\"rig-b\",\"ghost\",\"rig-d\",\"rig-c\"]}"
assert_eq "the run settles as completed" "$(jq -r '.status' "$WUA/results/$wua1.json")" "completed"
assert_eq "each rig lands in request order with its own settled outcome" \
    "$(jq -r '[.rigs[] | .name + ":" + .status] | join(",")' "$WUA/results/$wua1.json")" \
    "rig-a:applied,rig-b:failed,ghost:rejected,rig-d:rejected,rig-c:noop"
assert_eq "a mid-run failure does not stop the later rigs" \
    "$(jq -r '.counts | [.applied, .failed, .noop, .rejected] | join(",")' "$WUA/results/$wua1.json")" "1,1,1,2"
assert_contains "a rig that cannot take the upgrade carries its reason" \
    "$(jq -r '.rigs[3].reason' "$WUA/results/$wua1.json")" "no token"
assert_contains "a failed rig carries the rig's reason" \
    "$(jq -r '.rigs[1].reason' "$WUA/results/$wua1.json")" "build broke"
assert_eq "the rigs are dialed strictly one after another" \
    "$(grep '/upgrade$' "$WUA/dials.log" | sed -E 's#http://([0-9.]+):.*#\1#' | tr '\n' ' ')" "192.0.2.1 192.0.2.2 192.0.2.3 "
assert_eq "no per-rig result files are left behind" "$(find "$WUA/results" -type f | wc -l | tr -d ' ')" "1"
assert_contains "the run is audited as completed" "$(cat "$WUA/audit/control.log")" '"action":"worker-upgrade-all","status":"completed"'
assert_contains "each rig upgrade is audited too" "$(cat "$WUA/audit/control.log")" '"action":"worker-upgrade","status":"applied"'
if grep -q 'tok-' "$WUA/audit/control.log" "$WUA"/results/*.json 2>/dev/null; then
    bad "worker-upgrade-all never leaks a token to results/audit" "token found"
else
    ok "worker-upgrade-all never leaks a token to results/audit"
fi
wua2="56565656-5656-4565-9565-565656565656"
wua_run "$wua2" "{\"id\":\"$wua2\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":[\"rig-a\"]}" 0
assert_contains "a run over the per-drain budget is rejected" "$(jq -r '.error' "$WUA/results/$wua2.json")" "already in this cycle"
wua3="67676767-6767-4676-9676-676767676767"
wua_run "$wua3" "{\"id\":\"$wua3\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"9.9.9\",\"workers\":[\"rig-a\"]}"
assert_contains "a malformed version is rejected" "$(jq -r '.error' "$WUA/results/$wua3.json")" "version"
wua4="78787878-7878-4787-9787-787878787878"
wua_run "$wua4" "{\"id\":\"$wua4\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":[\"rig-a\",\"rig-a\"]}"
assert_contains "duplicate rig names are rejected" "$(jq -r '.error' "$WUA/results/$wua4.json")" "distinct rig names"
wua6="9a9a9a9a-9a9a-4a9a-9a9a-9a9a9a9a9a9a"
wua_run "$wua6" "{\"id\":\"$wua6\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":[\"rig-a\"]}"
assert_contains "a second run inside the cooldown is rejected" "$(jq -r '.error' "$WUA/results/$wua6.json")" "less than 5 minutes ago"
assert_eq "and the rejection names its action so the dashboard can show it" "$(jq -r '.action' "$WUA/results/$wua6.json")" "worker-upgrade-all"
wua7="abababab-abab-4bab-9bab-abababababab"
wua_run "$wua7" "{\"id\":\"$wua7\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":[\"bad name\"]}"
assert_contains "a rig name outside the printable charset is rejected" "$(jq -r '.error' "$WUA/results/$wua7.json")" "distinct rig names"
rm -f "$WUA/staged/.worker-upgrade-all-stamp"
jq -n '{workers: {list: [range(0;22) | {name: ("big-" + tostring), host: "192.0.2.50", control_port: 8082, token: "tok-big"}]}}' >"$WUA/config.json"
: >"$WUA/dials.log"
wua5="89898989-8989-4898-9898-898989898989"
wua_names=$(jq -nc '[range(0;22) | "big-" + tostring]')
wua_run "$wua5" "{\"id\":\"$wua5\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":$wua_names}"
assert_eq "a run past the per-run limit upgrades 20 rigs and reports the rest as not started" \
    "$(jq -r '[.counts.applied, .counts.not_started] | join(",")' "$WUA/results/$wua5.json")" "20,2"
assert_eq "the runner dials no rig past the per-run limit" "$(grep -c '/upgrade$' "$WUA/dials.log")" "20"
rm -f "$WUA/staged/.worker-upgrade-all-stamp"
cat >"$WUA/bin/curl" <<EOF2
#!/usr/bin/env bash
cat >/dev/null
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
    esac
done
printf 'not json' >"\$out"
printf '202'
EOF2
wua8="bcbcbcbc-bcbc-4cbc-9cbc-bcbcbcbcbcbc"
(export CONTROL_WU_POLL_CAP=1 && wua_run "$wua8" "{\"id\":\"$wua8\",\"action\":\"worker-upgrade-all\",\"actor\":\"admin\",\"version\":\"v9.9.9\",\"workers\":[\"big-0\",\"big-1\"]}")
assert_eq "a rig answering 202 with a non-JSON body does not abort the run" \
    "$(jq -r '.status + ":" + (.rigs | length | tostring)' "$WUA/results/$wua8.json")" "completed:2"
