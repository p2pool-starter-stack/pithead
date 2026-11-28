#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-recovery-bundle-leg.sh
source "$SCRIPT_DIR/appliance-recovery-bundle-leg.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/date" <<'STUB'
#!/usr/bin/env bash
cat "$WORK/clock"
STUB
cat >"$work/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo $(($(cat "$WORK/clock") + $1)) >"$WORK/clock"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$WORK/systemctl.log"
STUB
cat >"$work/bin/podman" <<'STUB'
#!/usr/bin/env bash
now=$(cat "$WORK/clock")
case "$1" in
stop) echo "$now" >"$WORK/stopped-at" ;;
ps)
    [ ! -f "$WORK/stopped-at" ] || [ "$now" -lt $(($(cat "$WORK/stopped-at") + STOP_TAKES)) ] || exit 0
    case "$*" in *Names*) echo caddy ;; *) echo abc123 ;; esac
    ;;
esac
STUB
chmod +x "$work/bin/"*
export WORK="$work"
run_stop() {
    echo 0 >"$work/clock"
    rm -f "$work/stopped-at" "$work/systemctl.log"
    PATH="$work/bin:$PATH" STOP_TAKES=$1 bash -c "$(recovery_bundle_stop_script)" >"$work/out" 2>&1
}

old_single_check() {
    echo 0 >"$work/clock"
    rm -f "$work/stopped-at"
    PATH="$work/bin:$PATH" STOP_TAKES=6 bash -c 'podman stop -a -t 5; [ -z "$(podman ps -q)" ]'
}
if old_single_check; then
    echo "negative control: the single check passed a 6 s stop" >&2
    exit 1
fi

run_stop 6
grep -Fxq 'stop caddy.service' "$work/systemctl.log"

if run_stop 100; then
    echo "a container that never stops passed" >&2
    exit 1
fi
grep -Fq 'the stack is not down' "$work/out"
[ "$(cat "$work/clock")" -ge 30 ] && [ "$(cat "$work/clock")" -le 34 ]

printf 'selftest-recovery-bundle: PASS (6 s stop waited for, systemd units stopped first, stuck container still fails at the 30 s bound)\n'
