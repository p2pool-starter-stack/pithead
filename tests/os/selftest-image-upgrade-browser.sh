#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

node --check "$HERE/image-upgrade-browser.mjs"
node --check "$HERE/image-upgrade-browser-host.mjs"
node "$HERE/image-upgrade-browser.mjs" --self-test
node "$HERE/image-upgrade-browser-host.mjs" --self-test
grep -Eq 'ignoreHTTPSErrors|ignore-certificate-errors|Security\.setIgnoreCertificateErrors' "$HERE/image-upgrade-browser.mjs" && exit 1
grep -Eq 'image-upgrade-browser\.mjs.*DASH_(USER|PASS)' "$HERE/image-upgrade-certificate-leg.sh" && exit 1
grep -Fq 'child.stdin.end(credentials)' "$HERE/image-upgrade-browser-host.mjs"
grep -Fq "\`\${work}:/work\`" "$HERE/image-upgrade-browser-host.mjs"
grep -Fq "\`\${key}:" "$HERE/image-upgrade-browser-host.mjs" && exit 1
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
