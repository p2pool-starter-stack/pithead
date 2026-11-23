#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/normalize-config-version.sh
source "$HERE/../lib/normalize-config-version.sh" || exit $?

echo "== a baseline stamped newer than VERSION is lowered on the box (#4373) =="

BOX="$(mktemp -d)"
trap 'rm -rf "$BOX"' EXIT
rx() { (cd "$BOX" && bash -c "$1"); }
it_log() { :; }

stamp() { jq -r .config_version "$BOX/config.json"; }
run_case() {
    printf '{"config_version":"%s","keep":1}\n' "$1" >"$BOX/config.json"
    printf '%s\n' "$2" >"$BOX/VERSION"
    _normalize_config_version
}

run_case 2.0.4 2.0.3
assert_eq "a newer stamp is lowered to VERSION" "$(stamp)" "2.0.3"
assert_eq "the rest of config.json is kept" "$(jq -r .keep "$BOX/config.json")" "1"
run_case 2.0.2 2.0.3
assert_eq "an older stamp is left alone" "$(stamp)" "2.0.2"
run_case 2.0.3 2.0.3
assert_eq "an equal stamp is left alone" "$(stamp)" "2.0.3"
assert_eq "no temp file is left behind" "$(find "$BOX" -name 'config.json.*' | wc -l | tr -d ' ')" "0"

echo "selftest-normalize-config-version: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
