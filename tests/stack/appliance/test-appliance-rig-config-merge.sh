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
