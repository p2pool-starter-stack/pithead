#!/usr/bin/env bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# pithead-boot's status record carries secrets, so it must not inherit a readable-by-others mode.
echo "== unit: boot status record is private and installed with its stack-health helper (#2383) =="
mk_tmpdir _BSH
cat >"$_BSH/pithead" <<'EOF'
#!/usr/bin/env bash
case "$1" in
doctor) printf '{"checks":[]}\n' ;;
status) printf 'secret status output\n' ;;
esac
EOF
chmod +x "$_BSH/pithead"
(
    cd "$_BSH" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot"
    BOOT_DOCTOR_JSON="$_BSH/doctor.json"
    BOOT_STATUS_LOG="$_BSH/status.log"
    gate_ready 200 1
)
_BSH_MODE=$(stat -c %a "$_BSH/status.log" 2>/dev/null || stat -f %Lp "$_BSH/status.log")
assert_eq "boot's status record is 0600 (#2383)" "$_BSH_MODE" "600"
assert_contains "boot's status record holds status output" "$(cat "$_BSH/status.log")" "secret status output"
assert_contains "the image installs the sourced stack-health sibling" \
    "$(grep -F 'pithead-boot-stack-health' "$ROOT/os/rootfs/Dockerfile")" "pithead-boot-stack-health"
printf '{"checks":[{"status":"fail","message":"The dashboard certificate does not cover: test"}]}\n' >"$_BSH/doctor.json"
cat >"$_BSH/pithead" <<'EOF'
#!/usr/bin/env bash
[ "$1" = status ] && exit 1
EOF
_BSH_ADVISORY=$(
    cd "$_BSH" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot"
    # shellcheck disable=SC2034 # read by the sourced gate helper
    BOOT_DOCTOR_JSON="$_BSH/doctor.json"
    # shellcheck disable=SC2034 # read by the sourced gate helper
    BOOT_STATUS_LOG="$_BSH/status.log"
    # shellcheck disable=SC2034 # read by the sourced advisory helper
    gate_remint_state=unchanged
    gate_cert_advisory_ready && echo commit || echo held
)
assert_eq "certificate-only doctor advisory with unhealthy status -> held" "$_BSH_ADVISORY" "held"
rm -rf "$_BSH"
unset _BSH _BSH_MODE _BSH_ADVISORY
