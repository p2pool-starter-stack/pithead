# shellcheck shell=bash
: "${STACK_SUITE:?is unset: run tests/stack/run.sh}"

echo "== unit: payout address rejection messages and retries =="
WA="$SANDBOX/wizard-addresses"
mkdir -p "$WA/retry"
printf '%s\n' "$VALID_SUBADDR" "$VALID_INTEGRATED" "${VALID_PRIMARY:0:50}B${VALID_PRIMARY:51}" \
    garbage "$VALID_PRIMARY" '' 2 "${VALID_TARI:0:90}B" \
    f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb \
    garbage "$VALID_TARI" nano '' none '' '' '' '' |
    run_sourced "$WA/retry" run_wizard >"$WA/retry/stdout" 2>"$WA/retry/stderr"
assert_rc "wizard saves after all address retries" "$?" 0
wa_err=$(cat "$WA/retry/stderr")
wa_out=$(cat "$WA/retry/stdout")
for wa_message in \
    "That's a subaddress (8…)" \
    "That's an integrated address" \
    "Checksum failed — at least one character is mistyped. Re-copy the address from your wallet." \
    "Not a valid Monero primary address (95 chars, starts with 4). Try again." \
    "Checksum failed — at least one character is mistyped. Re-copy the address from your Tari wallet." \
    "That address is for a Tari testnet — this stack mines MAINNET Tari." \
    "Not a valid Tari address (base58 or emoji form). Try again."; do
    assert_contains "address rejection is on stderr: $wa_message" "$wa_err" "$wa_message"
    assert_not_contains "address rejection is absent from stdout: $wa_message" "$wa_out" "$wa_message"
done
wa_cfg=$(cat "$WA/retry/config.json" 2>/dev/null)
assert_eq "retry saves the valid Monero primary" "$(jq -r '.monero.wallet_address' <<<"$wa_cfg")" "$VALID_PRIMARY"
assert_eq "retry saves the valid Tari mainnet address" "$(jq -r '.tari.wallet_address' <<<"$wa_cfg")" "$VALID_TARI"
assert_eq "retries leave the following pool answer aligned" "$(jq -r '.p2pool.pool' <<<"$wa_cfg")" nano

echo "== unit: payout EOF aborts without creating or replacing config =="
for wa_chain in monero tari; do
    for wa_eof in empty rejected partial valid-partial; do
        for wa_existing in absent present; do
            wa_dir="$WA/$wa_chain-$wa_eof-$wa_existing"
            mkdir -p "$wa_dir"
            printf '{ "preserve": "existing configuration" }\n\n' >"$wa_dir/original"
            [ "$wa_existing" = absent ] || cp "$wa_dir/original" "$wa_dir/config.json"
            {
                [ "$wa_chain" = monero ] || printf '%s\n\n2\n' "$VALID_PRIMARY"
                case "$wa_eof" in
                empty) : ;;
                rejected) printf 'garbage\n' ;;
                partial) printf garbage ;;
                valid-partial)
                    if [ "$wa_chain" = monero ]; then printf '%s' "$VALID_PRIMARY"; else printf '%s' "$VALID_TARI"; fi
                    ;;
                esac
            } | run_sourced "$wa_dir" run_wizard >"$wa_dir/stdout" 2>"$wa_dir/stderr"
            assert_rc "$wa_chain $wa_eof EOF ($wa_existing config) aborts" "$?" 1
            assert_contains "$wa_chain $wa_eof EOF explains the abort" "$(cat "$wa_dir/stderr")" "Aborting."
            if [ "$wa_existing" = present ]; then
                cmp -s "$wa_dir/original" "$wa_dir/config.json"
                assert_rc "$wa_chain $wa_eof EOF preserves existing config bytes" "$?" 0
            elif [ ! -e "$wa_dir/config.json" ]; then
                ok "$wa_chain $wa_eof EOF creates no config"
            else
                bad "$wa_chain $wa_eof EOF creates no config" "config.json was written"
            fi
        done
    done
done
unset WA wa_err wa_out wa_message wa_cfg wa_chain wa_eof wa_existing wa_dir
