# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SANDBOX:?}"

SB="$SANDBOX/ctrl4036"
mkdir -p "$SB/results" "$SB/audit" "$SB/bin" "$SB/out"

SB_ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
SB_ADDR="44nep4y8xiQPH96nSQgkChrvUXLrLb73HK5sSGa6hVt3thisdUwb9BtFKdw9iQ89GE7yWW8xvRqG6HZrAro79hPDvYSrqCG"
assert_eq "the Monero fixture is the 95-char shape the redactor keys on" "${#SB_ADDR}" "95"

cat >"$SB/bin/journalctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"\${SB_JOURNAL_LOG:-/dev/null}"
case "\$*" in
*monerod.service*)
    printf 'monerod: --rpc-login rpcuser:rpcpassvalue servicing --wallet %s\n' "$SB_ADDR"
    printf 'monerod: --http-access-token HTTPTOKENVALUE123 auth listener\n'
    ;;
*tor.service*)
    printf 'tor: Bootstrapped 100%% (done)\n'
    printf 'tor: built circuit to exit\n'
    printf 'tor: served %s\n' "$SB_ONION"
    ;;
*) printf 'boot: starting service\n' ;;
esac
exit 0
EOF
chmod +x "$SB/bin/journalctl"
export SB_JOURNAL_LOG="$SB/journal.log"

sb_run() {
    local keep=""
    [ "${1:-}" = "--keep-stamp" ] && {
        keep=1
        shift
    }
    mkdir -p "$SB/staged"
    [ -n "$keep" ] || rm -f "$SB/staged/.support-bundle-stamp"
    (
        export PATH="$SB/bin:$PATH"
        run_sourced_e "$SANDBOX" control_process_request "$1" "$SB"
    ) >/dev/null 2>&1
}
sb_req() {
    printf '{"id":"%s","action":"%s","actor":"admin"%s}\n' "$1" "$2" "${3:-}" >"$SB/req-$1.json"
    printf '%s\n' "$SB/req-$1.json"
}

echo "== control channel: support-bundle applies with an archive and audits the verb (#4036) =="
sid1="c403c403-0000-4000-8000-000000000001"
sb_run "$(sb_req "$sid1" support-bundle)"
assert_eq "support-bundle applies" "$(jq -r .status "$SB/results/$sid1.json")" "applied"
assert_eq "the applied result names the archive, the way backup does" \
    "$(jq -r '.archive | test("^support-bundle-[0-9T]+Z\\.tar\\.gz$")' "$SB/results/$sid1.json")" "true"
assert_rc "the archive sits in the results spool under the request id" \
    "$(
        ls "$SB/results/$sid1.tar.gz" >/dev/null 2>&1
        echo $?
    )" "0"
assert_eq "the spool archive is mode 600" \
    "$(stat -c '%a' "$SB/results/$sid1.tar.gz")" "600"
assert_contains "support-bundle is audited applied" \
    "$(cat "$SB/audit/control.log")" '"action":"support-bundle","status":"applied"'

echo "== control channel: the archive carries the unit journals and hides every seeded secret =="
mkdir -p "$SB/extract1"
tar -xzf "$SB/results/$sid1.tar.gz" -C "$SB/extract1"
assert_contains "the default window is 72 hours when the intent states none" \
    "$(cat "$SB/journal.log")" "--since 72 hours ago"
assert_rc "every Pithead unit is asked for by exact membership" \
    "$(grep -c -- '--no-pager' "$SB/journal.log")" "15"
for unit in pithead-boot.service pithead-boot-version.service pithead-address-watch.service pithead-miner-recovery.service dashboard.service caddy.service tor.service monerod.service tari.service p2pool.service xmrig-proxy.service docker-proxy.service docker-control.service xmrig.service rauc.service; do
    assert_contains "journal is asked for $unit" "$(cat "$SB/journal.log")" "-u $unit"
done
assert_contains "monerod journal lines land in the archive" \
    "$(cat "$SB/extract1/bundle/logs/monerod.service.log")" "monerod:"
assert_contains "tor bootstrap state is collected" \
    "$(cat "$SB/extract1/bundle/tor.txt")" "Bootstrapped 100%"
assert_not_contains "the seeded --rpc-login value is ABSENT from the whole archive" \
    "$(grep -rF 'rpcpassvalue' "$SB/extract1" || true)" "rpcpassvalue"
assert_not_contains "the seeded Monero payout address is ABSENT from the whole archive" \
    "$(grep -rF "$SB_ADDR" "$SB/extract1" || true)" "$SB_ADDR"
assert_not_contains "the seeded .onion is ABSENT from the whole archive" \
    "$(grep -rF "$SB_ONION" "$SB/extract1" || true)" "$SB_ONION"
assert_not_contains "the seeded --http-access-token value is ABSENT from the whole archive" \
    "$(grep -rF 'HTTPTOKENVALUE123' "$SB/extract1" || true)" "HTTPTOKENVALUE123"
assert_contains "the redactor fired rather than the lines vanishing: the marker is present" \
    "$(cat "$SB/extract1/bundle/logs/monerod.service.log")" "[redacted]"

echo "== control channel: the hours window is a request, and the host clamps it (#4036) =="
sid2="c403c403-0000-4000-8000-000000000002"
rm -f "$SB/journal.log"
sb_run "$(sb_req "$sid2" support-bundle ',"hours":9999')"
assert_eq "a widened window is clamped to the host cap, not trusted" \
    "$(jq -r .hours "$SB/results/$sid2.json")" "168"
assert_contains "the journal was cut at the clamped window" "$(cat "$SB/journal.log")" "--since 168 hours ago"
sid3="c403c403-0000-4000-8000-000000000003"
rm -f "$SB/journal.log"
sb_run "$(
    printf '{"id":"%s","action":"support-bundle","actor":"admin","hours":"12x"}\n' "$sid3" | tee "$SB/req-$sid3.json" >/dev/null
    printf '%s' "$SB/req-$sid3.json"
)"
assert_eq "a non-numeric window falls back to the stated default" \
    "$(jq -r .hours "$SB/results/$sid3.json")" "72"

echo "== control channel: a bundle over the host cap is refused, not truncated onto the wire =="
sid4="c403c403-0000-4000-8000-000000000004"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PATH="$SB/bin:$PATH" PITHEAD_SUPPORT_MAX_TOTAL_BYTES=0
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sid4" support-bundle)" "$SB"
) >/dev/null 2>&1
assert_eq "exceeding the total cap fails the request" "$(jq -r .status "$SB/results/$sid4.json")" "failed"
assert_rc "a refused bundle writes no archive" \
    "$([ -e "$SB/results/$sid4.tar.gz" ] && echo 0 || echo 1)" "1"

echo "== control channel: a second bundle inside a minute is rejected outright =="
sid5="c403c403-0000-4000-8000-000000000005"
sb_run "$(sb_req "$sid5" support-bundle)"
sb_run --keep-stamp "$(sb_req "$sid5" support-bundle)"
assert_eq "the throttle rejects the immediate second collect" \
    "$(jq -r .status "$SB/results/$sid5.json")" "rejected"

echo "== host CLI: recovery-bundle shares the one collector and prints a 600 archive (#4038) =="
rb=$(
    export PATH="$SB/bin:$PATH" PITHEAD_RECOVERY_BUNDLE_DIR="$SB/out"
    run_sourced_e "$SANDBOX" recovery_bundle --hours 24 2>/dev/null |
        sed -n 's/.*Support bundle written: //p' | tail -1
)
assert_rc "recovery-bundle writes an archive on a journal-only host" \
    "$([ -e "$rb" ] && echo 0 || echo 1)" "0"
assert_contains "the archive lands under the stated directory" "$rb" "$SB/out/support-bundle-"
assert_eq "the printed archive is mode 600" "$(stat -c '%a' "$rb")" "600"
mkdir -p "$SB/extract2"
tar -xzf "$rb" -C "$SB/extract2"
assert_contains "the journal-only archive carries journal lines" \
    "$(cat "$SB/extract2/bundle/logs/tor.service.log")" "Bootstrapped 100%"
assert_not_contains "the same one redactor covers the host CLI path" \
    "$(grep -rF 'rpcpassvalue' "$SB/extract2" || true)" "rpcpassvalue"
