# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Privileged GUI and operator CLI backups must coexist in either order without broadening access.

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

echo "== control channel: GUI and CLI backup ownership in both orders =="
if ! sudo -n true 2>/dev/null; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        bad "passwordless sudo is available for the cross-surface backup rows" "sudo -n failed on CI"
    else
        echo "  SKIP: passwordless sudo is unavailable, so the privileged GUI-backup rows did not run"
    fi
else
    for xb_order in "gui cli gui" "cli gui gui"; do
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
        printf 'onion-identity\n' >"$XB/data/tor/hs_ed25519_secret_key"
        printf 'dashboard-history\n' >"$XB/data/dashboard/dashboard.db"
        xb_step=0
        for xb_surface in $xb_order; do
            xb_step=$((xb_step + 1))
            xb_id="a0a0a0a0-0000-4000-8000-0000000033b$xb_step"
            if [ "$xb_surface" = gui ]; then
                printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$xb_id" >"$XB/req.json"
                sudo -n rm -f "$XB/ctl/staged/.backup-stamp"
                # Capture the one-time kit before redaction without changing the backup child.
                # shellcheck disable=SC2024
                sudo -n env PATH="$XB/bin:$PATH" PITHEAD_SELF="$XB/pithead" CONTROL_BACKUP_KIT_TTL_S=0 \
                    bash -Eeuo pipefail -c 'cd "$1"; source ./pithead; control_kit_redact() { :; }; control_process_request "$1/req.json" "$1/ctl"' _ "$XB" >"$XB/gui.out" 2>&1
                assert_rc "$xb_order: GUI backup $xb_step completes" "$?" "0"
                assert_eq "$xb_order: GUI backup $xb_step is applied" "$(sudo -n jq -r .status "$XB/ctl/results/$xb_id.json")" "applied"
                xb_archive="$XB/ctl/results/$xb_id.tar.gz.enc"
                (
                    umask 077
                    # shellcheck disable=SC2024
                    sudo -n jq -er .passphrase "$XB/ctl/results/$xb_id.json" >"$XB/pass-$xb_step"
                )
                xb_owner="0:1000" xb_mode=640
            else
                (cd "$XB" && umask 022 && PATH="$XB/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=operator-fixture-pass ./pithead backup -y) >"$XB/cli.out" 2>&1
                assert_rc "$xb_order: operator backup $xb_step completes" "$?" "0"
                xb_archive="$(find "$XB/backups" -name 'pithead-backup-*.tar.gz.enc' -type f)"
                printf '%s\n' operator-fixture-pass >"$XB/pass-$xb_step"
                xb_owner="$(id -u):$(id -g)" xb_mode=600
            fi
            printf '%s\n' "$xb_archive" >"$XB/archive-$xb_step"
            printf '%s\n' "$xb_owner" >"$XB/owner-$xb_step"
            printf '%s\n' "$xb_mode" >"$XB/mode-$xb_step"
            sleep 1
        done
        for xb_step in 1 2 3; do
            xb_archive="$(cat "$XB/archive-$xb_step")"
            assert_eq "$xb_order: archive $xb_step owner:group" "$(stat -c '%u:%g' "$xb_archive")" "$(cat "$XB/owner-$xb_step")"
            assert_eq "$xb_order: archive $xb_step mode" "$(file_mode "$xb_archive")" "$(cat "$XB/mode-$xb_step")"
            xb_reader=()
            [ "$(cat "$XB/mode-$xb_step")" != 640 ] || xb_reader=(sudo -n)
            xb_listing="$("${xb_reader[@]}" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$XB/pass-$xb_step" -in "$xb_archive" | tar -tzf -)"
            assert_rc "$xb_order: archive $xb_step decrypts with its own passphrase" "$?" "0"
            for xb_member in config.json .env data/tor/hs_ed25519_secret_key data/dashboard/dashboard.db; do
                assert_contains "$xb_order: archive $xb_step contains $xb_member" "$xb_listing" "${XB#/}/$xb_member"
            done
        done
        assert_eq "$xb_order: backups/ belongs to the operator" "$(stat -c '%u:%g' "$XB/backups")" "$(id -u):$(id -g)"
        assert_eq "$xb_order: stack restarted after all three backups" "$(grep -c '^compose up' "$XB_DOCKER_LOG")" "3"
        sudo -n rm -rf "$XB"
    done
    unset XB XB_DOCKER_LOG xb_order xb_step xb_surface xb_id xb_archive xb_owner xb_mode xb_listing xb_member xb_reader
fi
