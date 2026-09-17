#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
mkdir "$td/bin"
printf '%s\n' '#!/bin/sh' 'case "$1" in pull) [ "${FAIL_IMAGE_PULL:-0}" = 0 ] || exit 23;; image) printf "%s@sha256:%064d\n" "${5%:*}" 1;; esac' >"$td/bin/docker"
printf '%s\n' '#!/bin/sh' 'cp "$8" "$7"' >"$td/bin/cosign"
chmod +x "$td/bin/"*
: >"$td/key"
PATH="$td/bin:$PATH" PITHEAD_REGISTRY=registry.test "$HERE/image-upgrade-bundle.sh" "$td/candidate.tar.gz" \
    0123456789abcdef0123456789abcdef01234567 "$td/key"
[ -s "$td/candidate.tar.gz.sig" ] || {
    echo "candidate signature missing" >&2
    exit 1
}
[ "$(tar -xOf "$td/candidate.tar.gz" pithead/PITHEAD_COMMIT)" = 0123456789abcdef0123456789abcdef01234567 ] || {
    echo "candidate commit missing" >&2
    exit 1
}
tar -xOf "$td/candidate.tar.gz" pithead/docker-compose.yml | grep -E 'pithead-(tor|monero|p2pool|xmrig-proxy|dashboard):\$\{STACK_VERSION:-dev\}@sha256:[0-9a-f]{64}' >/dev/null || {
    echo "candidate images are not digest pinned" >&2
    exit 1
}
tar -xOf "$td/candidate.tar.gz" pithead/docker-compose.yml | grep -F 'registry.test/pithead-dashboard:' >/dev/null || {
    echo "candidate registry is not self-contained" >&2
    exit 1
}
cmp -s cosign.pub <(tar -xOf "$td/candidate.tar.gz" pithead/cosign.pub) || {
    echo "candidate image trust root changed" >&2
    exit 1
}
failure_rc=0
failure_out="$(FAIL_IMAGE_PULL=1 PATH="$td/bin:$PATH" PITHEAD_REGISTRY=registry.test \
    "$HERE/image-upgrade-bundle.sh" "$td/failed.tar.gz" \
    0123456789abcdef0123456789abcdef01234567 "$td/key" 2>&1)" || failure_rc=$?
[ "$failure_rc" -ne 0 ] || {
    echo "candidate bundle accepted a failed image pull" >&2
    exit 1
}
grep -F 'sub-step=tag-or-digest-resolution command="docker pull <candidate-tag>" exit=23' <<<"$failure_out" >/dev/null || {
    echo "candidate bundle did not attribute tag/digest resolution failure" >&2
    exit 1
}
if grep -F "$td/key" <<<"$failure_out" >/dev/null; then
    echo "candidate bundle failure exposed key input path" >&2
    exit 1
fi
echo "selftest-image-upgrade-bundle: PASS"
