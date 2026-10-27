# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"
WALLET="${WALLET:-$VALID_PRIMARY}"
core_reads=$(awk '/^wizard_ask_core\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
shape_reads=$(awk '/^wizard_ask_shape\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
assert_eq "core prompts cover only wallet and node configuration" "$core_reads" "8"
assert_eq "shape prompts are unchanged" "$shape_reads" "6"
W1="$SANDBOX/wizard-defaults"
mkdir -p "$W1"
printf '%s\n\n2\n%s\n\n\n\n\n' "$WALLET" "$VALID_TARI" | run_sourced "$W1" run_wizard >"$W1/output" 2>&1
w1_cfg="$(cat "$W1/config.json")"
assert_eq "wallet answer survives" "$(jq -r '.monero.wallet_address' <<<"$w1_cfg")" "$WALLET"
assert_eq "Tari answer survives" "$(jq -r '.tari.wallet_address' <<<"$w1_cfg")" "$VALID_TARI"
assert_eq "pool tier inherits mini" "$(jq -r '.p2pool | has("pool")' <<<"$w1_cfg")" false
assert_eq "username is admin" "$(jq -r '.dashboard.auth.username' <<<"$w1_cfg")" admin
assert_eq "new install XvB is off" "$(jq -r '.xvb.enabled' <<<"$w1_cfg")" false
assert_eq "DIY miner is off" "$(jq -r '.local_miner.enabled' <<<"$w1_cfg")" false
w1_pass=$(jq -r '.dashboard.auth.password' <<<"$w1_cfg")
assert_eq "generated password has 32 characters" "${#w1_pass}" 32
assert_eq "password is alphanumeric" "$(printf %s "$w1_pass" | tr -d 'A-Za-z0-9')" ""
assert_eq "password is shown once" "$(grep -Fc "$w1_pass" "$W1/output")" 1
for removed in "Pool tier [" "Dashboard username [" "Dashboard password (" "Enter Hostname [" "Join the XMRvsBeast raffle?"; do
    assert_not_contains "setup does not ask $removed" "$(cat "$W1/output")" "$removed"
done
WLM="$SANDBOX/wizard-local-miner"
mkdir -p "$WLM"
printf '%s\n\n2\n%s\n\n\n\ny\n' "$WALLET" "$VALID_TARI" | run_sourced "$WLM" run_wizard >/dev/null 2>&1
assert_eq "local miner remains opt-in" "$(jq -r '.local_miner.enabled' "$WLM/config.json")" true
W3="$SANDBOX/wizard-remote"
mkdir -p "$W3"
printf '%s\nn\nnode.example.com\n\n\ny\nremoteuser\nremotepass\n2\n%s\n\n\n\n\n' "$WALLET" "$VALID_TARI" | run_sourced "$W3" run_wizard >/dev/null 2>&1
assert_eq "remote node parameters survive" "$(jq -c '[.monero.mode,.monero.remote.host,.monero.remote.rpc_port,.monero.remote.zmq_port,.monero.node_username,.monero.node_password]' "$W3/config.json")" '["remote","node.example.com",18081,18083,"remoteuser","remotepass"]'
W4="$SANDBOX/wizard-remote-noauth"
mkdir -p "$W4"
printf '%s\nn\nremote2.example.com\n\n\nn\n2\n%s\n\n\n\n\n' "$WALLET" "$VALID_TARI" | run_sourced "$W4" run_wizard >/dev/null 2>&1
assert_eq "remote auth can remain empty" "$(jq -c '[.monero.node_username,.monero.node_password]' "$W4/config.json")" '["",""]'
W2="$SANDBOX/wizard-full"
mkdir -p "$W2"
printf '%s\n\n2\n%s\ny\ny\ny\nmybottoken123\n987654321\n' "$WALLET" "$VALID_TARI" | run_sourced "$W2" run_wizard >/dev/null 2>&1
w2_cfg="$(cat "$W2/config.json")"
assert_eq "fast sync applies to both local chains" "$(jq -c '[.monero.clearnet_initial_sync,.tari.clearnet_initial_sync]' <<<"$w2_cfg")" '[true,true]'
assert_eq "remote access enables onion" "$(jq -r '.dashboard.onion.enabled' <<<"$w2_cfg")" true
assert_eq "Telegram answers survive" "$(jq -c '[.telegram.enabled,.telegram.bot_token,.telegram.chat_id]' <<<"$w2_cfg")" '[true,"mybottoken123","987654321"]'
pointer_out="$(run_sourced "$SANDBOX" wizard_print_pointer 2>&1)"
for key in monero.view_key dashboard.energy.cost_per_kwh workers.list docs/configuration.md; do
    assert_contains "closing pointer names $key" "$pointer_out" "$key"
done

echo "== black-box: 'pithead setup' completes end-to-end from a wizard-produced config (#502) =="
# Everything above drives the wizard sub-functions directly (sourced). Nothing drives the actual
# command an operator runs — this is the gap. ensure_config_exists refuses a piped, non-interactive
# run OUTRIGHT when config.json is missing ([ ! -t 0 ] -> error, pithead ~L2118) — that gate is
# deliberate (don't silently generate a config from a script with no human reading the prompts), and
# it's exactly why the wizard functions were split out for testing (the comment above
# ensure_config_exists says so) rather than something to fake a tty around here. So: produce
# config.json the same piped-stdin way the wizard tests above do (proving the Q&A -> config path,
# same as W1), THEN hand it to the real `setup` command, which skips straight past that gate
# ([-f "$CONFIG_FILE"] short-circuit) and drives its own two remaining prompts (dashboard hostname,
# "start now?") from stdin like any other `read -r -p`. Same docker/sudo-stubbed sandbox as the apply
# black-box tests above; --skip-deps/--skip-optimize keep it host-safe (no apt/GRUB/sysctl edits);
# declining "start now?" stops short of actually bringing containers up.
SU="$SANDBOX/setup-e2e"
mkdir -p "$SU/build/tari" "$SU/dashboard"
: >"$SU/dashboard/Dockerfile"
cp "$STACK" "$SU/pithead"
cp "$ROOT/docker-compose.yml" "$SU/docker-compose.yml"
cp "$ROOT/build/tari/config.toml.template" "$SU/build/tari/"
make_stubs "$SU/bin"
printf '%s\n\n2\n%s\n\n\n\n\n\n\n\n' "$WALLET" "$VALID_TARI" | run_sourced "$SU" run_wizard >/dev/null 2>&1
if [ -f "$SU/config.json" ]; then ok "setup e2e: wizard stage produces config.json"; else bad "setup e2e: wizard stage produces config.json" "no file at $SU/config.json"; fi
su_out="$(cd "$SU" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$SU/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
su_rc=$?
assert_rc "'pithead setup' exits 0 given an existing config.json" "$su_rc" "0"
assert_contains "'pithead setup' reports completion" "$su_out" "Deployment preparation complete"
assert_eq "'pithead setup' writes a completed .env" \
    "$(run_sourced "$SU" env_get_file "$SU/.env" DEPLOYMENT_COMPLETED)" "true"

echo "== black-box: 'pithead setup' re-run with stdin on /dev/null refuses loudly (#924) =="
# Exactly how a systemd unit or cron invokes it (no tty, stdin /dev/null): the old
# `read -r -p ... || true` turned the immediate EOF into an empty RERUN, read as decline, exit 0
# — a silent FALSE SUCCESS. The fix refuses loudly with a nonzero exit instead of proceeding: an
# unattended re-provision must never ride on the absence of a terminal, and the appliance's own
# headless paths never reach this guard (a failed provisioning attempt is not deployed).
su2_out="$(cd "$SU" && DOCKER_LOG=/dev/null PATH="$SU/bin:$PATH" ./pithead setup --skip-deps --skip-optimize </dev/null 2>&1)"
su2_rc=$?
assert_rc "headless re-run on a deployed box refuses (nonzero, no silent success)" "$su2_rc" "1"
assert_contains "the refusal says how to proceed" "$su2_out" "run './pithead setup' from a terminal"
assert_not_contains "the refusal never claims setup was skipped-as-success" "$su2_out" "Setup skipped"
unset SU su_out su_rc su2_out su2_rc

echo "== black-box: a restored coordinator's carried DEPLOYMENT_COMPLETED does not strand headless setup (#1239) =="
# Live-guest evidence (#1239): a restored coordinator's .env carries the SOURCE machine's own
# DEPLOYMENT_COMPLETED=true. Pre-fix, is_deployed() read that literally and setup()'s headless
# guard (#924, proven above) fired on the box's OWN carried marker and fatally refused before
# prepare_directories/render_env/provision_tor ever ran — `podman ps -a` on the live guest: zero
# containers, forever, with a dark dashboard and no automatic recovery. restore_apply is the ONE
# commit point both restore doors share (firstboot_consume_restore's spool channel and
# consume_preseed_restore's ESP channel, exercised here — the exact door #1239's live guest hit at
# boot), so clearing the carried marker there — a just-restored box has NOT completed deployment
# on THIS hardware — fixes both without touching setup()'s guard, which must keep refusing an
# operator re-running setup on a genuinely live box (proven immediately above, and again below).
RT="$SANDBOX/restore-stranding"
mkdir -p "$RT/build/tari" "$RT/dashboard" "$RT/data/tor" "$RT/data/dashboard"
: >"$RT/dashboard/Dockerfile"
cp "$STACK" "$RT/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RT/build/tari/"
make_stubs "$RT/bin"
# make_stubs's sudo is a bare no-op — fine for setup's conditional sudo calls (writable test dirs
# skip them), but stack_backup shells to `sudo tar`/`sudo du` UNCONDITIONALLY. Same passthrough
# override the firstboot_consume_restore fixture above uses, for the same reason.
cat >"$RT/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
SUDOEOF
chmod +x "$RT/bin/sudo"
cat >"$RT/.env" <<EOF
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
PROXY_AUTH_TOKEN=0123456789abcdef01234567
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RT/config.json"
printf 'ONIONKEY-ORIG\n' >"$RT/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$RT/data/dashboard/dashboard.db"
(cd "$RT" && PATH="$RT/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y >/dev/null 2>&1)
rc=$?
assert_rc "restore-stranding fixture: backup exits 0" "$rc" "0"
rt_archive="$(ls "$RT"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rt_archive" ] && [ -f "$rt_archive" ]; } && ok "restore-stranding fixture: encrypted archive created" || bad "restore-stranding fixture: encrypted archive created" "no .enc archive"

# Play the TARGET machine: a fresh appliance, nothing provisioned yet, the archive carried on its
# ESP exactly as the installer stages it (#909) — same channel pithead-firstboot reads at boot.
RTESP="$RT/esp"
mkdir -p "$RTESP"
cp "$rt_archive" "$RTESP/pithead-restore.enc"
printf 'hunter2' >"$RTESP/pithead-restore-pass" # test fixture, not a real secret
rm -f "$RT/config.json" "$RT/.env"
printf 'CADDY-ORIG\n' >"$RT/Caddyfile"

preseed_out=$(cd "$RT" && PATH="$RT/bin:$PATH" PITHEAD_PRESEED_DIR="$RTESP" run_sourced "$RT" consume_preseed_restore 2>&1 && echo rc0)
assert_contains "consume_preseed_restore lands the carried archive" "$preseed_out" "rc0"
assert_eq "the restored config.json carries the source wallet" \
    "$([ -f "$RT/config.json" ] && grep -q "$WALLET" "$RT/config.json" && echo yes)" "yes"
assert_eq "the restored .env's completion marker is cleared, not carried forward (#1239)" \
    "$(cd "$RT" && run_sourced "$RT" env_get_file "$RT/.env" DEPLOYMENT_COMPLETED)" "false"

# The exact live-guest reproduction: pithead-firstboot's own headless call, `setup`, against the
# just-restored .env — pre-fix this hit is_deployed()'s no-tty branch and died with the SAME
# refusal string the #924 guard test above proves for a genuinely live box; post-fix the restored
# box actually provisions, same boot.
rt_setup_out=$(cd "$RT" && PATH="$RT/bin:$PATH" DOCKER_LOG=/dev/null ./pithead setup --skip-deps --skip-optimize </dev/null 2>&1)
rt_setup_rc=$?
assert_rc "restored box's headless setup proceeds instead of refusing (#1239)" "$rt_setup_rc" "0"
assert_contains "restored box's setup actually provisions" "$rt_setup_out" "Deployment preparation complete"
assert_not_contains "restored box's setup never hits the live-box refusal" "$rt_setup_out" "Already provisioned, and re-running setup"
assert_eq "restored box ends up actually deployed" \
    "$(cd "$RT" && run_sourced "$RT" env_get_file "$RT/.env" DEPLOYMENT_COMPLETED)" "true"
unset RT RTESP rt_archive preseed_out rt_setup_out rt_setup_rc

echo "== black-box: 'pithead setup' with stratum_tls in a hand-written config generates the keypair (#261) =="
# The setup path reaches compose through prepare_directories, never ensure_directories — a
# hand-written config.json with stratum_tls:true at FIRST setup must still get its cert + the
# fingerprint announcement (verifier catch: only the apply path was covered).
SUT="$SANDBOX/setup-tls"
mkdir -p "$SUT/build/tari" "$SUT/dashboard"
: >"$SUT/dashboard/Dockerfile"
cp "$STACK" "$SUT/pithead"
cp "$ROOT/build/tari/config.toml.template" "$SUT/build/tari/"
make_stubs "$SUT/bin"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_tls":true}, "dashboard":{"secure":false} }\n' "$WALLET" >"$SUT/config.json"
sut_out="$(cd "$SUT" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$SUT/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
assert_rc "setup with stratum_tls exits 0" "$?" "0"
[ -f "$SUT/data/proxy-tls/cert.pem" ] && [ -f "$SUT/data/proxy-tls/key.pem" ] &&
    ok "setup generates the TLS keypair (#261)" || bad "setup generates the TLS keypair (#261)" "missing under $SUT/data/proxy-tls"
assert_contains "setup announces the fingerprint for rig pinning" "$sut_out" "Stratum TLS is ON"
unset SUT sut_out

unset w1_cfg w2_cfg pointer_out core_reads shape_reads # NOT run_wizard: lib.sh owns it, and a bare unset drops the FUNCTION for every later domain

echo "== unit: a failed setup keeps the machine's configuration (#1059) =="
# The wizard's response to a non-zero `(setup)`. It used to be
# `mv -f config.json config.json.failed 2>/dev/null || rm -f config.json`, and it discarded a
# configuration that was valid enough to have rendered .env, provisioned Tor and started
# containers — the live capture that found this was a concurrent `backup` calling stack_down out
# from under setup's in-flight `compose up`, not a bad config. When the mv failed, for a reason
# it had already thrown away down 2>/dev/null, the fallback DELETED the file outright.
#
# Moving it aside was there to re-arm the setup wizard, and that needs BOTH of
# pithead-firstboot.service's ANDed conditions (asserted in run.sh's appliance-unit section).
# record_machine_role runs unconditionally on the accept path, so on every reachable failure the
# marker already holds the window shut and the move buys nothing.
WKF="$SANDBOX/wizard-keep-failed"
wkf_reset() { # <present|absent>  — the machine-role marker
    rm -rf "$WKF"
    mkdir -p "$WKF"
    cp "$STACK" "$WKF/pithead"
    # A fixed literal, not a fixture constant: wizard_keep_failed_config never parses the file,
    # so borrowing $WALLET would only buy an ordering dependency on another domain file.
    printf '{"submitted":"the operator answers"}\n' >"$WKF/config.json"
    # 644, NOT 600, and that is the whole point of the fixture. A copy tool derives the new
    # file's mode from the source, so a 600 source makes "the copy is 600" true of `cp` as much
    # as of `install -m 600` — the assertion would then be proven by the fixture instead of by
    # the guard. 644 is also the real shape: config.json written under systemd's default umask
    # 022 lands at 644, so this is what the tightening actually has to act on.
    chmod 644 "$WKF/config.json"
    if [ "$1" = "present" ]; then printf 'pithead\n' >"$WKF/machine-role"; fi
    return 0
}

# The reported case, and the only one an installed coordinator can reach.
wkf_reset present
wkf_out=$(run_sourced "$WKF" wizard_keep_failed_config 2>&1)
wkf_rc=$?
assert_rc "keeping the failed config reports success" "$wkf_rc" "0"
[ -f "$WKF/config.json" ] &&
    ok "a failed setup KEEPS config.json when machine-role exists (#1059)" ||
    bad "a failed setup KEEPS config.json when machine-role exists (#1059)" "config.json was removed"
[ -f "$WKF/config.json.failed" ] &&
    ok "a copy is kept as config.json.failed for the reopened page's prefill" ||
    bad "a copy is kept as config.json.failed for the reopened page's prefill" "no copy on disk"
assert_eq "the copy is byte-identical to what was submitted" \
    "$(cat "$WKF/config.json.failed" 2>/dev/null)" "$(cat "$WKF/config.json" 2>/dev/null)"
assert_eq "the copy stays owner-only — it holds the dashboard password and the wallet address" \
    "$(file_mode "$WKF/config.json.failed")" "600"

# The one case where removing it still buys something: record_machine_role is best-effort, so a
# marker that never landed leaves the wizard genuinely able to re-arm. The removal must survive.
wkf_reset absent
wkf_out=$(run_sourced "$WKF" wizard_keep_failed_config 2>&1)
wkf_rc=$?
assert_rc "the re-arming case reports success too" "$wkf_rc" "0"
[ ! -f "$WKF/config.json" ] &&
    ok "config.json IS still removed when machine-role is absent — the only case that re-arms the wizard" ||
    bad "config.json IS still removed when machine-role is absent — the only case that re-arms the wizard" "config.json survived"
[ -f "$WKF/config.json.failed" ] &&
    ok "the re-arming case keeps the copy before it removes anything" ||
    bad "the re-arming case keeps the copy before it removes anything" "removed with no copy on disk"

# The `|| rm -f` regression itself: make the copy impossible and check the configuration lives.
# machine-role is ABSENT on purpose — this is the branch the removal is reachable from, so a
# re-added fallback would actually delete here. The source is made unreadable rather than the
# destination unwritable, deliberately: an unwritable parent would also defeat the `rm`, and the
# case would then pass for a reason that has nothing to do with the guard.
# Verified against install(1) rather than assumed — a destination that is a directory, and one
# that is an existing 0400 file, BOTH succeed.
if [ "$(id -u)" = "0" ]; then
    echo "SKIP: running as root — mode 000 does not deny root, so an unreadable source cannot be staged"
else
    wkf_reset absent
    chmod 000 "$WKF/config.json"
    wkf_out=$(run_sourced "$WKF" wizard_keep_failed_config 2>&1)
    wkf_rc=$?
    chmod 600 "$WKF/config.json" 2>/dev/null || true
    assert_rc "a copy that cannot be made reports failure" "$wkf_rc" "1"
    [ -f "$WKF/config.json" ] &&
        ok "a copy that fails NEVER deletes the configuration (#1059)" ||
        bad "a copy that fails NEVER deletes the configuration (#1059)" "config.json was deleted with no copy on disk"
    [ ! -e "$WKF/config.json.failed" ] &&
        ok "and no half-written config.json.failed is left behind to look like a copy" ||
        bad "and no half-written config.json.failed is left behind to look like a copy" "a copy exists after a failed install"
    assert_contains "the reason is reported instead of discarded" "$wkf_out" "Could not keep a copy of the failed configuration"
fi

# The same four assertions at ANY uid. The staging above cannot be built as root (mode 000 does
# not deny root), and these are exactly the assertions that guard the reported defect, so the
# branch must not be uncovered on a root runner. Shadowing install(1) forces the failure directly.
# BESIDE the real-install case above, never instead of it: a stub proves the guard's shape, only a
# real install failure proves that a real one reaches it. The shadow is therefore coupled to the
# implementation still using install(1) — if that changes, this case reddens loudly (the success
# path runs and deletes config.json) rather than passing vacuously. Retarget the shadow then;
# do not delete the case.
wkf_reset absent
wkf_out=$(
    cd "$WKF" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    install() { return 1; }
    wizard_keep_failed_config 2>&1
)
wkf_rc=$?
assert_rc "a stubbed-failing copy reports failure too (any uid)" "$wkf_rc" "1"
[ -f "$WKF/config.json" ] &&
    ok "a failed copy NEVER deletes the configuration, at any uid (#1059)" ||
    bad "a failed copy NEVER deletes the configuration, at any uid (#1059)" "config.json was deleted"
[ ! -e "$WKF/config.json.failed" ] &&
    ok "and leaves no half-written copy behind, at any uid" ||
    bad "and leaves no half-written copy behind, at any uid" "a copy exists after a failed install"
assert_contains "the reason is reported at any uid" "$wkf_out" "Could not keep a copy of the failed configuration"

unset WKF wkf_out wkf_rc
unset -f wkf_reset
