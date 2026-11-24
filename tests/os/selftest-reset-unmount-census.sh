#!/usr/bin/env bash
set -uo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/reset-probe.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo 0 >"$work/clock"
mock_date() { case "$*" in '+%s') cat "$work/clock";; *) exit 0;; esac; }
mock_sleep() { echo $(( $(cat "$work/clock") + 2 )) >"$work/clock"; }

run_test() {
    local PROBE_DIR="$1"
    local stop_rc config_present=no
    [ ! -f "$PROBE_DIR/config.json" ] || config_present=yes
    set +e
    "$PROBE_DIR/_docker_mock" compose down --remove-orphans >"$PROBE_DIR/.reset-compose.log" 2>&1
    stop_rc=$?
    if [ "$stop_rc" -ne 0 ] && grep -q 'unmount' "$PROBE_DIR/.reset-compose.log" 2>/dev/null; then
        "$PROBE_DIR/_docker_mock" compose down --remove-orphans >>"$PROBE_DIR/.reset-compose.log" 2>&1
        stop_rc=$?
    fi
    if [ "$stop_rc" = 0 ]; then
        local _cr_end
        _cr_end=$(mock_date +%s)
        _cr_end=$(( _cr_end + 60 ))
        while [ "$(mock_date +%s)" -lt "$_cr_end" ]; do
            _cr_residue=$(_ssh "podman ps --format '{{.ID}}'" 2>/dev/null) && [ -z "$_cr_residue" ] && break
            mock_sleep 2
        done
        if [ -n "${_cr_residue:-}" ]; then
            printf 'compose down residue census after retry: %s\n' "$_cr_residue" >>"$PROBE_DIR/.reset-compose.log" 2>&1
        fi
    fi
    printf 'compose_exit=%s\nconfig_present=%s\n' "$stop_rc" "$config_present" >"$PROBE_DIR/.reset-compose.result"
    return "$stop_rc"
}

echo "TEST 1: unmount error cleared on retry"
mkdir -p "$work/t1"
touch "$work/t1/config.json"
echo 0 >"$work/t1/calls"
cat >"$work/t1/_docker_mock" <<'STUB'
#!/bin/bash
cnt=$(cat "$CNTFILE")
cnt=$(( cnt + 1 ))
echo "$cnt" >"$CNTFILE"
if [ "$cnt" -le "$FIRST_FAIL" ]; then
    printf 'error: unmount failed: device busy\n' >"$LOGFILE"
    exit 1
else
    printf 'compose down succeeded\n' >"$LOGFILE"
    exit 0
fi
STUB
chmod +x "$work/t1/_docker_mock"
export FIRST_FAIL=1
LOGFILE="$work/t1/.reset-compose.log"
export LOGFILE
CNTFILE="$work/t1/calls"
export CNTFILE
_ssh() { :; }
run_test "$work/t1"
if grep -q 'compose_exit=0' "$work/t1/.reset-compose.result" && \
   grep -q 'compose down succeeded' "$work/t1/.reset-compose.log"; then
    echo "  PASS: compose_exit=0 after unmount retry"
else
    echo "  FAIL: compose_exit not 0" >&2
    echo "  result: $(cat "$work/t1/.reset-compose.result")" >&2
    echo "  log: $(cat "$work/t1/.reset-compose.log")" >&2
    exit 1
fi

echo "TEST 2: census wait — residue cleared within 60 s"
mkdir -p "$work/t2"
touch "$work/t2/config.json"
cat >"$work/t2/_docker_mock" <<'STUB'
#!/bin/bash
printf 'compose down succeeded\n' >"$LOGFILE"
exit 0
STUB
chmod +x "$work/t2/_docker_mock"
echo 2 >"$work/t2/calls_left"
LOGFILE="$work/t2/.reset-compose.log"
_ssh() {
    local state
    state=$(cat "$work/t2/ssh_state" 2>/dev/null || echo present)
    case "$state" in
    present)
        local left
        left=$(cat "$work/t2/calls_left")
        left=$(( left - 1 ))
        echo "$left" >"$work/t2/calls_left"
        if [ "$left" -gt 0 ]; then
            echo mock-container-id
        else
            echo clear >"$work/t2/ssh_state"
        fi
        ;;
    esac
    return 0
}
run_test "$work/t2"
if grep -q 'compose_exit=0' "$work/t2/.reset-compose.result"; then
    if ! grep -q 'residue census after retry' "$work/t2/.reset-compose.log"; then
        echo "  PASS: residue cleared in time, no residue logged"
    else
        echo "  FAIL: residue logged when containers cleared" >&2
        exit 1
    fi
else
    echo "  FAIL: compose_exit not 0" >&2
    exit 1
fi

echo "TEST 3: base behavior — unmount error causes failure"
mkdir -p "$work/t3"
touch "$work/t3/config.json"
cat >"$work/t3/_docker_mock" <<'STUB'
#!/bin/bash
printf 'error: unmount failed: device busy\n' >"$LOGFILE"
exit 125
STUB
chmod +x "$work/t3/_docker_mock"
LOGFILE="$work/t3/.reset-compose.log"
_ssh() { echo mock-id; }
run_test "$work/t3" || true
if grep -q 'compose_exit=125' "$work/t3/.reset-compose.result"; then
    echo "  PASS: base goes red on unmount error"
else
    echo "  FAIL: expected compose_exit=125" >&2
    exit 1
fi

printf 'selftest-reset-unmount-census: PASS\n'
