#!/usr/bin/env bash
# pithead-boot's status record carries secrets, so it must not inherit a readable-by-others mode.
_bsh=$(mktemp -d)
cat >"$_bsh/pithead" <<'EOF'
#!/usr/bin/env bash
case "$1" in
doctor) printf '{"checks":[]}\n' ;;
status) printf 'secret status output\n' ;;
esac
EOF
chmod +x "$_bsh/pithead"
(
    cd "$_bsh" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot"
    BOOT_DOCTOR_JSON="$_bsh/doctor.json"
    BOOT_STATUS_LOG="$_bsh/status.log"
    gate_ready 200 1
)
_bsh_mode=$(stat -c %a "$_bsh/status.log" 2>/dev/null || stat -f %Lp "$_bsh/status.log")
assert_eq "boot's status record is 0600 (#2383)" "$_bsh_mode" "600"
assert_contains "boot's status record holds status output" "$(cat "$_bsh/status.log")" "secret status output"
assert_contains "the image installs the sourced stack-health sibling" \
    "$(grep -F 'pithead-boot-stack-health' "$ROOT/os/rootfs/Dockerfile")" "pithead-boot-stack-health"
rm -rf "$_bsh"
unset _bsh _bsh_mode
