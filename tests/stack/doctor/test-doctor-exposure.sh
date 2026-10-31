# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Stratum-exposure surface domain (#1772). The exposure CHECK itself — the bind x public-IP x mode
# matrix — is proven in test-doctor.sh and is not re-proven here. What this domain owns is the one
# thing that matrix cannot see: WHO READS THE VERDICT, and what the verdict is therefore allowed to
# say. Since #1736 `control_diag_doctor` runs `doctor --json` and ships every recorded message to
# the dashboard, so this check has two audiences that want different text, and one of them is a
# browser on the network.
#
# TWO CLAIMS, and they fail in opposite directions:
#   1. The doctor arms must not carry the host's public ADDRESS. `bundle_redact_log`
#      (07-support-bundle.sh) is the only redactor on that path and it keys on argv position, the
#      onion shape and the Monero shape -- it has NO IP rule, so nothing downstream removes the
#      value and it has to be absent from the message. (tests/integration/lib.sh's redact() does
#      have one, but that twin guards CI artifact uploads from a self-hosted runner, not this path.)
#   2. The APPLIANCE arm names the dashboard Configuration route #1959 makes available, plus the
#      router firewall the operator already owns.
# The setup console is the deliberate exception and is asserted to KEEP the address: it prints to
# the operator's own terminal on their own host, where the value is what makes the finding
# actionable, and it goes nowhere.
#
# THE ABSENCE CLAIMS NEED THE CONSOLE ROW TO BE MEANINGFUL, which is why it is not merely a nicety.
# "8.8.8.8 does not appear in the doctor output" is satisfied just as well by a broken stub whose
# address never reached ANY output. The console row is the positive control on the same instrument
# in the same file: it proves the stubbed address does reach a surface, so its absence elsewhere is
# a fact about the wording rather than about the fixture.
#
# Standalone-sourceable once tests/stack/lib.sh has been sourced; it builds its own `ip` stub rather
# than borrowing test-doctor.sh's, so neither domain can break the other by reordering.

echo "== unit: doctor's stratum-exposure verdict is worded for its surface (#1772) =="
XPBIN="$SANDBOX/xpbin"
mkdir -p "$XPBIN"
{
    printf '#!/usr/bin/env bash\n'
    printf 'cat <<'\''ADDRS'\''\n2: eth0    inet 8.8.8.8/24 scope global eth0\nADDRS\n'
} >"$XPBIN/ip"
chmod +x "$XPBIN/ip"
_xp() { STRATUM_BIND=0.0.0.0 PITHEAD_APPLIANCE="$1" PATH="$XPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure "$2" 2>&1; }

# THE POSITIVE CONTROL, and every ABSENT row below leans on it: the setup console names the address.
_xp_console=$(_xp 0 setup)
assert_contains "the setup console still names the address it found (#1772)" "$_xp_console" "8.8.8.8"

# The host doctor arm keeps its remedies -- it is the DIY wording -- but loses the value, because
# `dr_warn` records into DR_JSON_FILE and a host box with dashboard.control.enabled reaches the
# same browser an appliance does.
_xp_host=$(_xp 0 doctor)
assert_contains "the host doctor verdict still reports the exposure (#1772)" "$_xp_host" "public IP"
assert_not_contains "the host doctor verdict withholds the address (#1772)" "$_xp_host" "8.8.8.8"
assert_contains "the host doctor verdict keeps its host remedies (#1772)" "$_xp_host" "stratum_bind"

# The appliance arm: same finding, no value, and only remedies the operator can reach.
_xp_appl=$(_xp 1 doctor)
assert_contains "the appliance verdict still reports the exposure (#1772)" "$_xp_appl" "public IP"
assert_not_contains "the appliance verdict withholds the address (#1772)" "$_xp_appl" "8.8.8.8"
assert_not_contains "the appliance verdict does not prescribe the LAN firewall (#1772)" "$_xp_appl" "firewall it to your LAN"
assert_contains "the appliance verdict names the router remedy (#1772)" "$_xp_appl" "router"
assert_contains "the appliance verdict names the Configuration editor (#1959)" "$_xp_appl" "Open Configuration"
assert_contains "the appliance verdict names confirmation (#1959)" "$_xp_appl" "confirmation step"

# NO SEPARATE "the two arms differ" ROW. It would be STRICTLY ENTAILED by the pair above -- the host
# arm CONTAINS stratum_bind and the appliance arm does not -- so if the surface switch never flipped,
# the appliance rows red on their own and the differ row could never be the only red. That is the
# same redundant-control defect #1776's review found in this suite; not repeated here.

echo "== unit: a narrowed bind to the host's OWN public address still warns (#1803) =="
# The bind x public-IP CASE lives in test-doctor.sh; this domain's angle is the one thing that
# matrix can't see -- a bind narrowed to 8.8.8.8 itself is exactly as internet-reachable as
# 0.0.0.0, so it must reach the same withheld-address doctor verdict as the exposed row above,
# never the "not publicly exposed" OK a LAN-narrowed bind gets.
_xp_narrowed_public=$(STRATUM_BIND=8.8.8.8 PITHEAD_APPLIANCE=0 PATH="$XPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)
assert_contains "doctor still warns on a bind narrowed to its own public address (#1803)" "$_xp_narrowed_public" "public IP"
assert_not_contains "doctor withholds that public bind address too (#1803)" "$_xp_narrowed_public" "8.8.8.8"

echo "== unit: doctor reads rendered stratum mitigations (#2461) =="
_xp_env="$SANDBOX/exposure-env"
mkdir -p "$_xp_env"
for _xp_surface in 0 1; do
    for _xp_password in '' fixture-password; do
        for _xp_tls in false true; do
            printf 'PROXY_STRATUM_PASSWORD=%s\nPROXY_STRATUM_TLS=%s\n' "$_xp_password" "$_xp_tls" >"$_xp_env/.env"
            _xp_row="surface=$_xp_surface password=${_xp_password:+set} TLS=$_xp_tls"
            _xp_out=$(STRATUM_BIND=0.0.0.0 PITHEAD_APPLIANCE="$_xp_surface" PATH="$XPBIN:$PATH" run_sourced "$_xp_env" check_stratum_exposure doctor 2>&1)
            assert_not_contains "$_xp_row: no FAIL" "$_xp_out" "FAIL"
            assert_not_contains "$_xp_row: no public address" "$_xp_out" "8.8.8.8"
            assert_not_contains "$_xp_row: no password value" "$_xp_out" "fixture-password"
            assert_not_contains "$_xp_row: never OK for exposure" "$_xp_out" "OK"
            if [ -n "$_xp_password" ] && [ "$_xp_tls" = true ]; then
                assert_contains "$_xp_row: INFO with both mitigations" "$_xp_out" "•"
                assert_not_contains "$_xp_row: no WARN with both mitigations" "$_xp_out" "WARN"
                assert_contains "$_xp_row: TLS remains per rig" "$_xp_out" "rigs not switched to TLS still connect in cleartext"
            else
                assert_contains "$_xp_row: WARN with incomplete mitigations" "$_xp_out" "WARN"
                if [ -n "$_xp_password" ]; then
                    assert_contains "$_xp_row: acknowledges password" "$_xp_out" "requires a password but is still cleartext"
                    assert_not_contains "$_xp_row: no unauthenticated claim" "$_xp_out" "unauthenticated"
                elif [ "$_xp_tls" = true ]; then
                    assert_contains "$_xp_row: TLS-only caveat" "$_xp_out" "rigs not switched to TLS still connect in cleartext without authentication"
                else
                    assert_contains "$_xp_row: default warning unchanged" "$_xp_out" "unauthenticated"
                    assert_contains "$_xp_row: default cleartext warning" "$_xp_out" "cleartext"
                fi
            fi
            _xp_setup=$(STRATUM_BIND=0.0.0.0 PITHEAD_APPLIANCE="$_xp_surface" PATH="$XPBIN:$PATH" run_sourced "$_xp_env" check_stratum_exposure setup 2>&1)
            assert_eq "$_xp_row: setup warning unchanged" "$_xp_setup" "$_xp_console"
        done
    done
done

echo "== unit: auto-heal requires dashboard control (#3166) =="
build_doctor_stubs
for _xp_surface in 0 1; do
    for _xp_heal in false true; do
        for _xp_control in false true; do
            printf 'TOR_AUTO_HEAL=%s\nDASHBOARD_CONTROL_ENABLED=%s\n' "$_xp_heal" "$_xp_control" >"$_xp_env/.env"
            _xp_row="surface=$_xp_surface heal=$_xp_heal control=$_xp_control"
            _xp_out=$(PITHEAD_APPLIANCE="$_xp_surface" RUNNING_CONTAINERS=tor PATH="$DRBIN:$PATH" run_sourced "$_xp_env" check_tor_running 2>&1)
            assert_not_contains "$_xp_row: prerequisite never FAILs" "$_xp_out" "FAIL"
            if [ "$_xp_heal" = true ] && [ "$_xp_control" = false ]; then
                assert_contains "$_xp_row: INFO for inert heal" "$_xp_out" "•"
                assert_contains "$_xp_row: describes limitation" "$_xp_out" "only probes and logs"
                assert_contains "$_xp_row: names login" "$_xp_out" "dashboard login"
                assert_contains "$_xp_row: names control" "$_xp_out" "enable dashboard control"
                assert_contains "$_xp_row: manual recovery" "$_xp_out" "restart Tor by hand"
            else
                assert_not_contains "$_xp_row: no inert-heal diagnostic" "$_xp_out" "only probes and logs"
            fi
        done
    done
    _xp_out=$(PITHEAD_APPLIANCE="$_xp_surface" RUNNING_CONTAINERS=p2pool PATH="$DRBIN:$PATH" run_sourced "$_xp_env" check_tor_running 2>&1)
    if [ "$_xp_surface" = 0 ]; then
        assert_contains "Tor down hint names control prerequisite" "$_xp_out" "dashboard.control.enabled:true"
    fi
done

# Force only the SOCKS probe to fail; no external connection is attempted.
printf '#!/usr/bin/env bash\nexit 1\n' >"$DRBIN/curl"
chmod +x "$DRBIN/curl"
_xp_out=$(PITHEAD_APPLIANCE=0 RUNNING_CONTAINERS=tor PATH="$DRBIN:$PATH" run_sourced "$_xp_env" check_tor_clearnet_egress 2>&1)
assert_contains "Tor egress hint names control prerequisite" "$_xp_out" "dashboard.control.enabled:true"
assert_contains "Tor egress hint names login prerequisite" "$_xp_out" "dashboard login"
