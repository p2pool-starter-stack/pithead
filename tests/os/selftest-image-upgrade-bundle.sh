#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
mkdir "$td/bin"
printf '%s\n' '#!/bin/sh' 'case "$1" in pull) exit 0;; image) printf "%s@sha256:%064d\n" "${5%:*}" 1;; esac' >"$td/bin/docker"
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
tar -xOf "$td/candidate.tar.gz" pithead/docker-compose.yml | grep -Eq 'pithead-(tor|monero|p2pool|xmrig-proxy|dashboard):\$\{STACK_VERSION:-dev\}@sha256:[0-9a-f]{64}' || {
    echo "candidate images are not digest pinned" >&2
    exit 1
}
tar -xOf "$td/candidate.tar.gz" pithead/docker-compose.yml | grep -Fq 'registry.test/pithead-dashboard:' || {
    echo "candidate registry is not self-contained" >&2
    exit 1
}
cmp -s cosign.pub <(tar -xOf "$td/candidate.tar.gz" pithead/cosign.pub) || {
    echo "candidate image trust root changed" >&2
    exit 1
}
echo "selftest-image-upgrade-bundle: PASS"
