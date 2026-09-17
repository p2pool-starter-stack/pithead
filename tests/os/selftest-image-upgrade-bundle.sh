#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
mkdir "$td/bin"
REAL_TAR="$(command -v tar)"
TAR_CALL_COUNT="$td/tar-call-count"
export REAL_TAR
export TAR_CALL_COUNT
printf '%s\n' '#!/bin/sh' 'case "$1" in pull) [ "${FAIL_IMAGE_PULL:-0}" = 0 ] || exit 23;; image) printf "%s@sha256:%064d\n" "${5%:*}" 1;; esac' >"$td/bin/docker"
printf '%s\n' '#!/bin/sh' \
    'case " $* " in *" --use-signing-config=false "*) ;; *) exit 24;; esac' \
    'case " $* " in *" --tlog-upload=false "*) ;; *) exit 24;; esac' \
    'output= source=' \
    'while [ "$#" -gt 0 ]; do case "$1" in --output-signature) output=$2; shift 2;; *) source=$1; shift;; esac; done' \
    'cp "$source" "$output"' >"$td/bin/cosign"
printf '%s\n' '#!/bin/sh' \
    'if [ "$1" = --no-xattrs ]; then count=$(cat "$TAR_CALL_COUNT" 2>/dev/null || echo 0); count=$((count + 1)); printf "%s\n" "$count" >"$TAR_CALL_COUNT"; [ "${FAIL_REPACK:-0}" != 1 ] || [ "$count" != 2 ] || { printf "must-not-leak\n" >&2; exit 25; }; fi' \
    'exec "$REAL_TAR" "$@"' >"$td/bin/tar"
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
repack_rc=0
rm -f "$TAR_CALL_COUNT"
repack_out="$(FAIL_REPACK=1 REAL_TAR="$REAL_TAR" TAR_CALL_COUNT="$TAR_CALL_COUNT" PATH="$td/bin:$PATH" PITHEAD_REGISTRY=registry.test \
    "$HERE/image-upgrade-bundle.sh" "$td/repack-failed.tar.gz" \
    0123456789abcdef0123456789abcdef01234567 "$td/key" 2>&1)" || repack_rc=$?
[ "$repack_rc" -eq 25 ] &&
    grep -F 'sub-step=candidate-bundle command="tar -czf <candidate-bundle>" exit=25' <<<"$repack_out" >/dev/null || {
    echo "candidate bundle did not attribute a repack failure" >&2
    exit 1
}
if grep -F 'must-not-leak' <<<"$repack_out" >/dev/null || grep -F "$td/key" <<<"$repack_out" >/dev/null; then
    echo "candidate repack failure exposed command output or key input" >&2
    exit 1
fi
echo "selftest-image-upgrade-bundle: PASS"
