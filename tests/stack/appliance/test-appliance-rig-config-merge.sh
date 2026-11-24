# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance rig-miner config merge (#3204): the rig role rebuilds RigForge's config.json from
# rig.json at every boot, and Worker Inspect's control-path edits land in that same file. The
# rebuild keeps the control-writable keys and still lets rig.json own everything else.
# Sourced by tests/stack/run.sh.

echo "== unit: the rig's config rebuild keeps Worker Inspect's edits (#3204) =="
mk_tmpdir RCM
mkdir -p "$RCM/rigforge" "$RCM/bin"
cat >"$RCM/bin/getent" <<'STUB'
#!/bin/bash
[ "$2" = coordinator.lan ] && echo "192.168.7.20 STREAM" || exit 2
STUB
chmod +x "$RCM/bin/getent"
printf '{"pool":"coordinator.lan:3333","worker":"shed-3","stratum_password":"pw","access_token":"%032d"}' 1 >"$RCM/rig.json"
rcm_render() { PITHEAD_RIGFORGE_DIR="$RCM/rigforge" PATH="$RCM/bin:$PATH" run_sourced "$RCM" render_rig_miner_config >/dev/null 2>&1; }
rcm_plain='["ACCESS_TOKEN","api","api_allow_from","control","pools"]'
rcm_render
assert_eq "a first render has no writable keys" "$(jq -c keys "$RCM/rigforge/config.json")" "$rcm_plain"
jq '. + {DONATION: 2, autotune: false, watchdog: true, watchdog_interval_min: 7, max_temp_c: 81,
    ACCESS_TOKEN: "stale", api: "disabled", control: "disabled", api_allow_from: "stale", pools: [{url: "edited:1", user: "x", pass: "stale"}]}' "$RCM/rigforge/config.json" >"$RCM/edit.json"
mv "$RCM/edit.json" "$RCM/rigforge/config.json"
rcm_render
assert_eq "writable keys survive a re-render" "$(jq -c '[.DONATION, .autotune, .watchdog, .watchdog_interval_min, .max_temp_c]' "$RCM/rigforge/config.json")" '[2,false,true,7,81]'
assert_eq "rig.json still owns connection and access settings" "$(jq -c '[.pools[0].url, .pools[0].user, .pools[0].pass, .ACCESS_TOKEN, .api, .control, .api_allow_from]' "$RCM/rigforge/config.json")" '["coordinator.lan:3333","shed-3","pw","00000000000000000000000000000001","enabled","enabled","192.168.7.20"]'
printf 'not json{' >"$RCM/rigforge/config.json"
rcm_render
assert_eq "a corrupt config falls back to the plain render" "$(jq -c keys "$RCM/rigforge/config.json")" "$rcm_plain"
printf '[1]' >"$RCM/rigforge/config.json"
rcm_render
assert_eq "a non-object config falls back to the plain render" "$(jq -c keys "$RCM/rigforge/config.json")" "$rcm_plain"
for rcm_invalid in '' '   ' '{"max_temp_c":81} broken{' '{"max_temp_c":81} {}'; do
    printf '%s' "$rcm_invalid" >"$RCM/rigforge/config.json"
    rcm_render
    assert_eq "empty or multi-value config falls back to the plain render ($rcm_invalid)" "$(jq -c keys "$RCM/rigforge/config.json")" "$rcm_plain"
done
rm -rf "$RCM"
unset RCM rcm_plain rcm_invalid
unset -f rcm_render

echo "== unit: api_allow_from branches on paired — own subnets for an outside pool (#4066) =="
mk_tmpdir ONSB
mkdir -p "$ONSB/rigforge" "$ONSB/bin"
cat >"$ONSB/bin/ip" <<'EOF2'
#!/bin/bash
case "$*" in
"-4 -o addr") cat "$IP_ADDRS" ;;
"-4 -o route show default") cat "$IP_ROUTE" ;;
esac
EOF2
chmod +x "$ONSB/bin/ip"
cat >"$ONSB/bin/getent" <<'EOF2'
#!/bin/bash
[ "$1 $2" = "ahostsv4 coordinator.lan" ] && printf '192.168.7.20    STREAM coordinator.lan\n' || exit 2
EOF2
chmod +x "$ONSB/bin/getent"
printf '%s\n' \
    '1: lo    inet 127.0.0.1/8 scope host lo' \
    '2: docker0    inet 172.17.0.1/16 scope global docker0' \
    '3: br-1a2b3c    inet 172.18.0.1/16 scope global br-1a2b3c' \
    '4: veth9@if8    inet 172.19.0.1/16 scope global veth9' \
    '5: eth1    inet 169.254.3.4/16 scope link eth1' \
    '6: eth0    inet 192.168.1.130/25 brd 192.168.1.255 scope global eth0' \
    '7: wlan0    inet 10.254.1.5/23 brd 10.254.1.255 scope global wlan0' >"$ONSB/addrs"
printf 'default via 192.168.1.1 dev eth0 proto dhcp\n' >"$ONSB/route"
: >"$ONSB/noroute"
run_onsb() { IP_ADDRS="$ONSB/addrs" IP_ROUTE="${IP_ROUTE:-$ONSB/route}" PITHEAD_RIGFORGE_DIR="$ONSB/rigforge" PATH="$ONSB/bin:$PATH" run_sourced "$ONSB" "$@"; }
rig_json() { printf '{"pool":"%s","worker":"shed-3","access_token":"dcfda835679ae98638633f189d9e5979"%s}' "$1" "$2" >"$ONSB/rig.json"; }
cfg() { jq -r "$1" "$ONSB/rigforge/config.json"; }

rig_json pool.example.com:3333 ',"paired":false'
rt_out=$(run_onsb render_rig_miner_config 2>&1)
assert_rc "paired-false render -> rc 0" "$?" "0"
assert_eq "paired-false pins the default-route subnet, network address masked, bridges and link-local excluded" "$(cfg '.control + " " + .api_allow_from')" "enabled 192.168.1.128/25"
assert_eq "the token is in the rendered config" "$(cfg '.ACCESS_TOKEN')" "dcfda835679ae98638633f189d9e5979"
assert_eq "rig_own_subnets alone yields the default-route subnet" "$(run_onsb rig_own_subnets)" "192.168.1.128/25"

assert_eq "with no default route the first qualifying subnet wins, x.254 hosts included" "$(IP_ROUTE="$ONSB/noroute" run_onsb rig_own_subnets)" "192.168.1.128/25"
grep -v eth0 "$ONSB/addrs" >"$ONSB/addrs.new" && mv -f "$ONSB/addrs.new" "$ONSB/addrs"
assert_eq "a non-default-route interface qualifies when it is the only one" "$(run_onsb rig_own_subnets)" "10.254.0.0/23"

printf '%s\n' '1: lo    inet 127.0.0.1/8 scope host lo' '2: docker0    inet 172.17.0.1/16 scope global docker0' '3: tailscale0    inet 100.64.1.1/10 scope global tailscale0' '4: eth9    inet 10.1.2.3/8 scope global eth9' >"$ONSB/addrs"
rt_out=$(run_onsb render_rig_miner_config 2>&1)
assert_rc "paired-false with no usable subnet -> rc 0" "$?" "0"
assert_eq "no usable subnet -> control falls closed, token still served" "$(cfg '[has("control"), has("api_allow_from"), .api, .ACCESS_TOKEN] | map(tostring) | join(" ")')" "false false enabled dcfda835679ae98638633f189d9e5979"
assert_contains "the fallen-closed control is said out loud" "$rt_out" "no connected LAN subnet qualifies"

rig_json pool.example.com:3333 ',"paired":false,"api_allow_from_override":"10.10.10.0/24"'
run_onsb render_rig_miner_config >/dev/null 2>&1
assert_eq "the override replaces the derived scope when paired is false" "$(cfg '.api_allow_from')" "10.10.10.0/24"
rig_json coordinator.lan:3333 ',"api_allow_from_override":"172.16.0.0/16"'
run_onsb render_rig_miner_config >/dev/null 2>&1
assert_eq "the override replaces the pool-host pin when paired" "$(cfg '.api_allow_from')" "172.16.0.0/16"

rig_json pool.example.com:3333 ',"paired":false,"api_allow_from_override":["10.0.0.0/8"]'
run_onsb render_rig_miner_config >/dev/null 2>&1
assert_eq "a non-string override is ignored, never rendered" "$(cfg 'has("api_allow_from")')" "false"
rig_json coordinator.lan:3333 ',"paired":"false"'
run_onsb render_rig_miner_config >/dev/null 2>&1
assert_eq "a non-boolean paired reads as paired" "$(cfg '.api_allow_from')" "192.168.7.20"
rig_json coordinator.lan:3333 ',"paired":true'
run_onsb render_rig_miner_config >/dev/null 2>&1
assert_eq "paired true is unchanged: the pool host pin" "$(cfg '.control + " " + .api_allow_from')" "enabled 192.168.7.20"
rig_json coordinator.lan:3333 ''
run_onsb render_rig_miner_config >/dev/null 2>&1
assert_eq "paired absent is unchanged: the pool host pin" "$(cfg '.control + " " + .api_allow_from')" "enabled 192.168.7.20"
assert_eq "paired-true card reason is the pool-host one" "$(run_onsb rig_allow_missing_reason)" "the pool host does not resolve to an IPv4 address to pin it to"
rig_json nowhere.lan:3333 ''
rt_out=$(run_onsb render_rig_miner_config 2>&1)
assert_contains "paired-true with an unresolvable host still falls closed with the pool-host warning" "$rt_out" "the pool host does not resolve"

rm -rf "$ONSB"
unset ONSB rt_out
unset -f run_onsb rig_json cfg
