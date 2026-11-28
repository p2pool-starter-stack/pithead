#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
CLI="$REPO/pithead"

if [ ! -x "$CLI" ]; then
    echo "selftest-os-update-clock: $CLI is not built — run make first" >&2
    exit 1
fi

FAILURES=0
PASSES=0
check() {
    if [ "$2" = "$3" ]; then PASSES=$((PASSES + 1)); else
        FAILURES=$((FAILURES + 1))
        echo "selftest-os-update-clock: FAIL: $1 — expected [$3], got [$2]" >&2
    fi
}
check_has() {
    case "$2" in
    *"$3"*) PASSES=$((PASSES + 1)) ;;
    *)
        FAILURES=$((FAILURES + 1))
        echo "selftest-os-update-clock: FAIL: $1 — [$2] missing [$3]" >&2
        ;;
    esac
}
check_lacks() {
    case "$2" in
    *"$3"*)
        FAILURES=$((FAILURES + 1))
        echo "selftest-os-update-clock: FAIL: $1 — [$2] contains [$3]" >&2
        ;;
    *) PASSES=$((PASSES + 1)) ;;
    esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/root.key" -out "$tmp/keyring.pem" \
    -days 30 -subj "/CN=pithead-clock-selftest-root" >/dev/null 2>&1 || {
    echo "selftest-os-update-clock: could not mint a test root" >&2
    exit 1
}
printf 'compatible=pithead-amd64\n' >"$tmp/system.conf"
printf 'release\n' >"$tmp/variant"
printf "RAUC_MF_COMPATIBLE='pithead-amd64'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$tmp/info.txt"
cat >"$tmp/bin/rauc" <<'STUB'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    [ -n "${RAUC_INFO_ERR:-}" ] && echo "$RAUC_INFO_ERR" >&2
    exit "${RAUC_INFO_RC:-0}"
    ;;
install) exit 0 ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/rauc"
: >"$tmp/bundle.raucb"
: >"$tmp/calls"

NOW=$(date +%s)
PAST=$((NOW - 315360000))

run_cli() {
    (
        cd "$tmp" || exit 1
        PATH="$tmp/bin:$PATH" RAUC_LOG="$tmp/calls" RAUC_INFO_OUT="$tmp/info.txt" \
            PITHEAD_VARIANT_FILE="$tmp/variant" PITHEAD_RAUC_SYSTEM_CONF="$tmp/system.conf" \
            PITHEAD_RAUC_KEYRING_FILE="$tmp/keyring.pem" PITHEAD_MIGRATION_MARKER_FILE="$tmp/marker" \
            env "$@" bash "$CLI" os-update "$tmp/bundle.raucb" --yes </dev/null 2>&1
    )
}
run_door() {
    (
        cd "$tmp" || exit 1
        PATH="$tmp/bin:$PATH" RAUC_LOG="$tmp/calls" RAUC_INFO_OUT="$tmp/info.txt" \
            PITHEAD_VARIANT_FILE="$tmp/variant" PITHEAD_RAUC_SYSTEM_CONF="$tmp/system.conf" \
            PITHEAD_RAUC_KEYRING_FILE="$tmp/keyring.pem" PITHEAD_MIGRATION_MARKER_FILE="$tmp/marker" \
            env "$@" bash -c 'source "$1"; set +e; os_verify_bundle_reason "$2" v9.9.9; echo "rc=$?"' _ "$CLI" "$tmp/bundle.raucb"
    ) 2>&1
}

: >"$tmp/calls"
out=$(run_cli PITHEAD_CLOCK_EPOCH="$PAST")
check_has "a clock earlier than the keyring's issue date is refused with the clock named" "$out" "clock reads"
check_has "the refusal tells the operator how to recover" "$out" "timedatectl set-time"
check_lacks "rauc is never asked to judge the bundle on a wrong clock" "$(cat "$tmp/calls")" "info"
check_lacks "rauc install is never reached on a wrong clock" "$(cat "$tmp/calls")" "install"

: >"$tmp/calls"
out=$(run_door PITHEAD_CLOCK_EPOCH="$PAST")
check_has "the dashboard door reports the wrong clock" "$out" "clock reads"
check_has "the dashboard door keeps the staged bundle on a wrong clock" "$out" "rc=3"
check_lacks "the dashboard door does not blame the signature on a wrong clock" "$out" "failed signature verification"
check_lacks "the dashboard door never calls rauc on a wrong clock" "$(cat "$tmp/calls")" "info"

: >"$tmp/calls"
out=$(run_cli PITHEAD_CLOCK_EPOCH="$NOW")
check_lacks "a clock inside the keyring's validity is not refused" "$out" "clock reads"
check_has "a correct clock reaches rauc info and install" "$(cat "$tmp/calls")" "install"

: >"$tmp/calls"
out=$(run_cli RAUC_INFO_RC=1 RAUC_INFO_ERR="signature verification failed: Verify error:certificate has expired")
check_has "an expired certificate names the clock and the rotation policy" "$out" "Signing key lifetime and rotation"
check_has "an expired certificate is reported as expired" "$out" "signing certificate expired"
check_lacks "rauc install is never reached on an expired certificate" "$(cat "$tmp/calls")" "install"

out=$(run_cli RAUC_INFO_RC=1 RAUC_INFO_ERR="signature verification failed: Verify error:certificate is not yet valid")
check_has "a not-yet-valid certificate is reported as such" "$out" "signing certificate not yet valid"

out=$(run_door RAUC_INFO_RC=1 RAUC_INFO_ERR="signature verification failed: Verify error:certificate has expired")
check_has "the dashboard door keeps the bundle on an expired certificate" "$out" "rc=3"
check_has "the dashboard door names the certificate verdict" "$out" "signing certificate expired"

out=$(run_door RAUC_INFO_RC=1 RAUC_INFO_ERR="signature verification failed: Verify error:self-signed certificate")
check_has "another signature failure still deletes the bundle as before" "$out" "failed signature verification"
check_has "another signature failure still returns the delete verdict" "$out" "rc=0"

out=$(run_cli PITHEAD_RAUC_KEYRING_FILE="$tmp/missing.pem" PITHEAD_CLOCK_EPOCH="$PAST")
check_lacks "an unreadable keyring sets no floor and leaves the verdict to rauc" "$out" "clock reads"
check_lacks "an unreadable keyring does not trip the abort trap" "$out" "aborted unexpectedly"

mkdir -p "$tmp/ca/new"
: >"$tmp/ca/index.txt"
printf '01\n' >"$tmp/ca/serial"
cat >"$tmp/ca/ca.cnf" <<CNF
[ca]
default_ca = CA_default
[CA_default]
dir = $tmp/ca
database = \$dir/index.txt
new_certs_dir = \$dir/new
serial = \$dir/serial
default_md = sha256
policy = pol
unique_subject = no
[pol]
commonName = supplied
CNF
openssl req -new -key "$tmp/root.key" -out "$tmp/future.csr" -subj "/CN=pithead-clock-selftest-new-root" >/dev/null 2>&1
openssl ca -batch -notext -selfsign -config "$tmp/ca/ca.cnf" -keyfile "$tmp/root.key" -in "$tmp/future.csr" \
    -startdate 20300101000000Z -enddate 20400101000000Z -out "$tmp/future.crt" >/dev/null 2>&1 || {
    echo "selftest-os-update-clock: could not mint a future-dated root" >&2
    exit 1
}
cat "$tmp/keyring.pem" "$tmp/future.crt" >"$tmp/transition.pem"
FUTURE_FLOOR=1893456001
out=$(run_cli PITHEAD_RAUC_KEYRING_FILE="$tmp/transition.pem" PITHEAD_CLOCK_EPOCH="$NOW")
check_has "the floor is the newest certificate of a transition keyring" "$out" "clock reads"
out=$(run_cli PITHEAD_RAUC_KEYRING_FILE="$tmp/transition.pem" PITHEAD_CLOCK_EPOCH="$FUTURE_FLOOR")
check_lacks "a clock past every certificate of the transition keyring is not refused" "$out" "clock reads"

echo "selftest-os-update-clock: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ]
