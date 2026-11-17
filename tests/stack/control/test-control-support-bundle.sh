# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SANDBOX:?}"

SB="$SANDBOX/ctrl4036"
mkdir -p "$SB/results" "$SB/audit" "$SB/bin" "$SB/out"

SB_ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
SB_ADDR="44nep4y8xiQPH96nSQgkChrvUXLrLb73HK5sSGa6hVt3thisdUwb9BtFKdw9iQ89GE7yWW8xvRqG6HZrAro79hPDvYSrqCG"
assert_eq "the Monero fixture is the 95-char shape the redactor keys on" "${#SB_ADDR}" "95"

cat >"$SB/bin/journalctl" <<'PYSTUB'
#!/usr/bin/env python3
import os, sys, time
from datetime import datetime, timezone

args = sys.argv[1:]
log = os.environ.get("SB_JOURNAL_LOG")
if log:
    with open(log, "a") as fh:
        fh.write(" ".join(args) + "\n")
now = int(time.time())
H = 3600
addr = os.environ["SB_ADDR"]
onion = os.environ["SB_ONION"]
oldest = int(os.environ.get("SB_OLDEST_HOURS", "100"))
entries = [
    (oldest * H, "pithead-boot.service", False, "oldest retained entry"),
    (50 * H, "monerod.service", False, "monerod: marker-50h"),
    (2 * H, "monerod.service", False, "monerod: --rpc-login rpcuser:rpcpassvalue servicing --wallet " + addr),
    (2 * H, "monerod.service", False, "monerod: --http-access-token HTTPTOKENVALUE123 auth listener"),
    (3 * H, "tor.service", False, "tor: Bootstrapped 100% (done)"),
    (3 * H, "tor.service", False, "tor: built circuit to exit"),
    (3 * H, "tor.service", False, "tor: served " + onion),
    (H, "pithead-zzdummy.service", False, "dummy: marker-1h"),
    (H, "quadletx.service", False, "quadlet: marker-1h"),
    (4 * H, "kernel", True, "kernel: --rpc-login kernpass1 marker-4h"),
    (30 * 60, "kernel", True, "kernel: marker-30m"),
]
for i in range(int(os.environ.get("SB_BULK", "0"))):
    entries.append((5 * H - i, "p2pool.service", False, "p2pool: bulk-%04d %s" % (i, "x" * (80 + i % 7))))
entries = [e for e in entries if e[0] <= oldest * H]
entries.sort(key=lambda e: -e[0])


def when(v):
    v = v.replace(" UTC", "")
    return int(datetime.strptime(v, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc).timestamp())


def opt(name):
    return args[args.index(name) + 1] if name in args else None


if "--disk-usage" in args:
    print("Archived and active journals take up 120.0M in the file system.")
    sys.exit(0)
if "--list-boots" in args:
    print("-1 aaaa Mon 2026-11-10 00:00:00 UTC—Tue 2026-11-11 00:00:00 UTC")
    sys.exit(0)
if "-o" in args:
    first = entries[0]
    print("%d.000000 host %s: %s" % (now - first[0], first[1], first[3]))
    sys.exit(0)
if os.environ.get("SB_FAIL_KERNEL") and "-k" in args:
    sys.stderr.write("boom: journal file is corrupt\n")
    sys.exit(1)
unit = opt("-u")
if os.environ.get("SB_SLOW_UNIT") and unit == os.environ["SB_SLOW_UNIT"]:
    time.sleep(30)
since = when(opt("--since")) if opt("--since") else 0
until = when(opt("--until")) if opt("--until") else now + 1
for ago, ident, kern, msg in entries:
    t = now - ago
    if t < since or t > until:
        continue
    if "-k" in args and not kern:
        continue
    if unit and ident != unit:
        continue
    print(datetime.fromtimestamp(t, timezone.utc).strftime("%b %d %H:%M:%S"), "host", msg)
PYSTUB
chmod +x "$SB/bin/journalctl"
cat >"$SB/bin/systemctl" <<'SYSCTL'
#!/usr/bin/env bash
case "$*" in
*list-unit-files*)
    printf 'pithead-zzdummy.service enabled enabled\n'
    printf 'pithead-zzdummy.timer enabled enabled\n'
    printf 'quadletx.service generated -\n'
    printf 'unrelated.service enabled enabled\n'
    printf 'tor.service generated -\n'
    ;;
esac
exit 0
SYSCTL
chmod +x "$SB/bin/systemctl"
export SB_JOURNAL_LOG="$SB/journal.log" SB_ADDR SB_ONION

sb_iso() { date -u -d "@$(($(date +%s) + $1))" +%Y-%m-%dT%H:%M:%SZ; }
sb_unzip() {
    rm -rf "$2"
    mkdir -p "$2"
    python3 -I -m zipfile -e "$1" "$2" >/dev/null
}
sb_man() { jq -r "$2" "$1/bundle/manifest.json"; }

sb_run() {
    local keep=""
    [ "${1:-}" = "--keep-stamp" ] && {
        keep=1
        shift
    }
    mkdir -p "$SB/staged"
    [ -n "$keep" ] || rm -f "$SB/staged/.support-bundle-stamp"
    (
        export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH"
        run_sourced_e "$SANDBOX" control_process_request "$1" "$SB"
    ) >/dev/null 2>&1
}
sb_req() {
    printf '{"id":"%s","action":"%s","actor":"admin"%s}\n' "$1" "$2" "${3:-}" >"$SB/req-$1.json"
    printf '%s\n' "$SB/req-$1.json"
}

echo "== control channel: support-bundle applies one zip and audits the verb (#4036, #4127) =="
sid1="c403c403-0000-4000-8000-000000000001"
sb_run "$(sb_req "$sid1" support-bundle)"
assert_eq "support-bundle applies" "$(jq -r .status "$SB/results/$sid1.json")" "applied"
assert_eq "the applied result names a zip archive" \
    "$(jq -r '.archive | test("^support-bundle-[0-9T]+Z\\.zip$")' "$SB/results/$sid1.json")" "true"
assert_rc "the archive sits in the results spool under the request id with a zip name" \
    "$(
        ls "$SB/results/$sid1.zip" >/dev/null 2>&1
        echo $?
    )" "0"
assert_rc "no tarball is produced" \
    "$(
        ls "$SB/results/$sid1.tar.gz" >/dev/null 2>&1
        echo $?
    )" "2"
assert_eq "the spool archive is mode 600" "$(stat -c '%a' "$SB/results/$sid1.zip")" "600"
assert_eq "the stock zip reader accepts the archive" \
    "$(python3 -I -m zipfile -t "$SB/results/$sid1.zip" >/dev/null 2>&1 && echo ok)" "ok"
if command -v unzip >/dev/null 2>&1; then
    assert_eq "the stock unzip accepts the archive" "$(unzip -tq "$SB/results/$sid1.zip" >/dev/null 2>&1 && echo ok)" "ok"
fi
assert_contains "support-bundle is audited applied" \
    "$(cat "$SB/audit/control.log")" '"action":"support-bundle","status":"applied"'
assert_eq "the applied result carries the effective window" \
    "$(jq -r '(.since | test("^[0-9]{4}-.*Z$")) and (.until | test("^[0-9]{4}-.*Z$"))' "$SB/results/$sid1.json")" "true"

echo "== control channel: the zip holds the whole journal, the kernel log, the boot list and a manifest =="
sb_unzip "$SB/results/$sid1.zip" "$SB/extract1"
assert_contains "the default window is the last 72 hours" \
    "$(sb_man "$SB/extract1" '(.window.requested.until | fromdate) - (.window.requested.since | fromdate)')" "259200"
assert_contains "the whole journal file carries every unit's lines" \
    "$(cat "$SB/extract1/bundle/journal/all.log")" "monerod: marker-50h"
assert_contains "the whole journal carries a unit the old hand-kept list never named" \
    "$(cat "$SB/extract1/bundle/journal/all.log")" "dummy: marker-1h"
assert_contains "the kernel journal for the window is collected" \
    "$(cat "$SB/extract1/bundle/journal/kernel.log")" "kernel: marker-30m"
assert_contains "the boot list is collected" \
    "$(cat "$SB/extract1/bundle/journal/boots.txt")" "aaaa"
assert_contains "monerod journal lines land in its per-unit file" \
    "$(cat "$SB/extract1/bundle/logs/monerod.service.log")" "monerod:"
assert_contains "tor bootstrap state is collected" \
    "$(cat "$SB/extract1/bundle/tor.txt")" "Bootstrapped 100%"

echo "== control channel: the unit list comes from the installed unit files, not a hand-kept string =="
assert_eq "an installed pithead service the old list never held is collected" \
    "$(sb_man "$SB/extract1" '[.files[].path] | index("logs/pithead-zzdummy.service.log") != null')" "true"
assert_eq "a quadlet-generated unit is collected" \
    "$(sb_man "$SB/extract1" '[.files[].path] | index("logs/quadletx.service.log") != null')" "true"
assert_eq "an installed pithead timer is collected" \
    "$(sb_man "$SB/extract1" '[.files[].path] | index("logs/pithead-zzdummy.timer.log") != null')" "true"
assert_contains "the dummy unit's lines are in its file" \
    "$(cat "$SB/extract1/bundle/logs/pithead-zzdummy.service.log")" "dummy: marker-1h"
assert_eq "an unrelated installed unit is not collected" \
    "$(sb_man "$SB/extract1" '[.files[].path] | index("logs/unrelated.service.log") != null')" "false"
assert_eq "the core units stay collected when they are not installed" \
    "$(sb_man "$SB/extract1" '[.files[].path] | index("logs/docker-control.service.log") != null')" "true"

echo "== control channel: the manifest records window, journald, policy, files and failures =="
assert_eq "the manifest lists the oldest retained journal entry" \
    "$(sb_man "$SB/extract1" '.window.oldest_retained_entry | test("^[0-9]{4}-.*Z$")')" "true"
assert_eq "a window inside the journal is not marked short" \
    "$(sb_man "$SB/extract1" '.window.journal_short')" "false"
assert_eq "the effective window equals the requested one when the journal covers it" \
    "$(sb_man "$SB/extract1" '.window.requested == .window.effective')" "true"
assert_contains "the manifest records the journald disk usage" \
    "$(sb_man "$SB/extract1" '.journald.disk_usage')" "120.0M"
assert_eq "the manifest records the journald settings as a list" \
    "$(sb_man "$SB/extract1" '.journald.effective_settings | type')" "array"
assert_eq "the manifest records the size policy caps" \
    "$(sb_man "$SB/extract1" '.size_policy | (.per_file_cap_bytes > 0) and (.total_cap_bytes > 0)')" "true"
assert_eq "the manifest records the collection time and version" \
    "$(sb_man "$SB/extract1" '(.collected_at | test("Z$")) and (.pithead_version | length > 0)')" "true"
assert_eq "every file entry carries bytes, state, window and truncation fields" \
    "$(sb_man "$SB/extract1" '[.files[] | has("bytes") and has("state") and has("window") and has("truncated") and has("dropped_lines") and has("dropped_bytes")] | all')" "true"
assert_eq "a clean collection records no failed step" "$(sb_man "$SB/extract1" '.failures | length')" "0"
assert_eq "a unit with lines in the window is ok" \
    "$(sb_man "$SB/extract1" '.files[] | select(.path == "logs/monerod.service.log") | .state')" "ok"
assert_eq "an installed unit with nothing in the window is empty" \
    "$(sb_man "$SB/extract1" '.files[] | select(.path == "logs/pithead-zzdummy.timer.log") | .state')" "empty"
assert_eq "a unit that is not installed and has no lines is missing" \
    "$(sb_man "$SB/extract1" '.files[] | select(.path == "logs/docker-control.service.log") | .state')" "missing"

echo "== control channel: no seeded secret reaches the whole-journal, kernel or per-unit files =="
assert_not_contains "the seeded --rpc-login value is ABSENT from the whole zip" \
    "$(grep -rF 'rpcpassvalue' "$SB/extract1" || true)" "rpcpassvalue"
assert_not_contains "the seeded kernel --rpc-login value is ABSENT from the whole zip" \
    "$(grep -rF 'kernpass1' "$SB/extract1" || true)" "kernpass1"
assert_not_contains "the seeded Monero payout address is ABSENT from the whole zip" \
    "$(grep -rF "$SB_ADDR" "$SB/extract1" || true)" "$SB_ADDR"
assert_not_contains "the seeded .onion is ABSENT from the whole zip" \
    "$(grep -rF "$SB_ONION" "$SB/extract1" || true)" "$SB_ONION"
assert_not_contains "the seeded --http-access-token value is ABSENT from the whole zip" \
    "$(grep -rF 'HTTPTOKENVALUE123' "$SB/extract1" || true)" "HTTPTOKENVALUE123"
assert_contains "the redactor fired rather than the lines vanishing: the marker is present" \
    "$(cat "$SB/extract1/bundle/journal/all.log")" "[redacted]"
assert_contains "the kernel file went through the redactor too" \
    "$(cat "$SB/extract1/bundle/journal/kernel.log")" "[redacted]"

echo "== control channel: an explicit start and end select the window's content =="
sid2="c403c403-0000-4000-8000-000000000002"
rm -f "$SB/journal.log"
sb_run "$(sb_req "$sid2" support-bundle ",\"since\":\"$(sb_iso -14400)\",\"until\":\"$(sb_iso -5400)\"")"
assert_eq "an explicit window applies" "$(jq -r .status "$SB/results/$sid2.json")" "applied"
assert_contains "the journal was cut with --since" "$(cat "$SB/journal.log")" "--since "
assert_contains "the journal was cut with --until" "$(cat "$SB/journal.log")" "--until "
sb_unzip "$SB/results/$sid2.zip" "$SB/extract2"
assert_contains "a line inside the window is present" \
    "$(cat "$SB/extract2/bundle/journal/all.log")" "monerod: --rpc-login [redacted]"
assert_not_contains "a line before the window is absent" \
    "$(cat "$SB/extract2/bundle/journal/all.log")" "marker-50h"
assert_not_contains "a line after the window is absent" \
    "$(cat "$SB/extract2/bundle/journal/all.log")" "dummy: marker-1h"
assert_not_contains "a line after the window is absent from the kernel file" \
    "$(cat "$SB/extract2/bundle/journal/kernel.log")" "marker-30m"
assert_eq "the manifest records the window that was asked for" \
    "$(sb_man "$SB/extract2" '(.window.requested.until | fromdate) - (.window.requested.since | fromdate)')" "9000"

echo "== control channel: the end second is included whole, so the newest lines are not cut =="
sidI="c403c403-0000-4000-8000-000000000012"
rm -f "$SB/journal.log"
sb_run "$(sb_req "$sidI" support-bundle ',"since":"2026-11-10T09:00:00Z","until":"2026-11-10T10:00:00Z"')"
assert_contains "journalctl is asked to stop at the end of the requested second" \
    "$(cat "$SB/journal.log")" "--until 2026-11-10 10:00:01 UTC"
assert_eq "the manifest still records the requested end as asked" \
    "$(jq -r .until "$SB/results/$sidI.json")" "2026-11-10T10:00:00Z"

echo "== control channel: a start older than the oldest retained entry is clamped and flagged =="
sid3="c403c403-0000-4000-8000-000000000003"
sb_run "$(sb_req "$sid3" support-bundle ",\"since\":\"$(sb_iso -432000)\"")"
sb_unzip "$SB/results/$sid3.zip" "$SB/extract3"
assert_eq "the manifest marks the journal as shorter than the window" \
    "$(sb_man "$SB/extract3" '.window.journal_short')" "true"
assert_eq "the effective start is the oldest retained entry" \
    "$(sb_man "$SB/extract3" '.window.effective.since == .window.oldest_retained_entry')" "true"
assert_eq "the requested start is kept beside it" \
    "$(sb_man "$SB/extract3" '.window.requested.since != .window.effective.since')" "true"
assert_eq "a unit with lines in a short journal is its own state" \
    "$(sb_man "$SB/extract3" '.files[] | select(.path == "logs/monerod.service.log") | .state')" "journal_short"

echo "== control channel: a bad window is rejected and nothing is collected =="
sid4="c403c403-0000-4000-8000-000000000004"
rm -f "$SB/journal.log"
sb_run "$(sb_req "$sid4" support-bundle ",\"since\":\"$(sb_iso -3600)\",\"until\":\"$(sb_iso -7200)\"")"
assert_eq "a start after the end is rejected" "$(jq -r .status "$SB/results/$sid4.json")" "rejected"
assert_contains "the rejection says why" "$(jq -r .error "$SB/results/$sid4.json")" "after end time"
sid5="c403c403-0000-4000-8000-000000000005"
sb_run "$(sb_req "$sid5" support-bundle ',"since":"yesterday"')"
assert_eq "an unparsable time is rejected" "$(jq -r .status "$SB/results/$sid5.json")" "rejected"
assert_contains "the unparsable rejection names the format" "$(jq -r .error "$SB/results/$sid5.json")" "RFC 3339"
sid6="c403c403-0000-4000-8000-000000000006"
sb_run "$(sb_req "$sid6" support-bundle ",\"until\":\"$(sb_iso 7200)\"")"
assert_eq "an end in the future is rejected" "$(jq -r .status "$SB/results/$sid6.json")" "rejected"
assert_contains "the future rejection says why" "$(jq -r .error "$SB/results/$sid6.json")" "future"
assert_rc "no rejected request ran the journal" "$([ -e "$SB/journal.log" ] && echo 0 || echo 1)" "1"
assert_rc "no rejected request wrote an archive" \
    "$(ls "$SB"/results/c403c403-0000-4000-8000-00000000000[456].zip >/dev/null 2>&1 && echo 0 || echo 1)" "1"

echo "== control channel: the hours request is still accepted and clamped by the host =="
sid7="c403c403-0000-4000-8000-000000000007"
sb_run "$(sb_req "$sid7" support-bundle ',"hours":9999')"
sb_unzip "$SB/results/$sid7.zip" "$SB/extract7"
assert_eq "a widened window is clamped to the host cap, not trusted" \
    "$(sb_man "$SB/extract7" '(.window.requested.until | fromdate) - (.window.requested.since | fromdate)')" "604800"
sid8="c403c403-0000-4000-8000-000000000008"
sb_run "$(sb_req "$sid8" support-bundle ',"hours":24')"
sb_unzip "$SB/results/$sid8.zip" "$SB/extract8"
assert_eq "an hours request maps to that many hours back" \
    "$(sb_man "$SB/extract8" '(.window.requested.until | fromdate) - (.window.requested.since | fromdate)')" "86400"
sid9="c403c403-0000-4000-8000-000000000009"
printf '{"id":"%s","action":"support-bundle","actor":"admin","hours":"12x"}\n' "$sid9" >"$SB/req-$sid9.json"
sb_run "$SB/req-$sid9.json"
sb_unzip "$SB/results/$sid9.zip" "$SB/extract9"
assert_eq "a non-numeric window falls back to the stated default" \
    "$(sb_man "$SB/extract9" '(.window.requested.until | fromdate) - (.window.requested.since | fromdate)')" "259200"

echo "== control channel: a busy file keeps its oldest and newest lines and says what was dropped =="
sidA="c403c403-0000-4000-8000-00000000000a"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH" SB_BULK=3000 PITHEAD_SUPPORT_MAX_BYTES_PER_FILE=40000
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sidA" support-bundle)" "$SB"
) >/dev/null 2>&1
assert_eq "a capped bundle still applies" "$(jq -r .status "$SB/results/$sidA.json")" "applied"
sb_unzip "$SB/results/$sidA.zip" "$SB/extractA"
assert_contains "the oldest line of the busy unit is kept" \
    "$(cat "$SB/extractA/bundle/logs/p2pool.service.log")" "bulk-2999"
assert_contains "the newest line of the busy unit is kept" \
    "$(cat "$SB/extractA/bundle/logs/p2pool.service.log")" "bulk-0000"
assert_contains "a marker inside the file says what was dropped" \
    "$(cat "$SB/extractA/bundle/logs/p2pool.service.log")" "lines ("
assert_eq "the manifest marks the file truncated" \
    "$(sb_man "$SB/extractA" '.files[] | select(.path == "logs/p2pool.service.log") | .truncated')" "true"
assert_eq "the manifest counts the dropped lines" \
    "$(sb_man "$SB/extractA" '.files[] | select(.path == "logs/p2pool.service.log") | .dropped_lines > 0 and .dropped_bytes > 0')" "true"
assert_eq "a small file in the same bundle is not marked truncated" \
    "$(sb_man "$SB/extractA" '.files[] | select(.path == "logs/tor.service.log") | .truncated')" "false"
sidG="c403c403-0000-4000-8000-000000000010"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH" SB_BULK=40
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sidG" support-bundle)" "$SB"
) >/dev/null 2>&1
sb_unzip "$SB/results/$sidG.zip" "$SB/extractG"
sb_fit=$(wc -c <"$SB/extractG/bundle/logs/p2pool.service.log" | tr -d ' ')
sidH="c403c403-0000-4000-8000-000000000011"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH" SB_BULK=40 PITHEAD_SUPPORT_MAX_BYTES_PER_FILE="$sb_fit"
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sidH" support-bundle)" "$SB"
) >/dev/null 2>&1
sb_unzip "$SB/results/$sidH.zip" "$SB/extractH"
assert_eq "a file exactly at its cap is kept whole and not marked truncated" \
    "$(sb_man "$SB/extractH" '.files[] | select(.path == "logs/p2pool.service.log") | .truncated')" "false"
assert_eq "the file at its cap holds every line" \
    "$(grep -c 'bulk-' "$SB/extractH/bundle/logs/p2pool.service.log")" "40"

echo "== control channel: a bundle over the total cap degrades under the policy instead of failing =="
sidB="c403c403-0000-4000-8000-00000000000b"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH" SB_BULK=3000 PITHEAD_SUPPORT_MAX_TOTAL_BYTES=300000
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sidB" support-bundle)" "$SB"
) >/dev/null 2>&1
assert_eq "exceeding the total cap still yields a bundle" "$(jq -r .status "$SB/results/$sidB.json")" "applied"
sb_unzip "$SB/results/$sidB.zip" "$SB/extractB"
assert_eq "the manifest records the shrunk files" \
    "$(sb_man "$SB/extractB" '[.files[] | select(.truncated)] | length > 0')" "true"
assert_eq "the sum of the file sizes fits the stated cap" \
    "$(sb_man "$SB/extractB" '([.files[].bytes] | add) <= 300000 + 100000')" "true"

echo "== control channel: a total cap no file can meet ends, applies and says so =="
sidE="c403c403-0000-4000-8000-00000000000e"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH" SB_BULK=3000 PITHEAD_SUPPORT_MAX_TOTAL_BYTES=1
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sidE" support-bundle)" "$SB"
) >/dev/null 2>&1
assert_eq "an unmeetable total cap still applies" "$(jq -r .status "$SB/results/$sidE.json")" "applied"
sb_unzip "$SB/results/$sidE.zip" "$SB/extractE"
assert_eq "the manifest records that the cap could not be met" \
    "$(sb_man "$SB/extractE" '[.failures[] | select(.step == "total-cap")] | length')" "1"

echo "== control channel: a window shorter than a second is compared with its fractions =="
sidF="c403c403-0000-4000-8000-00000000000f"
sb_run "$(sb_req "$sidF" support-bundle ',"since":"2026-11-10T10:00:00.900Z","until":"2026-11-10T10:00:00.100Z"')"
assert_eq "a start after the end by a fraction of a second is rejected" \
    "$(jq -r .status "$SB/results/$sidF.json")" "rejected"

echo "== control channel: a failed or timed-out step is recorded with its reason and the rest still collects =="
sidC="c403c403-0000-4000-8000-00000000000c"
rm -f "$SB/staged/.support-bundle-stamp"
(
    export PITHEAD_APPLIANCE=1 PATH="$SB/bin:$PATH" SB_FAIL_KERNEL=1 SB_SLOW_UNIT=pithead-zzdummy.service PITHEAD_SUPPORT_STEP_TIMEOUT=1
    run_sourced_e "$SANDBOX" control_process_request "$(sb_req "$sidC" support-bundle)" "$SB"
) >/dev/null 2>&1
assert_eq "a bundle with failed steps still applies" "$(jq -r .status "$SB/results/$sidC.json")" "applied"
sb_unzip "$SB/results/$sidC.zip" "$SB/extractC"
assert_eq "the failed kernel step is in the manifest as failed" \
    "$(sb_man "$SB/extractC" '.failures[] | select(.step == "journal/kernel.log") | .status')" "failed"
assert_contains "the failure carries the reason" \
    "$(sb_man "$SB/extractC" '.failures[] | select(.step == "journal/kernel.log") | .reason')" "boom"
assert_eq "the timed-out unit step is in the manifest as a timeout" \
    "$(sb_man "$SB/extractC" '.failures[] | select(.step == "logs/pithead-zzdummy.service.log") | .status')" "timeout"
assert_contains "the whole journal still collected" \
    "$(cat "$SB/extractC/bundle/journal/all.log")" "monerod: marker-50h"

echo "== control channel: a second bundle inside a minute is rejected outright =="
sidD="c403c403-0000-4000-8000-00000000000d"
sb_run "$(sb_req "$sidD" support-bundle)"
sb_run --keep-stamp "$(sb_req "$sidD" support-bundle)"
assert_eq "the throttle rejects the immediate second collect" \
    "$(jq -r .status "$SB/results/$sidD.json")" "rejected"

echo "== host CLI: recovery-bundle shares the one collector and prints a 600 zip (#4038, #4127) =="
mkdir -p "$SB/trip"
for t in docker podman docker-compose curl wget nc; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/trip.log"\nexit 127\n' "$t" "$SB" >"$SB/trip/$t"
    chmod +x "$SB/trip/$t"
done
rm -f "$SB/trip.log"
rb=$(
    export PITHEAD_APPLIANCE=1 PATH="$SB/trip:$SB/bin:$PATH" PITHEAD_RECOVERY_BUNDLE_DIR="$SB/out"
    run_sourced_e "$SANDBOX" recovery_bundle --hours 24 2>/dev/null |
        sed -n 's/.*Support bundle written: //p' | tail -1
)
assert_rc "recovery-bundle writes an archive on a journal-only host" \
    "$([ -e "$rb" ] && echo 0 || echo 1)" "0"
assert_eq "no container engine or network tool was invoked" "$(cat "$SB/trip.log" 2>/dev/null)" ""
assert_contains "the archive lands under the stated directory" "$rb" "$SB/out/support-bundle-"
assert_contains "the archive is a zip" "$rb" ".zip"
assert_eq "the printed archive is mode 600" "$(stat -c '%a' "$rb")" "600"
sb_unzip "$rb" "$SB/extractR"
assert_contains "the journal-only archive carries journal lines" \
    "$(cat "$SB/extractR/bundle/logs/tor.service.log")" "Bootstrapped 100%"
assert_not_contains "the same one redactor covers the host CLI path" \
    "$(grep -rF 'rpcpassvalue' "$SB/extractR" || true)" "rpcpassvalue"

echo "== host CLI: recovery-bundle takes --since and --until and rejects a bad window =="
rbw=$(
    export PITHEAD_APPLIANCE=1 PATH="$SB/trip:$SB/bin:$PATH" PITHEAD_RECOVERY_BUNDLE_DIR="$SB/out"
    run_sourced_e "$SANDBOX" recovery_bundle --since "$(sb_iso -14400)" --until "$(sb_iso -5400)" 2>/dev/null |
        sed -n 's/.*Support bundle written: //p' | tail -1
)
sb_unzip "$rbw" "$SB/extractW"
assert_eq "the CLI window selects the same content as the control request" \
    "$(sb_man "$SB/extractW" '(.window.requested.until | fromdate) - (.window.requested.since | fromdate)')" "9000"
assert_not_contains "a line after the CLI window is absent" \
    "$(cat "$SB/extractW/bundle/journal/all.log")" "dummy: marker-1h"
bad_out=$(
    export PITHEAD_APPLIANCE=1 PATH="$SB/trip:$SB/bin:$PATH" PITHEAD_RECOVERY_BUNDLE_DIR="$SB/outbad"
    run_sourced_e "$SANDBOX" recovery_bundle --since "$(sb_iso -3600)" --until "$(sb_iso -7200)" 2>&1 || true
)
assert_contains "recovery-bundle rejects a start after the end" "$bad_out" "after end time"
assert_rc "a rejected recovery-bundle writes nothing" "$(ls "$SB/outbad"/*.zip >/dev/null 2>&1 && echo 0 || echo 1)" "1"
