# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

eau_set() {
    jq -n --argjson w "$1" --argjson a "$2" --argjson c "$3" \
        '{nftables: [{rule: {comment: "would_drop", expr: [{counter: {packets: $w, bytes: 0}}]}},
        {rule: {comment: "allowlisted", expr: [{counter: {packets: $a, bytes: 0}}]}},
        {rule: {comment: "choice", expr: [{counter: {packets: $c, bytes: 0}}]}}]}' >"$EAU/json"
}
echo "== egress-status: the watchdog compares would_drop across consecutive checks (#4385) =="
eau_wd() { jq -c "$1" "$EAU/ctl/results/egress-status.json"; }
rm -f "$EAU/ctl/results/.egress-audit-prev"
cp "$EAU/json" "$EAU/json.base"
eau_status egress_status >/dev/null
assert_eq "a first check has no baseline, so it is clean, never a leak" "$(eau_wd .host_audit.watchdog)" '"clean"'
assert_eq "and it records the counter as the baseline" "$(cat "$EAU/ctl/results/.egress-audit-prev")" "55 - 0 0"
out=$(eau_status egress_status)
assert_contains "an unchanged counter stays clean" "$out" "watchdog=clean (rise 0 since the last check)"
cp "$EAU/counter-rising.json" "$EAU/json"
out=$(eau_status egress_status)
assert_contains "a rising counter is non-Tor egress seen, with the rise" "$out" "watchdog=leaking (rise 25 since the last check)"
assert_eq "the status file carries the verdict, the rise, the count and the time first seen" \
    "$(eau_wd '[.host_audit.watchdog, .host_audit.watchdog_delta, .host_audit.would_drop, .host_audit.first_seen == .checked_at]')" \
    '["leaking",25,80,true]'
assert_contains "doctor shows the watchdog verdict" "$(eau_status check_host_egress_audit 2>&1)" "(watchdog leaking)"
printf '55 1000\n' >"$EAU/ctl/results/.egress-audit-prev"
eau_status egress_status >/dev/null
assert_eq "a leak that keeps rising keeps the time it was first seen" "$(eau_wd .host_audit.first_seen)" "1000"
out=$(eau_status egress_status)
assert_contains "a counter that stopped rising for a full interval clears" "$out" "watchdog=clean (rise 0"
assert_eq "and the first-seen time clears with it" "$(eau_wd .host_audit.first_seen)" "null"
cp "$EAU/json.base" "$EAU/json"
out=$(eau_status egress_status)
assert_contains "a counter that fell (the table was reloaded) is a new baseline, not a leak" "$out" "watchdog=clean"
assert_eq "and the lower count becomes the baseline" "$(cat "$EAU/ctl/results/.egress-audit-prev")" "55 - 0 0"
printf '08 0900\n' >"$EAU/ctl/results/.egress-audit-prev"
assert_contains "a zero-padded baseline is read as decimal, never as an octal error" \
    "$(eau_status egress_status)" "watchdog=leaking (rise 47 since the last check)"
assert_eq "and its zero-padded first-seen time stays valid JSON" "$(eau_wd .host_audit.first_seen)" "900"
eau_set 100 20 0
eau_status egress_status >/dev/null
eau_set 110 30 0
out=$(eau_status egress_status)
assert_contains "a rise only in allowlisted flows is allowlisted, never a leak" "$out" "watchdog=allowlisted (rise 0"
eau_set 120 30 10
assert_contains "a rise only in an operator's chosen clearnet path is operator-choice, never a leak" \
    "$(eau_status egress_status)" "watchdog=operator-choice (rise 0"
eau_set 140 34 10
assert_contains "a rise beyond the allowlisted and chosen flows is a leak, by the outside share only" \
    "$(eau_status egress_status)" "watchdog=leaking (rise 16 since the last check)"
assert_eq "the status file keeps the allowlisted, choice and outside counts" \
    "$(eau_wd '[.host_audit.allowlisted, .host_audit.choice, .host_audit.outside]')" '[34,10,96]'
EAU_NFT_TABLE_RC=1 eau_status egress_status >/dev/null
assert_eq "an absent audit table is not-observed, never clean" "$(eau_wd .host_audit.watchdog)" '"not-observed"'
SUDO_DENY=1 eau_status egress_status >/dev/null
assert_eq "an unreadable audit table is not-observed too" "$(eau_wd .host_audit.watchdog)" '"not-observed"'
printf 'appliance\tdonation\tallow\tallow\thost\tnone\tnone\tchoice:donation tcp 4247\n' >>"$EAU/map-nolan.tsv"
assert_contains "the donation clearnet choice renders its own choice class on the port XvB shares" \
    "$(run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-nolan.tsv" "" "donation")" 'tcp dport { 4247 } counter comment "choice"'
assert_eq "donation and XvB both chosen render one choice rule, so no packet is counted in two classes" \
    "$(run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-nolan.tsv" "" "xvb donation" | grep -c 'comment "choice"')" "1"
assert_contains "the committed map labels the chosen donation path, so a donation the operator opted into never reads as a leak" \
    "$(run_sourced "$ROOT" render_host_egress_audit_nft appliance data/egress-map.tsv "" "donation")" 'tcp dport { 4247 } counter comment "choice"'
printf 'XVB_ENABLED=true\nXVB_TOR_ENABLED=false\nDONATION_ENABLED=true\nDONATION_TOR_ENABLED=false\n' >"$EAU/.env"
assert_eq "the audit names a class per chosen clearnet path, donation beside XvB" \
    "$(run_sourced "$EAU" host_egress_audit_choices)" " xvb donation"
printf 'DONATION_ENABLED=true\nDONATION_TOR_ENABLED=false\n' >"$EAU/.env"
assert_eq "donation chosen while XvB stays off renders donation alone" \
    "$(run_sourced "$EAU" host_egress_audit_choices)" " donation"
printf 'DONATION_ENABLED=true\nDONATION_TOR_ENABLED=true\n' >"$EAU/.env"
assert_eq "a donation that stays on Tor is no choice" "$(run_sourced "$EAU" host_egress_audit_choices)" ""
rm -f "$EAU/.env"
assert_not_contains "a malformed port cell renders nothing, never raw text into the nft ruleset" "$(
    printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest\taudit\nappliance\tx\tallow\tallow\thost\tnone\tnone\tallowlisted tcp 443;flush\n' >"$EAU/map-bad.tsv"
    run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-bad.tsv" "" ""
)" "flush"
assert_not_contains "a choice cell with an empty key renders nothing, so a crafted row never relabels traffic as operator-chosen" "$(
    printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest\taudit\nappliance\tx\tallow\tallow\thost\tnone\tnone\tchoice: tcp 4247\n' >"$EAU/map-emptykey.tsv"
    run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-emptykey.tsv" "" "donation"
)" "4247"
assert_eq "a port both allowlisted and chosen renders in one class only, so outside is never double-subtracted" "$(
    printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest\taudit\nappliance\ttls\tallow\tallow\thost\tnone\tnone\tallowlisted tcp 443\nappliance\txvb\tallow\tallow\thost\tnone\tnone\tchoice:xvb tcp 443,9001\n' >"$EAU/map-both.tsv"
    run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-both.tsv" "" "xvb" | grep -c 'dport { 443 }'
)" "1"
out=$(EAU_NFT_CAPTURE=1 eau_run apply_host_egress_audit 2>&1)
assert_contains "with no repo map the default render asks for the baked map, the same fallback the boot unit uses" \
    "$out" "/usr/share/pithead/egress-map.tsv"
eau_set 160 34 10
eau_status egress_status >/dev/null
jq '.checked_at -= 400' "$EAU/ctl/results/egress-status.json" >"$EAU/ctl/results/egress-status.stale" &&
    mv "$EAU/ctl/results/egress-status.stale" "$EAU/ctl/results/egress-status.json"
assert_contains "a verdict file past the dashboard's freshness window reads not-observed to doctor too" \
    "$(eau_status check_host_egress_audit 2>&1)" "(watchdog not-observed)"
assert_not_contains "a stale leaking verdict never warns from doctor" \
    "$(eau_status check_host_egress_audit 2>&1)" "watchdog leaking"

echo "== boot verdict: the KVM leg's watchdog judgement, fixture-tested so the boot phase cannot pass on noise (#4385) =="
# shellcheck source=tests/os/host-egress-watchdog-boot-verdict.sh
. "$ROOT/tests/os/host-egress-watchdog-boot-verdict.sh"
EW_ALLOW_OK='host-audit: present (outside the allowlist 55 packets) watchdog=allowlisted (rise 0 since the last check)'
EW_PROBE_OK='host-audit: present (outside the allowlist 80 packets) watchdog=leaking (rise 3 since the last check)'
assert_eq "the watchdog token is read out of the check's line" "$(
    host_egress_watchdog_state 'absent
host-audit: present (outside the allowlist 55 packets) watchdog=leaking (rise 25 since the last check)'
)" "leaking"
assert_eq "the rise is read out of the same line" \
    "$(host_egress_watchdog_rise 'host-audit: present (outside the allowlist 55 packets) watchdog=leaking (rise 25 since the last check)')" "25"
assert_eq "a check that never saw the table has no rise to read" \
    "$(host_egress_watchdog_rise 'host-audit: absent watchdog=not-observed')" ""
assert_contains "allowlisted flow quiet and probe leaking passes the boot leg" \
    "$(host_egress_watchdog_boot_verdict "$EW_ALLOW_OK" "$EW_PROBE_OK")" "read leaking on a deliberate clearnet probe"
assert_contains "quiet only because the allowlisted flow was never counted is a boot failure" \
    "$(host_egress_watchdog_boot_verdict 'host-audit: present (outside the allowlist 55 packets) watchdog=clean (rise 0 since the last check)' "$EW_PROBE_OK")" \
    "never counted"
assert_contains "the alert staying silent on the probe is a boot failure" \
    "$(host_egress_watchdog_boot_verdict "$EW_ALLOW_OK" 'host-audit: present (outside the allowlist 55 packets) watchdog=clean (rise 0 since the last check)')" \
    "left watchdog=clean"
assert_contains "the allowlisted flow alerting is a boot failure" \
    "$(host_egress_watchdog_boot_verdict 'host-audit: present (outside the allowlist 56 packets) watchdog=leaking (rise 1 since the last check)' "$EW_PROBE_OK")" \
    "allowlisted TLS flow alerted"
assert_contains "a leaking verdict with no counted rise is a boot failure" \
    "$(host_egress_watchdog_boot_verdict "$EW_ALLOW_OK" 'host-audit: present watchdog=leaking (rise 0 since the last check)')" "no packet rise"
assert_contains "no verdict at all on a booted appliance is a boot failure" \
    "$(host_egress_watchdog_boot_verdict 'absent' "$EW_PROBE_OK")" "printed no watchdog verdict"

echo "== no .env: the check runs where setup never ran — a booting appliance, a DIY tree before setup (#4385) =="
EW_NOENV="$EAU/noenv"
mkdir -p "$EW_NOENV"
ew_noenv=$(
    cd "$EW_NOENV" || exit
    export PATH="$EAU/bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    tor_egress_enforced() { return 1; }
    egress_status 2>&1
)
assert_contains "the watchdog verdict prints without a .env — the boot phase drives the shipped verb" \
    "$ew_noenv" "watchdog=clean"
assert_eq "with no CONTROL_DIR the status file lands under PWD, writable on a booting appliance" \
    "$([ -f "$EW_NOENV/data/control/results/egress-status.json" ] && echo written)" "written"
assert_contains "and the same file the check just wrote reads back with the verdict" \
    "$(jq -r '.host_audit.watchdog' "$EW_NOENV/data/control/results/egress-status.json")" "clean"
