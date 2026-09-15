#!/usr/bin/env bash
# Self-test for verify-image.sh's fail-closed package-absence check (#1380).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/os/verify-image-artifact-helpers.sh
source "$HERE/../../os/verify-image-artifact-helpers.sh"

echo "== verify-image: unwanted packages must be absent from valid dpkg metadata (#1380) =="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check() { # <name> <root> <want-rc>
    local name="$1" root="$2" want="$3" got
    package_absent "$root" xxd
    got=$?
    if [ "$got" = "$want" ]; then it_pass "$name"; else it_fail "$name" "want rc=$want, got rc=$got"; fi
}

mkdir -p "$TMP/absent/var/lib/dpkg"
printf 'Package: jq\nStatus: install ok installed\nDescription: JSON processor\n continuation line\n' >"$TMP/absent/var/lib/dpkg/status"
check "another installed package does not mask xxd absence" "$TMP/absent" 0

mkdir -p "$TMP/present/var/lib/dpkg"
printf 'Package: xxd\nStatus: install ok installed\n' >"$TMP/present/var/lib/dpkg/status"
check "an installed xxd package is rejected" "$TMP/present" 1

mkdir -p "$TMP/malformed/var/lib/dpkg"
printf 'Package: jq\nStatus: install ok installed\nnot a status field\n' >"$TMP/malformed/var/lib/dpkg/status"
check "malformed status metadata is rejected, not mistaken for absence" "$TMP/malformed" 1

echo "selftest-verify-image-package-absence: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
