#!/usr/bin/env bash
# Pure controls for the dashboard-uid same-text replay proof in the clearnet matrix row.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/run-egress-claim.sh
source "$HERE/../lib/run-egress-claim.sh"

probe() {
    (
        it_pass() { printf 'P:%s\n' "$1"; }
        it_fail() { printf 'F:%s\n' "$1"; }
        docker() {
            python3 - "$5" "$REPLAY_CASE" <<'PY'
import pathlib, sys
code, outcome = sys.argv[1:]
value = b"00000000-0000-4000-8000-000000000001\n"
class Marker:
    def __init__(self, path):
        assert path == "/clearnet-state/monero.synced"
    def read_bytes(self):
        if outcome == "unavailable":
            raise OSError("unreadable marker")
        return value
    def write_bytes(self, data):
        assert data == value
        if outcome == "denied":
            raise PermissionError("dashboard cannot write")
pathlib.Path = Marker
exec(compile(code, "<dashboard replay>", "exec"))
PY
        }
        rx() {
            case "$1" in
            *"rm -f"*) return 1 ;;
            "test -f"*) return 0 ;;
            *"python3 -c"*)
                # Execute emitted Python so shell quoting errors cannot pass the stub.
                eval "$1"
                ;;
            *) return 1 ;;
            esac
        }
        assert_host_claims_spent_sync /fixture/state true false
    )
}
echo "== dashboard same-text marker replay permission proof =="
REPLAY_CASE=denied
assert_contains "explicit same-text write denial passes" "$(probe)" "P:dashboard cannot replay spent monero marker in place"
REPLAY_CASE=accepted
assert_contains "successful same-text rewrite fails" "$(probe)" "F:dashboard cannot replay spent monero marker in place"
REPLAY_CASE=unavailable
assert_contains "failed exec or unreadable marker fails" "$(probe)" "F:dashboard cannot replay spent monero marker in place"
[ "$IT_FAIL" = 0 ]
