#!/usr/bin/env bash
# baseline_up (#2057): the restored baseline starts under strict_pithead unless its CLI predates
# container_engine on a podman box, and that one exemption is a counted by-design skip.
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

echo "== the probe reads the stack directory's own CLI =="
printf 'container_engine() { :; }\n' >"$td/pithead"
[ "$(PITHEAD_ENGINE=podman baseline_ruleset_verdict)" = aware ]
printf 'stack_up() { :; }\n' >"$td/pithead"
[ "$(PITHEAD_ENGINE=podman baseline_ruleset_verdict)" = predates:podman ]
[ "$(PITHEAD_ENGINE=docker baseline_ruleset_verdict)" = predates:docker ]
printf 'exit 1\n' >"$td/pithead"
[ -z "$(PITHEAD_ENGINE=podman baseline_ruleset_verdict)" ]
rm "$td/pithead"
[ -z "$(PITHEAD_ENGINE=podman baseline_ruleset_verdict)" ]

echo "== an engine-aware CLI stays strict on podman =="
printf 'container_engine() { :; }\n' >"$td/pithead"
calls="" skipped="$IT_SKIPPED_BY_DESIGN"
PITHEAD_ENGINE=podman baseline_up
[ "$calls" = "strict:up " ]
[ "$IT_SKIPPED_BY_DESIGN" = "$skipped" ]

echo "== a pre-engine CLI on docker stays strict =="
printf 'stack_up() { :; }\n' >"$td/pithead"
calls=""
PITHEAD_ENGINE=docker baseline_up
[ "$calls" = "strict:up " ]
[ "$IT_SKIPPED_BY_DESIGN" = "$skipped" ]

echo "== an unreadable CLI stays strict =="
printf 'exit 1\n' >"$td/pithead"
calls=""
PITHEAD_ENGINE=podman baseline_up
[ "$calls" = "strict:up " ]
[ "$IT_SKIPPED_BY_DESIGN" = "$skipped" ]

echo "== a pre-engine CLI on podman starts plain, with one counted by-design skip =="
printf 'stack_up() { :; }\n' >"$td/pithead"
calls=""
PITHEAD_ENGINE=podman baseline_up >/dev/null 2>&1
PITHEAD_ENGINE=podman baseline_up >/dev/null 2>&1
[ "$calls" = "plain:up plain:up " ]
[ "$IT_SKIPPED_BY_DESIGN" = "$((skipped + 1))" ]
printf '%b' "$IT_SKIPPED_NAMES" | grep -Fq '[by-design] leg      baseline Tor-egress ruleset (#2696) — v1.20.0 predates the podman ruleset'

echo "selftest-baseline-up: PASS"
