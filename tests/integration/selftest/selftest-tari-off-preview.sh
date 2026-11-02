#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-tari-off-preview.sh
source "$ROOT/lib/run-tari-off-preview.sh"

echo "== selftest: Tari-off preview reports the remote status and redacted stderr =="

fails=0
check() { if [ "$2" = ok ]; then echo "  ok   $1"; else
    echo "  FAIL $1"
    fails=$((fails + 1))
fi; }
has() { case "$1" in *"$2"*) echo ok ;; *) echo no ;; esac }
lacks() { case "$1" in *"$2"*) echo no ;; *) echo ok ;; esac }

IT_PITHEAD=./pithead
assert_rc() { :; }
assert_contains() { :; }
it_pass() { :; }
it_fail() { :; }

rx() {
    printf 'boom: ADMIN_PASSWORD=hunter2\n' >&2
    return 7
}
out="$(run_tari_off_preview)"
check "failure reports the remote exit status" "$(has "$out" 'remote exit status 7')"
check "failure reports the remote stderr" "$(has "$out" 'boom: ADMIN_PASSWORD=<redacted>')"
check "stderr secret is redacted" "$(lacks "$out" hunter2)"

rx() { printf 'Tari merge-mining OFF\nchain data on disk is KEPT\n'; }
out="$(run_tari_off_preview)"
check "success prints no diagnostic" "$(lacks "$out" 'remote exit status')"

# shellcheck disable=SC2016
scratch_line="$(grep -m1 'scratch=\$(mktemp' "$ROOT/lib/run-tari-off-preview.sh")"
# shellcheck disable=SC2016
made="$(env -u TMPDIR bash -c "set -eu; $scratch_line"'; printf %s "$scratch"; rm -rf "$scratch"' 2>&1)"
check "remote scratch dir is created without TMPDIR in the SSH environment" "$(has "$made" /tmp/tari-preview.)"

[ "$fails" -eq 0 ]
