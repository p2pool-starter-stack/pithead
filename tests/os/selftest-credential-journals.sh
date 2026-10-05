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
