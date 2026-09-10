#!/usr/bin/env bash
# End-to-end checks for the log excerpt tool, using synthetic logs only.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sanitize="$root/scripts/sanitize-test-log.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

{
    printf '\033[31mERROR early failure\033[0m\n'
    printf '\033]0;hidden title\007visible title line\n'
    printf '\033]8;;https://example.invalid\033\\visible link\033]8;;\033\\\n'
    printf 'progress\rnext\033[2K done\n'
    for ((i = 5; i <= 2000; i++)); do printf 'build step %s\n' "$i"; done
    printf 'FATAL final failure\n'
    printf '%10000s\n' end
} >"$tmp/raw"
cp "$tmp/raw" "$tmp/original"
bash "$sanitize" --lines 24 --width 80 "$tmp/raw" >"$tmp/out"
cmp "$tmp/raw" "$tmp/original"
grep -q 'ERROR early failure' "$tmp/out"
grep -q 'FATAL final failure' "$tmp/out"
grep -q 'visible title line' "$tmp/out"
grep -q 'visible link' "$tmp/out"
! grep -q 'hidden title\|https://example.invalid' "$tmp/out"
! LC_ALL=C grep -q $'\033\|\r' "$tmp/out"
grep -q 'omitted; long lines clipped' "$tmp/out"
[ "$(wc -l <"$tmp/out")" -le 29 ]
awk 'length > 100 { exit 1 }' "$tmp/out"
bash "$sanitize" --lines 24 --width 80 <"$tmp/raw" >"$tmp/stdin"
cmp "$tmp/out" "$tmp/stdin"
printf 'unterminated' | bash "$sanitize" >"$tmp/partial"
grep -q '1 input lines' "$tmp/partial"
bash "$sanitize" </dev/null >"$tmp/empty"
grep -q '0 input lines' "$tmp/empty"
if bash "$sanitize" --lines 0 >/dev/null 2>&1; then exit 1; fi
if bash "$sanitize" --width nope >/dev/null 2>&1; then exit 1; fi
if bash "$sanitize" "$tmp/missing" >/dev/null 2>&1; then exit 1; fi
echo 'log sanitizer: PASS (controls, bounded output, retained failures, stdin, input preservation, errors)'
