#!/usr/bin/env bash
# Prove the historical Digest exception without exempting later copies of the fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/gitleaks-history.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
COMMIT=051add657bebb7f744aef9e0622ad2ea9591d96b
FIXTURE=tests/integration/selftest/test_restore_curl_connection.py
FINGERPRINT="$COMMIT:$FIXTURE:generic-api-key:59"

scan() {
    if [[ -n ${GITLEAKS_BIN:-} ]]; then
        "$GITLEAKS_BIN" "$@"
    else
        # Use the same image pin as the required history scan.
        local image
        image=$(sed -n 's/^[[:space:]]*\(ghcr.io\/gitleaks\/gitleaks:[^[:space:]]*\).*/\1/p' "$ROOT/.github/workflows/ci.yml")
        [[ -n $image && $image != *$'\n'* ]]
        docker run --rm -v "$ROOT:$ROOT:ro" -v "$SANDBOX:$SANDBOX" "$image" "$@"
    fi
}

expect_finding() {
    local expected=$1 rc=0
    shift
    scan "$@" --report-format json --report-path "$SANDBOX/report.json" || rc=$?
    [[ $rc == 1 ]] || {
        echo "Expected a secret finding, got exit $rc" >&2
        return 1
    }
    jq -e --arg expected "$expected" \
        'length == 1 and .[0].Fingerprint == $expected' "$SANDBOX/report.json" >/dev/null
}

ARGS=(--no-banner --redact --config "$ROOT/.config/gitleaks.toml")
sed "\|^$FINGERPRINT$|d" "$ROOT/.config/gitleaksignore" >"$SANDBOX/without-digest.ignore"
expect_finding "$FINGERPRINT" git "$ROOT" "${ARGS[@]}" \
    --gitleaks-ignore-path "$SANDBOX/without-digest.ignore" --log-opts="$COMMIT^..$COMMIT"
scan git "$ROOT" "${ARGS[@]}" --gitleaks-ignore-path "$ROOT/.config/gitleaksignore" \
    --log-opts="$COMMIT^..$COMMIT"

# An unchanged fixture in a different commit must still be reported.
git init -q "$SANDBOX/repo"
mkdir -p "$SANDBOX/repo/$(dirname "$FIXTURE")"
git -C "$ROOT" show "$COMMIT:$FIXTURE" >"$SANDBOX/repo/$FIXTURE"
git -C "$SANDBOX/repo" add "$FIXTURE"
git -C "$SANDBOX/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Synthetic Digest scan control'
COPY=$(git -C "$SANDBOX/repo" rev-parse HEAD)
expect_finding "$COPY:$FIXTURE:generic-api-key:59" git "$SANDBOX/repo" "${ARGS[@]}" \
    --gitleaks-ignore-path "$ROOT/.config/gitleaksignore" --log-opts=HEAD
echo 'PASS: historical Digest finding ignored; missing exception and later copy detected'
