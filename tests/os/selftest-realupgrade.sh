#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/realupgrade-helpers.sh
source "$HERE/realupgrade-helpers.sh"
FAILS=0
check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$name"; else
        printf 'FAIL %s\n' "$name"
        FAILS=$((FAILS + 1))
    fi
}
refuses() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL %s (accepted)\n' "$name"
        FAILS=$((FAILS + 1))
    else printf 'ok   %s\n' "$name"; fi
}
eq() {
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        FAILS=$((FAILS + 1))
    fi
}

eq "old tag is the greatest published tag below the tree" v2.0.2 "$(realupgrade_old_tag 2.0.3 v2.0.1 v2.0.3 v2.0.2 v1.20.0)"
eq "old tag ignores a newer published tag" v2.0.3 "$(realupgrade_old_tag 2.0.4 v2.0.3 v2.0.5)"
eq "old tag orders numerically, not lexically" v2.0.10 "$(realupgrade_old_tag 2.1.0 v2.0.9 v2.0.10)"
eq "old tag skips pre-releases and junk" v2.0.1 "$(realupgrade_old_tag 2.0.3 v2.0.2-rc1 latest v2.0.1)"
refuses "old tag fails when nothing is older" realupgrade_old_tag 1.0.0 v1.0.0 v2.0.0

check "a build with the fixes gets the strict cause rows" realupgrade_cause_applies v2.0.4
check "a later build gets the strict cause rows" realupgrade_cause_applies v2.1.0
refuses "v2.0.2 predates the fixes" realupgrade_cause_applies v2.0.2
refuses "v2.0.3 predates the fixes" realupgrade_cause_applies v2.0.3
refuses "a junk tag has no cause rows" realupgrade_cause_applies latest
eq "commit budget is the gate timeout plus 50%" 1350 "$(realupgrade_commit_budget_s 900)"
refuses "commit budget refuses a non-number" realupgrade_commit_budget_s abc
check "time within budget passes" realupgrade_within_budget 1349 1350
check "time at budget passes" realupgrade_within_budget 1350 1350
refuses "time over budget fails" realupgrade_within_budget 1351 1350
refuses "an unreadable time fails" realupgrade_within_budget "" 1350

check "default legs are valid" realupgrade_legs_valid "$REALUPGRADE_LEGS_DEFAULT"
check "negative control alone is selectable" realupgrade_legs_valid negctl
check "upgrade alone is selectable" realupgrade_legs_valid upgrade
check "upgrade plus soak is selectable" realupgrade_legs_valid upgrade,soak
refuses "soak without its upgrade is refused" realupgrade_legs_valid soak
refuses "soak then negctl without upgrade is refused" realupgrade_legs_valid soak,negctl
refuses "an unknown leg is refused" realupgrade_legs_valid upgrade,bogus
refuses "an empty list is refused" realupgrade_legs_valid ""
check "leg enabled when listed" realupgrade_leg_enabled negctl upgrade,negctl
refuses "leg disabled when not listed" realupgrade_leg_enabled negctl upgrade,soak
check "a leg is not matched by substring" bash -c 'source "$1"; ! realupgrade_leg_enabled up upgrade' _ "$HERE/realupgrade-helpers.sh"

stamp=$(realupgrade_stamp soak extra-reboot)
case "$stamp" in
realupgrade-leg\ 20??-??-??T??:??:??Z\ epoch=[0-9]*\ leg=soak\ event=extra-reboot) printf 'ok   leg stamp carries a UTC time, an epoch, the leg and the event\n' ;;
*)
    printf 'FAIL leg stamp shape: %s\n' "$stamp"
    FAILS=$((FAILS + 1))
    ;;
esac

check "an updated verdict is accepted" realupgrade_verdict_updated '{"verdict":{"outcome":"updated"}}'
refuses "a rolled_back verdict is refused" realupgrade_verdict_updated '{"verdict":{"outcome":"rolled_back","blocking":["x"]}}'
refuses "an absent verdict is refused" realupgrade_verdict_updated '{"step":"verifying"}'
check "verifying is not a reboot offer" realupgrade_no_offer_while_verifying '{"step":"verifying"}'
refuses "reboot-pending while verifying is a reboot offer" realupgrade_no_offer_while_verifying '{"step":"reboot-pending"}'
check "an unchanged fingerprint passes" realupgrade_fingerprint_same AB:CD AB:CD
refuses "a changed fingerprint fails" realupgrade_fingerprint_same AB:CD EF:01
refuses "an unread fingerprint fails" realupgrade_fingerprint_same "" ""
check "SANs compare order-insensitively" realupgrade_sans_same "DNS:a,IP:1.2.3.4,IP:fd00::1" "IP:fd00::1,DNS:a,IP:1.2.3.4"
refuses "a dropped late ULA SAN fails" realupgrade_sans_same "DNS:a,IP:fd00::1" "DNS:a"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkroot() {
    mkdir -p "$1/etc/rauc" "$1/etc/systemd/system"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$1/etc/rauc/keyring.pem" -days 2 -subj "/CN=release" 2>/dev/null
}
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/tk.pem" -out "$TMP/test-cert.pem" -days 2 -subj "/CN=test" 2>/dev/null
mkroot "$TMP/root"
cp "$TMP/root/etc/rauc/keyring.pem" "$TMP/release-before.pem"
check "patching a root succeeds" realupgrade_patch_root "$TMP/root" "$TMP/test-cert.pem" http://192.0.2.1:8932 "$TMP/manifest.json"
eq "the keyring now holds two certs" 2 "$(grep -c 'BEGIN CERTIFICATE' "$TMP/root/etc/rauc/keyring.pem")"
check "the release cert is still first and byte-identical" bash -c 'head -c "$(wc -c <"$1")" "$2" | cmp -s - "$1"' _ "$TMP/release-before.pem" "$TMP/root/etc/rauc/keyring.pem"
check "the test cert was appended" bash -c 'tail -c "$(wc -c <"$1")" "$2" | cmp -s - "$1"' _ "$TMP/test-cert.pem" "$TMP/root/etc/rauc/keyring.pem"
check "the seed unit is enabled" test -L "$TMP/root/etc/systemd/system/multi-user.target.wants/$REALUPGRADE_SEED_UNIT"
check "the seed script is executable" test -x "$TMP/root/usr/local/sbin/pithead-realupgrade-seed"
check "the seed script parses" sh -n "$TMP/root/usr/local/sbin/pithead-realupgrade-seed"
eq "the seam base is planted" http://192.0.2.1:8932 "$(cat "$TMP/root/etc/pithead-realupgrade-base")"
eq "the manifest records the keyring change" "1 2" "$(jq -r '"\(.keyring_certs_before) \(.keyring_certs_after)"' "$TMP/manifest.json")"
eq "the manifest lists every planted path" 6 "$(jq '.planted | length' "$TMP/manifest.json")"
check "every planted path exists in the root" bash -c 'jq -r ".planted[]" "$1" | while read -r p; do [ -e "$2$p" ] || [ -L "$2$p" ] || exit 1; done' _ "$TMP/manifest.json" "$TMP/root"
mkdir -p "$TMP/bare/etc/systemd/system"
refuses "a root with no keyring is refused" realupgrade_patch_root "$TMP/bare" "$TMP/test-cert.pem" http://192.0.2.1:8932 "$TMP/m2.json"
mkroot "$TMP/root2"
: >"$TMP/empty.pem"
refuses "an empty test cert is refused" realupgrade_patch_root "$TMP/root2" "$TMP/empty.pem" http://192.0.2.1:8932 "$TMP/m3.json"
eq "a refused patch leaves the keyring alone" 1 "$(grep -c 'BEGIN CERTIFICATE' "$TMP/root2/etc/rauc/keyring.pem")"

head -c 4096 /dev/urandom >"$TMP/payload"
openssl cms -sign -binary -outform DER -signer "$TMP/test-cert.pem" -inkey "$TMP/tk.pem" -in "$TMP/payload" -out "$TMP/sig.der" 2>/dev/null
sigsize=$(wc -c <"$TMP/sig.der" | tr -d ' ')
{
    cat "$TMP/payload" "$TMP/sig.der"
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x' 0 0 0 0 $((sigsize >> 24 & 255)) $((sigsize >> 16 & 255)) $((sigsize >> 8 & 255)) $((sigsize & 255)))"
} >"$TMP/bundle.raucb"
check "the signer certificate is read out of a bundle" realupgrade_bundle_cert "$TMP/bundle.raucb" "$TMP/signer.pem"
check "the extracted certificate is the signing certificate" bash -c 'diff <(openssl x509 -in "$1" -noout -fingerprint) <(openssl x509 -in "$2" -noout -fingerprint)' _ "$TMP/test-cert.pem" "$TMP/signer.pem"
refuses "a bundle with a bad size trailer is refused" realupgrade_bundle_cert "$TMP/payload" "$TMP/none.pem"
eq "the scratch root now claims the debug variant the candidate carries" debug "$(tr -d '\n' <"$TMP/root/etc/pithead-variant")"
good='{"verdict":{"outcome":"rolled_back","interrupted":true,"blocking":["interrupted before the update was verified"]}}'
v202='{"verdict":{"outcome":"rolled_back","from":"2.0.2","to":"2.0.3","blocking":[]}}'
eq "the cause row is a skip on an N-2 without the fixes" skip "$(realupgrade_cause_row v2.0.2 "$v202")"
eq "the cause row passes on a fixed build that names the cause" pass "$(realupgrade_cause_row v2.0.4 "$good")"
eq "the cause row fails on a fixed build with the v2.0.2 verdict shape" fail "$(realupgrade_cause_row v2.0.4 "$v202")"
eq "the cause row fails without the interrupted flag" fail "$(realupgrade_cause_row v2.0.4 '{"verdict":{"outcome":"rolled_back","blocking":["interrupted before the update was verified"]}}')"
eq "the cause row fails on an updated verdict" fail "$(realupgrade_cause_row v2.0.4 '{"verdict":{"outcome":"updated"}}')"
check "a skipped cause row is a counted missing skip, never an info line" grep -Fq 'skip) it_skip_leg "negctl rollback cause on $RU_TAG (#3909/#3910)" "$REALUPGRADE_CAUSE_SKIP_REASON" missing ;;' "$HERE/realupgrade-legs.sh"
refuses "the cause row is never reported as info" grep -Eq 'info "negctl.*(cause|#3909)' "$HERE/realupgrade-legs.sh"
eq "the skip reason names the missing input and the tracking issue" "no published N-2 carries #3909/#3910 (#4338)" "$REALUPGRADE_CAUSE_SKIP_REASON"
RUN="$HERE/run.sh"
check "the rollback cause needle is the text pithead-boot records" grep -Fq "$REALUPGRADE_ROLLBACK_CAUSE" "$HERE/../../os/overlay/pithead-boot"
check "run.sh usage line lists the phase" grep -Fq '|crossupdate|realupgrade|realupgrade-main|realupgrade-negctl|stack|' "$RUN"
check "run.sh dispatches the phase" grep -Fq 'realupgrade) _run_phase realupgrade phase_realupgrade ;;' "$RUN"
check "run.sh dispatches the split phases to their own legs" bash -c 'grep -Fq "realupgrade-main) _run_phase realupgrade-main phase_realupgrade_main ;;" "$1" && grep -Fq "realupgrade-negctl) _run_phase realupgrade-negctl phase_realupgrade_negctl ;;" "$2"' _ "$RUN" "$RUN"
refuses "no realupgrade phase is in the all arm" bash -c 'sed -n "/^all)/,/;;/p" "$1" | grep -q realupgrade' _ "$RUN"
check "the main split runs upgrade and soak only" grep -Fq 'phase_realupgrade_main() { _ru_run upgrade,soak; }' "$HERE/phases/realupgrade.sh"
check "the negctl split runs the negative control only" grep -Fq 'phase_realupgrade_negctl() { _ru_run negctl; }' "$HERE/phases/realupgrade.sh"

[ "$FAILS" -eq 0 ] || {
    printf '%d realupgrade selftest check(s) failed\n' "$FAILS" >&2
    exit 1
}
printf 'realupgrade selftest: all checks passed\n'
