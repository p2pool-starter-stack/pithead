#!/usr/bin/env bash
# A control result is visible to readers only after its matching audit line.
set -euo pipefail
echo "== control audit precedes result =="

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/pithead-audit-order.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir"/{staged,results,audit}
CONFIG_FILE="$test_dir/config.json"
printf '{}\n' >"$CONFIG_FILE"

cat >"$test_dir/apply" <<'EOF'
#!/usr/bin/env bash
exit "${APPLY_RC:-0}"
EOF
chmod +x "$test_dir/apply"

ROOT="$ROOT" TEST_DIR="$test_dir" CONFIG_FILE="$CONFIG_FILE" bash -c '
    set -euo pipefail
    source "$ROOT/lib/pithead/43-control-approval-and-preview.sh"
    control_approval_gate() {
        [[ ${GATE_RC:-0} == 0 ]] || return 1
        printf P2POOL_FLAGS
    }
    control_carried_ssh() { return 1; }
    control_reown_operator_files() { :; }
    control_audit() { printf "%s:%s\n" "$4" "$5" >>"$1"; }
    control_write_result() {
        local status
        status=$(jq -r .status <<<"$3")
        grep -q "commit:$status" "$TEST_DIR/audit/control.log"
        printf "%s\n" "$3" >"$1/$2.json"
    }
    id=11111111-1111-4111-8111-111111111111
    control_commit "$id" admin "$TEST_DIR"
    [[ $(jq -r .status "$TEST_DIR/results/$id.json") == rejected ]]
    printf "{}\n" >"$TEST_DIR/staged/$id.json"
    touch -t 202001010000 "$TEST_DIR/staged/$id.json"
    : >"$TEST_DIR/audit/control.log"
    control_commit "$id" admin "$TEST_DIR"
    [[ $(jq -r .status "$TEST_DIR/results/$id.json") == rejected ]]
    printf "{}\n" >"$TEST_DIR/staged/$id.json"
    : >"$TEST_DIR/audit/control.log"
    GATE_RC=1 control_commit "$id" admin "$TEST_DIR"
    [[ $(jq -r .status "$TEST_DIR/results/$id.json") == rejected ]]
    for rc in 0 1; do
        printf "{}\n" >"$TEST_DIR/staged/$id.json"
        : >"$TEST_DIR/audit/control.log"
        APPLY_RC=$rc control_commit "$id" admin "$TEST_DIR"
        if (( rc == 0 )); then status=applied; else status=failed; fi
        [[ $(jq -r .status "$TEST_DIR/results/$id.json") == "$status" ]]
    done
' "$test_dir/apply"
echo 'control audit precedes result: PASS'
