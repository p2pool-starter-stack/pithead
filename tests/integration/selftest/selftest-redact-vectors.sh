#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

REPO="$(cd -P "$HERE/../../.." && pwd -P)"
VECTORS="$REPO/dashboard/tests/fixtures/log-redaction-vectors.tsv"

echo "== unit: shared log-redaction vectors through the shipped bundle_redact_log =="

if [ -s "$VECTORS" ]; then
    it_pass "the shared vector file is present and non-empty"
else
    it_fail "the shared vector file is present and non-empty" "$VECTORS"
    exit 1
fi

if python3 "$REPO/scripts/build-redact-patterns.py" --check; then
    it_pass "the generated slice carries exactly the shared pattern file"
else
    it_fail "the generated slice carries exactly the shared pattern file" "run scripts/build-redact-patterns.py"
fi

n=0
while IFS=$'\t' read -r name input expected; do
    n=$((n + 1))
    got="$(
        # shellcheck source=/dev/null
        source "$REPO/pithead" </dev/null >/dev/null 2>&1
        printf '%s\n' "$input" | bundle_redact_log
    )"
    if [ "$got" = "$expected" ]; then
        it_pass "vector $name"
    else
        it_fail "vector $name" "got: $got"
    fi
done <"$VECTORS"

if [ "$n" -ge 10 ]; then
    it_pass "at least ten vectors were exercised ($n)"
else
    it_fail "at least ten vectors were exercised ($n)" "vector file truncated"
fi

echo "selftest-redact-vectors: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
