#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

node --check "$HERE/image-upgrade-browser.mjs"
node "$HERE/image-upgrade-browser.mjs" --self-test
host_test_tmp=$(mktemp -d)
trap 'rm -rf "$host_test_tmp"' EXIT
real_python=$(command -v python3)
printf '%s\n' '#!/bin/sh' 'exit 99' >"$host_test_tmp/node"
chmod 0700 "$host_test_tmp/node"
ln -s "$real_python" "$host_test_tmp/python3"
env -u TMPDIR PATH="$host_test_tmp:/usr/bin:/bin" PYTHONPYCACHEPREFIX="$host_test_tmp/pycache" \
    python3 -m py_compile "$HERE/image-upgrade-browser-host.py"
env -u TMPDIR PATH="$host_test_tmp:/usr/bin:/bin" \
    python3 "$HERE/image-upgrade-browser-host.py" --self-test
rm -rf "$host_test_tmp"
trap - EXIT
grep -Eq 'ignoreHTTPSErrors|ignore-certificate-errors|Security\.setIgnoreCertificateErrors' "$HERE/image-upgrade-browser.mjs" && exit 1
grep -Eq 'image-upgrade-browser\.mjs.*DASH_(USER|PASS)' "$HERE/image-upgrade-certificate-leg.sh" && exit 1
grep -Fq "python3 \"\$SCRIPT_DIR/image-upgrade-browser-host.py\"" "$HERE/image-upgrade-certificate-leg.sh"
grep -Fq 'process.stdin.write(credentials.encode("utf-8"))' "$HERE/image-upgrade-browser-host.py"
grep -Fq 'f"{work}:/work"' "$HERE/image-upgrade-browser-host.py"
grep -Fq 'f"{key}:' "$HERE/image-upgrade-browser-host.py" && exit 1
for required in \
    'const credentials = JSON.parse' \
    'assert.rejects(page.goto(origin), /ERR_CERT_AUTHORITY_INVALID/)' \
    'page.locator("#proceed-link").click()' \
    'name: "Check now"' \
    'name: "Download"' \
    'name: "Install"' \
    'name: "Reboot now"' \
    'assert.deepEqual(after.sans, before.sans)' \
    'assert.equal(after.fingerprint, before.fingerprint)' \
    'assert.equal(after.key, before.key)'; do
    grep -Fq "$required" "$HERE/image-upgrade-browser.mjs"
done

# shellcheck source=tests/os/image-upgrade-certificate-leg.sh
source "$HERE/image-upgrade-certificate-leg.sh"
message=""
bad() { message="$1"; }
have() { return 1; }
image_upgrade_certificate_continuity_leg
[ "$message" = "image-upgrade certificate continuity requires Docker for the pinned browser runtime" ]
printf 'selftest-image-upgrade-browser: PASS\n'
