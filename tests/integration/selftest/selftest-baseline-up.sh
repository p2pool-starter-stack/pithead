#!/usr/bin/env bash
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
IT_MODE=local
IT_REMOTE_DIR="$td"
calls=""
strict_pithead() { calls="${calls}strict:$* "; }
pithead() { calls="${calls}plain:$* "; }

for engine in docker podman; do
    for cli in aware legacy unreadable missing; do
        case "$cli" in
        aware) printf 'container_engine() { :; }\n' >"$td/pithead" ;;
        legacy) printf 'stack_up() { :; }\n' >"$td/pithead" ;;
        unreadable) printf 'exit 1\n' >"$td/pithead" ;;
        missing) rm -f "$td/pithead" ;;
        esac
        echo "== $engine $cli baseline always starts strictly =="
        calls="" skipped="$IT_SKIPPED_BY_DESIGN"
        PITHEAD_ENGINE="$engine" baseline_up
        [ "$calls" = "strict:up " ]
        [ "$IT_SKIPPED_BY_DESIGN" = "$skipped" ]
        strict_pithead() {
            calls="${calls}strict:$* "
            return 17
        }
        calls="" rc=0
        PITHEAD_ENGINE="$engine" baseline_up || rc=$?
        [ "$rc" -eq 17 ]
        [ "$calls" = "strict:up " ]
        [ "$IT_SKIPPED_BY_DESIGN" = "$skipped" ]
        strict_pithead() { calls="${calls}strict:$* "; }
    done
done

echo "selftest-baseline-up: PASS"
