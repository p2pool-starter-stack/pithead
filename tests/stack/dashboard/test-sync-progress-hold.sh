# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: status holds the miner only on the dashboard's global syncing gate (#3351) =="
# `pithead status` must agree with /api/state.syncing: a Tari row stuck at "loading" while Tari is
# off (TARI_REQUIRED=false) is passive and never reads as a miner hold.
mk_tmpdir SH
mkdir -p "$SH/bin"
cat >"$SH/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s' "$CURL_BODY"
CURL
chmod +x "$SH/bin/curl"
sh_tari_off='{"syncing":false,"sync":{"monero":{"state":"done"},"tari":{"state":"loading","percent":0,"current":0,"target":0,"remaining":0}}}'
assert_eq "tari loading with syncing=false -> no hold message" \
    "$(CURL_BODY="$sh_tari_off" PATH="$SH/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)" ""
sh_mixed='{"syncing":true,"sync":{"monero":{"state":"syncing","percent":42,"current":100,"target":238,"remaining":138},"tari":{"state":"loading"}}}'
printf 'TARI_REQUIRED=false\n' >"$SH/env"
out="$(PITHEAD_ENV_FILE="$SH/env" CURL_BODY="$sh_mixed" PATH="$SH/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)"
assert_contains "monero syncing still holds" "$out" "held until it completes"
assert_not_contains "non-required tari row is not listed" "$out" "tari"
printf 'TARI_REQUIRED=true\n' >"$SH/env"
out="$(PITHEAD_ENV_FILE="$SH/env" CURL_BODY="$sh_mixed" PATH="$SH/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)"
assert_contains "required tari row is listed" "$out" "tari"
cat >"$SH/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CURL_ARGS"
cat >"$CURL_STDIN"
CURL
printf 'DASHBOARD_PROXY_SECRET=0123abcd\n' >"$SH/env"
PITHEAD_ENV_FILE="$SH/env" CURL_ARGS="$SH/args" CURL_STDIN="$SH/stdin" PATH="$SH/bin:$PATH" run_sourced "$SANDBOX" dashboard_state 3 >/dev/null 2>&1
assert_eq "dashboard_state sends the proxy secret from .env as a header on stdin" "$(cat "$SH/stdin")" 'X-Pithead-Proxy-Secret: 0123abcd'
assert_not_contains "dashboard_state keeps the proxy secret off curl's arguments" "$(cat "$SH/args")" "0123abcd"
assert_contains "dashboard_state reads the app's state route" "$(cat "$SH/args")" "--header @- http://127.0.0.1:8000/api/state"
assert_eq "dashboard_state is the CLI's only reader of the app's state route" \
    "$(grep -ro 'http://127\.0\.0\.1:8000/api/state' "$ROOT/lib/pithead" | wc -l | tr -d ' ')" "1"
rm -rf "$SH"
