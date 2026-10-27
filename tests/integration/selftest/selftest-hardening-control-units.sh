#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
checkout="$td/checkout"
control="$checkout/data/control"
units="$td/units"
fakebin="$td/bin"
mkdir -p "$control/requests" "$units" "$fakebin"
checkout="$(cd "$checkout" && pwd -P)"
control="$checkout/data/control"
units="$(cd "$units" && pwd -P)"
fakebin="$(cd "$fakebin" && pwd -P)"
mkdir -p "$checkout/lib/pithead"
cp "$ROOT/../../lib/pithead/10-installer-preseed.sh" "$checkout/lib/pithead/"
cp "$ROOT/../../lib/pithead/50-control-runner-provisioning.sh" "$checkout/lib/pithead/"
printf '#!/bin/sh\nexit 0\n' >"$fakebin/systemctl"
printf '#!/bin/sh\nexec "$@"\n' >"$fakebin/sudo"
chmod +x "$fakebin/systemctl" "$fakebin/sudo"
export INTEGRATION_RUN_SUITE=1
source "$ROOT/lib/run-hardening.sh"
quote_arg() { printf '%q' "$1"; }
env_on_box() { printf '%s' "$control"; }
rx() { (cd "$checkout" && env -u PITHEAD_UNIT_DIR PITHEAD_APPLIANCE="$target_appliance" PITHEAD_UNIT_DIR="$target_units" PATH="$fakebin:$PATH" bash -c "$1"); }
unit_dir() { (cd "$checkout" && env -u PITHEAD_UNIT_DIR PITHEAD_APPLIANCE="$1" bash -c 'source lib/pithead/10-installer-preseed.sh; source lib/pithead/50-control-runner-provisioning.sh; control_unit_dir'); }
export PITHEAD_UNIT_DIR="$td/runner-units"
target_appliance=1
target_units="$units"
service="$units/pithead-control.service"
path="$units/pithead-control.path"
write_service() { printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$service"; }
write_path() { printf '[Path]\nPathExistsGlob=%s/requests/*.json\n' "$1" >"$path"; }
clear_units() { rm -f "$service" "$path" "$td/unit-link"; }
removed() { _remove_control_units && [ ! -e "$service" ] && [ ! -e "$path" ]; }
retained() { _remove_control_units && [ -e "$service" ] && [ -e "$path" ]; }

[ "$(unit_dir 1)" = /run/systemd/system ]
[ "$(unit_dir 0)" = /etc/systemd/system ]
write_service "$checkout"
write_path "$control"
removed
target_appliance=0
checks=3
write_path "$control"
removed
checks=$((checks + 1))
write_service "$checkout"
saved_control="$control"
control="$td/missing-control"
removed
control="$saved_control"
checks=$((checks + 1))
write_path "$td/foreign-control"
_remove_control_units
[ -e "$path" ]
checks=$((checks + 1))
clear_units
write_service "$checkout"
write_path "$td/foreign-control"
retained
checks=$((checks + 1))
clear_units
printf '[Service]\nExecStart=/bin/false\n' >"$service"
write_path "$control"
retained
checks=$((checks + 1))
clear_units
write_service "$checkout"
printf '[Path]\nPathExistsGlob=invalid\n' >"$path"
retained
checks=$((checks + 1))
clear_units
write_service "$checkout"
write_path "$control"
mv "$service" "$td/unit-link"
ln -s "$td/unit-link" "$service"
retained
checks=$((checks + 1))
printf 'PASS: hardening control unit ownership (%s checks)\n' "$checks"
