#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
CLI="$REPO/pithead"

if [ ! -x "$CLI" ]; then
    echo "selftest-os-update-channel: $CLI is not built — run make first" >&2
    exit 1
fi

FAILURES=0
PASSES=0
check() {
    if [ "$2" = "$3" ]; then PASSES=$((PASSES + 1)); else
        FAILURES=$((FAILURES + 1))
        echo "selftest-os-update-channel: FAIL: $1 — expected [$3], got [$2]" >&2
    fi
}
check_has() {
    case "$2" in
    *"$3"*) PASSES=$((PASSES + 1)) ;;
    *)
        FAILURES=$((FAILURES + 1))
        echo "selftest-os-update-channel: FAIL: $1 — [$2] missing [$3]" >&2
        ;;
    esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SB="$tmp/os"
REQS="$SB/data/control/requests"
RES="$SB/data/control/results"
DIR="$SB/osdir"
mkdir -p "$REQS" "$RES" "$SB/data/control/staged" "$SB/data/control/audit" "$SB/bin" "$DIR"
printf '1.3.1' >"$SB/VERSION"
printf '{}' >"$SB/config.json"
printf 'DEPLOYMENT_COMPLETED=true\nDASHBOARD_CONTROL_ENABLED=true\nCONTROL_DIR=%s/data/control\nNETWORK_PREFIX=10.9.0\n' "$SB" >"$SB/.env"
printf 'release\n' >"$SB/variant-release"
printf 'compatible=pithead-os\n' >"$SB/system.conf"
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel","assets":[{"name":"pithead-os-v9.9.9.raucb","size":1000}]}' >"$SB/api.json"
printf '{"tag_name":"v9.9.9/../../x","assets":[{"name":"pithead-os-x.raucb","size":1000}]}' >"$SB/api-evil-tag.json"
printf '{"tag_name":"v9.9.9","assets":[]}' >"$SB/api-no-bundle.json"
printf '{"tag_name":"v2.0.10","assets":[{"name":"pithead-os-v2.0.10.raucb","size":1000}]}' >"$SB/api-2.0.10.json"
printf '{"tag_name":"v2.0.9","assets":[{"name":"pithead-os-v2.0.9.raucb","size":1000}]}' >"$SB/api-2.0.9.json"
yes x | head -c 1000 >"$SB/fixture.raucb"
cat >"$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
url="${*: -1}"
out=""
hdr=""
wfmt=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    [ "$prev" = "-D" ] && hdr="$a"
    [ "$prev" = "-w" ] && wfmt="$a"
    prev="$a"
done
emit() {
    case "$wfmt" in
    '\n%{http_code}') printf '\n%s' "$1" ;;
    '%{http_code}') printf '%s' "$1" ;;
    '%{http_code}\n') printf '%s\n' "$1" ;;
    esac
}
redirect() {
    printf 'HTTP/1.1 %s Found\r\nLocation: %s\r\n\r\n' "$1" "$2" >"$hdr"
    emit "$1"
    exit 0
}
case "$url" in
*api.github.com*)
    if [ "${CH_STUB_RC:-0}" != "0" ]; then exit "$CH_STUB_RC"; fi
    cat "${CH_API_RESPONSE:?}"
    emit 200
    ;;
*seam.invalid*)
    if [ "${CH_STUB_RC:-0}" != "0" ]; then exit "$CH_STUB_RC"; fi
    if [ "${CH_REDIRECT:-}" = "offseam" ]; then redirect 302 http://evil.invalid/x; fi
    if [ "${CH_REDIRECT:-}" = "inseam" ]; then
        n=0
        [ -f "${CH_HOPS:-}" ] && n=$(cat "$CH_HOPS")
        n=$((n + 1))
        printf '%s' "$n" >"${CH_HOPS:?}"
        [ "$n" -eq 1 ] && redirect 302 http://seam.invalid/os/rel.json
    fi
    cat "${CH_API_RESPONSE:?}" >"$out"
    emit 200
    ;;
*objects.githubusercontent.com* | *release-assets.githubusercontent.com*)
    if [ "${CH_STUB_RC:-0}" != "0" ]; then exit "$CH_STUB_RC"; fi
    if [ "$wfmt" != "%{http_code}\n" ]; then emit 200; exit 0; fi
    have=0
    [ -f "$out" ] && have=$(wc -c <"$out" | tr -d ' ')
    tail -c "+$((have + 1))" "${CH_BUNDLE:?}" >>"$out"
    emit 200
    ;;
*pithead-os-*)
    if [ "${CH_STUB_RC:-0}" != "0" ]; then exit "$CH_STUB_RC"; fi
    if [ "$wfmt" = "%{http_code}" ]; then
        case "${CH_REDIRECT:-}" in
        offhost) redirect 302 http://evil.invalid/b ;;
        loop) redirect 302 "https://github.com/next-hop/$(basename "$url")" ;;
        asset) redirect 302 https://release-assets.githubusercontent.com/asset.bin ;;
        oldasset) redirect 302 https://objects.githubusercontent.com/old.bin ;;
        *) emit 200 ;;
        esac
        exit 0
    fi
    if [ "${CH_FINAL_CODE:-200}" != "200" ]; then
        emit "$CH_FINAL_CODE"
        exit 0
    fi
    if [ "${CH_OVERSIZE:-0}" = "1" ]; then
        head -c 1500 /dev/zero >>"$out"
        emit 200
        exit 0
    fi
    have=0
    [ -f "$out" ] && have=$(wc -c <"$out" | tr -d ' ')
    tail -c "+$((have + 1))" "${CH_BUNDLE:?}" >>"$out"
    emit 200
    ;;
*) exit 22 ;;
esac
exit 0
EOF
cat >"$SB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$SB/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 1000000 0 ${DF_AVAIL_KB:-999999999} 0% /data"
EOF
chmod +x "$SB/bin/curl" "$SB/bin/systemctl" "$SB/bin/df"
chrun() {
    (cd "$SB" && PATH="$SB/bin:$PATH" CURL_LOG="$SB/curl.log" CH_API_RESPONSE="$SB/api.json" \
        CH_BUNDLE="$SB/fixture.raucb" PITHEAD_APPLIANCE=1 PITHEAD_OS_UPDATE_DIR="$DIR" \
        PITHEAD_VARIANT_FILE="$SB/variant-release" PITHEAD_RAUC_SYSTEM_CONF="$SB/system.conf" \
        PITHEAD_OS_DL_ATTEMPT=60 env "$@" ./pithead control-run-pending 2>&1)
}
ch_intent() {
    printf '{"id":"%s","action":"%s","actor":"admin"%s}\n' "$1" "$2" "${3:+,\"version\":\"$3\"}" >"$REQS/$1.json"
}
UC="77777777-7777-4888-8777-777777777777"
chresult() { jq -r "$1" "$RES/$UC.json" 2>/dev/null; }
chreset() { rm -f "$RES/$UC.json" "$DIR/target.json" "$DIR/.check-stamp" "$DIR/.check-stamp-short"; }
cp "$CLI" "$SB/pithead"
: >"$SB/curl.log"

ch_intent "$UC" os-check
chrun >/dev/null
check "a listing check reports checked" "$(chresult .status)" "checked"
check "the check carries the release tag" "$(chresult '.channel.tag')" "v9.9.9"
check "the first listing moved the channel" "$(chresult .channel.moved)" "true"
check "no staleness note on a fresh channel" "$(chresult .channel.note)" ""
ch_intent "$UC" os-check
chrun >/dev/null
check "the cached check still reports the channel" "$(chresult '.channel.tag')" "v9.9.9"
chreset
ch_intent "$UC" os-check
chrun >/dev/null
check "the same release does not advance the channel" "$(chresult .channel.moved)" "false"
check_has "a frozen channel is flagged stale" "$(chresult .channel.note)" "stale or frozen"
check "the high-water mark keeps the release" "$(jq -r .tag "$DIR/channel.json" 2>/dev/null)" "v9.9.9"
chreset
ch_intent "$UC" os-check
chrun CH_API_RESPONSE="$SB/api-evil-tag.json" >/dev/null
check "a tainted tag refuses the check" "$(chresult .status)" "rejected"
check_has "the refusal says no usable tag" "$(chresult .error)" "no usable release tag"
check "a tainted tag is never recorded" "$(jq -r .tag "$DIR/channel.json" 2>/dev/null)" "v9.9.9"
chreset
ch_intent "$UC" os-check
chrun CH_API_RESPONSE="$SB/api-no-bundle.json" >/dev/null
check "a release without the OS bundle refuses the check" "$(chresult .status)" "rejected"
check_has "the refusal names the missing bundle" "$(chresult .error)" "publishes no appliance OS bundle"
chreset
ch_intent "$UC" os-check
chrun >/dev/null
check "target refreshed for the download legs" "$(chresult .status)" "checked"
ch_intent "$UC" os-download "v9.9.9"
chrun CH_REDIRECT=offhost >/dev/null
check "a bundle URL off the allowlist is refused" "$(chresult .status)" "rejected"
check_has "the refusal names the off-host redirect" "$(chresult .error)" "off the release hosts"
check "no partial file after the refused resolve" "$(find "$DIR" -name '*.partial' | wc -l | tr -d ' ')" "0"
ch_intent "$UC" os-download "v9.9.9"
dials_before=$(grep -c 'pithead-os-v9.9.9.raucb' "$SB/curl.log" || true)
chrun CH_REDIRECT=loop >/dev/null
check "a redirect loop is refused" "$(chresult .status)" "rejected"
check_has "the loop refusal names the hop cap" "$(chresult .error)" "more than five times"
check "the loop stops at the hop cap" "$(($(grep -c 'pithead-os-v9.9.9.raucb' "$SB/curl.log") - dials_before))" "5"
ch_intent "$UC" os-download "v9.9.9"
chrun CH_REDIRECT=asset >/dev/null
check "the asset host hop resolves and completes" "$(chresult .status)" "downloaded"
check_has "bytes are fetched from the live asset host" "$(grep 'release-assets.githubusercontent.com' "$SB/curl.log" | tail -1)" "release-assets.githubusercontent.com/asset.bin"
check "the staged bundle is complete" "$(wc -c <"$DIR/pithead-os-v9.9.9.raucb" | tr -d ' ')" "1000"
check "the resolve step requests no body" "$(grep -F ' -w %{http_code} ' "$SB/curl.log" | grep -cF 'pithead-os-' | tr -d ' ')" "$(grep -F ' -w %{http_code} ' "$SB/curl.log" | grep -F 'pithead-os-' | grep -cF ' -I ' | tr -d ' ')"
check "production dials pin https over the Tor proxy" "$(grep -F ' --proto =https ' "$SB/curl.log" | grep -cF -- '--socks5-hostname 10.9.0.25:9050' | tr -d ' ')" "$(grep -F -- '--socks5-hostname 10.9.0.25:9050' "$SB/curl.log" | wc -l | tr -d ' ')"
rm -f "$DIR/pithead-os-v9.9.9.raucb"
ch_intent "$UC" os-download "v9.9.9"
chrun CH_REDIRECT=oldasset >/dev/null
check "the retired asset host still resolves and completes" "$(chresult .status)" "downloaded"
check "the old-host bundle is complete" "$(wc -c <"$DIR/pithead-os-v9.9.9.raucb" | tr -d ' ')" "1000"
rm -f "$DIR/pithead-os-v9.9.9.raucb"
ch_intent "$UC" os-download "v9.9.9"
chrun CH_OVERSIZE=1 >/dev/null
check "a stream past the announced size fails the download" "$(chresult .status)" "failed"
check_has "the failure names the announced size" "$(chresult .error)" "announced 1000-byte size"
check "the oversize partial is discarded" "$([ -f "$DIR/pithead-os-v9.9.9.raucb.partial" ] && echo present || echo absent)" "absent"
ch_intent "$UC" os-download "v9.9.9"
chrun CH_FINAL_CODE=302 >/dev/null
check "a non-2xx final answer fails the download" "$(chresult .status)" "failed"
check_has "the failure names the HTTP answer" "$(chresult .error)" "HTTP 302"
check "the partial file is discarded" "$([ -f "$DIR/pithead-os-v9.9.9.raucb.partial" ] && echo present || echo absent)" "absent"
chreset
printf '2.0.9' >"$SB/VERSION"
rm -f "$DIR/channel.json"
ch_intent "$UC" os-check
chrun CH_API_RESPONSE="$SB/api-2.0.9.json" >/dev/null
check "the lineage starts moved" "$(chresult .channel.moved)" "true"
chreset
ch_intent "$UC" os-check
chrun CH_API_RESPONSE="$SB/api-2.0.10.json" >/dev/null
check "2.0.10 above 2.0.9 advances the channel" "$(chresult .channel.moved)" "true"
check "2.0.10 compares newer than 2.0.9" "$(chresult .newer)" "true"
chreset
ch_intent "$UC" os-check
chrun CH_API_RESPONSE="$SB/api-2.0.9.json" >/dev/null
check "an offer older than the last listing is flagged regressed" "$(chresult .channel.regressed)" "true"
check "2.0.9 is not newer than 2.0.10" "$(chresult .newer)" "false"
check_has "the regression is reported as a possible replay" "$(chresult .channel.note)" "replayed listing"
check "the regression keeps the high-water mark" "$(jq -r .tag "$DIR/channel.json" 2>/dev/null)" "v2.0.10"
printf '1.3.1' >"$SB/VERSION"
chreset
printf 'http://seam.invalid/os' >"$SB/os-update-test-base"
ch_intent "$UC" os-check
chrun CH_STUB_RC=63 >/dev/null
check "a listing over the size cap refuses the check" "$(chresult .status)" "rejected"
check_has "the refusal names the size cap" "$(chresult .error)" "size cap"
chreset
ch_intent "$UC" os-check
chrun CH_STUB_RC=28 >/dev/null
check "a timed-out listing refuses the check" "$(chresult .status)" "rejected"
check_has "the refusal names the timeout" "$(chresult .error)" "timed out"
chreset
ch_intent "$UC" os-check
chrun CH_REDIRECT=offseam >/dev/null
check "a listing off the seam refuses the check" "$(chresult .status)" "rejected"
check_has "the refusal names the seam" "$(chresult .error)" "off the test seam"
chreset
ch_intent "$UC" os-check
chrun CH_REDIRECT=inseam CH_HOPS="$SB/hops" >/dev/null
check "a same-origin redirect still answers checked" "$(chresult .status)" "checked"
rm -f "$SB/os-update-test-base" "$SB/hops"

if [ "$FAILURES" -ne 0 ]; then
    echo "selftest-os-update-channel: $FAILURES failed, $PASSES passed" >&2
    exit 1
fi
echo "selftest-os-update-channel OK ($PASSES checks)"
