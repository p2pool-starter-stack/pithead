#!/usr/bin/env bash
# Tier-1 driver for the #2060 row payloads. Matched by `make test-integration-selftest`'s
# `tests/os/selftest*.sh` glob, so it runs in `make test` without a KVM guest.
#
# Two of the helpers have no other tier-1 driver: the approval one because the leg that consumes
# it (tests/os/appliance-config-approval-leg.sh) is at its recorded file budget, and the bundle one
# because it is a new file. The hostname, control-runner and doctor payloads are driven by their
# own legs' --self-test, already wired in tests/stack/test-harness-tooling.sh.
#
# Enumerated by name rather than by glob: a glob that stops matching and a suite with nothing to
# run print the same nothing, and this file exists because a row that says nothing is the defect.
# A name that no longer resolves is bash's own rc 127, which `|| rc=1` already fails on.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in appliance-approval-verdict.sh bundle-build-evidence.sh; do
    bash "$HERE/$t" --self-test || rc=1
done
[ "$rc" -eq 0 ] && echo "selftest-row-payloads: PASS"
exit "$rc"
