#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rig-pool-kind-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
pass=0
fail=0
ok() {
    pass=$((pass + 1))
    printf 'PASS: %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf 'FAIL: %s\n' "$1"
}

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -out "$work/srv.crt" -keyout "$work/srv.priv" -days 1 -subj /CN=test >/dev/null 2>&1
python3 - "$work" <<'PY' &
import socket, ssl, sys, threading, time

d = sys.argv[1]

def plain():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    open(d + "/plain.port", "w").write(str(srv.getsockname()[1]))
    while True:
        c, _ = srv.accept()
        try:
            c.sendall(b"hello plain\n")
        finally:
            c.close()

def tls():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(d + "/srv.crt", d + "/srv.priv")
    raw = socket.socket()
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw.bind(("127.0.0.1", 0))
    raw.listen(8)
    open(d + "/tls.port", "w").write(str(raw.getsockname()[1]))
    while True:
        try:
            c, _ = ctx.wrap_socket(raw.accept()[0], server_side=True)
        except Exception:
            continue
        try:
            c.close()
        except Exception:
            pass

threading.Thread(target=plain, daemon=True).start()
threading.Thread(target=tls, daemon=True).start()
time.sleep(300)
PY
listeners=$!
for _ in $(seq 50); do
    [ -f "$work/plain.port" ] && [ -f "$work/tls.port" ] && break
    sleep 0.2
done
[ -f "$work/plain.port" ] && [ -f "$work/tls.port" ] || {
    echo "listeners did not start"
    kill "$listeners" 2>/dev/null
    exit 1
}
PLAIN_PORT=$(cat "$work/plain.port")
TLS_PORT=$(cat "$work/tls.port")

consume_case() (
    dir="$1"
    spool="$2"
    cd "$dir"
    source "$ROOT/pithead" >/dev/null 2>&1
    wizard_submission_ready() { return 0; }
    wizard_spool_request() { printf '%s\n' "$1/$2"; }
    wizard_spool_clean() { :; }
    wizard_clear_submission_transaction() { :; }
    firstboot_consume_rig "$spool"
)
run_case() {
    local label="$1" body="$2" expect_rc="$3"
    shift 3
    local dir spool rc
    dir="$work/$label"
    spool="$dir/spool"
    mkdir -p "$dir" "$spool"
    printf '%s' "$body" >"$spool/rig-request.json"
    rc=0
    consume_case "$dir" "$spool" >"$dir/out.log" 2>&1 || rc=$?
    [ "$rc" = "$expect_rc" ] &&
        ok "$label rc $rc" ||
        bad "$label rc: expected $expect_rc got $rc"
}

run_case shape '{"pool":"not-an-address"}' 1
grep -q "host:port" "$work/shape/spool/error.txt" &&
    [ ! -e "$work/shape/rig.json" ] && [ ! -e "$work/shape/spool/rig-warning.txt" ] &&
    ok "shape refusal: error.txt, nothing landed, no warning" ||
    bad "shape refusal contract"

run_case down '{"pool":"127.0.0.1:9","worker":"shed-3"}' 0
[ -f "$work/down/rig.json" ] &&
    grep -q "127.0.0.1:9" "$work/down/spool/rig-warning.txt" &&
    [ ! -e "$work/down/spool/error.txt" ] &&
    [ ! -e "$work/down/spool/rig-request.json" ] &&
    ok "failed plain dial: accepted, rig-warning.txt, no error.txt" ||
    bad "failed plain dial contract"

run_case up "{\"pool\":\"127.0.0.1:$PLAIN_PORT\",\"worker\":\"shed-3\"}" 0
[ ! -e "$work/up/spool/rig-warning.txt" ] &&
    [ "$(jq -r '.worker' "$work/up/rig.json")" = "shed-3" ] &&
    ok "reachable plain pool: no warning" ||
    bad "reachable plain pool contract"

run_case tlsplain "{\"pool\":\"127.0.0.1:$PLAIN_PORT\",\"worker\":\"shed-3\",\"tls\":true}" 0
grep -q "127.0.0.1:$PLAIN_PORT" "$work/tlsplain/spool/rig-warning.txt" &&
    ok "plain answers where TLS was asked: unreachable, accepted with warning" ||
    bad "TLS dial against a plain listener"

run_case tlshost "{\"pool\":\"127.0.0.1:$TLS_PORT\",\"worker\":\"shed-3\",\"tls\":true,\"tls_fingerprint\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"paired\":false}" 0
[ ! -e "$work/tlshost/spool/rig-warning.txt" ] &&
    [ "$(jq -r '.tls' "$work/tlshost/rig.json")" = "true" ] &&
    [ "$(jq -r '.tls_fingerprint' "$work/tlshost/rig.json")" = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ] &&
    [ "$(jq -r '.paired' "$work/tlshost/rig.json")" = "false" ] &&
    ok "TLS answers where TLS was asked: accepted, keys landed verbatim" ||
    bad "TLS dial against a TLS listener"

run_case tlsx '{"pool":"127.0.0.1:9","tls":"yes"}' 1
grep -q "tls must be true or false" "$work/tlsx/spool/error.txt" &&
    ok "tls of the wrong type refused" ||
    bad "tls wrong-type refusal"

run_case pairedx "{\"pool\":\"127.0.0.1:9\",\"paired\":1}" 1
grep -q "paired must be true or false" "$work/pairedx/spool/error.txt" &&
    ok "paired of the wrong type refused" ||
    bad "paired wrong-type refusal"

run_case fpx "{\"pool\":\"127.0.0.1:9\",\"tls\":true,\"tls_fingerprint\":\"abc\"}" 1
grep -q "tls_fingerprint" "$work/fpx/spool/error.txt" &&
    ok "short fingerprint refused" ||
    bad "fingerprint shape refusal"

run_case nopaired "{\"pool\":\"127.0.0.1:$TLS_PORT\",\"worker\":\"shed-3\"}" 0
[ "$(jq -r 'has("paired")' "$work/nopaired/rig.json")" = "false" ] &&
    ok "rig.json without paired omits the key (read-default true)" ||
    bad "paired read-default contract"

run_case oldshape "{\"pool\":\"127.0.0.1:$PLAIN_PORT\",\"worker\":\"shed-3\",\"stratum_password\":\"pw\"}" 0
[ "$(jq -r '.worker' "$work/oldshape/rig.json")" = "shed-3" ] &&
    [ "$(jq -r '.stratum_password' "$work/oldshape/rig.json")" = "pw" ] &&
    [ "$(jq -r 'has("tls") or has("paired") or has("tls_fingerprint")' "$work/oldshape/rig.json")" = "false" ] &&
    ok "an old rig.json submission still lands, with no new keys" ||
    bad "old rig.json submission"

kill "$listeners" 2>/dev/null
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
