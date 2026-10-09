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
    [ -s "$DOCTOR_TIP_HIT" ] # A remote/skipped Monero check is not proof.
    if [ "$format" = json ]; then
        jq -e '[.checks[] | select(.message | startswith("monerod peers:"))] |
            length == 1 and .[0].status == "ok" and
            (.[0].message | contains("last block") | not)' "$scratch/output" >/dev/null
    else
        grep -F 'monerod peers:' "$scratch/output" >"$scratch/peers"
        [ "$(wc -l <"$scratch/peers")" -eq 1 ]
        grep -Fq OK "$scratch/peers"
        ! grep -Fq 'last block' "$scratch/peers"
    fi
    printf 'doctor-tip-time: %s zero timestamp has no age or stale warning\n' "$format"
done
