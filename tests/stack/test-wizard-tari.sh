# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
WALLET="${WALLET:-$VALID_PRIMARY}"

tari_reads=$(awk '/^wizard_ask_tari\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
assert_eq "wizard_ask_tari has exactly 1 read prompt (the payout address)" "$tari_reads" "1"

# A df stub on PATH so the disk-derived default is decided by the fixture, not by whatever the
# machine running the suite happens to have free. Every query answers for one filesystem mounted at
# /data; WDF_KB / WDF_H say how much is free on it. disk_fs_mount walks $PWD/data up to the sandbox
# dir, so the stub has to answer for both that path and the mount it reports — ignoring the path
# argument entirely is what makes it answer for both.
WT="$SANDBOX/wizard-tari"
mkdir -p "$WT/bin"
cat >"$WT/bin/df" <<'EOF'
#!/usr/bin/env bash
human=0
for a in "$@"; do case "$a" in -Ph) human=1 ;; esac; done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [ "$human" = 1 ]; then echo "src 9 9 ${WDF_H} 1% /data"; else echo "src 9 9 ${WDF_KB} 1% /data"; fi
EOF
chmod +x "$WT/bin/df"
# 600 GiB clears the 528 GiB the whole stack with a bundled Tari node needs; 100 GiB does not.
WT_ROOMY_KB=629145600 WT_ROOMY_H=600G
WT_SMALL_KB=104857600 WT_SMALL_H=100G

# Drive the whole wizard with a scripted disk and scripted answers. Prints the wizard's own output;
# the config it wrote is left at $WT/<name>/config.json. Answer order is wizard_ask_core's:
# Monero address, local-node y/n, [remote node details], THEN the Tari block, then pool tier,
# dashboard login, and wizard_ask_shape's four.
wt_run() { # <name> <answers-as-printf-%b>
    local d="$WT/$1"
    mkdir -p "$d"
    rm -f "$d/config.json"
    printf '%b' "$2" | run_sourced "$d" run_wizard 2>&1
}
wt_cfg() { cat "$WT/$1/config.json" 2>/dev/null; }

cat >"$WT/bin/du" <<'DU'
#!/usr/bin/env bash
if [ -n "${WDU_KB:-}" ]; then printf '%s\t%s\n' "$WDU_KB" "${*: -1}"; else exec /usr/bin/du "$@"; fi
DU
chmod +x "$WT/bin/du"

echo "== unit: a blank Tari wallet asks nothing more and writes tari.mode off =="
out="$(wt_run blank "$WALLET\n\n\n")"
c="$(wt_cfg blank)"
assert_eq "blank Tari: tari.mode is written, and it is off" "$(jq -r '.tari.mode' <<<"$c")" "off"
assert_eq "blank Tari: no payout address is stored" "$(jq -r '.tari | has("wallet_address")' <<<"$c")" "false"
assert_eq "blank Tari: tari carries the mode and nothing else" "$(jq -rc '.tari | keys' <<<"$c")" '["mode"]'
assert_eq "blank Tari: dashboard.tari_required is false" "$(jq -r '.dashboard.tari_required' <<<"$c")" "false"
assert_contains "blank Tari: the decline says what it turned off and how to turn it on" "$out" "Tari merge-mining is OFF"
assert_contains "blank Tari: and points at the key that does it" "$out" "tari.mode"
assert_not_contains "blank Tari: no node, address or port follow-up is asked" "$out" "Tari Node Host"

WT_GUIDE="$(cat "$ROOT/docs/dev/manual-qa/diy/01-fresh-install.md")"
WT_DEFAULT_EXPECTATION="$(awk '/^### 1\.4a / {section=1; next} section && /^### / {exit} section {print}' <<<"$WT_GUIDE")"
assert_contains "fresh-install step 1.4a agrees with the blank-Tari config" \
    "$WT_DEFAULT_EXPECTATION" "Fresh Enter-through expectation: \`tari_mode=$(jq -r '.tari.mode' <<<"$c")\`"

echo "== unit: a filled Tari wallet writes the bundled node =="
out="$(wt_run filled "$WALLET\n$VALID_TARI\n\n")"
c="$(wt_cfg filled)"
assert_eq "filled Tari: tari.mode is local" "$(jq -r '.tari.mode' <<<"$c")" "local"
assert_eq "filled Tari: the address is stored" "$(jq -r '.tari.wallet_address' <<<"$c")" "$VALID_TARI"
assert_eq "filled Tari: dashboard.tari_required is false on a new install (#3333)" "$(jq -r '.dashboard.tari_required' <<<"$c")" "false"
assert_contains "filled Tari: the line says the bundled node runs" "$out" "bundled Tari node"

echo "== unit: Tari checksum and wrong-network answers re-prompt =="
out="$(wt_run retry "$WALLET\n${VALID_TARI%?}X\ngarbage\n$VALID_TARI\n\n")"
assert_contains "a bad checksum or format is refused" "$out" "✗"
assert_eq "the valid address after the refusals is stored" "$(jq -r '.tari.wallet_address' <<<"$(wt_cfg retry)")" "$VALID_TARI"
out="$(wt_run eof "$WALLET\n")"
assert_contains "end of input at the Tari prompt aborts loudly" "$out" "End of input while reading the Tari payout address"
[ ! -f "$WT/eof/config.json" ] && ok "an aborted Tari prompt writes no config.json" || bad "an aborted Tari prompt writes no config.json" "file written"

budget=$(PATH="$WT/bin:$PATH" WDF_KB="$WT_SMALL_KB" WDF_H="$WT_SMALL_H" run_sourced "$SANDBOX" wizard_disk_budget)
assert_eq "host publishes the measured data filesystem bytes" "$(jq -r '.available_bytes' <<<"$budget")" "$((WT_SMALL_KB * 1024))"
assert_eq "both wizards share the local and remote budgets" "$(jq -rc '[.local_need_bytes,.remote_need_bytes]' <<<"$budget")" '[566935683072,223338299392]'
# The field the booted-disk Enter exception travels on (#3333): without it the browser wizard never
# learns that the data disk holds a Tari chain.
assert_eq "no Tari data directory: the budget says no chain is held" "$(jq -r '.tari_chain_held' <<<"$budget")" "false"
mkdir -p "$WT/budget-held/data/tari"
budget=$(WDU_KB=104857600 PATH="$WT/bin:$PATH" WDF_KB="$WT_SMALL_KB" WDF_H="$WT_SMALL_H" run_sourced "$WT/budget-held" wizard_disk_budget)
assert_eq "a Tari directory of half the budget: the budget says a chain is held" "$(jq -r '.tari_chain_held' <<<"$budget")" "true"
budget=$(WDU_KB=104857599 PATH="$WT/bin:$PATH" WDF_KB="$WT_SMALL_KB" WDF_H="$WT_SMALL_H" run_sourced "$WT/budget-held" wizard_disk_budget)
assert_eq "a Tari directory a KiB under half the budget: no chain is held" "$(jq -r '.tari_chain_held' <<<"$budget")" "false"

echo "== unit: failed randomness cannot disable the default dashboard login =="
_wf_rng_rejected() {
    openssl() { return 1; }
    if generate_node_password; then return 1; fi
}
run_sourced "$SANDBOX" _wf_rng_rejected >/dev/null 2>&1
assert_rc "shared generator rejects failed OpenSSL even in a conditional" "$?" "0"
_wf_empty_password() {
    generate_node_password() { :; }
    run_wizard
}
mkdir -p "$WT/failed-password"
out=$(printf '%b' "$WALLET\n\n1\n\n\n\n" | run_sourced "$WT/failed-password" _wf_empty_password 2>&1)
assert_contains "default login aborts if generation produces an empty password" "$out" "Could not generate a dashboard password"
[ ! -f "$WT/failed-password/config.json" ] && ok "failed password generation writes no config" || bad "failed password generation writes no config" "config.json exists"
unset -f _wf_rng_rejected _wf_empty_password

echo "== unit: installer reports conservative fresh capacity and ext4 free space =="
sed '$d' "$ROOT/os/installer/pithead-install" >"$WT/installer-functions"
cat >"$WT/inventory-fixture" <<'EOF'
#!/usr/bin/env bash
source "$1"
findmnt() { return 1; }
lsblk() {
    case "$*" in
    '-Jdno NAME,SIZE,MODEL,SERIAL,TYPE') printf '%s' '{"blockdevices":[{"name":"fixture","size":"600G","type":"disk"}]}' ;;
    '-Jpo NAME,PARTLABEL,FSTYPE /dev/fixture') printf '%s' '{"blockdevices":[{"name":"/dev/fixture1","partlabel":"data","fstype":"ext4"}]}' ;;
    '-no PARTLABEL /dev/fixture') echo 'system-a data' ;;
    esac
}
blockdev() { echo "$fixture_bytes"; }
dumpe2fs() { printf 'Free blocks: 110\nReserved block count: 10\nBlock size: 4096\n'; }
fixture_bytes="$2"
list_disks
EOF
inventory=$(bash "$WT/inventory-fixture" "$WT/installer-functions" "$((600 * 1073741824))")
assert_eq "installer fresh estimate reserves slots and filesystem overhead" "$(cut -f6 <<<"$inventory")" "$(((600 * 1073741824 - 8 * 1073741824 - 256 * 1048576) * 93 / 100))"
assert_eq "installer retained-data measurement excludes occupied and reserved blocks" "$(cut -f7 <<<"$inventory")" "409600"

echo "== black-box: 'pithead setup' completes on a config that declined Tari (#1916) =="
# The assertion the wizard-level cases cannot make. parse_and_validate_config already drops the
# Tari address from the required set when the mode is "off" (#1855), so the wizard's own check was
# the last thing demanding it — this proves a declined config actually walks through the real
# setup command rather than merely being written. Same docker/sudo-stubbed sandbox and host-safe
# flags as test-wizard-setup.sh's own setup e2e; declining "start now?" stops short of containers.
STO="$WT/setup-tari-off"
mkdir -p "$STO/build/tari" "$STO/dashboard" "$STO/bin"
: >"$STO/dashboard/Dockerfile"
cp "$STACK" "$STO/pithead"
cp "$ROOT/docker-compose.yml" "$STO/docker-compose.yml"
cp "$ROOT/build/tari/config.toml.template" "$STO/build/tari/"
make_stubs "$STO/bin"
cp "$WT/bin/df" "$STO/bin/df"
printf '%b' "$WALLET\n\n\n" |
    PATH="$STO/bin:$PATH" WDF_KB="$WT_ROOMY_KB" WDF_H="$WT_ROOMY_H" run_sourced "$STO" run_wizard >/dev/null 2>&1
assert_eq "setup e2e (declined): the wizard wrote tari.mode off" \
    "$(jq -r '.tari.mode' "$STO/config.json" 2>/dev/null)" "off"
sto_out="$(cd "$STO" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$STO/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
sto_rc=$?
assert_rc "'pithead setup' exits 0 on a config with no Tari payout address" "$sto_rc" "0"
assert_contains "'pithead setup' reports completion" "$sto_out" "Deployment preparation complete"
assert_not_contains "setup never demands the Tari address it was told not to need" "$sto_out" "Missing required wallet addresses"
# With its own positive control: an .env that was never written greps to zero as readily as one
# that correctly left the profile out, so assert what IS there before asserting what is not.
sto_profiles="$(run_sourced "$STO" env_get_file "$STO/.env" COMPOSE_PROFILES)"
assert_contains "the declined machine still runs its own Monero node" "$sto_profiles" "local_node"
assert_not_contains "the declined machine runs no Tari container (no local_tari profile)" "$sto_profiles" "local_tari"

unset WT_GUIDE WT_DEFAULT_EXPECTATION c out tari_reads sto_profiles WT WT_ROOMY_KB WT_ROOMY_H WT_SMALL_KB WT_SMALL_H STO sto_out sto_rc
unset -f wt_run wt_cfg
