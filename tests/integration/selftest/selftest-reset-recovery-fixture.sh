#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
# shellcheck disable=SC2034
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-reset-restore.sh"
echo "== candidate-compatible encrypted recovery fixture =="

case_fixture() (
    local fault="$1" root rc calls=0
    root=$(mktemp -d) || exit 1
    trap 'rm -rf "$root"' EXIT
    mkdir "$root/work" "$root/artifacts" "$root/scratch"
    export TMPDIR="$root/scratch"
    cd "$root/work" || exit 1
    printf ' {"config_version":"9.9.9","future":true,"monero":{"wallet_address":"fixture-wallet"},"dashboard":{"energy":{"cost_per_kwh":0.2}}}\n\n' >config.json
    cp -p config.json "$root/original.json"
    printf '%s\n' '{"config_version":"2.0.0","monero":{"wallet_address":"reference-wallet"},"tari":{"wallet_address":"reference-placeholder"},"dashboard":{"energy":{"cost_per_kwh":0.0}}}' >config.reference.json
    if [ "$fault" = baseline-unstamped ] || [ "$fault" = baseline-invalid ]; then
        if [ "$fault" = baseline-invalid ]; then
            jq '.config_version="malformed-version"' config.json >next.json
        else
            jq 'del(.config_version)' config.json >next.json
        fi
        mv next.json config.json
        cp config.json "$root/original.json"
    fi
    if [ "$fault" = wallet-fields ]; then
        jq '.monero += {view_key:"monero-view",payout_scan_height:123,payout_wallet:"monero-payout"} | .tari={wallet_address:"tari-wallet",view_key:"tari-view",spend_public_key:"tari-spend",payout_scan_birthday:456} | .xvb={donor_id:"fixture-donor"}' config.json >next.json
        mv next.json config.json
        cp config.json "$root/original.json"
        jq '.monero += {view_key:"",payout_scan_height:0,payout_wallet:""} | .tari += {view_key:"",spend_public_key:"",payout_scan_birthday:0} | .xvb={donor_id:"auto"}' config.reference.json >next.json
        mv next.json config.reference.json
    fi
    if [[ "$fault" == wallet-loss* ]]; then
        jq --arg fault "$fault" '.monero.hidden_payout = (if $fault == "wallet-loss-null" then null elif $fault == "wallet-loss-false" then false else "fixture-payout" end)' config.json >next.json
        mv next.json config.json
        cp config.json "$root/original.json"
    fi
    # shellcheck disable=SC2034
    IT_FAIL=0 IT_PASS=0 OUT_DIR="$root/artifacts"
    rx() {
        case "$1" in
        'cat config.json')
            [ "$fault" != snapshot ] || return 1
            cat config.json
            ;;
        'cat config.reference.json') [ "$fault" != reference ] && cat config.reference.json ;;
        'sha256sum config.json') shasum -a 256 config.json ;;
        'umask 077; cat >config.json')
            calls=$((calls + 1))
            if [ "$fault:$calls" = partial-copy:1 ]; then
                head -c 5 >config.json
                return 1
            fi
            if [ "$fault:$calls" = cleanup-copy:2 ] || [ "$fault:$calls" = cleanup-final-copy:3 ]; then return 1; fi
            cat >config.json
            if [ "$fault:$calls" = cleanup-bytes:3 ]; then printf '\n' >>config.json; fi
            ;;
        *) return 127 ;;
        esac
    }
    pithead() {
        printf '%s\n' "$1" >>"$root/commands"
        if [ "$calls" -eq 1 ] && [ "$1" = apply ]; then
            [ "$fault" != apply ] || return 1
            [ "$fault" != apply-stamp ] || return 0
            jq '.config_version="2.0.0"' config.json >next.json && mv next.json config.json
        elif [ "$calls" -ge 2 ]; then
            [ "$fault:$1" != cleanup-apply:apply ] || return 1
            [ "$fault:$1" != cleanup-up:up ] || return 1
            if [ "$1" = apply ] && jq -e '.config_version != "9.9.9"' config.json >/dev/null; then
                jq '.config_version="2.0.0"' config.json >next.json && mv next.json config.json
            fi
        fi
        [ "$fault:$1" != cleanup-down:down ]
    }
    upgrade_secret_fingerprints() {
        if [ "$fault" = snapshot-secrets ]; then return 1; fi
        if [ "$fault" = cleanup-secrets ] && [ "$calls" -ge 2 ]; then printf changed; else printf original; fi
    }
    wait_status_ok() { [ "$fault" != cleanup-health ]; }
    run_reset_restore_fixture() {
        jq -e '.config_version == "2.0.0" and (has("future") | not) and .monero.wallet_address == "fixture-wallet"' config.json >/dev/null || return 1
        if [ "$fault" = wallet-fields ]; then
            jq -e '.monero.view_key == "monero-view" and .monero.payout_scan_height == 123 and .monero.payout_wallet == "monero-payout" and .tari.wallet_address == "tari-wallet" and .tari.view_key == "tari-view" and .tari.spend_public_key == "tari-spend" and .tari.payout_scan_birthday == 456 and .xvb.donor_id == "fixture-donor"' config.json >/dev/null || return 1
        else
            jq -e 'has("tari") | not' config.json >/dev/null || return 1
        fi
        python3 -c 'import os, stat, sys; sys.exit(any(stat.S_IMODE(os.stat(os.path.join(sys.argv[1], name)).st_mode) != 0o700 for name in os.listdir(sys.argv[1])))' "$TMPDIR" || return 1
        python3 -c 'import os, stat, sys; sys.exit(any(stat.S_IMODE(os.stat(os.path.join(folder, name)).st_mode) != 0o600 for folder, _, names in os.walk(sys.argv[1]) for name in names))' "$TMPDIR" || return 1
        cp config.json "$root/archive.json"
        printf 'synthetic restore reached startup\n'
        [ "$fault" != probe ]
    }
    mktemp() { [ "$fault" != scratch ] && command mktemp "$@"; }
    local mask_before
    mask_before=$(umask)
    run_reset_restore >"$root/output" 2>&1
    rc=$?
    [ "$(umask)" = "$mask_before" ] || exit 1
    if [ "$fault" = none ] || [ "$fault" = wallet-fields ] || [ "$fault" = baseline-unstamped ] || [ "$fault" = baseline-invalid ]; then
        [ "$rc" -eq 0 ] && [ "$IT_FAIL" -eq 0 ] || {
            cat "$root/output"
            exit 1
        }
        cmp -s config.json "$root/original.json" || exit 1
        [ -f "$root/archive.json" ] || exit 1
        if [ "$fault" = baseline-unstamped ] || [ "$fault" = baseline-invalid ]; then
            jq -e '.baseline_version == null' "$root/artifacts/reset-restore.fixture.json" >/dev/null || exit 1
        else
            jq -e '.baseline_version == "9.9.9"' "$root/artifacts/reset-restore.fixture.json" >/dev/null || exit 1
        fi
        jq -e '.candidate_version == "2.0.0" and .fixture_version == "2.0.0"' "$root/artifacts/reset-restore.fixture.json" >/dev/null || exit 1
        [ -z "$(ls -A "$TMPDIR")" ] || exit 1
        [ "$(cat "$root/commands")" = $'apply\ndown\napply\nup' ] || exit 1
    else
        [ "$rc" -ne 0 ] || exit 1
        [ "$fault" != apply-stamp ] || [ ! -e "$root/artifacts/reset-restore.fixture.json" ] || exit 1
        case "$fault" in
        cleanup-*)
            find "$TMPDIR" -name original.json -exec cmp -s {} "$root/original.json" \; -print | grep -q . || exit 1
            grep -q 'private recovery copy retained' "$root/output" || exit 1
            ;;
        scratch | snapshot | snapshot-secrets | reference | wallet-loss*)
            cmp -s config.json "$root/original.json" || exit 1
            [ ! -e "$root/commands" ] || exit 1
            ;;
        *) cmp -s config.json "$root/original.json" || exit 1 ;;
        esac
    fi
)

case_fixture baseline-invalid && it_pass "an invalid baseline stamp is restored exactly and records a null version" ||
    it_fail "an invalid baseline stamp is restored exactly and records a null version" "invalid baseline fixture failed"
case_fixture baseline-unstamped && it_pass "an unstamped baseline has an explicit null version receipt" ||
    it_fail "an unstamped baseline has an explicit null version receipt" "unstamped fixture failed"
case_fixture wallet-fields && it_pass "synthetic recovery preserves both wallets, keys, scan fields and donor identity" ||
    it_fail "synthetic recovery preserves both wallets, keys, scan fields and donor identity" "wallet fields changed"
case_fixture none && it_pass "newer baseline uses a candidate-stamped synthetic archive and returns exact original bytes" ||
    it_fail "newer baseline uses a candidate-stamped synthetic archive and returns exact original bytes" "fixture contract failed"
for fault in scratch snapshot snapshot-secrets reference wallet-loss wallet-loss-null wallet-loss-false partial-copy apply apply-stamp probe cleanup-copy cleanup-final-copy cleanup-down cleanup-apply cleanup-up cleanup-health cleanup-bytes cleanup-secrets; do
    case_fixture "$fault" && it_pass "reset fixture handles $fault without accepting unverified cleanup" ||
        it_fail "reset fixture handles $fault without accepting unverified cleanup" "failure control failed"
done
[ "$IT_FAIL" -eq 0 ]
