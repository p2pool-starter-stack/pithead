#!/usr/bin/env bash
#
# Self-test for #3445: the harness keeps the newest PITHEAD_E2E_BACKUP_KEEP plaintext safety
# backups, always keeps the archive just written, and never touches foreign names.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/backup-prune.sh
source "$HERE/../lib/backup-prune.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkbackups() { # <dir> <count>
    local i
    rm -rf "$1" && mkdir -p "$1"
    for i in $(seq 1 "$2"); do : >"$1/$(printf 'pithead-backup-20260101-%06d.tar.gz' "$i")"; done
    : >"$1/pithead-backup-20250101-000001.tar.gz.enc"
    : >"$1/pithead-backup-chains-20250101-000001.tar.gz"
    : >"$1/notes.txt"
}
run() { bash -c "$1"; }
count() { ls -1 "$1" | grep -cE '^pithead-backup-[0-9]{8}-[0-9]{6}\.tar\.gz$'; }

echo "== backup_prune keeps the newest N =="
mkbackups "$T/b" 15
out="$(backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000015.tar.gz")"
assert_eq "15 archives rotate down to 10" "$(count "$T/b")" "10"
assert_contains "the removed count is logged" "$out" "pruned 5 old safety backup(s)"
assert_eq "the newest survived" "$(test -f "$T/b/pithead-backup-20260101-000015.tar.gz" && echo y)" "y"
assert_eq "the oldest went" "$(test -e "$T/b/pithead-backup-20260101-000001.tar.gz" && echo y || echo n)" "n"
assert_eq "foreign names are untouched" "$(ls -1 "$T/b" | grep -vcE '^pithead-backup-[0-9]{8}-[0-9]{6}\.tar\.gz$')" "3"

echo "== a protected archive outside the newest N is kept =="
mkbackups "$T/b" 15
backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000002.tar.gz" >/dev/null
assert_eq "the protected archive survived" "$(test -f "$T/b/pithead-backup-20260101-000002.tar.gz" && echo y)" "y"
assert_eq "N newest plus the protected one remain" "$(count "$T/b")" "11"

echo "== knobs =="
mkbackups "$T/b" 15
PITHEAD_E2E_BACKUP_KEEP=3 backup_prune run "$T/b" "" >/dev/null
assert_eq "KEEP=3 keeps three" "$(count "$T/b")" "3"
mkbackups "$T/b" 15
PITHEAD_E2E_BACKUP_KEEP=0 backup_prune run "$T/b" "" >/dev/null
assert_eq "KEEP=0 disables pruning" "$(count "$T/b")" "15"
PITHEAD_E2E_BACKUP_KEEP=abc backup_prune run "$T/b" "" >/dev/null
assert_eq "a non-number falls back to 10" "$(count "$T/b")" "10"

echo "== a failed backup is never pruned =="
mkbackups "$T/b" 15
assert_eq "run-safety prunes only after the archive is located" \
    "$(grep -B1 'backup_prune' "$HERE/../lib/run-safety.sh" | grep -c 'Safety backup: ')" "1"
assert_eq "run-lifecycle prunes only inside the successful-backup branch" \
    "$(grep -B3 'backup_prune' "$HERE/../lib/run-lifecycle.sh" | grep -c 'if \[ -n "\$arch" \]')" "1"
assert_eq "e2e backup_stack prunes only after the archive is located" \
    "$(sed -n '/^backup_stack() {$/,/^}$/p' "$HERE/../e2e.sh" | grep -A1 'ok "safety backup:' | tail -n1 | grep -c backup_prune)" "1"

printf '\nbackup-prune self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
