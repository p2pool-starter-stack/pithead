# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment}"
: "${LGD:?}" "${LG_ORDER:?}"
# Selected P2Pool/XvB exception lifecycle at Compose startup (#2790).
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_sync_ips() { echo 172.28.0.28; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; return 1; }; compose_up -d' >/dev/null
assert_eq "failed refresh stops a newly selected P2Pool choice" "$(cat "$LG_ORDER")" $'lan\negress:refresh'
: >"$LG_ORDER"
lg_real 'tor_egress_sync_ips() { echo 172.28.0.26; }; apply_tor_egress_iptables() { :; }; apply_tor_egress_firewall refresh' >/dev/null
assert_eq "node first sync uses its own transition guard, not the P2Pool/XvB marker" "$([ ! -e "$LGD/.pithead.lock.egress-choice-active" ] && echo yes)" yes
lg_real 'tor_egress_choice_active() { return 0; }; tor_egress_sync_ips() { echo 172.28.0.28; }; apply_tor_egress_iptables() { :; }; apply_tor_egress_firewall refresh' >/dev/null
assert_eq "firewall install arms the choice marker before Compose" "$([ -d "$LGD/.pithead.lock.egress-choice-active" ] && echo yes)" yes
: >"$LG_ORDER"
lg_out=$(lg_real 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_choice_active() { return 0; }; tor_egress_sync_ips() { echo 172.28.0.28; }; apply_tor_egress_iptables() { tor_egress_verify_or_warn ok; }; tor_egress_enforced() { return 5; }; if compose_up -d; then echo rc=0; else echo "rc=$?"; fi')
assert_eq "failed live readback of selected exception blocks Compose" "$(cat "$LG_ORDER")" lan
assert_contains "readback failure propagates through refresh" "$lg_out" "rc=1"
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; return 1; }; compose_up -d' >/dev/null
assert_eq "failed refresh stops startup after a clearnet choice is disabled" "$(cat "$LG_ORDER")" $'lan\negress:refresh'
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; env_get() { [ "$1" != TOR_EGRESS_FIREWALL ] || echo false; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; }; compose_up -d' >/dev/null
assert_eq "firewall opt-out cannot clear an unverified stale exception" "$([ -d "$LGD/.pithead.lock.egress-choice-active" ] && echo yes)" yes
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; return 1; }; compose_up -d' >/dev/null
assert_eq "re-enabled firewall still blocks a failed refresh after opt-out" "$(cat "$LG_ORDER")" $'lan\negress:refresh'
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; }; compose_up -d' >/dev/null
assert_eq "successful enabled refresh clears the selected-choice marker" "$([ ! -e "$LGD/.pithead.lock.egress-choice-active" ] && echo yes)" yes
lg_real 'env_get() { case "$1" in XVB_ENABLED) echo true ;; XVB_TOR_ENABLED) echo false ;; esac; }; tor_egress_sync_ips() { echo 172.28.0.29; }; apply_tor_egress_iptables() { :; }; apply_tor_egress_firewall refresh' >/dev/null
assert_eq "XvB alone arms the choice marker" "$([ -d "$LGD/.pithead.lock.egress-choice-active" ] && echo yes)" yes
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; return 1; }; compose_up -d' >/dev/null
assert_eq "XvB removal also blocks a failed refresh" "$(cat "$LG_ORDER")" $'lan\negress:refresh'
lg 'apply_lan_guard() { :; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { :; }; compose_up -d' >/dev/null
assert_eq "successful XvB removal clears the marker" "$([ ! -e "$LGD/.pithead.lock.egress-choice-active" ] && echo yes)" yes
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; tor_egress_sync_ips() { :; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; return 1; }; compose_up -d' >/dev/null
assert_eq "ordinary startup keeps its warning-only firewall behavior" "$(cat "$LG_ORDER")" $'lan\negress:refresh\ncompose'
