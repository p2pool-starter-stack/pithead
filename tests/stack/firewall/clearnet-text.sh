# shellcheck shell=bash
# shellcheck disable=SC2329
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${V:?}" "${STACK:?}"

mk_tmpdir CT_DIR
mkdir -p "$CT_DIR/state" "$CT_DIR/control/results"
: >"$CT_DIR/.env"
cat >"$CT_DIR/host-uid.py" <<'PY'
import os, sys
from types import SimpleNamespace

real = os.fstat
os.fstat = lambda fd: SimpleNamespace(st_mode=real(fd).st_mode, st_ino=real(fd).st_ino, st_ctime_ns=real(fd).st_ctime_ns, st_uid=int(os.environ["CT_UID"]))
sys.argv = sys.argv[1:]
exec(compile(sys.stdin.read(), "attestation", "exec"))
PY

ct_attest() {
    printf '%s\n' "$2" >"$CT_DIR/state/$1.synced"
    chmod 644 "$CT_DIR/state/$1.synced"
    python3 - "$CT_DIR/state/$1.synced" "$CT_DIR/control/results/clearnet-$1-tor.json" "${3:-$2}" <<'PY'
import json, os, sys
st = os.stat(sys.argv[1])
with open(sys.argv[2], "w") as fh:
    json.dump({"status": "verified", "marker": sys.argv[3], "inode": st.st_ino, "ctime_ns": st.st_ctime_ns}, fh)
PY
}
ct_reset() { rm -f "$CT_DIR"/state/* "$CT_DIR"/control/results/*; }
ct_run() {
    (
        cd "$CT_DIR" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PROFILE="$1" MFLAG="$2" TFLAG="$3"
        env_get() {
            case "$1" in
            PITHEAD_PROFILE) printf '%s' "$PROFILE" ;;
            MONERO_CLEARNET_SYNC) printf '%s' "$MFLAG" ;;
            TARI_CLEARNET_SYNC) printf '%s' "$TFLAG" ;;
            CLEARNET_STATE_DIR) printf '%s' "$CT_DIR/state" ;;
            CONTROL_DIR) printf '%s' "$CT_DIR/control" ;;
            esac
        }
        CT_UID=$(($4 == 1 ? 0 : 1000))
        export CT_UID
        python3() { command python3 "$CT_DIR/host-uid.py" "$@"; }
        "$5" 2>&1
    )
}
ct_banner() { ct_run "$1" "$2" "$3" "$4" print_clearnet_banner; }
ct_doctor() { ct_run "$1" "$2" "$3" "$4" check_clearnet_initial_sync; }
CT_PENDING="CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING"
CT_TORONLY="all node P2P is Tor-only"
CT_PERF="uses clearnet by the Performance profile"

echo "== status banner and doctor row for a temporary clearnet override and Performance (#3083) =="
for profile in balance privacy ""; do
    ct_reset
    out=$(ct_banner "$profile" true false 0)
    assert_contains "${profile:-unset}: monero override unattested names Monero" "$out" "$CT_PENDING"
    assert_contains "${profile:-unset}: banner names only Monero" "$out" "    Monero P2P may expose"
    assert_contains "${profile:-unset}: monero override unattested -> doctor WARN" "$(ct_doctor "$profile" true false 0)" "WARN"
    out=$(ct_banner "$profile" false true 0)
    assert_contains "${profile:-unset}: banner names only Tari" "$out" "    Tari P2P may expose"
    assert_contains "${profile:-unset}: tari override unattested -> doctor WARN" "$(ct_doctor "$profile" false true 0)" "WARN"
    assert_contains "${profile:-unset}: both flags name Monero + Tari" "$(ct_banner "$profile" true true 0)" "Monero + Tari P2P may expose"
    assert_not_contains "${profile:-unset}: pending doctor never claims Tor-only" "$(ct_doctor "$profile" true true 0)" "$CT_TORONLY"

    ct_attest monero 00000000-0000-4000-8000-000000000001
    ct_attest tari 00000000-0000-4000-8000-000000000002
    assert_eq "${profile:-unset}: valid attestation clears the banner" "$(ct_banner "$profile" true true 1)" ""
    assert_contains "${profile:-unset}: valid attestation -> doctor Tor-only OK" "$(ct_doctor "$profile" true true 1)" "$CT_TORONLY"
    assert_not_contains "${profile:-unset}: valid attestation -> no doctor WARN" "$(ct_doctor "$profile" true true 1)" "WARN"

    assert_contains "${profile:-unset}: attestation the host does not own keeps the banner" "$(ct_banner "$profile" true true 0)" "$CT_PENDING"
    assert_contains "${profile:-unset}: attestation the host does not own keeps the WARN" "$(ct_doctor "$profile" true true 0)" "WARN"
    ct_attest monero 00000000-0000-4000-8000-000000000001 00000000-0000-4000-8000-000000000009
    out=$(ct_banner "$profile" true false 1)
    assert_contains "${profile:-unset}: stale attestation keeps the banner" "$out" "$CT_PENDING"
    assert_contains "${profile:-unset}: stale attestation keeps the WARN" "$(ct_doctor "$profile" true false 1)" "WARN"
    ct_reset
    assert_contains "${profile:-unset}: missing attestation keeps the banner" "$(ct_banner "$profile" true false 1)" "$CT_PENDING"
done

echo "== Performance keeps clearnet by choice: no pending text, never Tor-only =="
for flags in "true true" "true false" "false true"; do
    read -r ct_m ct_t <<<"$flags"
    ct_reset
    assert_eq "performance $flags: no PENDING banner" "$(ct_banner performance "$ct_m" "$ct_t" 0)" ""
    out=$(ct_doctor performance "$ct_m" "$ct_t" 0)
    assert_not_contains "performance $flags: no clearnet WARN" "$out" "WARN"
    assert_not_contains "performance $flags: never claims Tor-only" "$out" "$CT_TORONLY"
    assert_contains "performance $flags: the info line names the choice" "$out" "$CT_PERF"
    assert_eq "performance $flags: doctor prints exactly one line" "$(printf '%s\n' "$out" | grep -c .)" "1"
    ct_attest monero 00000000-0000-4000-8000-000000000001
    ct_attest tari 00000000-0000-4000-8000-000000000002
    assert_eq "performance $flags: attestation does not change the banner" "$(ct_banner performance "$ct_m" "$ct_t" 1)" ""
    assert_not_contains "performance $flags: attestation never yields Tor-only" "$(ct_doctor performance "$ct_m" "$ct_t" 1)" "$CT_TORONLY"
done
assert_contains "performance with both flags false has no node on clearnet" "$(ct_doctor performance false false 0)" "$CT_TORONLY"
rm -rf "$CT_DIR"
unset -f ct_attest ct_reset ct_run ct_banner ct_doctor
