# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

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
cat >"$AW/bin/_restart-ok" <<'STUB'
#!/bin/bash
echo restart >>"$AW_RESTARTS"
if (exec 7>>"$AW/lock" && flock -n 7) 2>/dev/null; then echo free >>"$AW/lock-seen"; else echo held >>"$AW/lock-seen"; fi
STUB
cat >"$AW/bin/_restart-fail" <<'STUB'
#!/bin/bash
echo restart >>"$AW_RESTARTS"
exit 1
STUB
cat >"$AW/bin/_render-mints" <<'STUB'
#!/bin/bash
echo render >>"$AW_LOG"
cp "$AW_ADDRS" data/tls/wizard.crt
cp "$AW_ADDRS" Caddyfile
STUB
cat >"$AW/bin/_render-quiet" <<'STUB'
#!/bin/bash
echo render >>"$AW_LOG"
STUB
cat >"$AW/bin/_render-fail-mints" <<'STUB'
#!/bin/bash
echo render >>"$AW_LOG"
echo minted >data/tls/wizard.crt
exit 1
STUB
chmod +x "$AW/bin/_restart-ok" "$AW/bin/_restart-fail" "$AW/bin/_render-mints" "$AW/bin/_render-quiet" \
    "$AW/bin/_render-fail-mints" "$AW/bin/hostname" "$AW/bin/systemctl"
export AW
_run() {
    local rs
    if [ -f "$AW/run-restart" ]; then rs="$(cat "$AW/run-restart")"; else rs="$AW/bin/_restart-ok"; fi
    printf '%s\n' "$rs" >"$AW/restart-used"
    printf '%s\n' "$1" >"$AW/addrs"
    printf '%s\n' "${2:-active}" >"$AW/boot-state"
    AW_ADDRS="$AW/addrs" AW_BOOT_STATE="$AW/boot-state" AW_LOG="$AW/log" AW_RENDER_FAIL="$AW/render-fail" \
        PATH="$AW/bin:$PATH" PITHEAD_DIR="$AW/dir" PITHEAD_LOCK_FILE="$AW/lock" PITHEAD_ADDRESS_WATCH_STATE="$AW/state" \
        PITHEAD_TLS_DIR=data/tls AW_RESTARTS="$AW/restarts" PITHEAD_CADDY_RESTART_CMD="$rs" \
        bash "$HERE/../../os/overlay/pithead-address-watch" 2>&1
}
_render() {
    cp "$AW/bin/_render-$1" "$AW/dir/pithead"
}
_restart() {
    printf '%s' "$AW/bin/_restart-$1" >"$AW/run-restart"
}
_count() {
    local n
    n=$(grep -c "$1" "$2" 2>/dev/null)
    echo "${n:-0}"
}

_render mints
_run "192.168.1.5" >/dev/null
assert_eq "the first tick records the address set and renders once" "$(_count render "$AW/log")" "1"
assert_eq "…and restarts Caddy onto the files its render moved" "$(_count restart "$AW/restarts")" "1"
_run "192.168.1.5" >/dev/null
assert_eq "an unchanged address set does not render again" "$(_count render "$AW/log")" "1"
out=$(_run "192.168.1.5 fd1c::7")
assert_eq "a ULA arriving later renders again" "$(_count render "$AW/log")" "2"
assert_eq "…and restarts Caddy because the certificate changed" "$(_count restart "$AW/restarts")" "2"
assert_contains "…and says why on the journal" "$out" "addresses changed"
_run "fd1c::7 192.168.1.5" >/dev/null
assert_eq "the same set in a different order is not a change" "$(_count render "$AW/log")" "2"
_render quiet
_run "192.168.1.5 fd1c::7 fd1c::8" >/dev/null
assert_eq "a render that changes nothing does not restart Caddy" "$(_count restart "$AW/restarts")" "2"
_render fail-mints
_restart fail
out=$(
    _run "192.168.1.5 fd1c::9"
    echo "rc=$?"
)
assert_contains "a failed render leaves the unit successful" "$out" "rc=0"
assert_contains "…and names the retry" "$out" "retrying on the next tick"
before=$(_count render "$AW/log")
_x=$(_count restart "$AW/restarts")
assert_eq "…the files the failed render left still got one restart attempt" "$_x" "3"
_run "192.168.1.5 fd1c::9" >/dev/null
assert_eq "…the next tick renders again, the set never having been recorded" "$(_count render "$AW/log")" "$((before + 1))"
assert_eq "…and attempts the restart again from its own marker" "$(_count restart "$AW/restarts")" "$((_x + 1))"
_restart ok
_run "192.168.1.5 fd1c::9" >/dev/null
assert_eq "…the retry lands the moment Caddy can restart" "$(_count restart "$AW/restarts")" "$((_x + 2))"
assert_eq "…and the pending marker clears with it" "$(cat "$AW/state.pending" 2>/dev/null)" ""
# a pithead operation holding the mutation lock: no render, retry
_render mints
before=$(_count render "$AW/log")
out=$(flock -n "$AW/lock" true && (
    exec 8>>"$AW/lock"
    flock 8
    _run "192.168.1.5 fd1c::b"
))
assert_eq "a held mutation lock defers the render" "$(_count render "$AW/log")" "$before"
assert_contains "…and says it will retry" "$out" "retrying on the next tick"
before=$(_count render "$AW/log")
_x=$(_count restart "$AW/restarts")
_run "192.168.1.5 fd1c::b" >/dev/null
assert_eq "the render runs once the lock is free" "$(_count render "$AW/log")" "$((before + 1))"
assert_eq "…and its restart runs while the mutation lock is held" "$(tail -n 1 "$AW/lock-seen")" "held"
assert_eq "…with no lock that was free underneath it" "$(tail -n 1 "$AW/restart-used")" "$AW/bin/_restart-ok"
before=$(_count render "$AW/log")
_run "192.168.1.5 fd1c::a" activating >/dev/null
assert_eq "nothing renders while pithead-boot is still running" "$(_count render "$AW/log")" "$before"
_run "192.168.1.5 fd1c::a" failed >/dev/null
assert_eq "a failed pithead-boot (fallback boot) does not disable the watch" "$(_count render "$AW/log")" "$((before + 1))"
printf 'apply-crt\n' >"$AW/dir/data/tls/wizard.crt"
printf 'apply-caddy\n' >"$AW/dir/Caddyfile"
before=$(_count render "$AW/log")
_x=$(_count restart "$AW/restarts")
out=$(_run "192.168.1.5 fd1c::a")
assert_eq "a files-only change does not make the watch render" "$(_count render "$AW/log")" "$before"
assert_eq "the tick after an apply-owned re-render does not restart a Caddy that already serves the files" \
    "$(_count restart "$AW/restarts")" "$_x"
assert_contains "…and the log names the served files, not the addresses" "$out" "certificate or the Caddyfile changed"
assert_not_contains "…without blaming the addresses" "$out" "addresses changed"
assert_eq "the recorded signature makes the following tick quiet" "$(_run "192.168.1.5 fd1c::a")" ""
_restart fail
_run "192.168.1.5 fd1c::e" >/dev/null
before=$(_count render "$AW/log")
_x=$(_count restart "$AW/restarts")
_restart ok
out=$(_run "192.168.1.5 fd1c::a")
assert_eq "the owed restart is retried without rendering again" "$(_count render "$AW/log")" "$before"
assert_eq "…under the mutation lock" "$(tail -n 1 "$AW/lock-seen")" "held"
assert_eq "…as exactly one restart, the owed one" "$(_count restart "$AW/restarts")" "$((_x + 1))"
assert_contains "…named for the owed restart" "$out" "owed"
assert_eq "the following tick is quiet" "$(_run "192.168.1.5 fd1c::a")" ""
assert_eq "…with no pending marker left behind" "$(cat "$AW/state.pending" 2>/dev/null)" ""
_render quiet
printf 'apply-crt2\n' >"$AW/dir/data/tls/wizard.crt"
printf 'apply-caddy2\n' >"$AW/dir/Caddyfile"
before=$(_count render "$AW/log")
_x=$(_count restart "$AW/restarts")
out=$(_run "192.168.1.5 fd1c::h")
assert_eq "an address change whose files are already current renders once" "$(_count render "$AW/log")" "$((before + 1))"
assert_eq "…and does not restart the Caddy apply already restarted" "$(_count restart "$AW/restarts")" "$_x"
assert_contains "…while the log says the files were already current" "$out" "already current"
assert_not_contains "…without claiming a restart" "$out" "restarting Caddy"
assert_eq "the following tick is quiet" "$(_run "192.168.1.5 fd1c::h")" ""
rm -f "$AW/state" "$AW/state.served" "$AW/state.pending"
before=$(_count render "$AW/log")
_x=$(_count restart "$AW/restarts")
out=$(
    exec 8>>"$AW/lock"
    flock 8
    _run "192.168.1.5 fd1c::i"
)
assert_contains "a busy first tick says it will retry" "$out" "retrying on the next tick"
assert_eq "…renders nothing" "$(_count render "$AW/log")" "$before"
assert_eq "…and leaves no served baseline behind" "$(cat "$AW/state.served" 2>/dev/null)" ""
assert_eq "…and restarts nothing" "$(_count restart "$AW/restarts")" "$_x"
out=$(_run "192.168.1.5 fd1c::i")
assert_eq "the free tick on unchanged files is quiet" "$out" ""
assert_eq "…and restarts nothing, Caddy already serving what the render produced" \
    "$(_count restart "$AW/restarts")" "$_x"
assert_contains "…while recording the address set" "$(cat "$AW/state")" "192.168.1.5"
unset AW _run _render _restart _count out before _x

echo "== unit: address_watch_verdict — the KVM provision leg's discrimination (#2463) =="
# shellcheck source=tests/os/appliance-address-watch-leg.sh
source "$HERE/../os/appliance-address-watch-leg.sh"
AWV_OK='{"checks":[{"status":"ok","message":"The dashboard certificate covers every name Caddy serves."}]}'
AWV_BAD='{"checks":[{"status":"fail","message":"The dashboard certificate does not cover: fd00:2463::1 — x"}]}'
awv() { address_watch_verdict "${1-enabled}" "${2-active}" "${3-$AWV_OK}" "${4-0}" "${5-DNS:x, IP Address:FD00:2463:0:0:0:0:0:1}" "fd00:2463::1" "IP Address:FD00:2463:0:0:0:0:0:1"; }
assert_rc "a re-minted certificate with a green row and an enabled, active timer passes" "$(
    awv >/dev/null
    echo $?
)" 0
assert_rc "a disabled timer fails (image wiring)" "$(
    awv disabled >/dev/null
    echo $?
)" 1
assert_rc "an inactive timer fails" "$(
    awv enabled inactive >/dev/null
    echo $?
)" 1
assert_rc "a still-red doctor row fails" "$(
    awv enabled active "$AWV_BAD" >/dev/null
    echo $?
)" 1
assert_rc "a failed service run fails" "$(
    awv enabled active "$AWV_OK" 1 >/dev/null
    echo $?
)" 1
assert_rc "a certificate without the added address fails" "$(
    awv enabled active "$AWV_OK" 0 "IP:192.168.1.5" >/dev/null
    echo $?
)" 1
unset AWV_OK AWV_BAD awv

echo "== unit: appliance_mint_cert keeps a certificate that already carries an IPv6 address (#2463) =="
# openssl stores and prints an IPv6 SAN expanded and upper-case; the mint compared that string with
# `hostname -I`'s compressed spelling, so any IPv6 in the set re-minted the certificate on EVERY
# render and no render ever satisfied doctor. Mutation run: drop san_canonical_string from the
# comparison -> the second mint replaces the certificate and both rows go red.
AWM="$SANDBOX/address-watch-mint"
rm -rf "$AWM"
mkdir -p "$AWM"
awm_out=$(
    cd "$AWM" || exit 1
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    set +e
    appliance_tls_dir() { printf '%s' "$AWM/tls"; }
    appliance_site_names() { printf '%s' "rig1.local 192.168.1.20 fd00:2463::1 localhost"; }
    log() { echo "LOG: $*"; }
    fp1=$(appliance_mint_cert 2>&1)
    fp2=$(appliance_mint_cert 2>&1)
    echo "same=$([ "$fp1" = "$fp2" ] && echo yes || echo no)"
    appliance_site_names() { printf '%s' "rig1.local 192.168.1.20 fd00:2463::1 fd00:2463::2 localhost"; }
    fp3=$(appliance_mint_cert 2>&1)
    echo "changed=$([ "$fp1" != "$fp3" ] && echo yes || echo no)"
)
assert_contains "a second mint with an IPv6 address keeps the certificate" "$awm_out" "same=yes"
assert_contains "a new IPv6 address still re-mints" "$awm_out" "changed=yes"
unset AWM awm_out

echo "== unit: ipv6_canonical (#2463) =="
# shellcheck disable=SC1090
canon() { (
    source "$STACK" 2>/dev/null
    ipv6_canonical "$1"
); }
assert_eq "ipv6_canonical expands a compressed ULA" "$(canon fd00:2463::1)" "fd00:2463:0:0:0:0:0:1"
assert_eq "ipv6_canonical lower-cases and strips leading zeros as openssl prints" "$(canon FD00:2463:0000:0:0:0:0:0001)" "fd00:2463:0:0:0:0:0:1"
assert_eq "ipv6_canonical handles a leading ::" "$(canon ::1)" "0:0:0:0:0:0:0:1"
assert_eq "ipv6_canonical handles a trailing ::" "$(canon fd00::)" "fd00:0:0:0:0:0:0:0"
assert_eq "ipv6_canonical leaves an IPv4 literal alone" "$(canon 192.168.1.20)" "192.168.1.20"
assert_eq "ipv6_canonical leaves a malformed literal alone" "$(canon fd00:zz::1)" "fd00:zz::1"
assert_eq "ipv6_canonical leaves a double :: alone" "$(canon 1::2::3)" "1::2::3"
assert_eq "ipv6_canonical leaves an over-long group alone" "$(canon fffff::1)" "fffff::1"
assert_eq "ipv6_canonical leaves a stray trailing colon alone" "$(canon fd00::1:)" "fd00::1:"
unset -f canon

echo "== unit: doctor counts an IPv6 SAN as covered whatever its spelling (#2463) =="
# openssl prints the SAN expanded and upper-case, `hostname -I` compressed: one address, covered.
# Mutation run: drop the ipv6_canonical alternative in check_appliance_cert -> the first row goes red.
AWD="$SANDBOX/address-watch-doctor"
rm -rf "$AWD"
mkdir -p "$AWD/tls"
printf '{"dashboard":{"host":"auto"}}' >"$AWD/config.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$AWD/tls/wizard.key" -out "$AWD/tls/wizard.crt" \
    -subj "/CN=rig1.local" -addext "subjectAltName=DNS:rig1.local,IP:192.168.1.20,IP:fd00:2463::1,DNS:localhost" >/dev/null 2>&1
awd_run() { # <hostname -I output>
    (
        cd "$AWD" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$AWD/tls"; }
        appliance_bridge_gateway() { printf '172.19.0.1'; }
        env_get() { [ "$1" = HOST_IP ] && printf '%s' "${AWD_BASE:-rig1.local}"; }
        stub_host_addrs "$AWD_ADDRS" rig1
        check_appliance_cert 2>&1
    )
}
awd_out=$(AWD_ADDRS='192.168.1.20 fd00:2463::1' awd_run)
assert_contains "an IPv6 address the certificate carries counts as covered despite the spelling" "$awd_out" "covers every name"
awd_out=$(AWD_ADDRS='192.168.1.20 fd00:2463::2' awd_run)
assert_contains "a different IPv6 address is still uncovered" "$awd_out" "does not cover: fd00:2463::2"
awd_out=$(AWD_BASE=fd00:2463::1 AWD_ADDRS='fd00:2463::1' awd_run)
assert_contains "a base name pinned to a compressed IPv6 address is covered too" "$awd_out" "covers every name"
unset AWD awd_run awd_out AWD_ADDRS
