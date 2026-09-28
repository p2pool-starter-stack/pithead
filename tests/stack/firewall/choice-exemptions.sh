# shellcheck shell=bash
# Focused P2Pool and XvB opt-out rule selection and readback (#2790).
cnfw_apply false false '' true true false
assert_eq "P2Pool and enabled direct XvB receive only their own exemptions" "$(run_sourced "$V" tor_egress_sync_ips)" $'172.28.0.28\n172.28.0.29'
CN_CHOICE_BOOT="$(run_sourced "$V" render_tor_egress_boot_unit /usr/sbin/iptables 172.28.0.0/24 172.28.0.25 172.28.0.28 172.28.0.29)"
assert_contains "boot restores the selected P2Pool exemption" "$CN_CHOICE_BOOT" "-s 172.28.0.28 -j ACCEPT"
assert_contains "boot restores the selected XvB exemption" "$CN_CHOICE_BOOT" "-s 172.28.0.29 -j ACCEPT"
CN_CHOICE_RULES=$'-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.28 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.29 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP'
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_CHOICE_RULES"; then
    ok "readback accepts only the two selected choice exemptions"
else bad "readback accepts only the two selected choice exemptions" "live rule mismatch"; fi
cnfw_apply false false '' false false false
assert_eq "disabled XvB never exempts the proxy" "$(run_sourced "$V" tor_egress_sync_ips)" ""
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_CHOICE_RULES"; then
    bad "readback rejects stale choice exemptions" "accepted stale public-dial rules"
else ok "readback rejects stale choice exemptions"; fi
