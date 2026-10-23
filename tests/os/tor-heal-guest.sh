#!/usr/bin/env bash
# Guest-only Tor egress fault; the healer must lift it by restarting Tor.
set -Eeuo pipefail
stage=initialization
sink_started=0
trap 'printf "Tor heal guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2' ERR
cd /data/pithead
control=$(sed -n 's/^CONTROL_DIR=//p' .env)
data=$(sed -n 's/^TOR_DATA_DIR=//p' .env)
[ -d "$control" ] && [ -d "$data" ]
export TMPDIR="$control/work"
mkdir -p "$TMPDIR"
work=$(mktemp -d "$TMPDIR/tor-heal.XXXXXX")
cp config.json "$work/config.json"
identities() {
    find "$data" -type f -name hs_ed25519_secret_key -exec sha256sum {} + | sort
}
identities >"$work/identities"
[ -s "$work/identities" ]
restore() {
    local rc=$? restored=0 logfile
    trap - EXIT ERR
    if [ "$sink_started" = 1 ]; then
        systemctl stop pithead-test-tor-alert.service >/dev/null 2>&1 || restored=1
    fi
    cp "$work/config.json" config.json || restored=1
    docker compose stop tor >"$work/restore-stop.log" 2>&1 || restored=1
    docker compose start tor >"$work/restore-start.log" 2>&1 || restored=1
    ./pithead apply -y >"$work/restore.log" 2>&1 || restored=1
    if [ "$rc" != 0 ] || [ "$restored" != 0 ]; then
        for logfile in "$work"/*.log; do
            [ -f "$logfile" ] || continue
            printf 'Guest command log: %s\n' "${logfile##*/}"
            tail -c 4096 "$logfile" || true
        done
    fi
    printf 'Guest restoration exit: %s; original exit: %s\n' "$restored" "$rc"
    if [ "$rc" = 0 ] && [ "$restored" != 0 ]; then rc=1; fi
    exit "$rc"
}
trap restore EXIT
# A loopback sink remains reachable from the host-network dashboard during the fault.
stage=webhook-gateway
gateway=127.0.0.1
cat >"$work/sink.py" <<'PYTHON'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 65536:
            self.send_error(400)
            return
        payload = json.loads(self.rfile.read(length))
        with open(sys.argv[2], "a") as output:
            output.write(json.dumps(payload) + "\n")
        self.send_response(200)
        self.end_headers()
    def log_message(self, *_):
        pass

HTTPServer((sys.argv[1], 18918), Handler).serve_forever()
PYTHON
sink_started=1
systemd-run --unit pithead-test-tor-alert --property Type=exec \
    python3 "$work/sink.py" "$gateway" "$work/alerts.jsonl" >/dev/null
configure() {
    jq --argjson enabled "$1" --arg webhook "http://$gateway:18918/" \
        '.tor.auto_heal=$enabled | .dashboard.auth.password="" | .dashboard.control.enabled=false
        | .notifications.tor=false | .notifications.webhooks=[$webhook]' config.json >"$work/next-config"
    cp "$work/next-config" config.json
    ./pithead apply -y >"$work/apply.log" 2>&1
}
egress() {
    docker exec dashboard python3 -c '
from mining_dashboard.service.health.tor_heal import TorEgressHealer
ok, evidence = TorEgressHealer._probe_egress()
print("EGRESS_UP" if ok else "EGRESS_DOWN")
print(evidence)
' >"$work/egress.log" 2>&1 || return 2
    if grep -qx EGRESS_UP "$work/egress.log"; then return 0; fi
    if grep -qx EGRESS_DOWN "$work/egress.log"; then return 1; fi
    return 2
}
require_egress_down() {
    local rc=0
    egress || rc=$?
    [ "$rc" = 1 ]
}
container_start() {
    local stamp
    stamp=$(docker inspect --format '{{.State.StartedAt}}' "$1") || return 1
    [ -n "$stamp" ] || return 1
    date -d "$stamp" +%s >/dev/null || return 1
    printf '%s\n' "$stamp"
}
disable_network() {
    local reply attempt
    # This unsaved control setting survives NEWNYM and disappears only on a Tor restart.
    for ((attempt = 0; attempt < 30; attempt++)); do
        reply=$(docker exec tor sh -c '
            cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie)
            printf "AUTHENTICATE %s\r\nSETCONF DisableNetwork=1\r\nGETCONF DisableNetwork\r\nQUIT\r\n" "$cookie" |
                nc -w 3 127.0.0.1 9051' 2>/dev/null | tr -d '\r') || reply=""
        if [ "$(printf '%s\n' "$reply" | grep -c '^250 OK$')" = 2 ] &&
            printf '%s\n' "$reply" | grep -qx '250 DisableNetwork=1'; then
            require_egress_down || return 1
            return 0
        fi
        sleep 1
    done
    return 1
}
reset_tor() {
    docker compose stop tor >"$work/reset-stop.log" 2>&1
    docker compose start tor >"$work/reset-start.log" 2>&1
    for ((attempt = 0; attempt < 60; attempt++)); do
        if docker exec tor /usr/local/bin/tor-healthcheck.sh >/dev/null 2>&1 && egress; then return; fi
        sleep 5
    done
    return 1
}
applied_heals() {
    [ -f "$control/audit/control.log" ] || return 0
    jq -c --arg since "$since" 'select(.ts >= $since and .actor == "tor-heal" and .status == "applied")' \
        "$control/audit/control.log"
}
confirmed_newnyms() {
    local id ids
    ids=$(applied_heals | jq -r 'select(.action == "tor-newnym") | .id' | sort -u)
    [ "$(printf '%s\n' "$ids" | grep -c .)" = 2 ] || return 1
    while read -r id; do
        jq -e '.status == "applied" and .action == "tor-newnym"' "$control/results/$id.json" >/dev/null || return 1
    done <<<"$ids"
}
backup_count() {
    find "$data" -maxdepth 1 -name 'state.backup.*' -type f | wc -l
}
stage=configure-disabled
configure false
if ./pithead control-run-pending >"$work/disabled-runner.log" 2>&1; then exit 1; fi
grep -qx 'DASHBOARD_CONTROL_ENABLED=false' .env
before=$(backup_count)
tor_started=$(container_start tor)
monero_started=$(container_start monerod)
egress
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stage=inject-disabled
disable_network
stage=observe-disabled
deadline=$(($(date +%s) + 90 * 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    require_egress_down
    [ "$(container_start tor)" = "$tor_started" ]
    [ "$(container_start monerod)" = "$monero_started" ]
    applied_heals | jq -s -e 'length == 0' >/dev/null
    [ "$(backup_count)" = "$before" ]
    sleep 30
done
echo 'PASS: auto-heal off leaves real egress broken with no healing throughout the recovery window (#3118, #3166)'
: >"$work/alerts.jsonl"
stage=reset-tor
reset_tor
stage=configure-enabled
configure true
stage=verify-heal-only
grep -qx 'DASHBOARD_CONTROL_ENABLED=false' .env
systemctl is-active --quiet pithead-control.path
id=$(python3 -c 'import uuid; print(uuid.uuid4())')
jq -n --arg id "$id" '{id:$id,action:"restart",actor:"tor-heal"}' >"$work/request.json"
cp "$work/request.json" "$control/requests/.$id.tmp"
mv "$control/requests/.$id.tmp" "$control/requests/$id.json"
for ((attempt = 0; attempt < 60; attempt++)); do
    [ ! -f "$control/results/$id.json" ] || break
    sleep 1
done
jq -e '.status == "rejected" and .error == "only Tor healing is enabled"' "$control/results/$id.json" >/dev/null
echo 'PASS: No login keeps general control disabled and rejects unrelated requests (#3166)'
before=$(backup_count)
tor_started=$(container_start tor)
monero_started=$(container_start monerod)
egress
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stage=inject-enabled
disable_network
started=$(date +%s)
deadline=$((started + 95 * 60))
stage=host-recovery
recovered=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if confirmed_newnyms && [ "$(container_start tor)" != "$tor_started" ] &&
        [ "$(container_start monerod)" != "$monero_started" ] && egress &&
        [ "$(docker inspect --format '{{.State.Health.Status}}' monerod)" = healthy ] &&
        docker exec monerod /usr/local/bin/monerod-peers.sh | jq -e '(.outgoing | numbers) > 0' >/dev/null &&
        jq -e 'select(.text | contains("egress recovered following Tor restart;"))' "$work/alerts.jsonl" >/dev/null; then
        recovered=1
        break
    fi
    sleep 30
done
[ "$recovered" = 1 ]
stage=verify-recovery
confirmed_newnyms
applied_heals | jq -s -e '[.[] | select(.action == "tor-recover")] | length == 0' >/dev/null
[ "$(backup_count)" = "$before" ]
identities >"$work/after-identities"
cmp "$work/identities" "$work/after-identities"
docker exec tor /usr/local/bin/tor-healthcheck.sh
jq -s -e '[.[] | select(.text | contains("egress recovered following Tor restart;"))] | length == 1' "$work/alerts.jsonl" >/dev/null
docker logs --since "$since" dashboard >"$work/healer.log" 2>&1
grep -qF 'Restarting Tor; mining connections will drop.' "$work/healer.log"
grep -qF 'Restarting monerod alongside tor' "$work/healer.log"
echo 'PASS: No login host-runner NEWNYM and final healer restart restore real egress and local Monero, preserving onion keys (#3118, #3166)'
