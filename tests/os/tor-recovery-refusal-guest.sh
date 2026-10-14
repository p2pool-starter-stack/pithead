#!/usr/bin/env bash
# Read-only Tor recovery refusal proof inside this job's provisioned guest.
set -euo pipefail
cd /data/pithead
# shellcheck disable=SC1091 # Generated CLI exists only in the provisioned guest.
source ./pithead
umask 077
export TMPDIR="${TMPDIR:-/run}"
work=$(mktemp -d "${TMPDIR:?}/tor-recovery-refusal.XXXXXX")
trap 'rm -rf "$work"' EXIT
state="$(tor_recovery_mount)/state"
if ! sudo test -f "$state" || sudo test -L "$state" || ! sudo test -r "$state"; then
    echo 'FAIL: live Tor state is missing, linked or unreadable (#3262)' >&2
    exit 1
fi
# shellcheck disable=SC2024 # sudo reads Tor-owned state; this shell owns the private output.
if ! sudo cat "$state" >"$work/state-snapshot"; then
    echo 'FAIL: live Tor state could not be read (#3262)' >&2
    exit 1
fi
state_rc=0
awk '
    $0 == "CircuitBuildAbandonedCount 1000" { abandoned=1 }
    $0 == "TotalBuildTimes 1000" { total=1 }
    /^CircuitBuildTimeBin / { bins=1 }
    END { exit !(abandoned && total && !bins) }
' "$work/state-snapshot" || state_rc=$?
case "$state_rc" in
0)
    echo 'FAIL: Tor history is saturated; the healthy-refusal precondition is not established (#3262)' >&2
    exit 1
    ;;
1) ;; # The successfully read snapshot lacks the exact saturated signature.
*)
    echo 'FAIL: Tor history classification failed (#3262)' >&2
    exit 1
    ;;
esac
rc=0
timeout 30 ./pithead tor-recover check >"$work/stdout" 2>"$work/stderr" || rc=$?
if [ "$rc" != 1 ]; then
    printf 'FAIL: healthy Tor recovery check exits %s, expected 1 (#3262)\n' "$rc" >&2
    exit 1
fi
if ! grep -Fxq '[WARNING] Tor recovery refused: circuit history is not saturated.' "$work/stderr"; then
    echo 'FAIL: healthy Tor recovery check lacks the unsaturated-history warning on stderr (#3262)' >&2
    exit 1
fi
for diagnostic in 'aborted unexpectedly' 'bash -x'; do
    scan_rc=0
    grep -Fq "$diagnostic" "$work/stderr" || scan_rc=$?
    if [ "$scan_rc" != 1 ]; then
        echo 'FAIL: healthy Tor recovery stderr has unexpected-abort advice or cannot be read (#3262)' >&2
        exit 1
    fi
done
echo 'PASS: guest healthy Tor recovery check exits 1 with its guard warning and no unexpected-abort advice (#3262)'
