#!/usr/bin/env bash
# Run inside the provisioned guest, after the generated login authenticates.
# Never echo a matched hash, and never treat a failed/empty journal read as clean.
set -euo pipefail
umask 077
journal_file=$(mktemp)
trap 'rm -f "$journal_file"' EXIT
for scope in firstboot system; do
    args=(--quiet --no-pager -o cat)
    [ "$scope" != firstboot ] || args+=(-u pithead-firstboot)
    journalctl "${args[@]}" >"$journal_file" || exit 1
    [ -s "$journal_file" ] || exit 1
    rc=0
    grep -qE '\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}' "$journal_file" || rc=$?
    [ "$rc" -eq 1 ] || exit 1
done
