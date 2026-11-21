#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
PASS=0
FAIL=0
skips=""
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "${1:-}"
}
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
}
info() { :; }
it_warn() { :; }
it_err() { printf 'ERR: %s\n' "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
it_skip_leg() {
    skips="${skips:+$skips|}$1|$3"
    printf '  ! skipped leg %s (%s)\n' "$1" "$3"
}
_ssh() { cat "$work/ssh-out" 2>/dev/null; }
plain() { sed $'s/\033\\[[0-9;]*m//g'; }
ip=192.168.122.99
SCRIPT_DIR="$HERE"
HOST_SCRATCH="$work/scratch"
# shellcheck source=tests/os/netwatch-window.sh
source "$HERE/netwatch-window.sh" || exit 1

docker() {
    case "${1:-}" in
    info | image) return 0 ;;
    build | rm) return 0 ;;
    esac
    return 1
}

cat >"$work/cli" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cmd="$1"
out="$3"
case "$cmd" in
start)
    mkdir -p "$out"
    printf 'NW_PREFIX=172.28.0\nNW_TOR_IP=172.28.0.25\nNW_BOX_IP=\nNW_VANTAGE_IP=%s\nNW_STARTED=x\n' "$5" >"$out/meta.env"
    printf 'tcp\t192.168.122.99\t140.211.10.1\t443\t4\n' >"$out/flows.tsv"
    ;;
stop)
    if [ "${NW_STUB_STOP:-0}" = 1 ]; then exit 2; fi
    exit 0
    ;;
verify)
    [ "${NW_MODE:-}" = perimeter ] || {
        printf 'stub: verify lost the perimeter vantage\n' >&2
        exit 2
    }
    [ -n "${NW_RESOLVER_IP:-}" ] || {
        printf 'stub: verify lost the resolver\n' >&2
        exit 2
    }
    case "${NW_STUB_VERIFY:-clean}" in
    clean)
        printf 'netwatch: 5 unique flows observed\nnetwatch: every observed flow is permitted by the config.\n'
        ;;
    unexpected)
        printf 'netwatch: 3 unique flows observed\nnetwatch: 1 UNEXPECTED flow(s):\n'
        exit 1
        ;;
    dead)
        printf 'netwatch: NO FLOWS RECORDED — the capture is dead, not the network clean.\n' >&2
        exit 2
        ;;
    esac
    ;;
esac
EOF
NW_CLI="$work/cli"
printf '{}\n' >"$work/ssh-out"

row=$(netwatch_verdict_row "w" 0 "detail")
case "$row" in *✓*non-required*) ok ;; *) bad "the clean verdict row is not a green non-required row: $row" ;; esac
row=$(netwatch_verdict_row "w" 1 "detail")
case "$row" in *✗*non-required*) ok ;; *) bad "the unexpected-flow row is not red: $row" ;; esac
row=$(netwatch_verdict_row "w" 2 "detail")
case "$row" in *✗*DEAD*) ok ;; *) bad "the dead-capture row is not a red DEAD row: $row" ;; esac
[ "$FAIL" = 0 ] && [ "$PASS" = 3 ] && ok "verdict rows never touch the phase counters" ||
    bad "verdict rows changed PASS/FAIL (pass=$PASS fail=$FAIL)"

have() { return 1; }
skips=""
netwatch_window_start "engineless window" >/dev/null 2>&1
[ -z "${NW_WINDOW:-}" ] && ok "a host with no engine records no capture" || bad "a capture started without an engine"
case "$skips" in *"engineless window window|missing"*) ok ;; *) bad "the engineless start did not skip as missing: skips=$skips" ;; esac
out=$(netwatch_window_stop "engineless window" 2>&1)
[ -z "$out" ] && ok "stopping a never-started window records nothing" || bad "stop of an unstarted window emitted: $out"
have() { command -v "$1" >/dev/null 2>&1; }

out=$(netwatch_window_start "first boot (Test)" 2>&1 && netwatch_window_stop "first boot (Test)" 2>&1)
out=$(plain <<<"$out")
case "$out" in *"✓ netwatch first boot (Test): 5 recorded flows"*) ok ;; *) bad "the clean window row is missing: $out" ;; esac
case "$out" in *"NON-REQUIRED"*) bad "the clean row must not read as required" ;; *) ok ;; esac
meta="$HOST_SCRATCH/pithead-netwatch/first-boot-Test-/meta.env"
grep -qx 'NW_BOX_IP=192.168.122.99' "$meta" && ok "stop recorded the live guest address in the capture metadata" ||
    bad "meta.env never learned the guest address: $(tr '\n' ' ' <"$meta" 2>/dev/null)"

export NW_STUB_VERIFY=unexpected
out=$(netwatch_window_start "u" 2>&1 && netwatch_window_stop "u" 2>&1 | plain)
case "$out" in *"✗ netwatch u (non-required leg, #4196): 1 unexpected flow(s) among 3 recorded"*) ok ;; *) bad "the unexpected-flow window row is wrong: $out" ;; esac
export NW_STUB_VERIFY=dead
out=$(netwatch_window_start "d" 2>&1 && netwatch_window_stop "d" 2>&1 | plain)
case "$out" in *"DEAD CAPTURE — no flows at all were recorded"*) ok ;; *) bad "the dead-capture window row is wrong: $out" ;; esac
export NW_STUB_STOP=1
out=$(netwatch_window_start "s" 2>&1 && netwatch_window_stop "s" 2>&1 | plain)
case "$out" in *"DEAD CAPTURE — the recorder was not recording until the window closed"*) ok ;; *) bad "the stopped-recorder row is wrong: $out" ;; esac
unset NW_STUB_VERIFY NW_STUB_STOP
[ "$FAIL" = 0 ] && ok "red netwatch rows never entered the phase counters (fail=$FAIL)" || bad "netwatch rows leaked into FAIL: $FAIL"

printf 'enabled\n' >"$work/ssh-out"
row=$(netwatch_htpdate_row)
case "$row" in *"htpdate unit on the booted image reads enabled"*) ok ;; *) bad "the htpdate row is wrong: $row" ;; esac
printf 'Failed to get unit file state for htpdate.service: No such file or directory\n' >"$work/ssh-out"
row=$(netwatch_htpdate_row)
case "$row" in *"No such file or directory"*) ok ;; *) bad "the htpdate row hides an unreadable unit: $row" ;; esac
printf '{}\n' >"$work/ssh-out"

NW_MINING_MINUTES=0 out=$(netwatch_mining_hour "Test role" 2>&1 | plain)
case "$out" in *"✓ netwatch one hour of mining (Test role): 5 recorded flows"*) ok ;; *) bad "the zero-minute mining-hour row is wrong: $out" ;; esac

printf 'tcp\t10.0.0.5\t8.8.8.8\t443\t2\ntcp\t192.168.122.99\t140.211.10.1\t443\t4\ntcp\t192.168.122.1\t192.168.122.99\t22\t9\nudp\t192.168.122.99\t192.168.122.1\t53\t1\nudp\t192.168.5.9\t1.1.1.1\t53\t7\n' >"$work/flows"
kept=$(netwatch_scope_flows 192.168.122.99 192.168.122.1 <"$work/flows" | grep -c .)
[ "$kept" = 3 ] && ok "the vantage scope keeps only the guest and virbr0 flows" ||
    bad "the vantage scope kept $kept of 5 rows (want the 3 touching the guest subnet)"

_netwatch_meta_set "$work/m" NW_KEY "a b"
[ "$(grep -c '^NW_KEY=' "$work/m")" = 1 ] && grep -qx 'NW_KEY=a b' "$work/m" && ok "meta rewrite replaces in place" ||
    bad "meta rewrite duplicated or mangled the key: $(tr '\n' ';' <"$work/m")"

printf '\nos netwatch-window selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
