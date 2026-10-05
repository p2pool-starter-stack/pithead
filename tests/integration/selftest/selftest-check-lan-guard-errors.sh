#!/usr/bin/env bash
# Missing dependencies must fail the isolated LAN guard driver, not just print errors.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir "$SANDBOX/selftest"
ln -s "$HERE/../lib" "$SANDBOX/lib"
ln -s "$HERE/../lib.sh" "$SANDBOX/lib.sh"
DRIVER="$SANDBOX/selftest/selftest-check-lan-guard.sh"

echo "== LAN guard driver rejects unexpected missing commands =="
cp "$HERE/selftest-check-lan-guard.sh" "$DRIVER"
bash "$DRIVER" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
[ ! -s "$SANDBOX/stderr" ]
grep -Fxq 'selftest-check-lan-guard: PASS' "$SANDBOX/stdout"

for fault in onion conditional substitution; do
    case "$fault" in
    onion)
        # Reproduce the omitted unrelated assertion binding.
        sed 's/assert_onion_targets //' "$HERE/selftest-check-lan-guard.sh" >"$DRIVER"
        missing=assert_onion_targets
        ;;
    conditional)
        # A later success must not conceal a missing helper in an if condition.
        sed '/^SKIP_MINING_ASSERTS=/i\it_log() { if missing_lan_helper; then :; fi; }' \
            "$HERE/selftest-check-lan-guard.sh" >"$DRIVER"
        missing=missing_lan_helper
        ;;
    substitution)
        # Neither discarded stderr nor a subshell can conceal the missing helper.
        sed '/^SKIP_MINING_ASSERTS=/i\it_log() { local ignored; ignored="$(missing_lan_helper 2>/dev/null)"; :; }' \
            "$HERE/selftest-check-lan-guard.sh" >"$DRIVER"
        missing=missing_lan_helper
        ;;
    esac
    rc=0
    bash "$DRIVER" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" || rc=$?
    [ "$rc" -ne 0 ] || {
        echo "$fault: driver accepted missing $missing" >&2
        exit 1
    }
    grep -Fq 'FAIL (unexpected missing commands)' "$SANDBOX/stderr"
    if grep -Fq 'selftest-check-lan-guard: PASS' "$SANDBOX/stdout"; then
        echo "$fault: driver printed a misleading PASS" >&2
        exit 1
    fi
done
echo 'selftest-check-lan-guard-errors: PASS'
