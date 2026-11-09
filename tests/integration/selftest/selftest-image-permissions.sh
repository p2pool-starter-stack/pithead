#!/usr/bin/env bash
set -euo pipefail
echo "== image permission regression verdict controls =="
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=tests/integration/lib.sh
source "$ROOT/tests/integration/lib.sh"
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$ROOT/tests/integration/lib/run-source-image.sh"
OUT_DIR=$(mktemp -d)
trap 'rm -rf -- "$OUT_DIR"' EXIT
fixture_case=healthy
rx() {
    [ "$1" != 'test -f dashboard/Dockerfile' ] || return 0
    case "$1" in
    *c59e5ad6fc7c1fe82eb7558a2f962c18c1266299)
        [ "$fixture_case" != baseline-build-error ] || return 2
        [ "$fixture_case" = baseline-wrong-cause ] || echo 'FAIL: unreadable runtime file: /etc/tor/torrc.template'
        return 1
        ;;
    *' tor '*HEAD)
        [ "$fixture_case" != candidate-error ] || return 1
        echo 'PASS: tor runtime file permissions'
        ;;
    *' monero '*HEAD) echo 'PASS: monero runtime file permissions' ;;
    *' p2pool '*HEAD) echo 'PASS: p2pool runtime file permissions' ;;
    *' xmrig-proxy '*HEAD) echo 'PASS: xmrig-proxy runtime file permissions' ;;
    *' dashboard '*HEAD) echo 'PASS: dashboard runtime file permissions' ;;
    *) return 2 ;;
    esac
}
for fixture_case in healthy baseline-build-error baseline-wrong-cause candidate-error; do
    IT_FAIL=0
    result=0
    run_image_permissions >"$OUT_DIR/$fixture_case.log" 2>&1 || result=$?
    if [ "$fixture_case" = healthy ]; then
        [ "$result" = 0 ] && [ "$IT_FAIL" = 0 ]
    else
        [ "$result" != 0 ] && [ "$IT_FAIL" -gt 0 ]
    fi
done
echo 'PASS: image permission rows distinguish baseline permission failure, build errors and candidate failures'
