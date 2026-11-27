#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
Linux) ;;
*)
    echo "selftest-schema-hold: skipped off Linux (mv -T)"
    exit 0
    ;;
esac
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

mode_of() { stat -c '%a' "$1"; }
printf 'keep-me\n' >"$T/target-file"
chmod 640 "$T/target-file"
mkdir -p "$T/target-dir"
RAUC_STATUS_FILE="$T/bad.json"
for target in "$T/target-file" "$T/target-dir" "$T/missing"; do
    rm -f "$marker"
    ln -s "$target" "$marker"
    schema_hold_arm >/dev/null 2>&1 || fail "arming over a link at the marker must still arm ($target)"
    [ -f "$marker" ] && [ ! -L "$marker" ] || fail "arming must leave a real marker in place of the link ($target)"
done
[ "$(cat "$T/target-file")" = keep-me ] || fail "arming must not write through a link to a file"
[ "$(mode_of "$T/target-file")" = 640 ] || fail "arming must not change a linked file's mode"
[ -z "$(ls -A "$T/target-dir")" ] || fail "arming must not write into a linked folder"
[ ! -e "$T/missing" ] || fail "arming must not create a dangling link's target"

mktemp() {
    local made
    made=$(command mktemp "$@") || return
    : >"$T/mktemp-ran"
    case "$window" in
    final) ln -s "$T/victim" "$marker" ;;
    temp) command rm -f "$made" && ln -s "$T/victim" "$made" ;;
    esac
    printf '%s\n' "$made"
}
rm() {
    command rm "$@"
    [ "$window" != rm ] || ln -sf "$T/victim" "$marker"
}
for window in final temp rm; do
    printf 'keep-me\n' >"$T/victim"
    chmod 640 "$T/victim"
    command rm -f "$marker" "$T/mktemp-ran"
    schema_hold_arm >/dev/null 2>&1
    rc=$?
    [ -e "$T/mktemp-ran" ] || fail "arming must create the marker through mktemp ($window)"
    [ "$(cat "$T/victim")" = keep-me ] || fail "a link planted in the arming window must not be written through ($window)"
    [ "$(mode_of "$T/victim")" = 640 ] || fail "a link planted in the arming window must not change the victim's mode ($window)"
    [ "$window" = temp ] || { [ "$rc" = 0 ] && [ -f "$marker" ] && [ ! -L "$marker" ]; } ||
        fail "a link planted at the marker in the window must be replaced by a real marker"
done
unset -f mktemp rm

printf 'selftest-schema-hold: ok\n'
