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

echo "== unit: real status admits only the explicit migration stop and names active faults (#2383) =="
printf '2.0.0\n' >"$_BSH/migration-marker"
_bsh_status() { # <chain-state> <health>
    local chain_state="$1" chain_health="$2"
    (
        cd "$_BSH" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        env_get() { [ "$1" = COMPOSE_PROFILES ] && printf local_node || return 0; }
        dashboard_sync_progress() { return 1; }
        print_clearnet_banner() { :; }
        dashboard_onion_status() { return 1; }
        announce_stratum_auth() { :; }
        announce_stratum_tls() { :; }
        docker() {
            case "$*" in
            "compose ps") ;;
            "compose config --services") printf 'caddy\nmonerod\n' ;;
            "compose ps -aq caddy") printf 'caddy\n' ;;
            "compose ps -aq monerod") [ "$chain_state" != missing ] && printf 'monerod\n' ;;
            inspect*caddy) printf 'running healthy\n' ;;
            inspect*monerod) printf '%s %s\n' "$chain_state" "$chain_health" ;;
            esac
        }
        PITHEAD_MIGRATION_MARKER_FILE="$_BSH/migration-marker" PITHEAD_VERSION=2.0.0 stack_status
    )
}
_BSH_STATUS=$(_bsh_status missing none 2>&1)
_BSH_RC=$?
assert_rc "status: an explicitly migration-held missing chain service exits 0" "$_BSH_RC" "0"
assert_contains "status: the migration hold is reported" "$_BSH_STATUS" "intentionally held until this slot commits"
_BSH_STATUS=$(_bsh_status restarting none 2>&1)
_BSH_RC=$?
assert_rc "status: a restarting chain service under the migration hold exits 1" "$_BSH_RC" "1"
printf '%s\n' "$_BSH_STATUS" >"$_BSH/status.log"
_BSH_BLOCKING=$(bash -c 'source "$1"; BOOT_STATUS_LOG="$2"; boot_status_blocking' _ \
    "$ROOT/os/overlay/pithead-boot-stack-health" "$_BSH/status.log")
assert_contains "boot health names the restarting held-chain service" "$_BSH_BLOCKING" "container monerod: restarting"
_BSH_STATUS=$(_bsh_status running unhealthy 2>&1)
_BSH_RC=$?
assert_rc "status: an unhealthy chain service under the migration hold exits 1" "$_BSH_RC" "1"

echo "== unit: doctor judges a chain node left under compose's recreate name (#2556) =="
_bsh_revenue() { # <ps row: name<TAB>state<TAB>status>
    local row="$1"
    (
        cd "$_BSH" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        podman() { printf '%s\n' "$row"; }
        os_migration_hold_active() { return 1; }
        PITHEAD_ENGINE=podman check_revenue_containers
    ) 2>&1
}
_BSH_DOCTOR=$(_bsh_revenue "$(printf '4556c4f42f1d_monerod\texited\tExited (0) 5 seconds ago')")
assert_contains "doctor FAILs a stopped monerod that runs under compose's temporary name" "$_BSH_DOCTOR" "monerod is down"
_BSH_DOCTOR=$(_bsh_revenue "$(printf '4556c4f42f1d_monerod\trunning\tUp 5 minutes (healthy)')")
assert_contains "doctor passes the same node while it is up and healthy" "$_BSH_DOCTOR" "none crashed"
assert_eq "a name that only looks like a prefix is not a revenue container" \
    "$(run_sourced "$_BSH" revenue_container_verdict notahexid12_monerod exited 'Exited (0)')" "ok"

# The update phase's leg 5 fault bundle once broke the healthcheck inside the baked dashboard
# archive, but the shipped compose pins the dashboard to its signed registry digest, so the stack
# ran the healthy release image and the gate rightly committed (#2694). The fault must live in the
# compose file the slot ships, on the dashboard service, and nowhere else.
echo "== unit: the leg 5 fault breaks the dashboard healthcheck the shipped compose runs (#2694) =="
_bsh_break() { # <compose-file>
    (
        compose="$1"
        export PITHEAD_BUILD_IMAGE_TEST=1
        set -- # keep build-image.sh's arg loop off the compose path
        # shellcheck disable=SC1091
        source "$ROOT/os/build-image.sh"
        break_dashboard_healthcheck "$compose"
    ) 2>&1
}
cp "$ROOT/docker-compose.yml" "$_BSH/compose.yml"
_bsh_break "$_BSH/compose.yml" >/dev/null
assert_rc "the tree's compose carries one dashboard healthcheck to break" "$?" "0"
assert_eq "exactly one compose line changes" \
    "$(diff "$ROOT/docker-compose.yml" "$_BSH/compose.yml" | grep -c '^[<>]')" "2"
assert_contains "the dashboard service's healthcheck now always fails" \
    "$(awk '/^  [a-z]/ { svc = $1 } svc == "dashboard:" && /test:/' "$_BSH/compose.yml")" '["CMD-SHELL", "exit 1"]'
_BSH_OUT=$(_bsh_break "$_BSH/compose.yml")
assert_rc "a compose with no dashboard healthcheck to break refuses the fault build" "$?" "1"
assert_contains "the refusal names the missing healthcheck" "$_BSH_OUT" "no single dashboard healthcheck to break"
assert_contains "build-image applies the fault to the staged compose the slot ships" \
    "$(cat "$ROOT/os/build-image.sh")" "break_dashboard_healthcheck os/build/stage/docker-compose.yml || exit 1"
rm -rf "$_BSH"
unset -f _bsh_status _bsh_revenue _bsh_break
unset _BSH _BSH_MODE _BSH_ADVISORY _BSH_STATUS _BSH_RC _BSH_BLOCKING _BSH_OUT
