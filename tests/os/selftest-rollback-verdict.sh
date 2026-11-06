#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=tests/os/rollback-verdict.sh
. "$HERE/rollback-verdict.sh"

good='{"step":"idle","verdict":{"outcome":"rolled_back","from":"2.0.1","to":"2.0.2","blocking":["container dashboard: unhealthy"]}}'
rollback_verdict_check "$good" "container dashboard"
rollback_banner_blocked "$good" "$ROOT"
case "$(rollback_banner "$good" "$ROOT")" in *"Blocked by: container dashboard: unhealthy."*) ;; *) exit 1 ;; esac

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

if rollback_banner_blocked '{"verdict":{"outcome":"rolled_back","from":"2.0.1","to":"2.0.2"}}' "$ROOT"; then
    echo "banner claimed a cause with no blocking list" >&2
    exit 1
fi
if rollback_banner_blocked '{"verdict":{"outcome":"updated","to":"2.0.2"}}' "$ROOT"; then
    echo "an updated verdict rendered Blocked by" >&2
    exit 1
fi

_ssh() { printf 'out(%s)\n' "$1"; }
dest=$(mktemp)
trap 'rm -f "$dest"' EXIT
rollback_evidence "$dest"
for section in verdict in-flight grubenv doctor "pithead-boot journal (previous boot)"; do
    grep -qF "== $section" "$dest"
done
grep -qF 'out(journalctl -u pithead-boot -b -1' "$dest"
echo "rollback verdict helpers: ok"
