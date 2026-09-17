# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The CLI wizard's Tari merge-mining question (#1916). Its own domain rather than more of
# test-wizard-setup.sh, which is at its docs/dev/file-budget.tsv ceiling, and because this is one
# coherent behaviour: whether './pithead setup' can decline Tari at all, and what it then writes.
#
# Before #1916 there was no answer that meant "I do not merge-mine". The wizard demanded a payout
# address, aborted without one, and wrote no tari.mode — and a missing tari.mode parses as "local"
# (lib/pithead/28-parse-and-validate-config.sh, the default that keeps a 1.x upgrade merge-mining),
# so the only way to decline was to hand-edit config.json after setup and re-run apply.
WALLET="${WALLET:-$VALID_PRIMARY}" # exactly build_val_sandbox's own default; a no-op under run.sh

echo "== unit: the Tari question's prompt count is pinned (#1916) =="
# Same reasoning as test-wizard-setup.sh's pins for the other two stages: every Enter-through answer
# looks alike, so a prompt added here would silently eat one more blank line. Four: the mode, the
# payout address, and the remote node's host and gRPC port.
tari_reads=$(awk '/^wizard_ask_tari\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
assert_eq "wizard_ask_tari has exactly 4 read prompts (mode, payout address, remote host, remote gRPC port)" "$tari_reads" "4"

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
wt_run() { # <name> <free-kb> <free-h> <answers-as-printf-%b>
    local d="$WT/$1"
    mkdir -p "$d"
    rm -f "$d/config.json"
    printf '%b' "$4" | PATH="$WT/bin:$PATH" WDF_KB="$2" WDF_H="$3" run_sourced "$d" run_wizard 2>&1
}
wt_cfg() { cat "$WT/$1/config.json" 2>/dev/null; }

echo "== unit: Enter-through on a host with room writes tari.mode EXPLICITLY (#1916) =="
# The key is written even when the answer is the one a missing key would have meant. That is the
# whole point: wizard_write_config otherwise omits-and-inherits, and an omitted tari.mode is only
# right for configs written before the question existed.
wt_run roomy-default "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\n\n\n$VALID_TARI\n\n\n\n\n\n\n\n" >/dev/null
c="$(wt_cfg roomy-default)"
assert_eq "roomy Enter-through: tari.mode is written, and it is local" "$(jq -r '.tari.mode' <<<"$c")" "local"
assert_eq "roomy Enter-through: the payout address it was given is stored" "$(jq -r '.tari.wallet_address' <<<"$c")" "$VALID_TARI"
assert_eq "roomy Enter-through: no tari.remote block for a bundled node" "$(jq -r '.tari | has("remote")' <<<"$c")" "false"

echo "== unit: Enter-through on a host without room declines, and asks for no address (#1916) =="
# The answers after the mode are the same ones the roomy fixture gave; the address line is simply
# never consumed, because a decline asks nothing further. Note what is NOT asserted here: that the
# transcript lacks the address prompt. `read -p` writes its prompt to the terminal only, so a piped
# run prints none and that assertion passes against any wizard at all. The config shape is the real
# proof that nothing was collected, and roomy-declined below proves the prompt is not merely
# ignored but absent.
out="$(wt_run small-default "$WT_SMALL_KB" "$WT_SMALL_H" "$WALLET\n\n\n$VALID_TARI\n\n\n\n\n\n\n\n")"
c="$(wt_cfg small-default)"
assert_eq "small-disk Enter-through: tari.mode off" "$(jq -r '.tari.mode' <<<"$c")" "off"
assert_eq "small-disk Enter-through: NO tari.wallet_address — nothing merge-mines, so nothing is paid" \
    "$(jq -r '.tari | has("wallet_address")' <<<"$c")" "false"
assert_eq "small-disk Enter-through: tari carries the mode and nothing else" \
    "$(jq -rc '.tari | keys' <<<"$c")" '["mode"]'
assert_contains "the decline says what it turned off and how to turn it back on" "$out" "Tari merge-mining is OFF"
assert_contains "and points at the key that does it" "$out" "tari.mode"

echo "== unit: the disk figure shown is the stack's own budget, and follows monero.mode (#1916) =="
# Not a bare 'Tari needs 200 GiB': the question is whether Tari fits ALONGSIDE everything else that
# lands on that filesystem, which is what doctor and preflight_resources measure too. A remote
# Monero node keeps its chain on another host, so its 320 GiB drops out of the comparison.
assert_contains "local Monero: the whole stack's budget, 320+200+5+2+1" \
    "$(wt_run note-local "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\n\n1\n\n\n\n\n\n\n\n")" "needs ~528 GiB"
assert_contains "remote Monero: Monero's chain drops out of the budget" \
    "$(wt_run note-remote "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\nn\nnode.example.com\n\n\nn\n1\n\n\n\n\n\n\n")" "needs ~208 GiB"

echo "== unit: an explicit answer beats the disk-derived default, both ways (#1916) =="
# The probe picks the DEFAULT, never the answer. An operator with a big disk who does not want Tari
# and one with a small disk who has an external drive in mind must both be able to say so.
c="$(
    wt_run roomy-declined "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\n\n1\nnano\n\n\n\n\n\n\n" >/dev/null
    wt_cfg roomy-declined
)"
assert_eq "answering 1 on a roomy host still declines" "$(jq -r '.tari.mode' <<<"$c")" "off"
assert_eq "the answer after the decline lands on the pool tier — no address prompt stands between them" \
    "$(jq -r '.p2pool.pool' <<<"$c")" "nano"
c="$(
    wt_run small-accepted "$WT_SMALL_KB" "$WT_SMALL_H" "$WALLET\n\n2\n$VALID_TARI\n\n\n\n\n\n\n\n" >/dev/null
    wt_cfg small-accepted
)"
assert_eq "answering 2 on a small host still runs the bundled node" "$(jq -r '.tari.mode' <<<"$c")" "local"
assert_eq "and stores the address it was given" "$(jq -r '.tari.wallet_address' <<<"$c")" "$VALID_TARI"

echo "== unit: an unrecognised answer falls back to the default rather than guessing (#1916) =="
out="$(wt_run garbage "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\n\nbanana\n$VALID_TARI\n\n\n\n\n\n\n\n")"
assert_contains "an unrecognised answer says so" "$out" "Not 1/2/3"
assert_eq "an unrecognised answer takes the disk-derived default" "$(jq -r '.tari.mode' <<<"$(wt_cfg garbage)")" "local"

echo "== unit: answer 3 writes tari.mode remote with the node it was given (#1916) =="
# The third answer has to collect a host: parse_and_validate_config refuses tari.mode "remote"
# without tari.remote.host, so a wizard that wrote the mode and asked nothing would produce a
# config that fails the very next command. The gRPC port is deliberately answered with a
# non-number — jq --argjson aborts on one, which would have thrown away every answer already given.
wt_run remote-node "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\n\n3\n$VALID_TARI\ntari.example.com\nbanana\n\n\n\n\n\n\n" >/dev/null
c="$(wt_cfg remote-node)"
assert_eq "answer 3: tari.mode remote" "$(jq -r '.tari.mode' <<<"$c")" "remote"
assert_eq "answer 3: the node host is carried through" "$(jq -r '.tari.remote.host' <<<"$c")" "tari.example.com"
assert_eq "answer 3: a non-numeric port falls back to 18142 instead of aborting the wizard" \
    "$(jq -r '.tari.remote.grpc_port' <<<"$c")" "18142"
assert_eq "answer 3: the payout address is still required and stored" "$(jq -r '.tari.wallet_address' <<<"$c")" "$VALID_TARI"

echo "== unit: saying yes and then giving no address aborts loudly (#1916) =="
# The required-field check did not disappear with the decline — it moved behind the answer. A yes
# with nowhere to be paid is still a refusal, and it must not write a half-configured config.json.
out="$(wt_run yes-no-address "$WT_ROOMY_KB" "$WT_ROOMY_H" "$WALLET\n\n2\n\n\n\n\n\n\n\n")"
assert_contains "a yes with no payout address is refused" "$out" "Tari payout address is required"
assert_contains "and the refusal names the answer that avoids it" "$out" "Answer 1 (No)"
[ ! -f "$WT/yes-no-address/config.json" ] &&
    ok "a refused Tari answer writes no config.json" ||
    bad "a refused Tari answer writes no config.json" "a file was written at $WT/yes-no-address/config.json"

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
cp "$ROOT/build/tari/config.toml.template" "$STO/build/tari/"
make_stubs "$STO/bin"
cp "$WT/bin/df" "$STO/bin/df"
printf '%b' "$WALLET\n\n1\n\n\n\n\n\n\n\n" |
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

unset c out tari_reads sto_profiles WT WT_ROOMY_KB WT_ROOMY_H WT_SMALL_KB WT_SMALL_H STO sto_out sto_rc
unset -f wt_run wt_cfg

echo "== unit: Tari's config pins the active chain to mainnet (#2304) =="
# config.toml.template had no `network` key at all — only an unused `[mainnet.p2p.seeds]` section
# header — so minotari_node fell back to its binary-default network, silently ignoring every
# mainnet-specific section while the image tag, docs, and operator all assume mainnet. Asserted on
# the file the node actually reads (the rendered runtime config, via the real
# render_tari_runtime_config()), not just the source template, so a regression that strips the key
# from either the template or the render is caught.
TARISRC="$SANDBOX/tari-network-pin-src.toml"
cp "$ROOT/build/tari/config.toml.template" "$TARISRC"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=false CLEARNET_MARKER="$SANDBOX/tari-network-pin-absent-marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-network-pin-rt.toml"
)
assert_contains "rendered runtime config still pins network=mainnet (#2304)" "$(cat "$SANDBOX/tari-network-pin-rt.toml")" 'network = "mainnet"'
unset TARISRC
