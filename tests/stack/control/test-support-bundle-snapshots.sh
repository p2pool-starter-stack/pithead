# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SANDBOX:?}"
: "${SB:?is unset: this fragment runs straight after test-control-support-bundle.sh and reuses its stubs}"

SN="$SANDBOX/snap4128"
mkdir -p "$SN/bin" "$SN/tor" "$SN/p2pool/stats/local" "$SN/p2pool/stats/pool" "$SN/p2pool/stats/network" \
    "$SN/caddy" "$SN/dash" "$SN/support/sub" "$SN/state/support-bundles"

SN_COOKIE_HEX="c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(bytes.fromhex(sys.argv[2]))' "$SN/tor/control_auth_cookie" "$SN_COOKIE_HEX"
cat >"$SN/tor/state" <<'STATE'
TorVersion Tor 0.4.8.12
LastWritten 2026-11-15 10:00:00
Guard in=default rsa_id=AAAAAAAAAAAAAAAAAAAA nickname=guardone sampled_on=2026-11-01T00:00:00 confirmed_idx=0
Key SEEDEDSTATEKEY0001 secret
ed25519 SEEDEDED25519SECRET
STATE

cat >"$SN/bin/torfake" <<'PYTOR'
#!/usr/bin/env python3
import socket, sys, time

mode, portfile, cookie = sys.argv[1], sys.argv[2], sys.argv[3]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(4)
open(portfile, "w").write(str(srv.getsockname()[1]))
while True:
    conn, _ = srv.accept()
    if mode == "hang":
        time.sleep(300)
        continue
    fh = conn.makefile("rwb")
    line = fh.readline().decode().strip()
    if line != "AUTHENTICATE " + cookie:
        fh.write(b"515 Authentication failed\r\n")
        fh.flush()
        conn.close()
        continue
    fh.write(b"250 OK\r\n")
    fh.flush()
    while True:
        line = fh.readline().decode().strip()
        if not line or line == "QUIT":
            break
        if line == "GETINFO status/bootstrap-phase":
            fh.write(b'250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done"\r\n250 OK\r\n')
        elif line == "GETINFO entry-guards":
            fh.write(b"250+entry-guards=\r\n$AAAAAAAAAAAAAAAAAAAA~guardone up\r\n.\r\n250 OK\r\n")
        elif line == "GETINFO circuit-status":
            fh.write(b"250+circuit-status=\r\n123 BUILT $AAAA~guardone,$BBBB~mid PURPOSE=HS_CLIENT_REND REND_QUERY=seededrendquery SOCKS_USERNAME=seededsocksuser\r\n.\r\n250 OK\r\n")
        else:
            fh.write(("250-%s=1\r\n250 OK\r\n" % line.split(" ", 1)[1]).encode())
        fh.flush()
    conn.close()
PYTOR
chmod +x "$SN/bin/torfake"

cat >"$SN/bin/curl" <<'PYCURL'
#!/usr/bin/env python3
import os, sys, time

args = sys.argv[1:]
with open(os.environ["SN_CURL_LOG"], "a") as fh:
    fh.write(" ".join(args) + "\n")
mode = os.environ.get("SN_SVC", "ok")
if mode == "hang":
    time.sleep(300)
if mode == "refuse":
    sys.stderr.write("curl: (7) Failed to connect to 127.0.0.1 port 1: Connection refused\n")
    sys.exit(7)
url = args[-1]
if url.endswith("/get_info"):
    sys.stdin.read()
    sys.stdout.write('{"status":"OK","height":3300000,"target_height":3300000,"synchronized":true,"outgoing_connections_count":0,"incoming_connections_count":0,"white_peerlist_size":812,"nettype":"mainnet"}')
    sys.exit(0)


def frame(payload):
    return b"\x00" + len(payload).to_bytes(4, "big") + payload


if url.endswith("GetTipInfo"):
    meta = b"\x08" + bytes([0xB9, 0x60])
    payload = b"\x0a" + bytes([len(meta)]) + meta + b"\x10\x01"
elif url.endswith("GetNetworkStatus"):
    payload = b"\x18\x07"
else:
    sys.exit(22)
sys.stderr.write("HTTP/2 200\ngrpc-status: 0\n")
sys.stdout.buffer.write(frame(payload))
PYCURL
chmod +x "$SN/bin/curl"

cat >"$SN/bin/pithead-stub" <<'STUB'
#!/bin/sh
if [ "$1" = doctor ]; then
    echo '{"version":"t","exit":1,"summary":{"fail":1}}'
    exit 1
fi
STUB
chmod +x "$SN/bin/pithead-stub"
printf '#!/bin/sh\necho "2: eth0 inet 10.77.0.4/24 scope global"\n' >"$SN/bin/ip"
printf '#!/bin/sh\necho "table inet filter { ip saddr 192.168.50.7 accept; ip6 saddr fd00:aa::1 drop; tcp dport 22 accept }"\n' >"$SN/bin/nft"
printf '#!/bin/sh\necho "State: routable"\n' >"$SN/bin/networkctl"
printf '#!/bin/sh\necho "Current DNS Server: 9.9.9.9"\n' >"$SN/bin/resolvectl"
printf '#!/bin/sh\necho "System clock synchronized: yes"\n' >"$SN/bin/timedatectl"
printf '#!/bin/sh\necho "TIME  UID  PID  SIG COREFILE EXE"\n' >"$SN/bin/coredumpctl"
printf '#!/bin/sh\ncase "$*" in\n*images*) echo "localhost/monerod latest sha256:deadbeefdeadbeefdeadbeefdeadbeef" ;;\n*) echo "monerod state=exited status=Exited(137) exit_code=137 image=localhost/monerod:1 image_id=cafe" ;;\nesac\n' >"$SN/bin/podman"
printf '#!/bin/sh\ncase "$*" in\n*detailed*) echo "slot A: booted, boot status: good" ;;\n*) echo "Compatible: pithead" ;;\nesac\n' >"$SN/bin/rauc"
cat >"$SN/bin/systemctl" <<'SYSCTL'
#!/usr/bin/env bash
case "$*" in
*list-unit-files*)
    printf 'pithead-zzdummy.service enabled enabled\n'
    ;;
*show*)
    printf 'Id=systemd-timesyncd.service\nActiveState=active\nSubState=running\n'
    ;;
esac
exit 0
SYSCTL
chmod +x "$SN"/bin/*

NOW=$(date +%s)
python3 -I - "$SN" "$NOW" <<'PYSEED'
import gzip, json, os, sqlite3, sys, time

sn, now = sys.argv[1], int(sys.argv[2])
H = 3600


def line(age, uri="/", cookie="session=SEEDEDCOOKIE", status=200):
    return json.dumps({
        "ts": now - age, "status": status,
        "request": {"remote_ip": "10.0.0.9", "method": "GET", "uri": uri,
                    "headers": {"Cookie": [cookie], "Authorization": ["Basic SEEDEDAUTHBASIC"], "User-Agent": ["probe"]}},
        "resp_headers": {"Set-Cookie": ["sid=SEEDEDSETCOOKIE"], "Content-Type": ["text/html"]},
    }) + "\n"


with open(sn + "/caddy/access.log", "w") as fh:
    fh.write(line(H, "/api/x?token=SEEDEDURLTOKEN&page=2", status=401))
    fh.write(line(100 * H, "/too-old"))
    fh.write(line(H, "/hook/SEEDEDPATHTOKENSEEDEDPATHTOKEN?SEEDEDBARETOKEN"))
with open(sn + "/caddy/access-2026-11-10T00-00-00.000.log", "w") as fh:
    fh.write(line(5 * H, "/rotated-plain"))
with gzip.open(sn + "/caddy/access-2026-11-09T00-00-00.000.log.gz", "wt") as fh:
    fh.write(line(6 * H, "/rotated-gzip"))
for name in ("access-2026-11-10T00-00-00.000.log", "access-2026-11-09T00-00-00.000.log.gz"):
    os.utime(sn + "/caddy/" + name, (now - 4 * H, now - 4 * H))

db = sqlite3.connect(sn + "/dash/mining_data.db")
db.execute("CREATE TABLE history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL)")
db.execute("CREATE TABLE events (ts REAL, type TEXT, detail TEXT)")
db.execute("CREATE TABLE ping_failures (ts REAL, reason TEXT, detail TEXT)")
db.execute("CREATE TABLE audit_events (id TEXT PRIMARY KEY, ts TEXT, source TEXT, actor TEXT, action TEXT, status TEXT, keys TEXT)")
db.executemany("INSERT INTO history VALUES (?,?,?,?,?)", [("x", 1.0, 2.0, 3.0, now - 3 * H + i * 0.01) for i in range(6000)])
db.execute("INSERT INTO history VALUES ('old', 9, 9, 9, ?)", (now - 200 * H,))
db.execute("INSERT INTO events VALUES (?, 'node_down', 'monerod down')", (now - 2 * H,))
db.execute("INSERT INTO ping_failures VALUES (?, 'timeout', 'rig-a')", (now - 2 * H,))
db.execute("INSERT INTO audit_events VALUES ('a1', ?, 'control', 'admin', 'support-bundle', 'applied', 'hours')",
           (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 2 * H)),))
db.commit()
PYSEED

printf '{"pool_statistics":{"sidechainHeight":777}}' >"$SN/p2pool/stats/pool/stats"
printf '{"height":3300000}' >"$SN/p2pool/stats/network/stats"
printf '{"connections":9}' >"$SN/p2pool/stats/local/p2p"
printf '{"connections":3}' >"$SN/p2pool/stats/local/stratum"
printf 'console capture\nmonerod --rpc-login opuser:SEEDEDSUPPASS --wallet %s\nonion %s\n' "$SB_ADDR" "$SB_ONION" >"$SN/support/console-1.txt"
printf 'nested capture marker-support-sub\n' >"$SN/support/sub/console-2.txt"
printf 'ready' >"$SN/state/.initialized"
printf 'SEEDEDMARKERSECRET' >"$SN/state/wallet-secret"
printf 'must not be listed' >"$SN/state/support-bundles/old.zip"
sn_env="$SN/env"
printf 'COMPOSE_PROFILES=local_node,local_tari\nNETWORK_PREFIX=\nMONERO_RPC_URL=http://127.0.0.1:18081\nMONERO_NODE_USERNAME=rpcuser\nMONERO_NODE_PASSWORD=SEEDEDRPCPASS\nTARI_GRPC_ADDRESS=127.0.0.1:18142\nP2POOL_DATA_DIR=%s\nTOR_DATA_DIR=%s\nCADDY_LOG_DIR=%s\nDASHBOARD_DATA_DIR=%s\n' \
    "$SN/p2pool" "$SN/tor" "$SN/caddy" "$SN/dash" >"$sn_env"

sn_run() { # <id> <svc mode: fine|hang|refuse> [extra VAR=val ...]
    local id="$1" svc="$2"
    shift 2
    rm -f "$SB/staged/.support-bundle-stamp" "$SN/port"
    (
        export PATH="$SN/bin:$SB/bin:$PATH" PITHEAD_ENV_FILE="$sn_env" PITHEAD_ENGINE=podman PITHEAD_SELF="$SN/bin/pithead-stub" \
            SN_CURL_LOG="$SN/curl.log" SN_SVC="$svc" PITHEAD_SUPPORT_DIR="$SN/support" PITHEAD_STATE_ROOT="$SN/state"
        local kv
        for kv in "$@"; do export "${kv?}"; done
        run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$id" support-bundle)" "$SB"
    ) >/dev/null 2>&1
}
sn_tor() { # <mode>
    python3 -I "$SN/bin/torfake" "$1" "$SN/port" "$SN_COOKIE_HEX" &
    SN_TOR_PID=$!
    local i=0
    while [ ! -s "$SN/port" ] && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

echo "== support bundle snapshots: every source is collected and present (#4128) =="
rm -f "$SN/curl.log"
sn_tor fine
snid1="c412c412-0000-4000-8000-000000000001"
sn_run "$snid1" fine "PITHEAD_SUPPORT_TOR_CONTROL=127.0.0.1:$(cat "$SN/port")"
kill "$SN_TOR_PID" 2>/dev/null || true
assert_eq "the snapshot bundle applies" "$(jq -r .status "$SB/results/$snid1.json")" "applied"
sb_unzip "$SB/results/$snid1.zip" "$SN/x1"
B="$SN/x1/bundle"
sn_bad=""
for f in doctor.json status/monerod.json status/tari.json status/p2pool.json tor/control.txt tor/state-guards.txt \
    network/networkctl.txt network/ip-addr.txt network/ip-route.txt network/resolvectl.txt network/nft-ruleset.txt \
    time/timedatectl.txt time/sync-units.txt containers/ps-a.txt containers/images.txt rauc.txt rauc-detailed.txt \
    boot-slot.txt coredumps.txt caddy/access.log support-dir/console-1.txt support-dir/sub/console-2.txt \
    state-markers.txt dashboard-history.jsonl; do
    [ -s "$B/$f" ] || sn_bad="$sn_bad $f"
done
assert_eq "every snapshot file is present and non-empty" "$sn_bad" ""
assert_eq "a clean snapshot collection records no failed step, doctor's own nonzero verdict included" \
    "$(sb_man "$SN/x1" '.failures | length')" "0"
assert_eq "doctor.json holds the doctor document" "$(jq -r .summary.fail "$B/doctor.json")" "1"
assert_eq "the manifest states the per-step and total limits" \
    "$(sb_man "$SN/x1" '.limits | (.snapshot_step_seconds > 0) and (.total_seconds > 0) and (.journal_step_seconds > 0)')" "true"

echo "== support bundle snapshots: monerod, Tari and P2Pool report height, peers and the sync flag =="
assert_eq "monerod height" "$(jq -r .height "$B/status/monerod.json")" "3300000"
assert_eq "monerod sync flag" "$(jq -r .synchronized "$B/status/monerod.json")" "true"
assert_eq "monerod peer count field is present" "$(jq -r '.peers | has("outgoing")' "$B/status/monerod.json")" "true"
assert_eq "Tari height" "$(jq -r .height "$B/status/tari.json")" "12345"
assert_eq "Tari peer count" "$(jq -r .peers "$B/status/tari.json")" "7"
assert_eq "Tari sync flag" "$(jq -r .synced "$B/status/tari.json")" "true"
assert_eq "P2Pool sidechain height" "$(jq -r .sidechain_height "$B/status/p2pool.json")" "777"
assert_eq "P2Pool peer count" "$(jq -r .peers "$B/status/p2pool.json")" "9"
assert_eq "P2Pool sync flag" "$(jq -r .synced "$B/status/p2pool.json")" "true"
assert_not_contains "the monerod login never reached a command line" "$(cat "$SN/curl.log")" "SEEDEDRPCPASS"

echo "== support bundle snapshots: Tor control state and the guard section, never a key =="
assert_contains "Tor bootstrap phase" "$(cat "$B/tor/control.txt")" "PROGRESS=100"
assert_contains "Tor entry guards" "$(cat "$B/tor/control.txt")" "guardone"
assert_contains "Tor circuit state" "$(cat "$B/tor/control.txt")" "BUILT"
assert_contains "the state file's guard line is kept" "$(cat "$B/tor/state-guards.txt")" "nickname=guardone"
assert_not_contains "a seeded key in the Tor state file is excluded" "$(cat "$B/tor/state-guards.txt")" "SEEDEDSTATEKEY"

echo "== support bundle snapshots: network, container, boot and marker files =="
assert_not_contains "the nft ruleset has no IPv4 address" "$(cat "$B/network/nft-ruleset.txt")" "192.168.50.7"
assert_not_contains "the nft ruleset has no IPv6 address" "$(cat "$B/network/nft-ruleset.txt")" "fd00:aa::1"
assert_contains "the nft ruleset is still readable" "$(cat "$B/network/nft-ruleset.txt")" "[redacted-ip]"
assert_contains "podman ps -a carries the exit code" "$(cat "$B/containers/ps-a.txt")" "exit_code=137"
assert_contains "the image list carries the digest" "$(cat "$B/containers/images.txt")" "sha256:deadbeef"
assert_contains "rauc status --detailed is included" "$(cat "$B/rauc-detailed.txt")" "boot status: good"
assert_contains "the marker listing names a state marker" "$(cat "$B/state-markers.txt")" ".initialized"
assert_contains "a small marker's content is included" "$(cat "$B/state-markers.txt")" "content: ready"
assert_not_contains "a secret-named marker's content is not read" "$(cat "$B/state-markers.txt")" "SEEDEDMARKERSECRET"
assert_not_contains "the support-bundles directory is not listed" "$(cat "$B/state-markers.txt")" "old.zip"

echo "== support bundle snapshots: Caddy logs cover the window, rotations included, secrets removed =="
assert_contains "the current log's line is present" "$(cat "$B/caddy/access.log")" "/api/x"
assert_contains "a rotated plain generation is present" "$(cat "$B/caddy/access.log")" "/rotated-plain"
assert_contains "a rotated gzip generation is present" "$(cat "$B/caddy/access.log")" "/rotated-gzip"
assert_not_contains "a line before the window is absent" "$(cat "$B/caddy/access.log")" "/too-old"
assert_not_contains "a bare query token is removed" "$(cat "$B/caddy/access.log")" "SEEDEDBARETOKEN"
assert_not_contains "a path-segment token is removed" "$(cat "$B/caddy/access.log")" "SEEDEDPATHTOKENSEEDEDPATHTOKEN"
assert_contains "the failed login status stays" "$(cat "$B/caddy/access.log")" '"status": 401'

echo "== support bundle snapshots: the support directory is included whole and redacted =="
assert_contains "a nested console capture is included" "$(cat "$B/support-dir/sub/console-2.txt")" "marker-support-sub"
assert_contains "the console capture went through the redactor" "$(cat "$B/support-dir/console-1.txt")" "[redacted]"

echo "== support bundle snapshots: the dashboard export has no row cap and covers every table =="
assert_eq "all 6000 history rows in the window are exported" \
    "$(jq -r 'select(.table == "history" and .row.t == "x") | 1' "$B/dashboard-history.jsonl" | wc -l | tr -d ' ')" "6000"
assert_not_contains "a history row outside the window is absent" "$(cat "$B/dashboard-history.jsonl")" '"t": "old"'
assert_contains "ping_failures are exported" "$(cat "$B/dashboard-history.jsonl")" '"table": "ping_failures"'
assert_contains "the control audit events are exported" "$(cat "$B/dashboard-history.jsonl")" '"action": "support-bundle"'
assert_contains "a table the database lacks is a recorded row, not silence" "$(cat "$B/dashboard-history.jsonl")" '"table": "share_stats"'

echo "== support bundle snapshots: no seeded secret reaches any new file =="
sn_bad=""
for secret in SEEDEDCOOKIE SEEDEDAUTHBASIC SEEDEDSETCOOKIE SEEDEDURLTOKEN SEEDEDBARETOKEN SEEDEDPATHTOKENSEEDEDPATHTOKEN SEEDEDSTATEKEY SEEDEDED25519SECRET \
    "$SN_COOKIE_HEX" seededrendquery seededsocksuser SEEDEDSUPPASS SEEDEDMARKERSECRET SEEDEDRPCPASS "$SB_ADDR" "$SB_ONION"; do
    grep -rqF -- "$secret" "$SN/x1" && sn_bad="$sn_bad leaked:${secret:0:6}"
done
assert_eq "no seeded secret is in any file of the whole zip" "$sn_bad" ""
assert_contains "the query is replaced, not dropped silently" "$(cat "$B/caddy/access.log")" "?[redacted]"

echo "== support bundle snapshots: a missing DB is a manifest entry, not silence =="
snid2="c412c412-0000-4000-8000-000000000002"
grep -v '^DASHBOARD_DATA_DIR=' "$sn_env" >"$SN/env2"
sn_run "$snid2" fine "PITHEAD_ENV_FILE=$SN/env2" "PITHEAD_SUPPORT_TOR_CONTROL=127.0.0.1:1" "PITHEAD_SUPPORT_DIR=$SN/nodir"
sb_unzip "$SB/results/$snid2.zip" "$SN/x2"
assert_eq "the absent database is a skipped step in the manifest" \
    "$(sb_man "$SN/x2" '[.failures[] | select(.step == "dashboard-history.jsonl") | .status] | first')" "skipped"
assert_contains "the file says why" "$(cat "$SN/x2/bundle/dashboard-history.jsonl")" "no dashboard database"
assert_eq "an absent support directory is a skipped step in the manifest" \
    "$(sb_man "$SN/x2" '[.failures[] | select(.step == "support-dir/README.txt") | .status] | first')" "skipped"

echo "== support bundle snapshots: each wedged service times out, the bundle completes and the manifest says so =="
sn_tor hang
rm -f "$SN/p2pool/stats/local/p2p"
mkfifo "$SN/p2pool/stats/local/p2p"
snid3="c412c412-0000-4000-8000-000000000003"
t0=$(date +%s)
sn_run "$snid3" hang "PITHEAD_SUPPORT_TOR_CONTROL=127.0.0.1:$(cat "$SN/port")" PITHEAD_SUPPORT_SNAP_TIMEOUT=2 PITHEAD_SUPPORT_TOTAL_TIMEOUT=120
t1=$(date +%s)
kill "$SN_TOR_PID" 2>/dev/null || true
assert_eq "a bundle with four wedged services still applies" "$(jq -r .status "$SB/results/$snid3.json")" "applied"
assert_eq "the run finished inside the stated total limit" "$([ $((t1 - t0)) -lt 120 ] && echo yes || echo no)" "yes"
sb_unzip "$SB/results/$snid3.zip" "$SN/x3"
sn_bad=""
for step in status/monerod.json status/tari.json status/p2pool.json tor/control.txt; do
    [ "$(sb_man "$SN/x3" "[.failures[] | select(.step == \"$step\") | .status] | first")" = timeout ] || sn_bad="$sn_bad notimeout:$step"
    [ "$(sb_man "$SN/x3" "[.failures[] | select(.step == \"$step\") | .elapsed_seconds >= 2] | first")" = true ] || sn_bad="$sn_bad noelapsed:$step"
    [ "$(grep -c 'unavailable' "$SN/x3/bundle/$step" || true)" = 1 ] || sn_bad="$sn_bad nofile:$step"
done
assert_eq "the wedged monerod, Tari, P2Pool and Tor steps are timed out with elapsed time and an unavailable file" "$sn_bad" ""
assert_eq "an unavailable file is marked unavailable in the manifest" \
    "$(sb_man "$SN/x3" '[.files[] | select(.path == "status/tari.json") | .state] | first')" "unavailable"
assert_contains "the journal still collected beside the wedged services" \
    "$(cat "$SN/x3/bundle/journal/all.log")" "monerod: marker-50h"
rm -f "$SN/p2pool/stats/local/p2p"
printf '{"connections":9}' >"$SN/p2pool/stats/local/p2p"

echo "== support bundle snapshots: each refused service is a recorded failure with its reason =="
snid4="c412c412-0000-4000-8000-000000000004"
sed "s#^P2POOL_DATA_DIR=.*#P2POOL_DATA_DIR=$SN/nope#" "$sn_env" >"$SN/env3"
sn_run "$snid4" refuse "PITHEAD_ENV_FILE=$SN/env3" "PITHEAD_SUPPORT_TOR_CONTROL=127.0.0.1:1"
sb_unzip "$SB/results/$snid4.zip" "$SN/x4"
assert_eq "a bundle with four refusing services still applies" "$(jq -r .status "$SB/results/$snid4.json")" "applied"
sn_bad=""
for step in status/monerod.json status/tari.json tor/control.txt; do
    [ "$(sb_man "$SN/x4" "[.failures[] | select(.step == \"$step\") | .status] | first")" = failed ] || sn_bad="$sn_bad $step"
done
assert_eq "the refused monerod, Tari and Tor steps are recorded as failed" "$sn_bad" ""
assert_contains "the monerod failure carries the reason" \
    "$(sb_man "$SN/x4" '[.failures[] | select(.step == "status/monerod.json") | .reason] | first')" "did not answer"
assert_eq "P2Pool with no readable data-api file is recorded as failed" \
    "$(sb_man "$SN/x4" '[.failures[] | select(.step == "status/p2pool.json") | .status] | first')" "failed"
assert_eq "the refused monerod file says it is unreachable" "$(jq -r .reachable "$SN/x4/bundle/status/monerod.json")" "false"

echo "== support bundle snapshots: a total limit that runs out skips steps and still produces the bundle =="
snid5="c412c412-0000-4000-8000-000000000005"
sn_run "$snid5" hang PITHEAD_SUPPORT_TOTAL_TIMEOUT=1 "PITHEAD_SUPPORT_TOR_CONTROL=127.0.0.1:1"
assert_eq "a bundle past its total limit still applies" "$(jq -r .status "$SB/results/$snid5.json")" "applied"
sb_unzip "$SB/results/$snid5.zip" "$SN/x5"
assert_eq "the manifest records the steps the limit skipped" \
    "$(sb_man "$SN/x5" '[.failures[] | select(.status == "skipped")] | length > 0')" "true"
assert_eq "the skip names the limit" \
    "$(sb_man "$SN/x5" '[.failures[] | select(.status == "skipped") | .reason | contains("total time limit")] | all')" "true"
assert_eq "the manifest states the total limit it applied" "$(sb_man "$SN/x5" '.limits.total_seconds')" "1"
