#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/rollback-verdict.sh
. "$HERE/rollback-verdict.sh"

good='{"step":"idle","verdict":{"outcome":"rolled_back","from":"2.0.1","to":"2.0.2","blocking":["container dashboard: unhealthy"]}}'
rollback_verdict_check "$good" "container dashboard"

must_fail() {
    if rollback_verdict_check "$1" "$2" >/dev/null; then
        echo "accepted: $1" >&2
        exit 1
    fi
}
must_fail '{"verdict":{"outcome":"updated","blocking":["container dashboard"]}}' "container dashboard"
must_fail '{"verdict":{"outcome":"rolled_back"}}' "container dashboard"
must_fail '{"verdict":{"outcome":"rolled_back","blocking":[]}}' "container dashboard"
must_fail '{"verdict":{"outcome":"rolled_back","blocking":["",null]}}' "container dashboard"
must_fail '{"verdict":{"outcome":"rolled_back","blocking":["doctor: cert"]}}' "container dashboard"
must_fail '' "container dashboard"
must_fail 'not json' "container dashboard"

flag='{"from":"2.0.1","to":"2.0.2","blocking":["container dashboard: unhealthy","doctor: x"]}'
rollback_blocking_check "$flag" . "container dashboard"
for bad_flag in '{"to":"2.0.2"}' '{"blocking":[]}' '{"blocking":["doctor: x"]}' 'junk'; do
    if rollback_blocking_check "$bad_flag" . "container dashboard" >/dev/null; then
        echo "accepted flag: $bad_flag" >&2
        exit 1
    fi
done

curl() { printf '%s' "$served"; }
served='text Blocked by: text'
rollback_banner_served 192.0.2.1 u:p
served='return "no cause named";'
if rollback_banner_served 192.0.2.1 u:p; then
    echo "banner module without Blocked by accepted" >&2
    exit 1
fi
unset -f curl

_ssh() { printf 'out(%s)\n' "$1"; }
dest=$(mktemp)
trap 'rm -f "$dest"' EXIT
rollback_evidence "$dest"
for section in verdict in-flight grubenv doctor "pithead-boot journal (previous boot)"; do
    grep -qF "== $section" "$dest"
done
for want in \
    'out(cat /data/pithead/data/control/results/os-update-state.json)' \
    'out(cat /data/pithead/data/os-update/in-flight.json)' \
    'out(grub-editenv /boot/efi/grub/grubenv list)' \
    'out(cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json)' \
    'out(journalctl -u pithead-boot -b -1' \
    'out(journalctl -u pithead-boot -b 0'; do
    grep -qF "$want" "$dest" || {
        echo "missing guest command: $want" >&2
        exit 1
    }
done
echo "rollback verdict helpers: ok"
