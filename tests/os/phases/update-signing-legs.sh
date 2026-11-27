# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_update_signing_chain_leg() {
    info "leg 8 — rotated keyring, expired certificate with a correct clock, real RAUC verdict text (#4012)"
    local out
    out=$(
        _ssh bash -s 2>&1 <<'GUEST'
set -u
w=$(mktemp -d /data/signing-leg.XXXXXX)
trap 'rm -rf "$w"' EXIT
cd "$w"
year=$(date +%Y)
[ "$year" -ge 2026 ] || { echo "SIGNING_CLOCK_BAD $year"; exit 0; }
    mkroot() { openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.crt" -days 3650 -subj "/CN=signing-leg-$1" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null; }
    mkleaf() {
    openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=signing-leg-$1" 2>/dev/null
    openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -CAcreateserial -out "$1.crt" \
            -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n") \
        -not_before "$3" -not_after "$4" 2>/dev/null
}
    mkbundle() {
    rm -rf in && mkdir in
    head -c 4096 /dev/zero >in/rootfs.img
    printf '[update]\ncompatible=pithead-amd64\nversion=0.0.1\n[bundle]\nformat=plain\n[image.rootfs]\nfilename=rootfs.img\n' >in/manifest.raucm
    rauc bundle --cert="$1.crt" --key="$1.key" in "$1.raucb" >"$1.build.log" 2>&1 || { echo "SIGNING_BUNDLE_FAIL $1"; tail -3 "$1.build.log"; exit 0; }
}
past=20200101000000Z
past_end=20210101000000Z
future=20400101000000Z
mkroot r1
mkroot r2
mkleaf l1 r1 "$past" "$future"
mkleaf l2 r2 "$past" "$future"
mkleaf lx r1 "$past" "$past_end"
cat r1.crt r2.crt >transition.crt
for l in l1 l2 lx; do mkbundle "$l"; done
    verdict() {
    if rauc --keyring="$2" info "$3" >"$1.out" 2>&1; then echo "SIGNING_RESULT $1 pass"; else echo "SIGNING_RESULT $1 fail"; fi
}
verdict new_leaf_old_keyring r1.crt l2.raucb
verdict new_leaf_transition_keyring transition.crt l2.raucb
verdict old_leaf_transition_keyring transition.crt l1.raucb
verdict old_leaf_old_keyring r1.crt l1.raucb
verdict expired_leaf r1.crt lx.raucb
grep -q "certificate has expired" expired_leaf.out && echo "SIGNING_EXPIRED_TEXT yes" || { echo "SIGNING_EXPIRED_TEXT no"; tail -3 expired_leaf.out; }
mkdir bin
printf '#!/bin/sh\nexec /usr/bin/rauc --keyring=%s/r1.crt "$@"\n' "$w" >bin/rauc
chmod +x bin/rauc
res=$(cd /data/pithead && PATH="$w/bin:$PATH" ./pithead os-update "$w/lx.raucb" --yes </dev/null 2>&1)
echo "SIGNING_UPDATER_RC $?"
printf '%s\n' "$res" | grep -q "signing certificate expired" && echo "SIGNING_UPDATER_MSG yes" || echo "SIGNING_UPDATER_MSG no: $(printf '%s' "$res" | tail -2 | tr '\n' ' ')"
door=$(cd /data/pithead && PATH="$w/bin:$PATH" bash -c 'source ./pithead; os_verify_bundle_reason "$1" v0.0.1; echo "rc=$?"' _ "$w/lx.raucb" 2>&1 </dev/null)
case "$door" in *"signing certificate expired"*"rc=3") echo "SIGNING_DOOR yes" ;; *) echo "SIGNING_DOOR no: $door" ;; esac
reason=$(cd /data/pithead && bash -c 'source ./pithead; os_rauc_clock_reason "$1"' _ "$(cat "$w/expired_leaf.out")" 2>&1)
case "$reason" in *"signing certificate expired"*) echo "SIGNING_MAPPED yes" ;; *) echo "SIGNING_MAPPED no: $reason" ;; esac
GUEST
    )
    local line
    for line in new_leaf_old_keyring:fail new_leaf_transition_keyring:pass old_leaf_transition_keyring:pass old_leaf_old_keyring:pass expired_leaf:fail; do
        if printf '%s\n' "$out" | grep -qx "SIGNING_RESULT ${line%%:*} ${line##*:}"; then
            ok "leg 8: ${line%%:*} verdict is ${line##*:}"
        else
            bad "leg 8: ${line%%:*} did not come back ${line##*:} ($(printf '%s' "$out" | tail -4 | tr '\n' ' '))"
        fi
    done
    printf '%s\n' "$out" | grep -qx 'SIGNING_EXPIRED_TEXT yes' && ok "leg 8: RAUC reports an expired certificate in the text the updater recognises" || bad "leg 8: RAUC's expired-certificate text is not 'certificate has expired'"
    printf '%s\n' "$out" | grep -q '^SIGNING_UPDATER_RC [1-9]' && ok "leg 8: os-update refuses the expired-certificate bundle with a correct clock" || bad "leg 8: os-update did not refuse the expired-certificate bundle ($(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
    printf '%s\n' "$out" | grep -qx 'SIGNING_UPDATER_MSG yes' && ok "leg 8: the os-update refusal names the expired signing certificate" || bad "leg 8: the os-update refusal lacks the expired-certificate message"
    printf '%s\n' "$out" | grep -qx 'SIGNING_DOOR yes' && ok "leg 8: the dashboard verify door keeps the bundle and names the expired certificate" || bad "leg 8: the dashboard verify door gave the wrong verdict for the expired certificate"
    printf '%s\n' "$out" | grep -qx 'SIGNING_MAPPED yes' && ok "leg 8: the updater turns RAUC's real expired verdict into the clock and rotation message" || bad "leg 8: the updater did not map RAUC's real expired verdict"
}
_update_wrong_clock_leg() {
    info "leg 9 — a wrong clock is refused with a clear message and the clock is restored (#4012)"
    local out
    out=$(
        _ssh bash -s 2>&1 <<'GUEST'
set -u
ntp=$(timedatectl show -p NTP --value 2>/dev/null || echo yes)
start=$(date +%s)
mark=$SECONDS
    restore() {
    date -s "@$((start + SECONDS - mark))" >/dev/null 2>&1
    [ "$ntp" = no ] || timedatectl set-ntp true >/dev/null 2>&1 || true
    echo "CLOCK_RESTORED $(date +%Y)"
}
trap restore EXIT
timedatectl set-ntp false >/dev/null 2>&1 || true
date -s '2001-01-01 00:00:00' >/dev/null 2>&1
: >/data/clock-leg.bundle
cd /data/pithead
res=$(./pithead os-update /data/clock-leg.bundle --yes </dev/null 2>&1)
echo "CLOCK_RC $?"
printf '%s\n' "$res" | tail -3 | sed 's/^/CLOCK_OUT /'
rm -f /data/clock-leg.bundle
GUEST
    )
    printf '%s\n' "$out" | grep -q '^CLOCK_RC [1-9]' && ok "leg 9: os-update refuses on a clock before the keyring existed" || bad "leg 9: os-update did not refuse on a wrong clock ($(printf '%s' "$out" | tail -4 | tr '\n' ' '))"
    printf '%s\n' "$out" | grep -q "CLOCK_OUT.*clock reads" && ok "leg 9: the refusal names the clock" || bad "leg 9: the refusal does not name the clock"
    printf '%s\n' "$out" | grep -q '^CLOCK_RESTORED 202[6-9]' && ok "leg 9: the guest clock was put back" || bad "leg 9: the guest clock was not restored"
}
phase_update_signing_legs() {
    if [ "${LEG4_PITHEAD_BOOT_PROVED:-0}" != "1" ]; then
        it_skip_leg "signing-chain rotation and wrong-clock legs (#4012)" \
            "leg 4 did not reach a committed, provisioned guest on this run, so there is no pithead CLI on the guest to judge a clock" missing
        return
    fi
    _update_signing_chain_leg
    _update_wrong_clock_leg
}
