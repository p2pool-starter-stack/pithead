#!/usr/bin/env bash
# Read-only live-stack fault: only the last-block-header response is replaced.
set -euo pipefail
command_line=${1:?Pithead command required}
scratch=$(mktemp -d "${TMPDIR:?runner scratch required}/doctor-tip-time.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
export DOCTOR_TIP_CURL DOCTOR_TIP_HIT
DOCTOR_TIP_CURL=$(command -v curl)
DOCTOR_TIP_HIT=$scratch/hit
cat >"$scratch/curl" <<'CURL'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *'"method":"get_last_block_header"'* ]]; then
        printf '%s\n' '{"result":{"block_header":{"timestamp":0}}}'
        printf '%s\n' hit >>"$DOCTOR_TIP_HIT"
        exit 0
    fi
done
exec "$DOCTOR_TIP_CURL" "$@"
CURL
chmod +x "$scratch/curl"
for format in text json; do
    : >"$DOCTOR_TIP_HIT"
    args=""
    [ "$format" != json ] || args="--json"
    # Other doctor's checks may fail independently; grade only the asserted peer/tip check.
    PATH="$scratch:$PATH" bash -c "$command_line doctor $args" >"$scratch/output" 2>"$scratch/stderr" || true
    fail() { # <reason>: say why, so a red row is diagnosable
        printf 'doctor-tip-time: %s FAILED: %s\n--- stdout ---\n' "$format" "$1"
        head -c 4000 "$scratch/output"
        printf -- '--- stderr ---\n'
        head -c 2000 "$scratch/stderr"
        exit 1
    }
    [ -s "$DOCTOR_TIP_HIT" ] || fail "the faked last-block-header request was never made (remote or skipped Monero check)"
    # A node with no outbound peers legitimately warns about isolation; only the tip age is graded.
    if [ "$format" = json ]; then
        jq -e '[.checks[] | select(.message | startswith("monerod peers:"))] | length == 1' "$scratch/output" >/dev/null ||
            fail "expected exactly one monerod peers check in the JSON"
        jq -e '.checks[] | select(.message | startswith("monerod peers:")) |
            (.message | test("last block|s old") | not) and
            (.status == "ok" or (.message | startswith("monerod peers: 0 out")))' "$scratch/output" >/dev/null ||
            fail "the peers check carries a tip age or stale warning, or is not ok with peers"
    else
        grep -F 'monerod peers:' "$scratch/output" >"$scratch/peers" || fail "no monerod peers line"
        [ "$(wc -l <"$scratch/peers")" -eq 1 ] || fail "expected exactly one monerod peers line"
        ! grep -Eq 'last block|s old' "$scratch/peers" || fail "the peers line carries a tip age or stale warning"
        grep -Fq OK "$scratch/peers" || grep -Fq 'monerod peers: 0 out' "$scratch/peers" || fail "the peers line is not OK with peers"
    fi
    printf 'doctor-tip-time: %s zero timestamp has no age or stale warning\n' "$format"
done
