# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: passwords, tokens and keys reach jq and awk through the environment, not their arguments =="
mk_tmpdir SEH
mkdir -p "$SEH/bin" "$SEH/rigforge" "$SEH/esp"
for seh_tool in jq awk; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/argv.log"\ncase "$*" in *"${SEH_FAIL_ON:-@none@}"*) exit 3 ;; esac\nexec %s "$@"\n' \
        "$SEH" "$(command -v "$seh_tool")" >"$SEH/bin/$seh_tool"
    chmod +x "$SEH/bin/$seh_tool"
done
SEH_S=$'q"b\\d$s\'p \xc3\xa9'
seh_run() { : >"$SEH/argv.log" && PATH="$SEH/bin:$PATH" run_sourced "$SEH" "$@"; }
seh_log() { cat "$SEH/argv.log"; }

printf '{}' >"$SEH/config.json"
seh_run eval 'MONERO_MODE_WIZ=local IN_MONERO_WALLET=4wallet IN_MONERO_USER=nodeuser IN_MONERO_PASS="$SEH_S-mp" TARI_MODE_WIZ=off POOL_TIER=mini WIZ_STRATUM_PASSWORD="$SEH_S-sp" IN_DASH_USER=admin IN_DASH_PASS="$SEH_S-dp" CLEARNET_SYNC=false ONION_ENABLED=false TELEGRAM_BOT_TOKEN="$SEH_S-tt" TELEGRAM_CHAT_ID=42 LOCAL_MINER=false; wizard_write_config' >/dev/null 2>&1
assert_contains "the recording jq saw the wizard's calls" "$(seh_log)" "--arg mode local"
assert_not_contains "wizard: the node password is not a jq argument" "$(seh_log)" "$SEH_S-mp"
assert_not_contains "wizard: the stratum password is not a jq argument" "$(seh_log)" "$SEH_S-sp"
assert_not_contains "wizard: the dashboard password is not a jq argument" "$(seh_log)" "$SEH_S-dp"
assert_not_contains "wizard: the Telegram token is not a jq argument" "$(seh_log)" "$SEH_S-tt"
assert_eq "wizard: each value lands in config.json as typed" \
    "$(jq -r '[.monero.node_password, .p2pool.stratum_password, .dashboard.auth.password, .telegram.bot_token] | join("|")' "$SEH/config.json")" \
    "$SEH_S-mp|$SEH_S-sp|$SEH_S-dp|$SEH_S-tt"
assert_eq "wizard: the user name and chat id still land" \
    "$(jq -r '[.monero.node_username, .dashboard.auth.username, .telegram.chat_id] | join("|")' "$SEH/config.json")" "nodeuser|admin|42"

printf '{}' >"$SEH/config.json"
seh_run eval 'persist_node_credentials nodeuser "$SEH_S-np"; printenv JQ_NP || echo unset' >"$SEH/out" 2>/dev/null
assert_not_contains "node credentials: the password is not a jq argument" "$(seh_log)" "$SEH_S-np"
assert_eq "node credentials: the password lands as typed" "$(jq -r '.monero.node_password' "$SEH/config.json")" "$SEH_S-np"
assert_eq "node credentials: the value is not left in the shell's environment" "$(cat "$SEH/out")" "unset"

seh_run b32encode_hex 666f6f6261725f6b6579 >"$SEH/out" 2>/dev/null
assert_not_contains "onion key encoder: the hex key is not an awk argument" "$(seh_log)" "666f6f6261725f6b6579"
assert_eq "onion key encoder: the base32 output is unchanged" "$(cat "$SEH/out")" "MZXW6YTBOJPWWZLZ"
seh_run b32encode_hex zz >/dev/null 2>&1
assert_rc "onion key encoder: a non-hex input is still refused" "$?" "1"

printf '{"dashboard":{"onion":{"enabled":true}}}' >"$SEH/config.json"
seh_run eval 'validate_config_document() { :; }; generate_node_password() { printf "%s" "$SEH_S-op"; }; ensure_onion_password' >/dev/null 2>&1
assert_not_contains "onion password: the generated password is not a jq argument" "$(seh_log)" "$SEH_S-op"
assert_eq "onion password: the generated password lands" "$(jq -r '.dashboard.auth.password' "$SEH/config.json")" "$SEH_S-op"

printf '{}' >"$SEH/config.json"
seh_run eval '_console() { :; }; generate_node_password() { printf "%s" "$SEH_S-ap"; }; ensure_appliance_dashboard_password "" "$PWD/config.json"' >/dev/null 2>&1
assert_not_contains "appliance login: the generated password is not a jq argument" "$(seh_log)" "$SEH_S-ap"
assert_eq "appliance login: the generated password lands" "$(jq -r '.dashboard.auth.password' "$SEH/config.json")" "$SEH_S-ap"

mkdir -p "$SEH/control/staged" "$SEH/control/results" "$SEH/control/audit"
printf '#!/bin/sh\nmkdir -p "$(dirname "$SEH_ARCHIVE")" && : >"$SEH_ARCHIVE" && echo "[pithead] Backup written to: $SEH_ARCHIVE"\n' >"$SEH/self"
chmod +x "$SEH/self"
SEH_ARCHIVE="$SEH/backups/b.tar.gz.enc" PITHEAD_SELF="$SEH/self" APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 \
    seh_run eval 'control_prepare_backups_dir() { :; }; control_kit_redact() { :; }; generate_node_password() { printf "%s" "$SEH_S-bk"; }; control_backup bk1 admin "$PWD/control"' >/dev/null 2>&1
assert_not_contains "backup kit: the passphrase is not a jq argument" "$(seh_log)" "$SEH_S-bk"
assert_eq "backup kit: the passphrase lands in the kit" "$(jq -r '.passphrase' "$SEH/control/results/bk1.json")" "$SEH_S-bk"

APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 \
    seh_run eval 'control_kit_redact() { :; }; onion_client_credential() { printf "abcd.onion\t%s" "$SEH_S-ck"; }; control_onion_client_key ck1 admin "$PWD/control"' >/dev/null 2>&1
assert_not_contains "onion client kit: the private key is not a jq argument" "$(seh_log)" "$SEH_S-ck"
assert_eq "onion client kit: the key lands in both forms" \
    "$(jq -r '.client_key + "|" + .torrc_line' "$SEH/control/results/ck1.json")" "$SEH_S-ck|abcd:descriptor:x25519:$SEH_S-ck"

printf '{"local_miner":{"enabled":true}}' >"$SEH/config.json"
printf 'STRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=0123456789abcdef0123456789abcdef\n' >"$SEH/.env"
PITHEAD_APPLIANCE=1 PITHEAD_RIGFORGE_DIR="$SEH/rigforge" PITHEAD_HUGEPAGES_MARKER="$SEH/no-marker" \
    seh_run render_local_miner_config >/dev/null 2>&1
assert_not_contains "local miner: the stratum password is not a jq argument" "$(seh_log)" "0123456789abcdef0123456789abcdef"
assert_eq "local miner: the stratum password lands as the pool pass" "$(jq -r '.pools[0].pass' "$SEH/rigforge/config.json")" "0123456789abcdef0123456789abcdef"
rm -f "$SEH/.env" "$SEH/config.json" "$SEH/rigforge/config.json"

printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$SEH/rig.json"
seh_run rig_access_token >"$SEH/out" 2>/dev/null
assert_eq "rig token: a token is minted and kept" "$(jq -r '.access_token' "$SEH/rig.json")" "$(cat "$SEH/out")"
assert_not_contains "rig token: the minted token is not a jq argument" "$(seh_log)" "$(cat "$SEH/out")"

printf '#!/bin/sh\nexit 0\n' >"$SEH/bin/timeout"
chmod +x "$SEH/bin/timeout"
mkdir -p "$SEH/spool" "$SEH/rigforge-folder/config.json"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","access_token":"0123456789abcdef0123456789abcdef"}' >"$SEH/rig.json"
printf '{"pool":"10.0.0.9:3333","worker":"shed-3"}' >"$SEH/spool/rig-request.json"
seh_run firstboot_consume_rig "$SEH/spool" >/dev/null 2>&1
assert_not_contains "rig request: the kept token is not a jq argument" "$(seh_log)" "0123456789abcdef0123456789abcdef"
assert_eq "rig request: the token is kept with the new pool" "$(jq -r '.access_token + " " + .pool' "$SEH/rig.json")" "0123456789abcdef0123456789abcdef 10.0.0.9:3333"
rm -f "$SEH/bin/timeout"

printf '{"pool":"10.0.0.5:3333","worker":"shed-3","access_token":"0123456789abcdef0123456789abcdef"}' >"$SEH/rig.json"
printf '{"max_temp_c":81}' >"$SEH/rigforge/config.json"
chmod 644 "$SEH/rigforge/config.json"
exec {SEH_FD}<"$SEH/rigforge/config.json"
(umask 022 && PITHEAD_RIGFORGE_DIR="$SEH/rigforge" seh_run render_rig_miner_config >/dev/null 2>&1)
assert_not_contains "rig miner: the control token is not a jq argument" "$(seh_log)" "0123456789abcdef0123456789abcdef"
assert_eq "rig miner: the token and the kept key land" "$(jq -r '"\(.ACCESS_TOKEN) \(.max_temp_c)"' "$SEH/rigforge/config.json")" "0123456789abcdef0123456789abcdef 81"
assert_eq "rig miner: a config that was mode 644 ends owner-only" "$(file_mode "$SEH/rigforge/config.json")" "600"
assert_eq "rig miner: the old file is replaced, not rewritten" "$(cat <&"$SEH_FD")" '{"max_temp_c":81}'
exec {SEH_FD}<&-
seh_old=$(cat "$SEH/rigforge/config.json")
SEH_FAIL_ON=ACCESS_TOKEN PITHEAD_RIGFORGE_DIR="$SEH/rigforge" seh_run render_rig_miner_config >/dev/null 2>&1
assert_rc "rig miner: a failing render returns 1" "$?" "1"
assert_eq "rig miner: a failing render keeps the old config" "$(cat "$SEH/rigforge/config.json")" "$seh_old"
assert_eq "rig miner: a failing render leaves no temporary file" "$(find "$SEH/rigforge" -name 'config.json.*' | wc -l | tr -d ' ')" "0"
PITHEAD_RIGFORGE_DIR="$SEH/rigforge-folder" seh_run render_rig_miner_config >/dev/null 2>&1
assert_rc "rig miner: a folder at the config name fails the render" "$?" "1"
assert_eq "rig miner: nothing is put inside that folder" "$(find "$SEH/rigforge-folder" -mindepth 1 | wc -l | tr -d ' ')" "1"

mkdir -p "$SEH/data/firstboot"
SEH_FB='wizard_issue_file() { printf "%s/console.issue" "$PWD"; }; agetty() { [ "$1" = --reload ]; }; container_engine() { echo true; }; export_build_provenance() { :; }; stage_wizard_spool() { :; }; load_baked_images() { :; }; preseed_token() { return 1; }; wizard_mint_token() { echo token; }; wizard_keep_requested() { return 1; }; bash() { return 0; }; write_handoff_card() { cat >"$PWD/card.json"; }; wizard_spool_has() { [ "$2" != handoff-ack ] || exit 0; return 1; };'
PITHEAD_PRESEED_DIR="$SEH/esp" PITHEAD_INSTALL_BIN=/nonexistent PITHEAD_REGISTRY=registry STACK_VERSION=dev \
    seh_run eval "$SEH_FB firstboot_consume_rig() { return 0; }; firstboot_wizard" >/dev/null 2>&1
assert_not_contains "rig card: the control token is not a jq argument" "$(seh_log)" "0123456789abcdef0123456789abcdef"
assert_eq "rig card: the token lands on the card" "$(jq -r '.token' "$SEH/card.json" 2>/dev/null)" "0123456789abcdef0123456789abcdef"

rm -f "$SEH/rig.json" "$SEH/card.json"
jq -n --arg p "$SEH_S-cp" --arg s "$SEH_S-cs" '{monero: {mode: "remote", wallet_address: "4wallet"}, tari: {mode: "off"},
    dashboard: {auth: {username: "admin", password: $p}}, p2pool: {stratum_password: $s}}' >"$SEH/restored.json"
PITHEAD_PRESEED_DIR="$SEH/esp" PITHEAD_INSTALL_BIN=/nonexistent PITHEAD_REGISTRY=registry STACK_VERSION=dev \
    seh_run eval "$SEH_FB"' firstboot_consume_rig() { return 2; }; firstboot_consume_restore() { cp "$PWD/restored.json" "$PWD/config.json"; }; remote_node_addresses_allowed() { return 0; }; preflight_remote_nodes() { return 0; }; ensure_appliance_dashboard_password() { :; }; apply_appliance_defaults() { :; }; firstboot_wizard' >/dev/null 2>&1
assert_not_contains "coordinator card: the dashboard password is not a jq argument" "$(seh_log)" "$SEH_S-cp"
assert_not_contains "coordinator card: the stratum password is not a jq argument" "$(seh_log)" "$SEH_S-cs"
assert_not_contains "coordinator card: the stratum password is not a jq argument as JSON text either" "$(seh_log)" "$(jq -rn --arg v "$SEH_S-cs" '$v | tojson | .[1:-1]')"
assert_eq "coordinator card: both passwords land on the card" \
    "$(jq -r '.password + "|" + .stratum_password' "$SEH/card.json" 2>/dev/null)" "$SEH_S-cp|$SEH_S-cs"

unset -f seh_run seh_log
rm -rf "$SEH"
unset SEH SEH_S SEH_FD SEH_FB seh_tool seh_old
