# Hand the operator-facing stack files that the ROOT control-runner just wrote back to the stack
# owner (#33 v1.4). control_run_pending is root (User=root in pithead-control.service), so its
# `apply` renders `.env` under `umask 077` as root:root 0600 and rewrites the Caddyfile as root —
# but pithead runs a NON-ROOT operator model ($REAL_USER), and a normal operator-run apply leaves
# these files owned by the operator. Without this, the operator's next `status`/`apply` can't even
# read .env (Permission denied), which is what the tier-4 gate caught. The target owner is DERIVED
# from config.json's on-disk owner — an operator-owned file the dashboard container CANNOT write
# (its raw config.json mount was dropped in #440; control_commit's `cp` also preserves its inode/
# owner), so nothing from the request or spool can steer the chown. $USER/$SUDO_USER are NOT usable
# here — the runner is root, so they read as root. The control-dir (staged/results/audit) is
# deliberately host-owned and is NOT touched: that rw/ro split is the #33 trust boundary.
control_reown_operator_files() {
    local owner f
    # GNU stat first, BSD fallback (see the provision_onion_client_auth note). No owner → skip.
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    [ -n "$owner" ] || return 0
    # .bak-workers is the pre-2.0 name of the migration backup .bak-1x now writes (#1832) — both are
    # listed so a machine that migrated under 1.x still has its old copy reowned rather than stranded.
    for f in "$ENV_FILE" "Caddyfile" "${CONFIG_FILE}.bak-control" "${CONFIG_FILE}.bak-1x" "${CONFIG_FILE}.bak-workers"; do
        [ -e "$f" ] || continue
        # Fail safe: a chown that can't complete leaves the pre-existing bug, never corrupts state.
        chown "$owner" "$f" 2>/dev/null ||
            warn "Could not re-own $f to $owner after the control apply — the operator may need to chown it by hand."
    done
}
