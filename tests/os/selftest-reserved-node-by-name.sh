#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/reserved-node-by-name-leg.sh" --self-test || {
    echo "selftest-reserved-node-by-name: FAIL" >&2
    exit 1
}
echo "selftest-reserved-node-by-name: PASS"
