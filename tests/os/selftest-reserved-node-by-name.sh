#!/usr/bin/env bash
# Tier-1 driver for the #2351 by-name leg's run/skip guard, matched by the `tests/os/selftest*.sh`
# glob. A wrong guard is silent in the battery: a dotted glob shipped first and swallowed genuine
# names (`10.0.0.5.nip.io`), which would have skipped the by-name proof forever.
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/reserved-node-by-name-leg.sh" --self-test || {
    echo "selftest-reserved-node-by-name: FAIL" >&2
    exit 1
}
echo "selftest-reserved-node-by-name: PASS"
