#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/journal-boot-verdict.sh
. "$HERE/journal-boot-verdict.sh"

must_pass() {
    if ! "$@" >/dev/null; then
        echo "rejected: $*" >&2
        exit 1
    fi
}
must_fail() {
    if "$@" >/dev/null 2>&1; then
        echo "accepted: $*" >&2
        exit 1
    fi
}

must_pass journal_config_verdict persistent 200M active
must_fail journal_config_verdict auto 200M active
must_fail journal_config_verdict volatile 200M active
must_fail journal_config_verdict persistent missing active
must_fail journal_config_verdict persistent 50% active
must_fail journal_config_verdict persistent 200M failed
must_fail journal_config_verdict "" "" ""

[ "$(journal_cap_kib 200M)" = "204800" ]
[ "$(journal_cap_kib 1024)" = "1" ]
[ "$(journal_cap_kib 1K)" = "1" ]
[ "$(journal_cap_kib 1G)" = "1048576" ]
cap_refused() {
    if journal_cap_kib "$1" >/dev/null 2>&1; then
        echo "cap accepted: $1" >&2
        exit 1
    fi
}
cap_refused 50%
cap_refused ""
cap_refused missing
cap_refused garbage

out=$(journal_window_verdict 0 1048576 3600 204800 100)
[ "$?" -eq 0 ]
case "$out" in *"journal measurement (boot load):"*1048576\ bytes*204800\ KiB*100\ s*) : ;; *)
    echo "measurement text: $out" >&2
    exit 1
    ;;
esac
out=$(journal_window_verdict 1048576 1085440 420 204800 100 "settled idle load")
[ "$?" -eq 0 ]
case "$out" in *"journal measurement (settled idle load):"*36864\ bytes*420\ s*) : ;; *)
    echo "settled text: $out" >&2
    exit 1
    ;;
esac
must_pass journal_window_verdict 10485760 104857600 60 204800 0
must_pass journal_window_verdict 1000 1049576 3600 204800 -1
must_pass journal_window_verdict 1000 1049576 3600 204800 ""
must_fail journal_window_verdict 1000 1000 3600 204800 100
must_fail journal_window_verdict 1000 999 300 204800 100
must_fail journal_window_verdict x 1100 300 204800 100
must_fail journal_window_verdict 1000 x 300 2048576 0
must_fail journal_window_verdict 1000 1100 0 204800 100
must_fail journal_window_verdict 1000 1100 300 0 100

must_pass journal_boot_verdict 1 1 5
must_fail journal_boot_verdict 1 2 5
must_fail journal_boot_verdict 1 1 0
must_fail journal_boot_verdict a b c

must_pass journal_home_verdict '/var/log/journal 42
42
xfs
yes
2'
must_fail journal_home_verdict '/var 7
42
overlay
yes
2'
must_fail journal_home_verdict '/var/log/journal 7
42
xfs
yes
2'
must_fail journal_home_verdict '/var/log/journal 42
42
xfs
no
2'
must_fail journal_home_verdict '/var/log/journal 42
42
xfs
yes
1'
must_fail journal_home_verdict 'junk junk
junk
?
no
?'

echo "selftest-journal-boot-verdict: ok"
