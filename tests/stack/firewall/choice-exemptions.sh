# shellcheck shell=bash
# Focused P2Pool and XvB opt-out rule selection and readback (#2790).
cnfw_apply false false '' true true false
assert_eq "P2Pool and enabled direct XvB receive only their own exemptions" "$(run_sourced "$V" tor_egress_sync_ips)" $'172.28.0.28\n172.28.0.29'
CN_CHOICE_BOOT="$(run_sourced "$V" render_tor_egress_boot_unit /usr/sbin/iptables 172.28.0.0/24 172.28.0.25 172.28.0.28 172.28.0.29)"
assert_contains "boot restores the selected P2Pool exemption" "$CN_CHOICE_BOOT" "-s 172.28.0.28 -j ACCEPT"
assert_contains "boot restores the selected XvB exemption" "$CN_CHOICE_BOOT" "-s 172.28.0.29 -j ACCEPT"
assert_contains "boot checks P2Pool's current choice marker" "$CN_CHOICE_BOOT" "$(run_sourced "$V" tor_egress_choice_marker)/p2pool"
assert_contains "boot checks XvB's current choice marker" "$CN_CHOICE_BOOT" "$(run_sourced "$V" tor_egress_choice_marker)/xvb"
# Keep the old unit text, as if its rewrite failed after disabling P2Pool. Its ExecStart must
# read the current marker and refuse to restore the stale ACCEPT on the next boot.
CN_BOOT_CALLS="$V/choice-boot-calls"
export CN_BOOT_CALLS
cat >"$V/bin/choice-boot-iptables" <<'IPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CN_BOOT_CALLS"
IPT
chmod +x "$V/bin/choice-boot-iptables"
CN_OLD_BOOT="$(run_sourced "$V" render_tor_egress_boot_unit "$V/bin/choice-boot-iptables" 172.28.0.0/24 172.28.0.25 172.28.0.28)"
CN_OLD_ACCEPT="$(sed -n "/-s 172.28.0.28 -j ACCEPT/s/^ExecStart=\/bin\/bash -c '\(.*\)'$/\1/p" <<<"$CN_OLD_BOOT")"
assert_eq "old boot unit has a runnable conditional choice rule" "$([ -n "$CN_OLD_ACCEPT" ] && echo yes)" yes
: >"$CN_BOOT_CALLS"
bash -c "$CN_OLD_ACCEPT"
assert_contains "selected choice restores its boot ACCEPT" "$(cat "$CN_BOOT_CALLS")" "-s 172.28.0.28 -j ACCEPT"
rmdir "$(run_sourced "$V" tor_egress_choice_marker)/p2pool"
: >"$CN_BOOT_CALLS"
bash -c "$CN_OLD_ACCEPT"
assert_eq "old boot unit cannot restore a disabled choice after rewrite failure" "$(cat "$CN_BOOT_CALLS")" ""
CN_CHOICE_NFT="$(run_sourced "$V" render_tor_egress_nft 172.28.0.0/24 172.28.0.25 '' 172.28.0.28 172.28.0.29)"
assert_contains "nft permits P2Pool before the subnet drop" "$CN_CHOICE_NFT" "ip saddr 172.28.0.28 accept"
assert_contains "nft permits XvB before the subnet drop" "$CN_CHOICE_NFT" "ip saddr 172.28.0.29 accept"
CN_CHOICE_NFT_LIVE='{"nftables":[{"chain":{"name":"forward"}},
{"rule":{"chain":"forward","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"172.28.0.28"}},{"accept":null}]}},
{"rule":{"chain":"forward","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"172.28.0.29"}},{"accept":null}]}},
{"rule":{"chain":"forward","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"172.28.0.0","len":24}}}},{"drop":null}]}}]}'
if run_sourced "$V" tor_egress_sync_rules_match nft "$CN_CHOICE_NFT_LIVE"; then
    ok "nft readback accepts both selected choice exemptions"
else bad "nft readback accepts both selected choice exemptions" "live rule mismatch"; fi
CN_CHOICE_RULES=$'-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.28 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.29 -j ACCEPT\n-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP'
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_CHOICE_RULES"; then
    ok "readback accepts only the two selected choice exemptions"
else bad "readback accepts only the two selected choice exemptions" "live rule mismatch"; fi
cnfw_apply false false '' false false false
assert_eq "disabled XvB never exempts the proxy" "$(run_sourced "$V" tor_egress_sync_ips)" ""
if run_sourced "$V" tor_egress_sync_rules_match nft "$CN_CHOICE_NFT_LIVE"; then
    bad "nft readback rejects stale choice exemptions" "accepted stale public-dial rules"
else ok "nft readback rejects stale choice exemptions"; fi
if run_sourced "$V" tor_egress_sync_rules_match iptables "$CN_CHOICE_RULES"; then
    bad "readback rejects stale choice exemptions" "accepted stale public-dial rules"
else ok "readback rejects stale choice exemptions"; fi
