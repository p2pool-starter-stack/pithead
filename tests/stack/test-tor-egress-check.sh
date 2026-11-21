# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The dashboard's view of the Tor-only egress firewall (#2599): a host timer runs the doctor's
# tor_egress_enforced() every two minutes and writes the verdict where the containerised dashboard
# can read it. These pin the units (the timer targets the read-only check, never the boot unit),
# the status file the verb writes, and that up/apply/opt-out/uninstall own the pair under the
# control runner's ownership rule. Self-contained stubs. Sourced by tests/stack/run.sh.

EC="$SANDBOX/egress-check"
mkdir -p "$EC/bin" "$EC/units" "$EC/ctl"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$EC/bin/sudo"
printf '#!/usr/bin/env bash\necho Linux\n' >"$EC/bin/uname"
# systemctl logs every call; `is-active` answers from SYSTEMCTL_ACTIVE (default: not active).
# SYSTEMCTL_FAIL=disable|daemon-reload makes that verb fail; RM_FAIL=1 makes rm fail (sudo execs it).
cat >"$EC/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$EC/systemctl.log"
[ "\$1" = is-active ] && exit "\${SYSTEMCTL_ACTIVE:-1}"
[ "\$1" = "\${SYSTEMCTL_FAIL:-}" ] && exit 1
exit 0
EOF
printf '#!/usr/bin/env bash\n[ "${RM_FAIL:-0}" = 1 ] && exit 1\nexec /bin/rm "$@"\n' >"$EC/bin/rm"
chmod +x "$EC"/bin/*
ec_env() { printf 'CONTROL_DIR=%s\nTOR_EGRESS_FIREWALL=%s\n' "$EC/ctl" "${1:-true}" >"$EC/.env"; }
ec_env
ec_run() {
    PITHEAD_ENGINE="${EC_ENGINE:-docker}" PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EC/units" \
        PATH="$EC/bin:$PATH" run_sourced "$EC" "$@"
}
EC_SVC="$EC/units/pithead-egress-check.service"
EC_TIMER="$EC/units/pithead-egress.timer"
ec_has() { [ -e "$1" ] && echo present; }

echo "== units: a 2-minute timer on a read-only check, never on the boot unit (#2599) =="
ET=$(run_sourced "$SANDBOX" render_egress_check_timer)
assert_contains "fires two minutes after boot" "$ET" "OnBootSec=2min"
assert_contains "and every two minutes after the last check" "$ET" "OnUnitActiveSec=2min"
assert_contains "targets the check, not pithead-egress.service (the boot unit)" "$ET" "Unit=pithead-egress-check.service"
assert_contains "installed with the timers" "$ET" "WantedBy=timers.target"
ES=$(run_sourced "$SANDBOX" render_egress_check_service /opt/ph podman)
assert_eq "its only ExecStart is the read-only verb (no rule is inserted or deleted)" \
    "$(printf '%s\n' "$ES" | grep '^ExecStart=')" "ExecStart=/opt/ph/pithead egress-status"
assert_contains "pins the engine the install was provisioned with (#2059)" "$ES" "Environment=PITHEAD_ENGINE=podman"
assert_contains "runs from the install" "$ES" "WorkingDirectory=/opt/ph"

echo "== verb: egress-status writes {rc, verdict, checked_at} for the dashboard (#2599) =="
ec_status() { # <rc tor_egress_enforced returns>
    (
        cd "$EC" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        eval "tor_egress_enforced() { return $1; }"
        egress_status
    )
}
EC_FILE="$EC/ctl/results/egress-status.json"
for pair in 0:enforced 1:absent 2:no-tool 3:unreadable 4:jump-missing 5:shadowed; do
    out=$(ec_status "${pair%%:*}" | head -n1)
    assert_eq "each tor_egress_enforced rc prints its verdict on the first line" "rc ${pair%%:*}:$out" "rc $pair"
    assert_eq "each rc is written with its verdict" "$(jq -c '[.rc, .verdict]' "$EC_FILE")" \
        "[${pair%%:*},\"${pair#*:}\"]"
done
out=$(ec_status 1)
assert_contains "a second stdout line reports the host egress audit view (#4195)" "$out" "host-audit:"
assert_eq "the audit section is typed and never claims counters it cannot read" \
    "$(jq -c '[(.host_audit.verdict | IN("present","absent","no-tool","unreadable")), (.host_audit.counters | type)]' "$EC_FILE")" \
    '[true,"array"]'
now=$(date +%s)
assert_eq "checked_at is the write time" "$(jq '.checked_at >= '"$((now - 5))"' and .checked_at <= '"$((now + 5))" "$EC_FILE")" "true"
assert_eq "the dashboard (another uid) can read it" "$(stat -c %a "$EC_FILE" 2>/dev/null || stat -f %Lp "$EC_FILE")" "644"
assert_eq "no temp file is left beside it (written by rename)" "$(find "$EC/ctl/results" -name '.egress-status.*' | wc -l | tr -d ' ')" "0"

echo "== provision: up/apply install and start the pair; re-runs are quiet (#2599) =="
rm -f "$EC/systemctl.log"
ec_run provision_egress_check_units >/dev/null 2>&1
assert_eq "writes the check service" "$(cat "$EC_SVC" 2>/dev/null)" "$(run_sourced "$SANDBOX" render_egress_check_service "$(cd "$EC" && pwd)" docker)"
assert_eq "writes the timer" "$(cat "$EC_TIMER" 2>/dev/null)" "$(run_sourced "$SANDBOX" render_egress_check_timer)"
assert_contains "enables and starts the timer" "$(cat "$EC/systemctl.log")" "enable --now pithead-egress.timer"
rm -f "$EC/systemctl.log"
SYSTEMCTL_ACTIVE=0 ec_run provision_egress_check_units >/dev/null 2>&1
assert_not_contains "a re-run with the same units and the timer active does not reload systemd" \
    "$(cat "$EC/systemctl.log")" "daemon-reload"
assert_contains "up provisions the pair" "$(run_sourced "$SANDBOX" type stack_up)" "provision_egress_check_units"
assert_contains "render (every appliance boot) provisions both firewall check pairs" "$(run_sourced "$SANDBOX" type render_derived)" "provision_firewall_check_units"

echo "== provision: another live install's pair is left alone unless stolen (#2599) =="
mkdir -p "$EC/other"
run_sourced "$SANDBOX" render_egress_check_service "$EC/other" docker >"$EC_SVC"
out=$(ec_run provision_egress_check_units 2>&1)
assert_contains "refuses to repoint a live sibling's pair" "$out" "egress-check:foreign-units"
assert_contains "and leaves it naming the sibling" "$(cat "$EC_SVC")" "ExecStart=$EC/other/pithead egress-status"
ec_run provision_egress_check_units steal >/dev/null 2>&1
assert_contains "upgrade's steal takes it over" "$(cat "$EC_SVC")" "ExecStart=$(cd "$EC" && pwd -P)/pithead egress-status"
run_sourced "$SANDBOX" render_egress_check_service "$EC/gone" docker >"$EC_SVC"
ec_run provision_egress_check_units >/dev/null 2>&1
assert_contains "a pair naming a deleted install is adopted" "$(cat "$EC_SVC")" "ExecStart=$(cd "$EC" && pwd -P)/pithead egress-status"

echo "== provision: opt-out and uninstall remove only this install's pair (#2599) =="
printf '[Unit]\n' >"$EC/units/other.timer"
ec_env false
rm -f "$EC/systemctl.log"
ec_run provision_egress_check_units >/dev/null 2>&1
assert_eq "opting out removes the check service" "$(ec_has "$EC_SVC")" ""
assert_eq "and the timer" "$(ec_has "$EC_TIMER")" ""
assert_contains "and stops it" "$(cat "$EC/systemctl.log")" "disable --now pithead-egress.timer"
assert_eq "another unit is left alone" "$(ec_has "$EC/units/other.timer")" "present"
ec_env true
run_sourced "$SANDBOX" render_egress_check_service "$EC/other" docker >"$EC_SVC"
ec_run remove_egress_check_units >/dev/null 2>&1
assert_eq "removal leaves a live sibling's pair" "$(ec_has "$EC_SVC")" "present"
rm -f "$EC_SVC"
ec_run provision_egress_check_units >/dev/null 2>&1
un_out=$(
    cd "$EC" || exit
    export PITHEAD_ENGINE=docker PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EC/units" PATH="$EC/bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    detect_os() { :; }
    docker() { :; }
    provision_control_runner() { :; }
    remove_tor_egress_firewall() { :; }
    stack_uninstall -y 2>&1
)
assert_contains "uninstall completes" "$un_out" "Uninstalled."
assert_eq "uninstall removes the check service" "$(ec_has "$EC_SVC")" ""
assert_eq "and the timer" "$(ec_has "$EC_TIMER")" ""

echo "== removal: a failed step is named, and no caller reports the pair removed (#2599) =="
ec_uninstall() {
    (
        cd "$EC" || exit
        export PITHEAD_ENGINE=docker PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EC/units" PATH="$EC/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        detect_os() { :; }
        docker() { :; }
        provision_control_runner() { :; }
        remove_tor_egress_firewall() { :; }
        remove_lan_guard() { :; }
        stack_uninstall -y 2>&1
    )
    printf 'rc=%s\n' "$?" # outside the subshell: error() exits it
}
ec_optout() { # fresh pair, then opt out; the fault comes from the caller's environment
    ec_env true
    SYSTEMCTL_FAIL="" RM_FAIL=0 ec_run provision_egress_check_units >/dev/null 2>&1
    ec_env false
    ec_run provision_egress_check_units 2>&1
    ec_env true
}
ec_fresh_uninstall() { # fresh pair and .env, then uninstall with the caller's fault
    ec_env true
    SYSTEMCTL_FAIL="" RM_FAIL=0 ec_run provision_egress_check_units >/dev/null 2>&1
    ec_uninstall
}
out=$(ec_optout)
assert_contains "a clean opt-out says the timer was removed" "$out" "Removed pithead-egress.timer"
out=$(SYSTEMCTL_FAIL=disable ec_optout)
assert_contains "opt-out: a failed disable is named" "$out" "egress-check:disable-failed"
assert_contains "opt-out: a failed disable leaves the removal incomplete" "$out" "egress-check:removal-incomplete"
assert_not_contains "opt-out: a failed disable is never reported as removed" "$out" "Removed pithead-egress.timer"
out=$(RM_FAIL=1 ec_optout)
assert_contains "opt-out: a failed delete is named" "$out" "egress-check:delete-failed"
assert_not_contains "opt-out: a failed delete is never reported as removed" "$out" "Removed pithead-egress.timer"
assert_eq "opt-out: after a failed delete the unit files are still there, as reported" "$(ec_has "$EC_TIMER")" "present"
RM_FAIL=0 ec_run remove_egress_check_units >/dev/null 2>&1
out=$(SYSTEMCTL_FAIL=daemon-reload ec_optout)
assert_contains "opt-out: a failed daemon-reload is named" "$out" "egress-check:reload-failed"
assert_not_contains "opt-out: a failed daemon-reload is never reported as removed" "$out" "Removed pithead-egress.timer"
out=$(SYSTEMCTL_FAIL=disable ec_fresh_uninstall)
assert_contains "uninstall: a failed disable is named" "$out" "egress-check:disable-failed"
assert_not_contains "uninstall: a failed disable never prints Uninstalled." "$out" "Uninstalled."
assert_contains "uninstall: a failed disable exits non-zero" "$out" "rc=1"
out=$(RM_FAIL=1 ec_fresh_uninstall)
assert_contains "uninstall: a failed delete is named" "$out" "egress-check:delete-failed"
assert_not_contains "uninstall: a failed delete never prints Uninstalled." "$out" "Uninstalled."
assert_contains "uninstall: a failed delete exits non-zero" "$out" "rc=1"
RM_FAIL=0 ec_run remove_egress_check_units >/dev/null 2>&1
out=$(SYSTEMCTL_FAIL=daemon-reload ec_fresh_uninstall)
assert_contains "uninstall: a failed daemon-reload is named" "$out" "egress-check:reload-failed"
assert_not_contains "uninstall: a failed daemon-reload never prints Uninstalled." "$out" "Uninstalled."
assert_contains "uninstall: a failed daemon-reload exits non-zero" "$out" "rc=1"
out=$(ec_fresh_uninstall)
assert_contains "uninstall: a clean removal prints Uninstalled." "$out" "Uninstalled."
assert_contains "uninstall: a clean removal exits zero" "$out" "rc=0"
EAU="$SANDBOX/host-egress-audit"
mkdir -p "$EAU/bin"
printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest\n' >"$EAU/map-lan.tsv"
printf 'appliance\tpool lan\tallow\tallow\tlan\tlan-guard\tnone\nappliance\tupdate fetch\tallow\tallow\thost\tnone\tnone\n' >>"$EAU/map-lan.tsv"
printf 'rig\tpool lan\tallow\tallow\tlan\tnone\tnone\n' >>"$EAU/map-lan.tsv"
printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest\n' >"$EAU/map-nolan.tsv"
printf 'appliance\tupdate fetch\tallow\tallow\thost\tnone\tnone\nrig\tpool\tallow\tallow\thost\tnone\tnone\n' >>"$EAU/map-nolan.tsv"
printf '{"nftables":[{"metainfo":{"json_version":1}},{"table":{"family":"inet","name":"pithead_egress_audit"}},{"rule":{"family":0,"chain":"output","handle":2,"expr":[{"counter":{"packets":7,"bytes":700}},{"accept":null}],"comment":"loopback"},"table":"pithead_egress_audit"},{"rule":{"family":0,"chain":"output","handle":5,"expr":[{"counter":{"packets":42,"bytes":3780}},{"log":{"prefix":"pithead-egress-audit: "}},{"accept":null}],"comment":"would_drop"},"table":"pithead_egress_audit"}]}\n' >"$EAU/json"
printf '#!/usr/bin/env bash\n[ -n "${SUDO_DENY:-}" ] && exit 1\n[ "${1:-}" = -n ] && shift\nexec "$@"\n' >"$EAU/bin/sudo"
printf '#!/usr/bin/env bash\necho Linux\n' >"$EAU/bin/uname"
cat >"$EAU/bin/nft" <<EOF
#!/usr/bin/env bash
case "\$*" in
"list tables") exit "\${EAU_NFT_LIST:-0}" ;;
"list table inet pithead_egress_audit") exit "\${EAU_NFT_EXISTS:-0}" ;;
"-j list table inet pithead_egress_audit") [ "\${EAU_NFT_TABLE_RC:-0}" = 0 ] || exit 1; cat "$EAU/json" ;;
*) if [ -n "\${EAU_NFT_CAPTURE:-}" ]; then cat >"$EAU/load.nft"; fi; exit "\${EAU_NFT_ANY_RC:-0}" ;;
esac
EOF
chmod +x "$EAU"/bin/*
eau_run() { PATH="$EAU/bin:$PATH" run_sourced "$EAU" "$@"; }

EAU_OK_TABLE='table inet pithead_egress_audit {
  chain output {
    type filter hook output priority -150; policy accept;
    oifname "lo" counter packets 4 bytes 240 comment "loopback"
    ct state established,related counter packets 9 bytes 900 comment "reply"
    oifname != "lo" ct state != { established, related } counter packets 42 bytes 3780 comment "would_drop"
    oifname != "lo" ct state != { established, related } limit rate 30/second log prefix "pithead-egress-audit: "
  }
}'

echo "== render: the log-only inet output table comes from the egress map, not from hand-copied rules (#4195) =="
EAU_R=$(run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-lan.tsv")
assert_eq "the map file is replaced atomically (add then delete then recreate)" \
    "$(printf '%s\n' "$EAU_R" | grep -A1 -m1 'add table inet pithead_egress_audit' | tail -1)" \
    "delete table inet pithead_egress_audit"
assert_contains "the chain hooks the host output path" "$EAU_R" "type filter hook output priority -150; policy accept;"
assert_contains "loopback flows get their own counter" "$EAU_R" 'oifname "lo" counter comment "loopback"'
assert_contains "replies get their own counter" "$EAU_R" 'ct state established,related counter comment "reply"'
assert_contains "the would_drop rule counts, exact, no verdict" "$EAU_R" 'counter comment "would_drop"'
assert_contains "journal noise is gated by its own rate-limited log rule" "$EAU_R" \
    'limit rate 30/second log prefix "pithead-egress-audit: "'
assert_contains "a route=lan row of this role renders the lan class" "$EAU_R" 'counter comment "lan"'
assert_contains "would_drop counts only flows the loopback, reply and lan classes did not take" "$EAU_R" \
    'oifname != "lo" ct state != { established, related } ip daddr != { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } counter comment "would_drop"'
assert_contains "the log rule carries the same gate, so a logged line names a would-be drop, never loopback" "$EAU_R" \
    'oifname != "lo" ct state != { established, related } ip daddr != { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } limit rate 30/second log prefix "pithead-egress-audit: "'
EAU_NOLAN=$(run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/map-nolan.tsv")
assert_not_contains "with no route=lan row the lan class is not rendered" "$EAU_NOLAN" 'comment "lan"'
assert_contains "with no lan class the gate is the loopback and reply complements only" "$EAU_NOLAN" \
    'oifname != "lo" ct state != { established, related } counter comment "would_drop"'
assert_not_contains "the gate never names a lan class the role did not render" "$EAU_NOLAN" 'ip daddr !='
EAU_RIG=$(run_sourced "$EAU" render_host_egress_audit_nft rig "$EAU/map-lan.tsv")
assert_contains "the rig role renders from its own rows" "$EAU_RIG" 'counter comment "lan"'
EAU_RIGN=$(run_sourced "$EAU" render_host_egress_audit_nft rig "$EAU/map-nolan.tsv")
assert_not_contains "the role filter is what picks the rows: a rig with no lan row has no lan class" "$EAU_RIGN" 'comment "lan"'
assert_eq "an unknown role renders nothing" "$(
    run_sourced "$EAU" render_host_egress_audit_nft laptop "$EAU/map-lan.tsv"
    printf 'rc=%s' "$?"
)" "rc=1"
assert_eq "a missing map fails the render rather than inventing rules" "$(
    run_sourced "$EAU" render_host_egress_audit_nft appliance "$EAU/absent.tsv" 2>/dev/null
    printf 'rc=%s' "$?"
)" "rc=1"
EAU_REPO=$(run_sourced "$ROOT" render_host_egress_audit_nft appliance data/egress-map.tsv)
assert_contains "the committed egress map drives the appliance table" "$EAU_REPO" 'counter comment "would_drop"'
assert_contains "and the rate-limited log rule ships with it" "$EAU_REPO" 'limit rate 30/second log prefix "pithead-egress-audit: "'
assert_contains "the committed map renders the gate too, so would_drop is not total output traffic" "$EAU_REPO" \
    'oifname != "lo" ct state != { established, related } ip daddr != {'
assert_eq "the rendered table never carries a terminal verdict: none of accept/drop/reject is rendered anywhere" \
    "$(printf '%s\n' "$EAU_R" "$EAU_RIG" "$EAU_REPO" | grep -Ec '(^|[[:space:]])(accept|drop|reject)([[:space:]]|$)')" "0"
assert_eq "the mawk-safe split renders every lan net (Debian 12 awk) comma-separated" \
    "$(printf '%s\n' "$EAU_R" | grep 'comment "lan"' | grep -c '127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10')" "1"

echo "== apply: the loader loads once; the clearnet refresh path keeps the counters accumulating (#4195) =="
out=$(EAU_NFT_CAPTURE=1 PITHEAD_EGRESS_AUDIT_STATE="$EAU/state" eau_run apply_host_egress_audit "$EAU/map-lan.tsv" 2>&1)
assert_contains "a successful load is logged as log-only" "$out" "counted and logged, none dropped"
assert_contains "what reached nft was the rendered table" "$(cat "$EAU/load.nft")" 'comment "would_drop"'
rm -f "$EAU/load.nft"
out=$(EAU_NFT_CAPTURE=1 PITHEAD_EGRESS_AUDIT_STATE="$EAU/state" eau_run apply_host_egress_audit "$EAU/map-lan.tsv" 2>&1)
assert_contains "a second apply with the table live and the render unchanged does not reload" "$out" "already loaded"
assert_eq "the unchanged render never reaches nft again, so the counters keep counting" \
    "$([ -e "$EAU/load.nft" ] && echo rewrote || echo untouched)" "untouched"
out=$(EAU_NFT_CAPTURE=1 PITHEAD_EGRESS_AUDIT_STATE="$EAU/state" eau_run apply_host_egress_audit "$EAU/map-nolan.tsv" 2>&1)
assert_contains "a changed ruleset is reloaded" "$out" "counted and logged, none dropped"
assert_not_contains "and the reloaded table is the changed render" "$(cat "$EAU/load.nft")" 'comment "lan"'
rm -f "$EAU/load.nft"
out=$(EAU_NFT_CAPTURE=1 PITHEAD_EGRESS_AUDIT_STATE="$EAU/state" eau_run apply_host_egress_audit "$EAU/map-nolan.tsv" 2>&1)
assert_contains "the new ruleset is likewise loaded only once" "$out" "already loaded"
out=$(EAU_NFT_CAPTURE=1 EAU_NFT_EXISTS=1 PITHEAD_EGRESS_AUDIT_STATE="$EAU/state" eau_run apply_host_egress_audit "$EAU/map-nolan.tsv" 2>&1)
assert_contains "a table deleted underneath is reloaded even though the state file matches" "$out" "counted and logged, none dropped"
out=$(EAU_NFT_CAPTURE=1 EAU_NFT_ANY_RC=1 PITHEAD_EGRESS_AUDIT_STATE="$EAU/state-fail" eau_run apply_host_egress_audit "$EAU/map-lan.tsv" 2>&1)
assert_contains "an nft failure is named with a stable token" "$out" "egress-audit:load-failed"
assert_eq "a failed load records no state, so the next apply retries" \
    "$([ -f "$EAU/state-fail" ] && echo written || echo clean)" "clean"

echo "== counters: the view reports per-rule counters and the would_drop total (#4195) =="
EAU_C=$(eau_run host_egress_audit_counters)
assert_eq "the counters JSON names every counter and the would_drop total" "$EAU_C" \
    '{"counters":[{"packets":7,"bytes":700},{"packets":42,"bytes":3780}],"would_drop":42}'
EAU_A=$(
    EAU_NFT_TABLE_RC=1 eau_run host_egress_audit_counters 2>/dev/null
    printf 'rc=%s' "$?"
)
assert_eq "an absent table is rc 1" "$EAU_A" "rc=1"
EAU_D=$(
    SUDO_DENY=1 eau_run host_egress_audit_counters 2>/dev/null
    printf 'rc=%s' "$?"
)
assert_eq "a sudo refusal is rc 3, never 'absent'" "$EAU_D" "rc=3"

echo "== egress-status: the verdict file carries the audit counters, and the human line shows would_drop (#4195) =="
eau_status() {
    (
        cd "$EAU" || exit
        export PATH="$EAU/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        tor_egress_enforced() { return 1; }
        printf 'CONTROL_DIR=%s\n' "$EAU/ctl" >.env
        "$@"
    )
}
out=$(eau_status egress_status)
assert_eq "the verdict stays the first stdout line" "$(printf '%s\n' "$out" | head -n1)" "absent"
assert_contains "and the audit line follows it" "$out" "host-audit: present (would_drop 42 packets)"
assert_eq "the dashboard file keeps rc/verdict and gains host_audit counters" \
    "$(jq -c '[.rc, .verdict, .host_audit.verdict, (.host_audit.counters | length), .host_audit.counters[1].packets]' "$EAU/ctl/results/egress-status.json")" \
    '[1,"absent","present",2,42]'
out=$(EAU_NFT_TABLE_RC=1 eau_status egress_status)
assert_contains "an absent table says so on stdout" "$out" "host-audit: absent"
out=$(SUDO_DENY=1 eau_status egress_status)
assert_contains "an unreadable table says so rather than 'absent'" "$out" "host-audit: unreadable"
out=$(eau_status check_host_egress_audit 2>&1)
assert_contains "doctor shows the would_drop counter when the table is loaded" "$out" "would_drop counter at 42 flows"
out=$(EAU_NFT_TABLE_RC=1 eau_status check_host_egress_audit 2>&1)
assert_contains "doctor warns when the table is not loaded" "$out" "log-only host egress audit table is not loaded"

echo "== boot verdict: the KVM leg's judgement, fixture-tested so the boot phase cannot pass on noise (#4195) =="
. "$ROOT/tests/os/host-egress-audit-boot-verdict.sh"
assert_eq "the would_drop counter is read out of the live table text" \
    "$(host_egress_audit_would_drop "$EAU_OK_TABLE")" "42"
assert_eq "and the loopback counter from the same text" "$(host_egress_audit_counter loopback "$EAU_OK_TABLE")" "4"
assert_eq "the delta helper subtracts two counter values" "$(host_egress_audit_delta 42 40)" "2"
assert_eq "the delta helper never invents a number out of an unreadable counter" "$(host_egress_audit_delta x 40)" ""
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" 10 42 0 3 5 210); then ok "loaded at boot, rising counter, loopback excluded, nothing dropped"; else
    bad "the healthy boot state fails the verdict"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict inactive "$EAU_OK_TABLE" 10 42 0 3 5 210); then bad "a unit that never ran passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE
    ip daddr 10.0.0.0/8 drop" 10 42 0 3 5 210); then bad "a dropping table passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE
    tcp dport 53 accept" 10 42 0 3 5 210); then bad "a table with a foreign terminal accept passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active 'table inet pithead_egress_audit {
  chain output {
    type filter hook output priority -150; policy accept;
  }
}' 10 10 0 3 5 210); then bad "a table without a logged would_drop rule passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active 'table inet pithead_egress_audit {
  chain output {
    type filter hook output priority -150; policy accept;
    oifname "lo" counter packets 4 bytes 240 comment "loopback"
    counter packets 99 bytes 9000 comment "would_drop"
    limit rate 30/second log prefix "pithead-egress-audit: "
  }
}' 10 42 0 3 5 210); then bad "a table whose log rule counts every packet passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" 42 42 0 3 5 210); then bad "a counter that did not rise passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" "" "" 0 3 5 210); then bad "an unreadable counter passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" 10 42 0 3 210 200); then bad "loopback counted into would_drop passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" 10 42 0 2 2 4); then bad "a loopback probe that never reached lo passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" 10 42 0 "" "" ""); then bad "an unreadable loopback leg passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
if v=$(host_egress_audit_boot_verdict active "$EAU_OK_TABLE" 10 42 1 3 5 210); then bad "a failed test flow passes"; else
    ok "rejected"
    printf '      %s\n' "$v"
fi
