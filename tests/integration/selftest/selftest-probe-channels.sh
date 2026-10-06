#!/usr/bin/env bash
# Checkout-only probes skip appliances, never a broken DIY fixture or transport.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=tests/integration/lib.sh
source "$ROOT/tests/integration/lib.sh"
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$ROOT/tests/integration/lib/run-source-image.sh"
# shellcheck source=tests/integration/lib/run-connection-announcements.sh
source "$ROOT/tests/integration/lib/run-connection-announcements.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-lifecycle-wallet-fixture.sh
source "$ROOT/tests/integration/lib/run-lifecycle-wallet-fixture.sh"
echo "== checkout-only probe channel decisions =="
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
OUT_DIR=$fixture
cat >"$fixture/pithead" <<'CLI'
is_appliance() { [ "${TEST_APPLIANCE:-0}" = 1 ]; }
CLI
rx() {
    printf '%s\n' "$1" >>"$fixture/commands"
    if [ "$1" = 'source ./pithead && is_appliance' ] && [ "${TEST_TRANSPORT_FAILURE:-0}" = 1 ]; then
        return 255
    fi
    (cd "$fixture" && bash -c "$1")
}
reset_counts() {
    IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_BY_DESIGN=0
    IT_SKIPPED_MISSING=0 IT_SKIPPED_NAMES=''
    : >"$fixture/commands"
}
export TEST_APPLIANCE=1
reset_counts
prove_wallet_supersession
run_connection_announcements
[ "$IT_PASS" -eq 0 ] && [ "$IT_FAIL" -eq 0 ]
[ "$IT_SKIPPED_LEGS" -eq 6 ] && [ "$IT_SKIPPED_BY_DESIGN" -eq 6 ]
[ "$IT_SKIPPED_MISSING" -eq 0 ]
[ "$(wc -l <"$fixture/commands")" -eq 2 ]
[[ "$IT_SKIPPED_NAMES" == *'(#3133)'* && "$IT_SKIPPED_NAMES" == *'(#3090)'* ]]
[[ "$IT_SKIPPED_NAMES" == *'appliance channel:'* && "$IT_SKIPPED_NAMES" == *'not shipped'* ]]
[ ! -e "$fixture/connection-announcements.log" ]
echo 'PASS: appliance without a tests tree records six named by-design skips and runs no checkout probe'

export TEST_APPLIANCE=0
for transport in 0 1; do
    export TEST_TRANSPORT_FAILURE=$transport
    reset_counts
    prove_wallet_supersession || true
    [ "$IT_FAIL" -eq 1 ] && [ "$IT_PASS" -eq 0 ]
    [ "$IT_SKIPPED_LEGS" -eq 0 ]
    grep -Fq 'python3 tests/integration/tools/prove-wallet-supersession.py .' "$fixture/commands"
    if run_connection_announcements; then
        echo 'FAIL: missing DIY connection tool passed' >&2
        exit 1
    fi
    [ "$IT_FAIL" -eq 6 ] && [ "$IT_PASS" -eq 0 ]
    [ "$IT_SKIPPED_LEGS" -eq 0 ]
    grep -Fq 'connection-setup-pty.py' "$fixture/commands"
    echo "PASS: missing DIY tools remain failures with channel transport failure=$transport"
done
export TEST_TRANSPORT_FAILURE=0
mkdir -p "$fixture/tests/integration/tools"
printf 'print("supersession proof ran")\n' >"$fixture/tests/integration/tools/prove-wallet-supersession.py"
reset_counts
prove_wallet_supersession
[ "$IT_PASS" -eq 1 ] && [ "$IT_FAIL" -eq 0 ] && [ "$IT_SKIPPED_LEGS" -eq 0 ]
echo 'PASS: DIY supersession executes its tool and records its assertion'
