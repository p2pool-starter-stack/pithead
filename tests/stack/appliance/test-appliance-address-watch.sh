# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The address watch (#2463): an address that arrives after pithead-boot committed used to leave the
# dashboard certificate and Caddy's bind list stale until the next apply or reboot. The script
# re-renders when `hostname -I` differs from what the last render saw, and restarts Caddy only when
# the certificate or Caddyfile actually changed. Driven with stubbed hostname/systemctl and a fake
# ./pithead whose render "mints" from the current address list. Sourced by tests/stack/run.sh.

echo "== unit: pithead-address-watch — re-render when an address arrives after boot (#2463) =="
AW="$SANDBOX/address-watch"
rm -rf "$AW"
mkdir -p "$AW/bin" "$AW/dir/data/tls"
printf 'HOST_IP=192.168.1.5\n' >"$AW/dir/.env"
printf '{}\n' >"$AW/dir/config.json"
echo seed >"$AW/dir/data/tls/wizard.crt"
echo seed >"$AW/dir/Caddyfile"
cat >"$AW/bin/hostname" <<'STUB'
#!/bin/bash
cat "$AW_ADDRS"
STUB
cat >"$AW/bin/systemctl" <<'STUB'
#!/bin/bash
cat "$AW_BOOT_STATE"
STUB
cat >"$AW/dir/pithead" <<'STUB'
#!/bin/bash
[ "$1" = render ] || exit 2
echo render >>"$AW_LOG"
[ ! -f "$AW_RENDER_FAIL" ] || exit 1
cp "$AW_ADDRS" data/tls/wizard.crt
cp "$AW_ADDRS" Caddyfile
STUB
cat >"$AW/bin/restart-caddy" <<'STUB'
#!/bin/bash
echo restart >>"$AW_RESTARTS"
STUB
chmod +x "$AW/bin/restart-caddy" "$AW/bin/hostname" "$AW/bin/systemctl" "$AW/dir/pithead"
export AW
aw_run() { # <addresses> [boot-state] -> script output; render calls in $AW/log, restarts in $AW/restarts
    printf '%s\n' "$1" >"$AW/addrs"
    printf '%s\n' "${2:-active}" >"$AW/boot-state"
    AW_ADDRS="$AW/addrs" AW_BOOT_STATE="$AW/boot-state" AW_LOG="$AW/log" AW_RENDER_FAIL="$AW/render-fail" \
        PATH="$AW/bin:$PATH" PITHEAD_DIR="$AW/dir" PITHEAD_LOCK_FILE="$AW/lock" PITHEAD_ADDRESS_WATCH_STATE="$AW/state" \
        PITHEAD_TLS_DIR=data/tls AW_RESTARTS="$AW/restarts" PITHEAD_CADDY_RESTART_CMD="$AW/bin/restart-caddy" \
        bash "$HERE/../../os/overlay/pithead-address-watch" 2>&1
}
aw_count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

aw_run "192.168.1.5" >/dev/null
assert_eq "the first tick records the address set and renders once" "$(aw_count render "$AW/log")" "1"
aw_run "192.168.1.5" >/dev/null
assert_eq "an unchanged address set does not render again" "$(aw_count render "$AW/log")" "1"
out=$(aw_run "192.168.1.5 fd1c::7")
assert_eq "a ULA arriving later renders again" "$(aw_count render "$AW/log")" "2"
assert_eq "…and restarts Caddy because the certificate changed" "$(aw_count restart "$AW/restarts")" "2"
assert_contains "…and says why on the journal" "$out" "addresses changed"
aw_run "fd1c::7 192.168.1.5" >/dev/null
assert_eq "the same set in a different order is not a change" "$(aw_count render "$AW/log")" "2"
# render that changes nothing
cat >"$AW/dir/pithead" <<'STUB'
#!/bin/bash
echo render >>"$AW_LOG"
STUB
aw_run "192.168.1.5 fd1c::7 fd1c::8" >/dev/null
assert_eq "a render that changes nothing does not restart Caddy" "$(aw_count restart "$AW/restarts")" "2"
# render that rewrites the files and then fails: Caddy must still be restarted onto them, and the
# retry must not forget it (the address set is unrecorded, the served signature is not)
cat >"$AW/dir/pithead" <<'STUB'
#!/bin/bash
echo render >>"$AW_LOG"
echo minted >data/tls/wizard.crt
exit 1
STUB
out=$(aw_run "192.168.1.5 fd1c::9"; echo "rc=$?")
assert_contains "a failed render leaves the unit successful" "$out" "rc=0"
assert_contains "…and names the retry" "$out" "retrying on the next tick"
assert_eq "…yet Caddy is restarted onto the files it left" "$(aw_count restart "$AW/restarts")" "3"
before=$(aw_count render "$AW/log")
aw_run "192.168.1.5 fd1c::9" >/dev/null
assert_eq "…and the next tick renders again, the set never having been recorded" "$(aw_count render "$AW/log")" "$((before + 1))"
assert_eq "…without restarting Caddy a second time for the same files" "$(aw_count restart "$AW/restarts")" "3"
# a pithead operation holding the mutation lock: no render, retry
cat >"$AW/dir/pithead" <<'STUB'
#!/bin/bash
echo render >>"$AW_LOG"
STUB
before=$(aw_count render "$AW/log")
out=$(flock -n "$AW/lock" true && (exec 8>>"$AW/lock"; flock 8; aw_run "192.168.1.5 fd1c::b"))
assert_eq "a held mutation lock defers the render" "$(aw_count render "$AW/log")" "$before"
assert_contains "…and says it will retry" "$out" "retrying on the next tick"
aw_run "192.168.1.5 fd1c::b" >/dev/null
assert_eq "the render runs once the lock is free" "$(aw_count render "$AW/log")" "$((before + 1))"
before=$(aw_count render "$AW/log")
aw_run "192.168.1.5 fd1c::a" activating >/dev/null
assert_eq "nothing renders while pithead-boot is still running" "$(aw_count render "$AW/log")" "$before"
aw_run "192.168.1.5 fd1c::a" failed >/dev/null
assert_eq "a failed pithead-boot (fallback boot) does not disable the watch" "$(aw_count render "$AW/log")" "$((before + 1))"
unset AW aw_run aw_count out before

echo "== unit: address_watch_verdict — the KVM provision leg's discrimination (#2463) =="
# shellcheck source=tests/os/appliance-address-watch-leg.sh
source "$HERE/../os/appliance-address-watch-leg.sh"
AWV_OK='{"checks":[{"status":"ok","message":"The dashboard certificate covers every name Caddy serves."}]}'
AWV_BAD='{"checks":[{"status":"fail","message":"The dashboard certificate does not cover: fd00:2463::1 — x"}]}'
awv() { address_watch_verdict "${1-enabled}" "${2-active}" "${3-$AWV_OK}" "${4-0}" "${5-DNS:x, IP Address:FD00:2463:0:0:0:0:0:1}" "fd00:2463::1" "IP Address:FD00:2463:0:0:0:0:0:1"; }
assert_rc "a re-minted certificate with a green row and an enabled, active timer passes" "$(awv >/dev/null; echo $?)" 0
assert_rc "a disabled timer fails (image wiring)" "$(awv disabled >/dev/null; echo $?)" 1
assert_rc "an inactive timer fails" "$(awv enabled inactive >/dev/null; echo $?)" 1
assert_rc "a still-red doctor row fails" "$(awv enabled active "$AWV_BAD" >/dev/null; echo $?)" 1
assert_rc "a failed service run fails" "$(awv enabled active "$AWV_OK" 1 >/dev/null; echo $?)" 1
assert_rc "a certificate without the added address fails" "$(awv enabled active "$AWV_OK" 0 "IP:192.168.1.5" >/dev/null; echo $?)" 1
unset AWV_OK AWV_BAD awv
