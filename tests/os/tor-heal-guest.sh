#!/usr/bin/env bash
# Guest-only Tor saturation fault. Never run against a shared stack.
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
cp "$data/state" "$work/original-state"
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
    if docker compose stop tor >"$work/restore-stop.log" 2>&1; then
        cp "$work/original-state" "$data/state" || restored=1
    else
        restored=1
    fi
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
# An isolated guest-local webhook proves delivery while Tor egress is disabled.
guest_gateway() {
    local networks network gateway
    networks=$(podman inspect dashboard --format '{{json .NetworkSettings.Networks}}') || return 1
    while IFS= read -r network; do
        gateway=$(podman network inspect "$network" | jq -er '
            [.[] | .subnets[]? | .gateway | select(type == "string" and
                test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))][0] // empty') || continue
        printf '%s\n' "$gateway"
        return 0
    done < <(jq -r 'keys[]' <<<"$networks")
    return 1
}
stage=webhook-gateway
gateway=$(guest_gateway)
[ -n "$gateway" ]
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
saturated() {
    grep -qx 'CircuitBuildAbandonedCount 1000' "$1" &&
        grep -qx 'TotalBuildTimes 1000' "$1" &&
        ! grep -q '^CircuitBuildTimeBin ' "$1"
}
configure() {
    jq --argjson enabled "$1" --arg webhook "http://$gateway:18918/" \
        '.tor.auto_heal=$enabled | .notifications.tor=false | .notifications.webhooks=[$webhook]' config.json >"$work/next-config"
    cp "$work/next-config" config.json
    ./pithead apply -y >"$work/apply.log" 2>&1
}
poison() {
    docker compose stop tor >"$work/stop.log" 2>&1
    awk '!/^CircuitBuild/ && !/^TotalBuildTimes /' "$work/original-state" >"$data/state"
    printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >>"$data/state"
    docker compose start tor >"$work/start.log" 2>&1
    # SETCONF is in-memory only: a recovery stop/start lifts DisableNetwork.
    local reply
    for ((attempt = 0; attempt < 30; attempt++)); do
        reply=$(docker exec tor sh -c '
            cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie)
            printf "AUTHENTICATE %s\r\nSETCONF DisableNetwork=1\r\nQUIT\r\n" "$cookie" |
                nc -w 3 127.0.0.1 9051' 2>/dev/null | tr -d '\r') || reply=""
        if [ "$(printf '%s\n' "$reply" | grep -c '^250 OK$')" = 2 ]; then
            saturated "$data/state"
            return
        fi
        sleep 1
    done
    return 1
}
backup_count() {
    find "$data" -maxdepth 1 -name 'state.backup.*' -type f | wc -l
}
stage=configure-disabled
configure false
before=$(backup_count)
stage=inject-disabled
poison
stage=observe-disabled
deadline=$(($(date +%s) + 90 * 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    saturated "$data/state"
    [ "$(backup_count)" = "$before" ]
    sleep 30
done
echo 'PASS: auto-heal off preserves saturated state throughout the full recovery window (#3118)'
: >"$work/alerts.jsonl"
stage=configure-enabled
configure true
before=$(backup_count)
stage=inject-enabled
poison
started=$(date +%s)
deadline=$((started + 25 * 60))
stage=first-round-alert
diagnosed=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if jq -e 'select(.text | contains("circuit-build-time history is saturated"))' \
        "$work/alerts.jsonl" >/dev/null 2>&1; then
        diagnosed=1
        break
    fi
    sleep 30
done
[ "$diagnosed" = 1 ]
echo 'PASS: first-round saturated alert is delivered within 25 minutes (#3118)'
deadline=$((started + 95 * 60))
stage=host-recovery
applied=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if find "$control/results" -maxdepth 1 -name '*.json' -type f -exec \
        jq -e --argjson started "$started" 'select(.action == "tor-recover" and .status == "applied" and .ts >= $started)' {} \; 2>/dev/null |
        grep 'tor-recover' >/dev/null; then
        applied=1
        break
    fi
    sleep 30
done
[ "$applied" = 1 ]
stage=verify-recovery
[ "$(backup_count)" -gt "$before" ]
stamp=$(cat "$control/tor-recovery-at")
saturated "$data/state.backup.$stamp"
[ -s "$data/state" ] && ! saturated "$data/state"
identities >"$work/after-identities"
cmp "$work/identities" "$work/after-identities"
docker exec tor /usr/local/bin/tor-healthcheck.sh
# Both diagnosis and confirmed-reset notes must be delivered once for this outage.
deadline=$(($(date +%s) + 10 * 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if jq -e 'select(.text | contains("reset saturated circuit history and guards"))' "$work/alerts.jsonl" >/dev/null; then
        break
    fi
    sleep 30
done
jq -s -e '
    [.[] | select(.text | contains("circuit-build-time history is saturated"))] | length == 1' "$work/alerts.jsonl" >/dev/null
jq -s -e '
    [.[] | select(.text | contains("reset saturated circuit history and guards"))] | length == 1' "$work/alerts.jsonl" >/dev/null
echo 'PASS: guest host-gated recovery backs up saturation, clears state, preserves identities and restores Tor health (#3118)'
