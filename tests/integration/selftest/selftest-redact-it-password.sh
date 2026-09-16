#!/usr/bin/env bash
#
# Self-test for #2058's redaction backstop. IT_DASHBOARD_PASSWORD is the one credential in this
# harness that never renders onto the box (#379's Caddy-fronted /metrics leg carries it straight
# from the runner's environment to curl's stdin config) — so the KEY=value / JSON vocabulary
# selftest-redact.sh covers can never meet it: nothing captured off the box ever contains the
# string "IT_DASHBOARD_PASSWORD=...". The harness is instead the one place that holds the exact
# VALUE, so redact_it_password() (lib.sh) scrubs by literal match, independent of shape or key
# name, wired into both redact() (artifacts) and it_fail() (the console stream a bench-ci job
# captures as its log — tiers/pithead/tier4-e2e.sh tees it verbatim).
#
# A file rather than a line in selftest-redact.sh: that file sits near lint-file-budget.sh's
# 400-line target already (selftest-redact-vocab.sh split off for the same reason).
#
# Run: tests/integration/selftest/selftest-redact-it-password.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

SENTINEL='fixturesecret42"\tail' # matches selftest-curl-credentials.sh's fixture — punctuation on purpose

echo "== redact(): the literal value is scrubbed regardless of shape or key name =="
export IT_DASHBOARD_PASSWORD="$SENTINEL"
OUT="$(printf 'user = "fixture-user:%s"\n' "$SENTINEL" | redact)"
case "$OUT" in *"$SENTINEL"*) it_fail "curl -K auth line: raw password absent" "password leaked: $OUT" ;; *) it_pass "curl -K auth line: raw password absent" ;; esac

OUT="$(printf 'a bare mid-sentence mention of %s with no key prefix\n' "$SENTINEL" | redact)"
case "$OUT" in *"$SENTINEL"*) it_fail "unprefixed literal value absent" "password leaked: $OUT" ;; *) it_pass "unprefixed literal value absent" ;; esac

echo "== redact(): every BRE/sed-delimiter metacharacter in the password is escaped, not just &/\\ =="
# The literal-match sed builds its own pattern from the password at runtime (lib.sh), so a
# password containing a regex metacharacter must not (a) fail to match — leaving the raw value
# in the output — or (b) match something OTHER than itself. One password per metachar class.
for p in 'pass*word' 'pass[word]' 'a.b^c$d' 'sl/ash' 'back\slash'; do
    export IT_DASHBOARD_PASSWORD="$p"
    OUT="$(printf 'the secret is %s here\n' "$p" | redact)"
    case "$OUT" in
    *"$p"*) it_fail "metachar password '$p' redacted" "raw value survived: $OUT" ;;
    *"<redacted>"*) it_pass "metachar password '$p' redacted" ;;
    *) it_fail "metachar password '$p' redacted" "no marker either — pattern likely broke the sed command: $OUT" ;;
    esac
done
unset IT_DASHBOARD_PASSWORD

echo "== redact(): unset IT_DASHBOARD_PASSWORD is a no-op, nothing invented to redact =="
unset IT_DASHBOARD_PASSWORD
OUT="$(printf 'ordinary text unrelated to any credential\n' | redact)"
assert_eq "no password set: text passes through unchanged" "$OUT" "ordinary text unrelated to any credential"

echo "== it_fail(): the console stream a bench-ci job log captures is scrubbed too =="
export IT_DASHBOARD_PASSWORD="$SENTINEL"
# Command substitution runs it_fail in a subshell, so its own IT_FAIL bump never reaches ours —
# only OUT, its captured stdout, is what this file's own assertions below judge.
OUT="$(it_fail "hypothetical future leak" "response carried $SENTINEL in the clear")"
case "$OUT" in *"$SENTINEL"*) it_fail "it_fail detail: raw password absent from console output" "password leaked: $OUT" ;; *) it_pass "it_fail detail: raw password absent from console output" ;; esac
assert_contains "it_fail detail: a marker replaces it" "$OUT" "<redacted>"
unset IT_DASHBOARD_PASSWORD

echo "selftest-redact-it-password: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
