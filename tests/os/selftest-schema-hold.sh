#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

mkdir -p "$T/bin" "$T/dash" "$T/run"
cat >"$T/bin/rauc" <<'EOF'
#!/usr/bin/env bash
if [ -n "${RAUC_STATUS_RC:-}" ]; then
    exit "$RAUC_STATUS_RC"
fi
cat "$RAUC_STATUS_FILE"
EOF
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
exit "${DOCKER_RC:-0}"
EOF
chmod +x "$T/bin/rauc" "$T/bin/docker"
export PATH="$T/bin:$PATH"

cd "$T/run" || exit 1
printf 'DASHBOARD_DATA_DIR=%s\n' "$T/dash" >.env
printf 'rootwait rauc.slot=A\n' >"$T/cmdline"
export PITHEAD_CMDLINE="$T/cmdline"

# shellcheck source=os/overlay/pithead-boot
source "$HERE/../../os/overlay/pithead-boot" || fail "pithead-boot must source"

printf '%s' '{"slots":{"rootfs":{"A":{"state":"booted","bootname":"A","boot_status":"good"},"B":{"state":"inactive","bootname":"other","boot_status":"good"}}}}' >"$T/good.json"
printf '%s' '{"slots":{"rootfs":{"A":{"state":"booted","bootname":"A","boot_status":"bad"}}}}' >"$T/bad.json"
printf '%s' '{"slots":{"rootfs":{"B":{"state":"booted","bootname":"B","boot_status":"good"}}}}' >"$T/other.json"
printf '%s' 'not json' >"$T/broken.json"
export RAUC_STATUS_FILE="$T/good.json" RAUC_STATUS_RC=""

marker="$T/dash/.os-schema-held"
: >"$T/docker.log"

schema_hold_arm
[ ! -e "$marker" ] || fail "a committed slot must leave no marker"

RAUC_STATUS_FILE="$T/bad.json"
schema_hold_arm >"$T/arm.out" 2>&1
[ -e "$marker" ] || fail "an uncommitted slot must write the hold marker"
grep -q 'dashboard schema hold armed' "$T/arm.out" || fail "arming the hold must report it"
schema_hold_arm
[ -e "$marker" ] || fail "re-arming must keep the hold marker"
DOCKER_LOG="$T/docker.log" schema_hold_release >"$T/rel.out" 2>&1 || fail "a clean release must not fail the boot"
[ ! -e "$marker" ] || fail "release must remove the marker"
grep -q 'dashboard schema hold released' "$T/rel.out" || fail "releasing the hold must report it"
: >"$T/arm2.out"
RAUC_STATUS_FILE="$T/good.json"
schema_hold_arm >"$T/arm2.out" 2>&1
grep -q 'dashboard schema hold' "$T/arm2.out" && fail "a committed boot must not report a hold"

RAUC_STATUS_FILE="$T/other.json"
schema_hold_arm
[ -e "$marker" ] || fail "a good verdict for another slot must defer"
rm -f "$marker"

RAUC_STATUS_FILE="$T/broken.json"
schema_hold_arm
[ -e "$marker" ] || fail "unparseable rauc status must defer"

RAUC_STATUS_FILE="$T/good.json"
RAUC_STATUS_RC=3
rm -f "$marker"
schema_hold_arm
[ -e "$marker" ] || fail "a failing rauc status must defer"
RAUC_STATUS_RC=""
touch "$marker"
RAUC_STATUS_RC=3
schema_hold_arm
RAUC_STATUS_RC=""
[ -e "$marker" ] || fail "an uncertain verdict must never clear the marker"

printf 'rootwait quiet\n' >"$T/cmdline"
rm -f "$marker"
schema_hold_arm
[ -e "$marker" ] || fail "an unknown booted slot must defer"
printf 'rootwait rauc.slot=A\n' >"$T/cmdline"
rm -f "$marker"

mv .env .env.bak
rm -f "$marker"
schema_hold_arm
mv .env.bak .env
[ ! -e "$marker" ] || fail "an unrendered .env cannot arm"

RAUC_STATUS_FILE="$T/bad.json"
schema_hold_arm
RAUC_STATUS_FILE="$T/good.json"
schema_hold_arm
[ ! -e "$marker" ] || fail "a committed boot must clear the stale marker"

: >"$T/docker3.log"
restarts() { grep -c 'compose restart dashboard' "$T/docker3.log" || true; }
RAUC_STATUS_FILE="$T/bad.json"
schema_hold_arm
schema_hold_arm
[ "$(restarts)" = 0 ] || fail "arm must never restart"
RAUC_STATUS_FILE="$T/good.json"
DOCKER_LOG="$T/docker3.log" schema_hold_release || fail "release must not fail the boot"
[ ! -e "$marker" ] || fail "release must remove the marker"
[ "$(restarts)" = 1 ] || fail "release must restart the dashboard exactly once"
DOCKER_LOG="$T/docker3.log" schema_hold_release || fail "release without a marker must be a no-op"
[ "$(restarts)" = 1 ] || fail "no marker, no restart"

RAUC_STATUS_FILE="$T/bad.json"
schema_hold_arm
DOCKER_LOG="$T/docker2.log" DOCKER_RC=1 schema_hold_release >"$T/release2.out" 2>&1 || fail "a faulty restart must stay non-fatal"
[ ! -e "$marker" ] || fail "the marker must drop even when the restart faults"
grep -q 'FAULT' "$T/release2.out" || fail "a faulty restart must alert"

RAUC_STATUS_FILE="$T/bad.json"
schema_hold_arm
[ -e "$marker" ] || fail "re-arm for the gate-pass wiring check"
: >"$T/docker4.log"
DOCKER_LOG="$T/docker4.log" boot_gate_passed || fail "the gate pass must not fail"
[ ! -e "$marker" ] || fail "boot_gate_passed must release the schema hold"
gate_restarts=$(grep -c 'compose restart dashboard' "$T/docker4.log" || true)
[ "$gate_restarts" = 1 ] || fail "the gate pass must restart the dashboard exactly once"

printf 'selftest-schema-hold: ok\n'
