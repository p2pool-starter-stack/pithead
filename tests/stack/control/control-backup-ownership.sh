# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Cross-surface ownership of the CLI backup destination (#3363): the GUI backup verb runs as the
# privileged control user and starts the real `backup -y` as a child, which creates backups/. The
# operator's own `./pithead backup` in the same checkout must still be able to write there, with no
# manual chown, and the stack must come back after both. Two layers: glue rows (a stub child and a
# chown shim, runnable anywhere) and the real-root rows. Unlike the glue rows in test-control-backup.sh
# (a stub child, a chown shim) this runs the real stack_backup under real root via `sudo -n`, so it
# needs passwordless sudo: GitHub's runners have it. Without it the rows cannot run and say so; on CI
# (GITHUB_ACTIONS set) that is a failure, never a silent skip. Sourced from the end of
# test-control-backup.sh with its own domain_ran call, like control-results-prune.sh, and
# standalone-sourceable once tests/stack/lib.sh has been sourced: $SANDBOX, $STACK, $ROOT,
# $VALID_PRIMARY and $VALID_TARI are the names it reads without assigning.

: "${SANDBOX:?}"
: "${STACK:?}"

echo "== control channel: backup verb leaves backups/ to the config owner (#3363) =="
# The root child's own `mkdir -p backups` made the directory root:root 755, so the operator's next
# `./pithead backup` could not write. The glue now creates it first and chowns ONLY it to the
# config.json owner. A chown shim records the call (this suite is not root); the stub child records
# whether backups/ already existed when it started.
own_d="$SANDBOX/own3363"
mkdir -p "$own_d/bin" "$own_d/ctl/staged" "$own_d/ctl/results" "$own_d/ctl/audit"
printf '{}\n' >"$own_d/config.json"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/chown.log"\n' "$own_d" >"$own_d/bin/chown"
chmod +x "$own_d/bin/chown"
cat >"$own_d/self" <<'EOF'
#!/usr/bin/env bash
[ -d "$PWD/backups" ] && echo existed >>"$OWN_LOG" || echo missing >>"$OWN_LOG"
echo "[pithead] Backup written to: $FAKE_ARCHIVE"
EOF
chmod +x "$own_d/self"
own_id="a0a0a0a0-0000-4000-8000-0000000033a3"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$own_id" >"$own_d/req.json"
(
    export PATH="$own_d/bin:$PATH" PITHEAD_SELF="$own_d/self" OWN_LOG="$own_d/own.log" CONFIG_FILE="$own_d/config.json"
    export FAKE_ARCHIVE="$own_d/archive.enc" CONTROL_BACKUP_KIT_TTL_S=0
    printf 'x' >"$FAKE_ARCHIVE"
    run_sourced_e "$own_d" control_process_request "$own_d/req.json" "$own_d/ctl" >/dev/null 2>&1
)
assert_eq "backups/ exists before the root child runs" "$(cat "$own_d/own.log" 2>/dev/null)" "existed"
assert_contains "backups/ is handed to the config.json owner" \
    "$(cat "$own_d/chown.log" 2>/dev/null)" "$(stat -c '%u:%g' "$own_d/config.json") $own_d/backups"
assert_eq "the backups/ directory is re-owned exactly once, never recursively" \
    "$(grep -c "$own_d/backups\$" "$own_d/chown.log")" "1"
# A backups -> elsewhere symlink must not be followed by the root chown.
rm -rf "$own_d/backups" "$own_d/chown.log"
mkdir -p "$own_d/elsewhere"
ln -s "$own_d/elsewhere" "$own_d/backups"
(
    export PATH="$own_d/bin:$PATH" CONFIG_FILE="$own_d/config.json"
    run_sourced_e "$own_d" control_prepare_backups_dir >/dev/null 2>&1
)
assert_eq "a backups symlink is never chowned" "$(cat "$own_d/chown.log" 2>/dev/null | grep -c .)" "0"
rm -rf "$own_d"
unset own_d own_id

echo "== control channel: GUI backup then operator CLI backup in one checkout (#3363) =="
if ! sudo -n true 2>/dev/null; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        bad "passwordless sudo is available for the cross-surface backup rows" "sudo -n failed on CI"
    else
        echo "  SKIP: passwordless sudo is unavailable, so the privileged GUI-backup rows did not run"
    fi
else
    XB="$(cd "$SANDBOX" && pwd -P)/backup-xsurface"
    mkdir -p "$XB/build/tari" "$XB/data/tor" "$XB/data/dashboard" "$XB/bin" \
        "$XB/ctl/staged" "$XB/ctl/results" "$XB/ctl/audit"
    cp "$STACK" "$XB/pithead"
    cp "$ROOT/build/tari/config.toml.template" "$XB/build/tari/"
    XB_DOCKER_LOG="$XB/docker.log"
    : >"$XB_DOCKER_LOG"
    cat >"$XB/bin/docker" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$XB_DOCKER_LOG"
case "\$*" in
"compose ps --status running -q") echo fakecid ;;
"compose config --services") printf '%s\n' tor monerod tari p2pool dashboard caddy ;;
esac
exit 0
EOS
    printf '#!/usr/bin/env bash\nexec "$@"\n' >"$XB/bin/sudo"
    chmod +x "$XB/bin/docker" "$XB/bin/sudo"
    cat >"$XB/.env" <<'EOS'
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=XBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOS
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' \
        "$VALID_PRIMARY" >"$XB/config.json"
    xb_id="a0a0a0a0-0000-4000-8000-0000000033b3"
    printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$xb_id" >"$XB/req.json"

    # The GUI half, as the privileged control user: the real CLI is the child control_backup starts.
    # shellcheck disable=SC2024  # the redirect is deliberately the caller's: only the command is privileged
    sudo -n env PATH="$XB/bin:$PATH" PITHEAD_SELF="$XB/pithead" APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 \
        bash -Eeuo pipefail -c 'cd "$1"; source ./pithead; shift; "$@"' _ "$XB" \
        control_process_request "$XB/req.json" "$XB/ctl" >"$XB/gui.out" 2>&1
    assert_eq "the GUI backup (privileged) is applied" "$(jq -r .status "$XB/ctl/results/$xb_id.json" 2>/dev/null)" "applied"

    # The CLI half, as the configured non-root operator, with no chown in between.
    (cd "$XB" && PATH="$XB/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y) >"$XB/cli.out" 2>&1
    assert_rc "the operator's ./pithead backup -y succeeds after a GUI backup" "$?" "0"
    xb_archive="$(ls "$XB"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
    { [ -n "$xb_archive" ] && [ -s "$xb_archive" ]; } &&
        ok "the operator's backup wrote its timestamped archive under backups/" ||
        bad "the operator's backup wrote its timestamped archive under backups/" "$(tail -n 3 "$XB/cli.out")"
    assert_eq "the operator's archive is chmod 600" "$(stat -c '%a' "$xb_archive" 2>/dev/null)" "600"
    assert_eq "backups/ belongs to the operator" "$(stat -c '%u' "$XB/backups" 2>/dev/null)" "$(id -u)"
    assert_eq "the stack was started again after each of the two backups" \
        "$(grep -c '^compose up' "$XB_DOCKER_LOG")" "2"
    sudo -n rm -rf "$XB"
    unset XB XB_DOCKER_LOG xb_id xb_archive
fi
