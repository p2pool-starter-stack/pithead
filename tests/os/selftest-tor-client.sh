#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
HELPER="$REPO/os/overlay/pithead-tor"

case "$(uname -s)" in
Linux) ;;
*)
    echo "selftest-tor-client: skipped off Linux (flock and runuser)"
    exit 0
    ;;
esac

fail() {
    echo "selftest-tor-client: $*" >&2
    exit 1
}

[ -x "$HELPER" ] || fail "$HELPER is not executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/fake-boot" <<'EOF'
#!/bin/bash
echo "Bootstrapped 5% (connecting)"
echo "Bootstrapped 100% (done): Done"
sleep 60
EOF
cat >"$tmp/fake-never" <<'EOF'
#!/bin/bash
echo "Bootstrapped 5% (connecting)"
echo "Bootstrapped 40% (loading statuses or descriptors)"
for i in 1 2 3 4 5 6 7; do
    echo "Monitored process 4242 is still alive."
    sleep 0.4
done
sleep 60
EOF
cat >"$tmp/fake-dead" <<'EOF'
#!/bin/bash
echo "Socks listen failed"
exit 1
EOF
chmod +x "$tmp/fake-boot" "$tmp/fake-never" "$tmp/fake-dead"

t_env=(
    "PITHEAD_TOR_RUN_DIR=$tmp/run"
    "PITHEAD_TOR_LOCK=$tmp/lock"
    "PITHEAD_TOR_TIMEOUT=2"
)

out="$(env "${t_env[@]}" "$HELPER" 2>&1)"
rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"usage: pithead-tor"* ]] ||
    fail "no-args must print usage and exit 2, got rc=$rc out=$out"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN=no-such-tor-xyz "$HELPER" true 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"no tor binary"* ]] ||
    fail "a missing tor binary must fail loudly, got rc=$rc out=$out"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-boot" PITHEAD_TOR_CLOCK_EPOCH=1000 "$HELPER" true 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"behind the installed OS build"* ]] ||
    fail "a clock behind the OS build must be refused, got rc=$rc out=$out"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-boot" PITHEAD_TOR_CLOCK_EPOCH=4102444801 "$HELPER" true 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"past 2100"* ]] ||
    fail "a clock past 2100 must be refused, got rc=$rc out=$out"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-boot" \
    "$HELPER" sh -c 'case "$ALL_PROXY" in socks5h://127.0.0.1:9253) echo PROXY-SET ;; esac' 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == *"PROXY-SET"* ]] ||
    fail "a bootstrapped run must export the SOCKS proxy and pass rc=0, got rc=$rc out=$out"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-boot" "$HELPER" sh -c 'exit 3' 2>&1)"
rc=$?
[ "$rc" -eq 3 ] || fail "the command's exit code must be propagated, got rc=$rc out=$out"
sleep 0.5
[ -z "$(pgrep -f "$tmp/fake-" 2>/dev/null)" ] ||
    fail "a stopped Tor process survived the helper exiting"
[ -z "$(find "$tmp" -maxdepth 1 -name 'run.*' -print -quit)" ] ||
    fail "the helper left its /run state directory behind"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-never" "$HELPER" true 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"did not complete a circuit"* ]] ||
    fail "a Tor that never bootstraps must time out with a clear error, got rc=$rc out=$out"
[[ "$out" == *"progress: Bootstrapped 40%"* ]] ||
    fail "the timeout must name where bootstrap got stuck, got out=$out"
[[ "$out" != *"Monitored process"* ]] ||
    fail "the timeout tail must not be swamped by the owning-process heartbeat, got out=$out"
sleep 0.5
[ -z "$(pgrep -f "$tmp/fake-never" 2>/dev/null)" ] ||
    fail "the helper left the timed-out Tor process running"

out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-dead" "$HELPER" true 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"did not complete a circuit"* && "$out" == *"Socks listen failed"* ]] ||
    fail "a Tor that dies at once must fail with its log tail, got rc=$rc out=$out"

env "${t_env[@]}" PITHEAD_TOR_TIMEOUT=10 PITHEAD_TOR_BIN="$tmp/fake-never" "$HELPER" true >"$tmp/sig.out" 2>&1 &
sigpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "setsid.*fake-never" >/dev/null 2>&1 && break
    sleep 0.1
done
kill -TERM "$sigpid" 2>/dev/null
rc=0
wait "$sigpid" || rc=$?
[ "$rc" -eq 143 ] ||
    fail "a SIGTERM'd helper must stop Tor and exit 143, got rc=$rc out=$(cat "$tmp/sig.out" 2>/dev/null)"
sleep 0.5
[ -z "$(pgrep -f "$tmp/fake-never" 2>/dev/null)" ] ||
    fail "a SIGTERM'd helper left its Tor process running"
[ -z "$(find "$tmp" -maxdepth 1 -name 'run.*' -print -quit)" ] ||
    fail "a SIGTERM'd helper left its /run state directory behind"

flock "$tmp/lock" sleep 3 &
holder=$!
sleep 0.3
out="$(env "${t_env[@]}" PITHEAD_TOR_BIN="$tmp/fake-boot" "$HELPER" true 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"already running"* ]] ||
    fail "a second caller must be refused while the lock is held, got rc=$rc out=$out"
wait "$holder" 2>/dev/null

grep -q 'systemctl mask systemd-firstboot.service tor.service tor@default.service' "$REPO/os/rootfs/Dockerfile" ||
    fail "the image no longer masks both Debian Tor units"
grep -Eq '^[[:space:]]+tor \\$' "$REPO/os/rootfs/Dockerfile" ||
    fail "the image no longer installs the tor package"
grep -q 'os/overlay/pithead-tor' "$REPO/Makefile" ||
    fail "the helper is missing from the lint-sh enumeration"
grep -q 'headroom_floor_mib' "$REPO/os/build-image.sh" ||
    fail "the image build no longer gates slot headroom"

echo "selftest-tor-client OK"
