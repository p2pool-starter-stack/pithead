# `uninstall` (#77 phase 1, #2379): the clean exit for the DIY channel — stop and remove
# everything pithead put on this host, and delete NO data, ever, on any flag. Three named
# volumes (caddy_data, wallet_data, tari_wallet_data) are pithead's, not the operator's — all
# three are derived (view-only wallets rebuild from the view keys in config.json, Caddy
# re-issues its ACME state) — so they go with the containers via `compose down -v`. Everything
# an operator would call "their data" (chains, Tor onion keys, dashboard history, the p2pool
# sidechain) is a bind mount and is never touched. The appliance has no uninstall — its
# equivalents are the reset tiers.
#
# uninstall_quote() single-quotes a path for a copy-pasteable shell command (handles spaces and
# embedded quotes); it is the only formatting helper this needs; the rest of the closing message
# is plain log lines, one per line, because log() prefixes every call with "[pithead]".
uninstall_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# uninstall_removable <path> <expected> <checkout> <kept>... succeeds only for the derived
# directory at exactly the path setup gives it (<expected>), with no . or .. component, not the
# checkout or above it, and neither a kept path nor above or inside one. A derived *_DIR key is
# read from .env, which an operator can edit; pointing one anywhere else must never become an
# `rm -rf`.
uninstall_removable() {
    local p k
    p=$(printf '%s' "$1" | sed 's#//*#/#g; s#/$##')
    case "$p" in /?*) ;; *) return 1 ;; esac
    case "$p/" in */../* | */./*) return 1 ;; esac
    [ "$p" = "$(printf '%s' "$2" | sed 's#//*#/#g; s#/$##')" ] || return 1
    case "$3/" in "$p/"*) return 1 ;; esac
    shift 3
    for k in "$@"; do
        k=$(printf '%s' "$k" | sed 's#//*#/#g; s#/$##')
        case "$k/" in "$p/"*) return 1 ;; esac
        case "$p/" in "$k/"*) return 1 ;; esac
    done
}

stack_uninstall() {
    local yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) yes=1 ;;
        *) error "Unknown option for uninstall: $arg. Run '$0 help'." ;;
        esac
    done
    [ -f .env ] || error "No .env here — nothing deployed to uninstall. A never-deployed checkout is just a directory: remove it."
    # #2692: every version dir drives the one Compose project (`name: pithead`), the host firewall
    # and the shared data root, so uninstall from a kept rollback dir would take down the LIVE
    # stack. Refuse before anything runs; the live dir is where uninstall belongs.
    local live
    if live=$(superseded_by_live_install "$PWD"); then
        error "This is not the live install: $(dirname "$PWD")/current points at $live, and uninstall here would stop that stack. Nothing changed. To uninstall, run it in $live. To tidy up this old version only, delete $PWD by hand, after checking that no *_DATA_DIR in $live/.env lives inside it."
    fi
    detect_os

    # Every path below is read from .env BEFORE uninstall deletes it.
    local checkout_dir="$PWD" kept_dirs=() derived_dirs=() d dkey
    for dkey in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR TOR_DATA_DIR; do
        d=$(env_get_file .env "$dkey")
        [ -n "$d" ] && kept_dirs+=("$d")
    done
    # #2379 §3: four more directories setup creates (hardcoded under data/, or under the shared
    # data root for PROXY_TLS_DIR) that the old keep-list never named or removed. None is operator
    # data — the control spool + audit trail, the clearnet-sync marker, Caddy's access log, and the
    # stratum TLS keypair — so they are removed individually, by exact path, never `rm -rf data/`.
    # Where setup puts each one (28-parse-and-validate-config.sh): three fixed under ./data, and
    # proxy-tls in the shared data root when the four chain/Tor dirs share a parent.
    local data_root want mon tar p2p tor
    mon=$(env_get_file .env MONERO_DATA_DIR)
    tar=$(env_get_file .env TARI_DATA_DIR)
    p2p=$(env_get_file .env P2POOL_DATA_DIR)
    tor=$(env_get_file .env TOR_DATA_DIR)
    data_root=$(dirname "${mon:-$checkout_dir/data/monero}")
    { [ "$(dirname "${tar:-/}")" = "$data_root" ] && [ "$(dirname "${p2p:-/}")" = "$data_root" ] &&
        [ "$(dirname "${tor:-/}")" = "$data_root" ]; } || data_root="$checkout_dir/data"
    for dkey in CONTROL_DIR:"$checkout_dir/data/control" CLEARNET_STATE_DIR:"$checkout_dir/data/clearnet-state" \
        CADDY_LOG_DIR:"$checkout_dir/data/caddy-logs" PROXY_TLS_DIR:"$data_root/proxy-tls"; do
        want=${dkey#*:}
        dkey=${dkey%%:*}
        d=$(env_get_file .env "$dkey")
        [ -n "$d" ] || continue
        if uninstall_removable "$d" "$want" "$checkout_dir" "${kept_dirs[@]}" "$checkout_dir/config.json" "$checkout_dir/backups"; then
            derived_dirs+=("$d")
        else
            warn "Not removing $dkey=$d: setup puts it at $want, and it must not overlap data uninstall keeps. Remove it by hand if it is pithead's."
        fi
    done
    # #2379 §1: the Tari view-key secret file — chmod 600, holds MINOTARI_WALLET_PASSWORD in the
    # clear — is fixed under ./data (33-render-env.sh), not a *_DIR key in .env.
    local secret_file="$checkout_dir/data/tari-wallet-secret.env"

    local kept_list derived_list
    kept_list=$(printf '%s\n' "${kept_dirs[@]}" | sort -u | tr '\n' ' ')
    derived_list=$(printf '%s\n' "${derived_dirs[@]}" "$secret_file" | sort -u | tr '\n' ' ')

    warn "DESTRUCTIVE: stops the stack and removes everything pithead put on this host. Deletes no data."
    log "Removed: containers, networks and images; the caddy_data/wallet_data/tari_wallet_data volumes; this checkout's control-runner units; the egress firewall rules and their pithead-egress.service boot unit; .env, Caddyfile, build/tari/config.toml and .pithead-first-run-done in $checkout_dir, and: ${derived_list}"
    log "Kept (yours): $checkout_dir/config.json, $checkout_dir/backups/, and the data dirs: ${kept_list:-none recorded}"
    log "Left behind (shared with the machine, not pithead's alone to remove): the apt packages setup installed (jq, openssl, docker.io, docker-compose-v2); the GRUB HugePages cmdline; the runtime HugePages pool."
    if [ "$yes" -ne 1 ]; then
        printf "Type 'uninstall' to continue: "
        read -r arg
        [ "$arg" == "uninstall" ] || {
            log "Aborted — nothing changed."
            return 1
        }
    fi
    remove_tor_egress_firewall 2>/dev/null || true
    remove_tor_egress_boot_unit
    remove_lan_guard
    docker compose down --remove-orphans -v 2>/dev/null ||
        warn "compose down failed (engine not running?) — continuing with cleanup. Once the engine runs, remove the volumes with: docker volume rm pithead_caddy_data pithead_wallet_data pithead_tari_wallet_data"
    # Exact image refs from the compose config; failures (image shared/in use) are non-fatal.
    docker compose config --images 2>/dev/null | sort -u | while read -r img; do
        [ -n "$img" ] && docker rmi "$img" >/dev/null 2>&1 || true
    done
    # Removes only THIS checkout's pithead-control units (the ownership check inside).
    DASHBOARD_CONTROL_ENABLED=false provision_control_runner 2>/dev/null || true
    # The view-key secret goes first: nothing after it may leave a 0600 key behind.
    rm -f "$secret_file"
    rm -f .env Caddyfile build/tari/config.toml .pithead-first-run-done
    local failed=0
    for d in "${derived_dirs[@]}"; do
        # CADDY_LOG_DIR is root:root-owned (31-directories-and-dashboard-state.sh) so the
        # capability-stripped caddy container can write it; a non-root operator's plain rm fails.
        rm -rf "$d" 2>/dev/null || sudo rm -rf "$d" || {
            warn "Could not remove $d — remove it with: sudo rm -rf $(uninstall_quote "$d")"
            failed=1
        }
    done
    # The version symlink (#455) is removed only when it is THIS checkout's: a versioned deploy
    # dir (pithead-vX.Y.Z) whose sibling `current` still points here. Anything else — a plain
    # checkout, or a `current` some other version now owns — is left alone.
    if is_versioned_install_dir "$checkout_dir"; then
        local parent name
        parent=$(dirname "$checkout_dir")
        name=$(basename "$checkout_dir")
        [ -L "$parent/current" ] && [ "$(readlink "$parent/current")" = "$name" ] && rm -f "$parent/current"
    fi

    log "Uninstalled."
    log "Every data directory is still here. To delete pithead's data, run:"
    if [ "${#kept_dirs[@]}" -gt 0 ]; then
        local q quoted_kept=""
        for d in "${kept_dirs[@]}"; do
            q=$(uninstall_quote "$d")
            quoted_kept="$quoted_kept $q"
        done
        printf '  sudo rm -rf%s\n' "$quoted_kept"
    fi
    # printf, not log: log's echo -e would turn a backslash in a path into a control character.
    printf '  rm -rf %s %s\n' "$(uninstall_quote "$checkout_dir/backups")" "$(uninstall_quote "$checkout_dir/config.json")"
    local inside=""
    for d in "${kept_dirs[@]}"; do
        case "$d/" in "$checkout_dir/"*) inside=" It holds data kept above, so run this only once that is gone or moved." ;; esac
    done
    log "Then, to remove the program itself:${inside}"
    printf '  rm -rf %s\n' "$(uninstall_quote "$checkout_dir")"
    # error, not a bare non-zero return: that would also print the ERR trap's "aborted unexpectedly".
    [ "$failed" -eq 0 ] || error "Uninstall finished, but a derived directory could not be removed: run the command in the warning above."
}

# --- First-boot wizard (#77 phase 3) -------------------------------------------------------------
# The browser-first setup path for BOTH channels: a token-gated form (the dashboard image in
# wizard mode) collects the CLI wizard's answers pre-sync; THIS host validates and applies them.
# Container asks, host provisions — the #33 trust shape. Plain HTTP on the trusted LAN with
# secret minimization: addresses and shape choices only (docs/dev/dual-distribution-plan.md § 3).

# Human-typable one-time token: 6 chars from an unambiguous alphabet (no 0/O/1/I/l).
wizard_mint_token() {
    local alphabet="23456789ABCDEFGHJKMNPQRSTUVWXYZ" out="" i idx
    for i in 1 2 3 4 5 6; do
        idx=$(($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % ${#alphabet}))
        out="$out${alphabet:$idx:1}"
    done
    printf 'pit-%s' "$out"
}

# Consume one wizard submission: validate the candidate with the same parser setup/apply use; on
# success install it as ./config.json and mark the spool applied (the wizard page polls for it).
# On failure surface a short error into the spool for the form. rc: 0 applied, 1 rejected, 2 none.
firstboot_consume_spool() ( # <spool-dir> [<config-dest>]
    local spool="$1" dest="${2:-$PWD/config.json}" cand="$1/config.json" err
    local snap rc=0
    wizard_submission_ready "$spool" || return 2
    snap=$(wizard_spool_request "$spool" config.json) || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    trap 'rm -f "${snap}.bak-1x"; wizard_spool_clean "${snap%/*}"' EXIT
    cand="$snap"
    # CONFIG_FILE is readonly after sourcing; validate the candidate in a fresh process via the
    # PITHEAD_CONFIG_FILE override (the same parser setup/apply run, against the same file).
    if err=$(PITHEAD_CONFIG_FILE="$cand" PITHEAD_CONFIG_SET=1 bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        install -m 600 "$cand" "$dest" || {
            wizard_clear_submission_transaction "$spool" || true
            return 1
        }
        rm -f "$spool/config.json"
        wizard_spool_publish "$spool" applied true || return 1
        return 0
    fi
    printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 | wizard_spool_publish "$spool" error.txt cat
    rm -f "$spool/config.json"
    wizard_clear_submission_transaction "$spool" || return 1
    return 1
)

# --- the machine role (one stick, three machines) -------------------------------------------
# What a machine IS is the wizard's first question: a Pithead coordinator, a coordinator that
# also mines (Both), or a RigForge rig. config.json states the coordinator roles exactly — Both
# IS local_miner.enabled — so the marker is derived from it there. The rig role has no
# config.json at all, which is why the marker, with rig.json beside it, exists: the boot path
# reads machine-role to know which leg to start. Absent marker = pithead (every machine
# provisioned before this contract).

record_machine_role() { # <pithead|both|rig>
    printf '%s\n' "$1" >"$PWD/machine-role" 2>/dev/null || true
    # A role change replaces the role's data with it (#1318): rig.json — and the control token in
    # it — belongs to the rig role only, so a machine accepted as a coordinator leaves none behind.
    [ "$1" = rig ] || rm -f "$PWD/rig.json"
}

# The wizard's response to a failed (setup), as one step so it can be driven directly (#1059).
#
# It KEEPS the machine's configuration. A non-zero (setup) says something went wrong, never that
# the submitted config is what went wrong — the capture that found this was a concurrent `backup`
# calling stack_down out from under setup's in-flight `compose up`, on a config valid enough to
# have rendered .env, provisioned Tor and started containers.
#
# This used to MOVE the file, to re-arm the setup wizard. It cannot, on any path that reaches it:
# pithead-firstboot.service ANDs !config.json with !machine-role, and record_machine_role above
# has already run, so the second condition holds the window shut whatever this does with the
# first. Keeping the file also keeps the next boot working — pithead-boot.service's conditions
# are ORed so it runs regardless, and os/overlay/pithead-boot's `./pithead render` reads exactly
# the file the move used to take away.
#
# The removal therefore happens only where it can still buy something: a machine-role that never
# landed (record_machine_role is best-effort). It lives INSIDE the success branch on purpose —
# the defect this replaced was `mv ... 2>/dev/null || rm -f config.json`, which deleted the
# operator's configuration outright whenever the mv failed, for a reason it had already
# discarded. Structurally, nothing here can remove the file without a copy already on disk.
#
# install -m 600, not cp: config.json holds the dashboard password and the wallet address, and
# the copy must not widen its mode.
#
# rc 0 = a copy was kept, 1 = it could not be.
wizard_keep_failed_config() {
    # #2050: setup sets DEPLOYMENT_COMPLETED=true a third of the way in, so a failure past that
    # point leaves the marker on a machine that is NOT deployed and setup's is_deployed guard
    # (#924) refuses every retry headless — the reopened page was unusable. Same clear, same
    # reason, as restore_apply makes on a carried .env (#1239): one marker, two doors.
    if [ -f "$PWD/$ENV_FILE" ]; then
        safe_sed 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' "$PWD/$ENV_FILE" ||
            warn "Could not clear the deployment marker — a retry from the setup page will refuse as already provisioned."
    fi
    if install -m 600 "$PWD/config.json" "$PWD/config.json.failed" 2>/dev/null; then
        [ -f "$PWD/machine-role" ] || rm -f "$PWD/config.json"
        return 0
    fi
    warn "Could not keep a copy of the failed configuration as config.json.failed."
    return 1
}

# CONTENTION IS NOT A BAD CONFIG — the wizard's half of #1342's routing, and it was missing.
#
# os/overlay/pithead-boot has the boot leg's half (fail_boot_contended): a lock timeout there is
# contention, not a bad A/B slot, so the fallback is not spent. `setup` runs inside a mutating
# window too, and can lose exactly the same race — but every non-zero (setup) was routed as a
# provisioning failure, which tells the operator their configuration is wrong and asks them to
# correct it. On a first boot there is no shell to contradict it with.
#
# Worse than misleading. That path calls wizard_keep_failed_config, which removes config.json
# whenever the machine-role marker never landed — and record_machine_role is best-effort
# (`printf ... || true`). So contention could take a VALID configuration away from the operator
# and then blame them for it: #1059's own shape, on the one leg #1059's fix did not route.
#
# Kept as a function rather than inline at the call site, for the reason boot_up_failed gives on
# the other leg: the two halves of one decision drift apart when they are written twice.
#
# rc 0 = a config.json.failed copy was kept (so the reopened page prefills from it), 1 = not.
# Contention deliberately returns 1 WITHOUT calling wizard_keep_failed_config: nothing is copied,
# nothing is removed, and the live config.json the operator submitted is what prefills the retry.
wizard_setup_failed() { # <exit status of setup>
    if [ "$1" = "$PITHEAD_EX_LOCK_TIMEOUT" ]; then
        warn "Another pithead operation still held the machine, and provisioning timed out waiting for it."
        warn "That is contention, NOT a problem with the configuration you submitted — it is kept exactly as it is."
        warn "Reopening the setup window so it can be resubmitted once the other operation has finished."
        return 1
    fi
    warn "Provisioning failed. A copy of the submitted configuration is kept as config.json.failed;"
    warn "reopening the setup window so it can be corrected."
    wizard_keep_failed_config
}

# The marker, read back. Anything unrecognised (or absent) is a coordinator: every machine
# provisioned before this contract existed had no marker and was one.
machine_role() { # echoes pithead|both|rig
    local r=""
    if [ -f "$PWD/machine-role" ]; then
        r=$(tr -d '[:space:]' <"$PWD/machine-role" 2>/dev/null) || r=""
    fi
    case "$r" in rig | both | pithead) printf '%s' "$r" ;; *) printf 'pithead' ;; esac
}

machine_role_from_config() { # <config-file>
    if [ "$(jq -r '.local_miner.enabled // false' "$1" 2>/dev/null)" = "true" ]; then
        printf 'both'
    else
        printf 'pithead'
    fi
}

# The rig role's pool pre-fill: a Pithead on the LAN answers pithead.local:3333. The HOST
# dials — the container never touches the network — and publishes the finding to the spool the
# way the disk inventory travels. Fail open: no answer publishes only this machine's name, and
# the pool field opens empty. PITHEAD_RIG_PROBE overrides the target for tests.
publish_rig_defaults() { # <spool-dir>
    local probe="${PITHEAD_RIG_PROBE:-pithead.local:3333}" pool=""
    if timeout 3 bash -c "</dev/tcp/${probe%:*}/${probe##*:}" 2>/dev/null; then
        pool="$probe"
    fi
    jq -n --arg pool "$pool" --arg worker "$(hostname)" \
        '{worker: $worker} + (if $pool == "" then {} else {pool: $pool} end)' | wizard_spool_publish "$1" rig-defaults.json cat
}

# Consume one rig-role submission: shape-check the pool address, dial it BEFORE anything
# irreversible — the same validate-before-erase discipline the coordinator flow gets — and
# land the accepted answers as $PWD/rig.json, host-side and outside the spool (the same trust
# move firstboot_consume_spool makes: what got validated is what gets used, whatever the
# container writes afterwards). rc: 0 accepted, 1 rejected, 2 none.
firstboot_consume_rig() ( # <spool-dir>
    local spool="$1" req="$1/rig-request.json" pool worker host port
    local snap rc=0
    wizard_submission_ready "$spool" || return 2
    snap=$(wizard_spool_request "$spool" rig-request.json) || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    trap 'rm -f "${snap%/*}/rig.json"; wizard_spool_clean "${snap%/*}"' EXIT
    req="$snap"
    pool=$(jq -r '.pool // ""' "$req" 2>/dev/null | tr -d '[:cntrl:]')
    worker=$(jq -r '.worker // ""' "$req" 2>/dev/null | tr -d '[:cntrl:]')
    host="${pool%:*}"
    port="${pool##*:}"
    host="${host#\[}"
    host="${host%\]}"
    if [ "$host" = "$pool" ] || ! is_valid_host "$host" || ! is_valid_port "$port"; then
        printf 'the pool address must look like host:port — a Pithead answers on port 3333' | wizard_spool_publish "$spool" error.txt cat
        rm -f "$spool/rig-request.json"
        wizard_clear_submission_transaction "$spool" || return 1
        return 1
    fi
    if ! timeout 5 bash -c '</dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null; then
        printf 'cannot reach a pool at %s:%s — check the address, and that the Pithead is up' "$host" "$port" | wizard_spool_publish "$spool" error.txt cat
        rm -f "$spool/rig-request.json"
        wizard_clear_submission_transaction "$spool" || return 1
        return 1
    fi
    # The control token (#1836) survives a "Set up again" that keeps the role AND the worker name
    # (#1318): the coordinator adopted THIS worker with THIS token. Any other change mints a new one.
    local keep_tok=""
    [ "$(jq -r '.worker // ""' "$PWD/rig.json" 2>/dev/null)" = "${worker:-$(hostname)}" ] &&
        keep_tok=$(jq -r '.access_token // ""' "$PWD/rig.json" 2>/dev/null)
    if ! (
        umask 077
        jq --arg w "${worker:-$(hostname)}" --arg t "$keep_tok" '{pool: .pool, worker: $w}
        + (if (.stratum_password // "") == "" then {} else {stratum_password: .stratum_password} end)
        + (if $t == "" then {} else {access_token: $t} end)' \
            "$req" >"${snap%/*}/rig.json" 2>/dev/null && mv -fT "${snap%/*}/rig.json" "$PWD/rig.json"
    ); then
        rm -f "$spool/rig-request.json" "$PWD/rig.json"
        printf 'could not record the rig settings — submit again' | wizard_spool_publish "$spool" error.txt cat
        wizard_clear_submission_transaction "$spool" || return 1
        return 1
    fi
    chmod 600 "$PWD/rig.json" 2>/dev/null || true
    rm -f "$spool/rig-request.json"
    return 0
)
