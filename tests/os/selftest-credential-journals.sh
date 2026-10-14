#!/usr/bin/env bash
# Pure fixture controls for the guest journal assertion; discovered by CI's selftest glob.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin"
cat >"$fixture_dir/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
scope=system
[[ "$*" != *pithead-firstboot* ]] || scope=firstboot
[ "$scope" != "${ERROR_SCOPE:-}" ] || exit 1
if [ "$scope" = "${EMPTY_SCOPE:-}" ]; then
    [[ "$*" == *--quiet* ]] || printf '%s\n' '-- No entries --'
    exit 0
fi
printf 'fixture journal: setup complete\n'
if [ "$scope" = "${LEAK_SCOPE:-}" ]; then
    printf 'fixture container: $2%s$14$%053d\n' "${BCRYPT_VARIANT:-y}" 0
fi
STUB
chmod +x "$fixture_dir/bin/journalctl"
export PATH="$fixture_dir/bin:$PATH"
bash "$HERE/credential-journals.sh"
for scope in firstboot system; do
    for variant in a b y; do
        if LEAK_SCOPE="$scope" BCRYPT_VARIANT="$variant" bash "$HERE/credential-journals.sh"; then
            echo "FAIL: $scope bcrypt $variant accepted"
            exit 1
        fi
    done
    if ERROR_SCOPE="$scope" bash "$HERE/credential-journals.sh"; then
        echo "FAIL: $scope read error accepted"
        exit 1
    fi
    if EMPTY_SCOPE="$scope" bash "$HERE/credential-journals.sh"; then
        echo "FAIL: $scope empty read accepted"
        exit 1
    fi
done
echo 'selftest-credential-journals: PASS (clean, six leaks, two errors, two empty reads)'

# Exercise the real narrow phase through fixture transports: dropping the journal
# invocation must fail even when all setup/authentication rows still succeed.
(
    OS_RUN_SUITE=1 SCRIPT_DIR="$HERE" SERIAL="$fixture_dir/serial" HARNESS_WALLET=fixture-wallet
    printf 'pit-FIXTUR\n' >"$SERIAL"
    # shellcheck source=tests/os/phases/setup-defaults.sh
    source "$HERE/phases/setup-defaults.sh"
    _build_image() { echo fixture-image; }
    _vm_boot_disk() { ip=fixture.invalid; }
    _wait_ssh() { :; }
    _wait_setup_page() { :; }
    _ssh() {
        case "$*" in
        'bash -s') bash -s ;;
        *'podman ps'*) echo 'caddy dashboard' ;;
        *'jq -e'*) return 0 ;;
        *) return 1 ;;
        esac
    }
    curl() {
        case "$*" in
        *'/api/wizard-state'*)
            printf '%s\n' '{"new_machine":true,"disk_budget":{"available_bytes":1,"local_need_bytes":2},"config":{"tari":{"mode":"off","clearnet_initial_sync":false},"xvb":{"enabled":false},"monero":{"clearnet_initial_sync":false}},"auth_mode":"auto"}'
            ;;
        *'/api/handoff') printf '{"password":"%032d"}\n' 0 ;;
        *'/submit'* | *'/handoff-ack'*) echo 200 ;;
        *'admin:'*) echo 200 ;;
        *'-w'*) echo 401 ;;
        *) return 0 ;;
        esac
    }
    journal_pass=0 journal_fail=0 other_fail=0
    ok() {
        [[ "$1" != *'journals'* ]] || journal_pass=$((journal_pass + 1))
        return 0
    }
    bad() {
        if [[ "$1" == *'journals'* || "$1" == *'journal contains'* ]]; then
            journal_fail=$((journal_fail + 1))
        else
            other_fail=$((other_fail + 1))
        fi
    }
    phase_setup_defaults
    [ "$journal_pass" -eq 1 ] && [ "$journal_fail" -eq 0 ] && [ "$other_fail" -eq 0 ]
    journal_pass=0 journal_fail=0
    export LEAK_SCOPE=system
    phase_setup_defaults
    [ "$journal_pass" -eq 0 ] && [ "$journal_fail" -eq 1 ] && [ "$other_fail" -eq 0 ]
)
echo 'selftest-credential-journals: PASS (setup-defaults checks clean and leaking guest journals)'
