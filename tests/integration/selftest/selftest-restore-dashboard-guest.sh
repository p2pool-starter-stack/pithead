#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib.sh"
ROOT=$(cd "$HERE/../../.." && pwd)
echo "== candidate-compatible restore dashboard fixture =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sleep() { SECONDS=$((SECONDS + 60)); }
export -f sleep
run_case() {
    local fault="$1" rc=0
    local dir="$work/$fault"
    mkdir -p "$dir/bin" "$dir/data" "$dir/backups"
    printf untouched >"$dir/backups/existing.tar.gz"
    cp "$ROOT/config.reference.json" "$dir/config.reference.json"
    printf '2.0.0\n' >"$dir/VERSION"
    jq '.config_version = "2.0.1" | .future_only = "preserve" |
        .monero.wallet_address = "fixture-monero" | .monero.view_key = "fixture-view" |
        .tari.wallet_address = "fixture-tari" | .tari.view_key = "fixture-tari-view" |
        .tari.spend_public_key = "fixture-public" | .monero.payout_scan_height = 123 |
        .tari.payout_scan_birthday = 456 | .xvb.donor_id = "fixture-donor" |
        .dashboard.auth.password = "fixture-password" | .dashboard.energy.cost_per_kwh = 0.456 |
        .xvb.enabled = false' "$ROOT/config.reference.json" >"$dir/original.json"
    if [ "$fault" = unknown-wallet ]; then
        jq '.monero.future_wallet = {address: "preserve"}' "$dir/original.json" >"$dir/new.json"
        mv "$dir/new.json" "$dir/original.json"
    fi
    cp "$dir/original.json" "$dir/config.json"
    cat >"$dir/pithead" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>trace
case "$1" in
apply)
    if jq -e 'has("future_only")' config.json >/dev/null; then
        [ "$FIXTURE_FAULT" != cleanup-apply ] || exit 1
        if [ "$FIXTURE_FAULT" = cleanup-mutation ]; then
            jq '.future_only = "changed"' config.json >next.json
            mv next.json config.json
        fi
    fi
    if ! jq -e '.config_version == "2.0.1"' config.json >/dev/null; then
        jq '.config_version = "2.0.0"' config.json >next.json
        mv next.json config.json
    fi
    cp config.json api.json
    ;;
backup)
    jq -e '.config_version == "2.0.0" and (has("future_only") | not)' config.json >/dev/null
    cp config.json synthetic-at-backup.json
    cp config.json "$PWD/backups/pithead-backup-fixture.tar.gz"
    printf '[pithead] Backup written to: %s/backups/pithead-backup-fixture.tar.gz\n' "$PWD"
    ;;
restore)
    [ "$FIXTURE_FAULT" != restore-refuse ] || exit 1
    jq -e '.config_version == "2.0.0"' "$3" >/dev/null
    cp "$3" config.json
    [ "$FIXTURE_FAULT" = stale ] || cp config.json api.json
    ;;
status) [ "$FIXTURE_FAULT" != cleanup-unhealthy ] ;;
down | up) ;;
*) exit 127 ;;
esac
CLI
    cat >"$dir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
endpoint=${!#}
endpoint=${endpoint##*/}
printf 'curl-%s\n' "$endpoint" >>trace
if [ "$endpoint" = state ]; then
    if [ "$FIXTURE_FAULT" = state-stale ]; then
        printf '{"energy":{"cost_per_kwh":0.789}}\n'
    else
        jq '{energy: .dashboard.energy}' api.json
    fi
else
    cat api.json
fi
CURL
    cat >"$dir/bin/cp" <<'COPY'
#!/usr/bin/env bash
set -euo pipefail
if [ "$FIXTURE_FAULT" = fixture-copy ] && [[ "$1" = */fixture.json ]] && [ "$2" = config.json ]; then
    : >config.json
    exit 1
fi
exec /bin/cp "$@"
COPY
    chmod +x "$dir/pithead" "$dir/bin/curl" "$dir/bin/cp"
    (cd "$dir" && FIXTURE_FAULT="$fault" TMPDIR="$dir/data" PATH="$dir/bin:$PATH" bash "$HERE/../lib/restore-dashboard-guest.sh") >"$dir/output" 2>&1 || rc=$?
    printf '%s' "$rc"
}
assert_eq "a newer baseline can supply a separate candidate fixture" "$(run_case success)" 0
assert_eq "the original newer baseline is restored byte-for-byte" \
    "$(cmp -s "$work/success/original.json" "$work/success/config.json" && echo yes)" yes
assert_eq "the synthetic archive has the candidate version and no future-only field" \
    "$(jq '.config_version == "2.0.0" and (has("future_only") | not)' "$work/success/synthetic-at-backup.json")" true
assert_eq "wallets, payout controls and false settings are unchanged in the fixture" \
    "$(jq --slurpfile saved "$work/success/original.json" '
        [.monero.wallet_address, .monero.view_key, .monero.payout_scan_height,
         .tari.wallet_address, .tari.view_key, .tari.spend_public_key, .tari.payout_scan_birthday,
         .xvb.donor_id, .xvb.enabled] ==
        ($saved[0] | [.monero.wallet_address, .monero.view_key, .monero.payout_scan_height,
         .tari.wallet_address, .tari.view_key, .tari.spend_public_key, .tari.payout_scan_birthday,
         .xvb.donor_id, .xvb.enabled])' "$work/success/synthetic-at-backup.json")" true
assert_eq "both APIs are checked after restore/up before cleanup applies anything" \
    "$(cat "$work/success/trace")" \
    $'apply\nbackup\napply\ncurl-config\ndown\nrestore\nup\ncurl-config\ncurl-state\ndown\napply\nup\nstatus\nstatus'
assert_eq "a verified cleanup removes only its fixture and new archive" \
    "$(find "$work/success/data" -type f | wc -l | tr -d ' ')|$([ ! -e "$work/success/backups/pithead-backup-fixture.tar.gz" ] && cat "$work/success/backups/existing.tar.gz")" '0|untouched'
for fault in stale state-stale restore-refuse fixture-copy; do
    rc=$(run_case "$fault")
    assert_eq "$fault fails the probe" "$([ "$rc" -ne 0 ] && echo yes)" yes
    assert_eq "$fault still restores the original baseline" \
        "$(cmp -s "$work/$fault/original.json" "$work/$fault/config.json" && echo yes)" yes
    assert_eq "$fault still verifies cleanup health twice" \
        "$(grep -c '^status$' "$work/$fault/trace")" 2
done
assert_eq "a stale config response cannot suppress the state assertion" \
    "$(grep -c '^curl-state$' "$work/stale/trace")" 2
for fault in cleanup-apply cleanup-mutation cleanup-unhealthy; do
    rc=$(run_case "$fault")
    assert_eq "$fault fails closed" "$([ "$rc" -ne 0 ] && echo yes)" yes
    retained=$(find "$work/$fault/data" -name original.json -type f)
    assert_eq "$fault retains the unchanged recovery baseline" \
        "$([ -n "$retained" ] && cmp -s "$work/$fault/original.json" "$retained" && echo yes)" yes
    assert_eq "$fault keeps recovery files private" "$(stat -c %a "$retained")|$(stat -c %a "$(dirname "$retained")")" '600|700'
    assert_contains "$fault reports unverified cleanup" "$(cat "$work/$fault/output")" 'cleanup unverified'
done
assert_eq "cleanup health failure is bounded" "$(grep -c '^status$' "$work/cleanup-unhealthy/trace")" 4
assert_eq "an unsupported wallet field is refused" "$([ "$(run_case unknown-wallet)" -ne 0 ] && echo yes)" yes
assert_eq "unsupported wallet refusal happens before any CLI mutation" \
    "$([ ! -e "$work/unknown-wallet/trace" ] && cmp -s "$work/unknown-wallet/original.json" "$work/unknown-wallet/config.json" && echo yes)" yes
[ "$IT_FAIL" -eq 0 ]
