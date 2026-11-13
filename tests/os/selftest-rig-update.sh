#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
CLI="$REPO/pithead"

if [ ! -x "$CLI" ]; then
    echo "selftest-rig-update: $CLI is not built — run make first" >&2
    exit 1
fi

FAILURES=0
PASSES=0
check() {
    if [ "$2" = "$3" ]; then PASSES=$((PASSES + 1)); else
        FAILURES=$((FAILURES + 1))
        echo "selftest-rig-update: FAIL: $1 — expected [$3], got [$2]" >&2
    fi
}
check_has() {
    case "$2" in
    *"$3"*) PASSES=$((PASSES + 1)) ;;
    *)
        FAILURES=$((FAILURES + 1))
        echo "selftest-rig-update: FAIL: $1 — [$2] missing [$3]" >&2
        ;;
    esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SB="$tmp/os"
STAGE="$SB/data/os-update"
mkdir -p "$SB/bin" "$STAGE"
printf '1.3.1\n' >"$SB/VERSION"
printf 'rig\n' >"$SB/machine-role"
printf 'release\n' >"$SB/variant-release"
printf 'compatible=pithead-os\n' >"$SB/system.conf"
yes x | head -c 1000 >"$SB/fixture.raucb"
listing() {
    printf '{"tag_name":"%s","html_url":"https://example.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$1" "$1" "${2:-1000}" >"$SB/api.json"
}
listing v9.9.9
printf '{"tag_name":"v9.9.9/../../x","assets":[{"name":"pithead-os-x.raucb","size":1000}]}' >"$SB/api-evil-tag.json"
printf '{"tag_name":"v9.9.9","assets":[]}' >"$SB/api-no-bundle.json"
printf 'http://seam.invalid/os' >"$SB/os-update-test-base"

cat >"$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
*api.github.com* | *seam.invalid*releases-latest.json)
    if [ "${CH_STUB_RC:-0}" != "0" ]; then exit "$CH_STUB_RC"; fi
    cat "${CH_API_RESPONSE:?}" >"$out"
    printf '200'
    ;;
*pithead-os-*)
    have=0
    [ -f "$out" ] && have=$(wc -c <"$out" | tr -d ' ')
    if [ "${CH_TRUNCATE:-0}" = 1 ]; then
        head -c 600 "${CH_BUNDLE:?}" >>"$out"
    else
        tail -c "+$((have + 1))" "${CH_BUNDLE:?}" >>"$out"
    fi
    printf '200'
    ;;
*) exit 22 ;;
esac
exit 0
EOF
cat >"$SB/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "rauc $*" >>"${RAUC_LOG:-/dev/null}"
case "$1" in
info)
    if [ "$#" -ge 2 ] && [ "$2" = "--output-format=shell" ]; then
        [ "${RAUC_INFO_FAIL:-0}" = 1 ] && exit 1
        printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VERSION='%s'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" \
            "${RAUC_BUNDLE_VERSION:-9.9.9}"
        exit 0
    fi
    [ "${RAUC_INFO_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
status)
    case "${2:-}" in
    --output-format=json)
        printf '{"booted":"A","slots":[{"rootfs.0":{"bootname":"A","state":"booted","boot_status":"good"}},{"rootfs.1":{"bootname":"B","state":"inactive","boot_status":"%s"}}]}\n' \
            "${RAUC_OTHER_STATUS:-good}"
        ;;
    esac
    exit 0
    ;;
install)
    [ "${RAUC_INSTALL_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
*) exit 0 ;;
esac
EOF
cat >"$SB/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 1000000 0 ${DF_AVAIL_KB:-999999999} 0% /data"
EOF
cat >"$SB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$SB/bin/pithead-tor" <<'EOF'
#!/usr/bin/env bash
echo "tor $*" >>"${TOR_LOG:-/dev/null}"
exec "$@"
EOF
cat >"$SB/reboot-stub" <<'EOF'
#!/usr/bin/env bash
echo reboot >>"${REBOOT_LOG:-/dev/null}"
EOF
chmod +x "$SB/bin/curl" "$SB/bin/rauc" "$SB/bin/df" "$SB/bin/systemctl" "$SB/bin/pithead-tor" "$SB/reboot-stub"
cp "$CLI" "$SB/pithead"
: >"$SB/rauc.log"
: >"$SB/curl.log"
: >"$SB/tor.log"
: >"$tmp/reboot.log"

rig() {
    local -a e=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
        *=*)
            e+=("$1")
            shift
            ;;
        *) break ;;
        esac
    done
    (cd "$SB" && PATH="$SB/bin:$PATH" CURL_LOG="$SB/curl.log" CH_API_RESPONSE="$SB/api.json" \
        CH_BUNDLE="$SB/fixture.raucb" RAUC_LOG="$SB/rauc.log" TOR_LOG="$SB/tor.log" \
        REBOOT_LOG="$tmp/reboot.log" PITHEAD_APPLIANCE=1 PITHEAD_OS_UPDATE_DIR="$STAGE" \
        PITHEAD_RIG_UPDATE_STATE="$SB/rig-update.json" PITHEAD_RIG_UPDATE_ATTEMPTS=3 \
        PITHEAD_VARIANT_FILE="$SB/variant-release" PITHEAD_RAUC_SYSTEM_CONF="$SB/system.conf" \
        PITHEAD_DATA_FLOOR_FILE="$SB/floor" PITHEAD_REBOOT_CMD="$SB/reboot-stub" \
        env ${e[@]+"${e[@]}"} ./pithead rig-update "$@" 2>&1)
}
state() { jq -r "$1" "$SB/rig-update.json" 2>/dev/null; }
staged() { find "$STAGE" -name 'pithead-os-*' | wc -l | tr -d ' '; }

out=$(rig check)
check_has "check reports both versions over the seam" "$out" "running v1.3.1, release channel offers v9.9.9 (1000 bytes)"
check "the seam check starts no Tor" "$(grep -c 'rig-update' "$SB/tor.log")" "0"

listing v9.9.9
rm -f "$SB/os-update-test-base"
out=$(rig check)
check_has "check passes with no seam" "$out" "release channel offers v9.9.9"
check_has "check starts Tor through the helper" "$(cat "$SB/tor.log")" "rig-update check"
check "the channel fetch dials the Tor SOCKS port" "$(grep -c -- '--socks5-hostname 127.0.0.1:9253' "$SB/curl.log")" "1"
printf 'http://seam.invalid/os' >"$SB/os-update-test-base"

out=$(rig check)
check_has "a frozen channel is reported" "$out" "stale or frozen"

out=$(rig CH_API_RESPONSE="$SB/api-evil-tag.json" check)
check_has "a tainted tag is refused" "$out" "no usable release tag"
check "the refusal is in the status file" "$(state .state)" "refused"
check_has "the status file names the reason" "$(state .reason)" "no usable release tag"

out=$(rig CH_API_RESPONSE="$SB/api-no-bundle.json" check)
check_has "a release without the OS bundle is refused" "$out" "publishes no appliance OS bundle"

out=$(rig install --max-version)
check "a missing --max-version value is refused" "$(printf '%s' "$out" | grep -c 'needs a version')" "1"

listing v1.3.1
out=$(rig install)
check_has "the equal version is refused" "$out" "already runs v1.3.1"
listing v1.0.0
out=$(rig install)
check_has "a downgrade is refused" "$out" "downgrade"
listing v9.9.9

out=$(rig install --max-version 2.0.0)
check_has "a tag above --max-version is refused semantically" "$out" "above --max-version v2.0.0"

out=$(rig install --tag v9-9-9)
check_has "an unparseable --tag is refused" "$out" "vX.Y.Z form"

jq -n '{state:"pending",from:"1.3.1",to:"9.9.9",ts:1}' >"$SB/rig-update.json"
out=$(rig install)
check_has "a pending update is refused" "$out" "pending a reboot"
check "the pending record survives the refusal" "$(state .state)" "pending"
check "the refusal names the pending target" "$(state .to)" "9.9.9"

rm -f "$SB/rig-update.json"
touch "$SB/.boot-gate-failures"
out=$(rig RAUC_OTHER_STATUS=unknown install)
check_has "an uncommitted other slot with a failed gate boot is refused" "$out" "uncommitted"
check "the uncommitted refusal keeps /data clean" "$(staged)" "0"
rm -f "$SB/.boot-gate-failures"

out=$(rig DF_AVAIL_KB=100 install)
check_has "a bundle larger than free /data is refused with a reason" "$out" "not enough free space on /data"

out=$(rig CH_TRUNCATE=1 install)
check_has "a truncated file is never verified as complete" "$out" "never verified as complete"
check "the truncated download staged no bundle" "$(staged)" "0"

out=$(rig RAUC_INFO_FAIL=1 install)
check_has "a mis-signed bundle is refused" "$out" "failed signature verification"
check "the mis-signed bundle is deleted" "$(staged)" "0"

out=$(rig RAUC_BUNDLE_VERSION=9.9.8 install)
check_has "a stamp mismatch against the tag is refused" "$out" "refusing a version-mismatched file"
check "the mismatched bundle is deleted" "$(staged)" "0"

out=$(rig RAUC_INSTALL_FAIL=1 install)
check_has "an install failure is refused with a reason" "$out" "could not be installed"
check "the failed install recorded no pending update" "$(state .state)" "refused"
check "the failed install kept nothing staged" "$(staged)" "0"

rauc_n=$(grep -c "rauc install $STAGE/pithead-os-v9.9.9.raucb" "$SB/rauc.log")
out=$(rig install)
check_has "the good install reboots to the spare slot" "$(cat "$tmp/reboot.log")" "reboot"
check "the install ran rauc install once" "$(( $(grep -c "rauc install $STAGE/pithead-os-v9.9.9.raucb" "$SB/rauc.log") - rauc_n ))" "1"
check "the pending record names the intent" "$(state .state)" "pending"
check "the pending record carries the target version" "$(state .to)" "9.9.9"
check "the bundle is deleted after the install" "$(staged)" "0"

printf '9.9.9\n' >"$SB/VERSION"
out=$(rig boot-record)
check_has "the boot settles the verdict as updated" "$out" "verdict updated"
check "the status file reads updated" "$(state .state)" "updated"

printf '2.0.0\n' >"$SB/VERSION"
jq -n '{state:"pending",from:"2.0.0",to:"9.9.9",ts:1}' >"$SB/rig-update.json"
yes x | head -c 10 >"$STAGE/pithead-os-v9.9.9.raucb"
out=$(rig boot-record)
check_has "the fallback boot records the rollback" "$out" "never committed"
check "the fallback verdict is in the status file" "$(state .state)" "rolled_back"
check_has "the fallback names the reason" "$(state .reason)" "miner never came up"
check "the failed slot was marked bad" "$(grep -c 'rauc status mark-bad other' "$SB/rauc.log")" "1"
check "the fallback boot swept the staged bundle" "$(staged)" "0"

if [ "$FAILURES" -ne 0 ]; then
    echo "selftest-rig-update: $FAILURES failed, $PASSES passed" >&2
    exit 1
fi
echo "selftest-rig-update OK ($PASSES checks)"
