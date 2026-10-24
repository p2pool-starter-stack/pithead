#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/pithead/12c-wizard-rig-preseed.sh"
TASK_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_DIR"' EXIT
mkdir -p "$TASK_DIR/host" "$TASK_DIR/esp"
cd "$TASK_DIR/host"
PRESEED_DIR="$TASK_DIR/esp"
installer=0
installer_mode_available() { [ "$installer" -eq 1 ]; }
record_machine_role() { printf '%s' "$1" >machine-role; }
scrub_staged_rig() {
    printf '%s' "$1" >scrubbed
    rm -f "$PRESEED_DIR/pithead-rig.json"
}
_console() { printf '%s\n' "$*" >>console; }
warn() { printf '%s\n' "$*" >>warnings; }
seed() {
    printf '%s' '{"pool":"example.test:3333","worker":"fixture","access_token":"0123456789abcdef0123456789abcdef"}' >"$PRESEED_DIR/pithead-rig.json"
}
seed
wizard_consume_rig_preseed
cmp rig.json <(printf '%s' '{"pool":"example.test:3333","worker":"fixture","access_token":"0123456789abcdef0123456789abcdef"}')
[ "$(stat -c %a rig.json)" = 600 ]
[ "$(cat machine-role)" = rig ]
[ "$(cat scrubbed)" = consumed ]
[ ! -e "$PRESEED_DIR/pithead-rig.json" ]
grep -q 'RigForge rig (fixture)' console
printf preserved >rig.json
rm -f scrubbed console
seed
wizard_consume_rig_preseed
[ -f "$PRESEED_DIR/pithead-rig.json" ]
[ "$(cat rig.json)" = preserved ]
[ ! -e scrubbed ]
rm -f rig.json machine-role
installer=1
wizard_consume_rig_preseed
[ -f "$PRESEED_DIR/pithead-rig.json" ]
[ ! -e rig.json ]
[ ! -e machine-role ]
[ ! -e scrubbed ]
installer=0
for payload in '{"pool":"example.test:3333"}' '{"pool":""}' '{"pool":"example.test:3333","access_token":"bad"}' 'invalid'; do
    printf '%s' "$payload" >"$PRESEED_DIR/pithead-rig.json"
    wizard_consume_rig_preseed
    [ ! -e rig.json ]
    [ ! -e machine-role ]
    [ ! -e "$PRESEED_DIR/pithead-rig.json" ]
    [ "$(cat scrubbed)" = unusable ]
    grep -q unusable warnings
    rm -f scrubbed warnings
done
seed
install() { return 1; }
wizard_consume_rig_preseed
[ ! -e rig.json ]
[ ! -e machine-role ]
[ "$(cat scrubbed)" = unusable ]
[ ! -e "$PRESEED_DIR/pithead-rig.json" ]
wizard_consume_rig_preseed
printf 'wizard rig preseed self-test: PASS\n'
