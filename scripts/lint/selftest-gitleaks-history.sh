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
    local expected=$1 rc=0 count=${EXPECTED_FINDINGS:-1}
    shift
    scan "$@" --report-format json --report-path "$SANDBOX/report.json" || rc=$?
    [[ $rc == 1 ]] || {
        echo "Expected a secret finding, got exit $rc" >&2
        return 1
    }
    jq -e --arg expected "$expected" --argjson count "$count" \
        'length == $count and all(.[]; .Fingerprint == $expected)' "$SANDBOX/report.json" >/dev/null
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

# Only complete stale dashboard-hash fixture lines in reviewed paths are exempt.
HASH_PATHS=(tests/stack/appliance/test-appliance-setup.sh
    tests/stack/appliance/test-appliance-restore.sh tests/stack/test-cli-restore-hardening.sh)
HASH_LINE=$(sed -n '/^DASHBOARD_AUTH_HASH_B64=[[:alnum:]]/p' "$ROOT/${HASH_PATHS[1]}")
[[ -n $HASH_LINE && $HASH_LINE != *$'\n'* ]]
git init -q "$SANDBOX/hash-repo"
for HASH_FILE in "${HASH_PATHS[@]}"; do
    mkdir -p "$SANDBOX/hash-repo/$(dirname "$HASH_FILE")"
    printf '# Synthetic archive fixture\n%s\n' "$HASH_LINE" >"$SANDBOX/hash-repo/$HASH_FILE"
done
git -C "$SANDBOX/hash-repo" add .
git -C "$SANDBOX/hash-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Reviewed stale dashboard-hash fixtures'
scan git "$SANDBOX/hash-repo" "${ARGS[@]}" --log-opts=HEAD

# A fixture suffix must not exempt another credential on the same line.
HASH_FILE=${HASH_PATHS[2]}
PREFIX=$(printf 'stale-hash-prefix-control' | sha256sum | cut -d' ' -f1)
printf '# Synthetic archive fixture\nAPI_KEY=%s # %s\n' "$PREFIX" "$HASH_LINE" >"$SANDBOX/hash-repo/$HASH_FILE"
git -C "$SANDBOX/hash-repo" add "$HASH_FILE"
git -C "$SANDBOX/hash-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Prefixed stale dashboard-hash control'
COPY=$(git -C "$SANDBOX/hash-repo" rev-parse HEAD)
EXPECTED_FINDINGS=2 expect_finding "$COPY:$HASH_FILE:generic-api-key:2" git "$SANDBOX/hash-repo" "${ARGS[@]}" \
    --log-opts="$COPY^..$COPY"
jq -e 'map(.StartColumn) | unique | length == 2' "$SANDBOX/report.json" >/dev/null

# Changed lines and lookalike paths must remain findings.
for CONTROL in suffix value path; do
    CONTROL_FILE=$HASH_FILE
    CONTROL_LINE=$HASH_LINE
    case $CONTROL in
    suffix) CONTROL_LINE+=" # changed fixture line" ;;
    value) CONTROL_LINE="${HASH_LINE/c3RhbGUtZml4dHVyZQ==/YWx0ZXJlZC1maXh0dXJl}" ;;
    path) CONTROL_FILE="$HASH_FILE.unreviewed" ;;
    esac
    printf '# Synthetic archive fixture\n%s\n' "$CONTROL_LINE" >"$SANDBOX/hash-repo/$CONTROL_FILE"
    git -C "$SANDBOX/hash-repo" add "$CONTROL_FILE"
    git -C "$SANDBOX/hash-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false commit -qm "Changed stale dashboard-hash $CONTROL control"
    COPY=$(git -C "$SANDBOX/hash-repo" rev-parse HEAD)
    expect_finding "$COPY:$CONTROL_FILE:generic-api-key:2" git "$SANDBOX/hash-repo" "${ARGS[@]}" \
        --log-opts="$COPY^..$COPY"
done
echo 'PASS: stale dashboard-hash fixtures accepted; prefixes, changed lines and other paths detected'

# Moving the archive fixture must keep the exception limited to its exact path and line.
BACKUP=tests/stack/lib/backup-fixtures.sh
git init -q "$SANDBOX/backup-repo"
mkdir -p "$SANDBOX/backup-repo/$(dirname "$BACKUP")"
cp "$ROOT/$BACKUP" "$SANDBOX/backup-repo/$BACKUP"
git -C "$SANDBOX/backup-repo" add "$BACKUP"
git -C "$SANDBOX/backup-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Reviewed synthetic archive fixture'
scan git "$SANDBOX/backup-repo" "${ARGS[@]}" --log-opts=HEAD

# The identical token in an unreviewed file must remain a finding.
grep '^PROXY_AUTH_TOKEN=' "$ROOT/$BACKUP" >"$SANDBOX/backup-repo/unreviewed.sh"
git -C "$SANDBOX/backup-repo" add unreviewed.sh
git -C "$SANDBOX/backup-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Unreviewed proxy-token control'
COPY=$(git -C "$SANDBOX/backup-repo" rev-parse HEAD)
expect_finding "$COPY:unreviewed.sh:generic-api-key:1" git "$SANDBOX/backup-repo" "${ARGS[@]}" \
    --log-opts="$COPY^..$COPY"

# A fixture suffix must not exempt another credential prepended on the same line.
PREFIX=$(printf 'prefixed-credential-control' | sha256sum | cut -d' ' -f1)
sed "s/^PROXY_AUTH_TOKEN=/API_KEY=$PREFIX # PROXY_AUTH_TOKEN=/" "$ROOT/$BACKUP" >"$SANDBOX/backup-repo/$BACKUP"
LINE=$(grep -n '^API_KEY=' "$SANDBOX/backup-repo/$BACKUP" | cut -d: -f1)
git -C "$SANDBOX/backup-repo" add "$BACKUP"
git -C "$SANDBOX/backup-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Prefixed credential control'
COPY=$(git -C "$SANDBOX/backup-repo" rev-parse HEAD)
EXPECTED_FINDINGS=2 expect_finding "$COPY:$BACKUP:generic-api-key:$LINE" git "$SANDBOX/backup-repo" "${ARGS[@]}" \
    --log-opts="$COPY^..$COPY"
jq -e 'map(.StartColumn) | unique | length == 2' "$SANDBOX/report.json" >/dev/null

# Even at the reviewed path, a different complete line must remain a finding.
sed '/^PROXY_AUTH_TOKEN=/s/$/ # not the reviewed fixture line/' "$ROOT/$BACKUP" >"$SANDBOX/backup-repo/$BACKUP"
LINE=$(grep -n '^PROXY_AUTH_TOKEN=' "$SANDBOX/backup-repo/$BACKUP" | cut -d: -f1)
git -C "$SANDBOX/backup-repo" add "$BACKUP"
git -C "$SANDBOX/backup-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Changed proxy-token line control'
COPY=$(git -C "$SANDBOX/backup-repo" rev-parse HEAD)
expect_finding "$COPY:$BACKUP:generic-api-key:$LINE" git "$SANDBOX/backup-repo" "${ARGS[@]}" \
    --log-opts="$COPY^..$COPY"
echo 'PASS: moved archive fixture accepted; other paths, prefixes and changed lines detected'

# Stratum seed exceptions bind only one commit/path/line, including after squash merges.
# Derive the original deterministic fixture instead of depending on unmerged branch objects.
STRATUM_FILE=tests/os/selftest-miner-connection.sh
STRATUM_SEED=$(printf '%x' {0..15} {0..7})
git init -q "$SANDBOX/stratum-repo"
mkdir -p "$SANDBOX/stratum-repo/$(dirname "$STRATUM_FILE")"
printf 'PROXY_STRATUM_PASSWORD=%s\n' "$STRATUM_SEED" >"$SANDBOX/stratum-repo/$STRATUM_FILE"
git -C "$SANDBOX/stratum-repo" add "$STRATUM_FILE"
git -C "$SANDBOX/stratum-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Synthetic stratum seed negative control'
COPY=$(git -C "$SANDBOX/stratum-repo" rev-parse HEAD)
STRATUM_FINDING="$COPY:$STRATUM_FILE:generic-api-key:1"
expect_finding "$STRATUM_FINDING" git "$SANDBOX/stratum-repo" "${ARGS[@]}" \
    --gitleaks-ignore-path "$ROOT/.config/gitleaksignore" --log-opts=HEAD
cp "$ROOT/.config/gitleaksignore" "$SANDBOX/with-stratum.ignore"
printf '%s\n' "$STRATUM_FINDING" >>"$SANDBOX/with-stratum.ignore"
scan git "$SANDBOX/stratum-repo" "${ARGS[@]}" \
    --gitleaks-ignore-path "$SANDBOX/with-stratum.ignore" --log-opts=HEAD
sed "\|^$STRATUM_FINDING$|d" "$SANDBOX/with-stratum.ignore" >"$SANDBOX/without-stratum.ignore"
expect_finding "$STRATUM_FINDING" git "$SANDBOX/stratum-repo" "${ARGS[@]}" \
    --gitleaks-ignore-path "$SANDBOX/without-stratum.ignore" --log-opts=HEAD
git -C "$SANDBOX/stratum-repo" rm -q "$STRATUM_FILE"
git -C "$SANDBOX/stratum-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Remove synthetic stratum fixture'
mkdir -p "$SANDBOX/stratum-repo/$(dirname "$STRATUM_FILE")"
printf 'PROXY_STRATUM_PASSWORD=%s\n' "$STRATUM_SEED" >"$SANDBOX/stratum-repo/$STRATUM_FILE"
git -C "$SANDBOX/stratum-repo" add "$STRATUM_FILE"
git -C "$SANDBOX/stratum-repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Copied stratum seed negative control'
COPY=$(git -C "$SANDBOX/stratum-repo" rev-parse HEAD)
expect_finding "$COPY:$STRATUM_FILE:generic-api-key:1" git "$SANDBOX/stratum-repo" "${ARGS[@]}" \
    --gitleaks-ignore-path "$SANDBOX/with-stratum.ignore" --log-opts="$COPY^..$COPY"
echo 'PASS: exact stratum fixture ignored; missing exception and later copy detected'
