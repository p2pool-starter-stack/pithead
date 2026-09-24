# The installer's restore door (#909, #1854): an accepted restore never crosses the target's ESP.
# consume_install_request calls this once pithead-install has written the target.
#
# Apply an installer restore straight onto the target's protected data filesystem while the
# passphrase still lives only in tmpfs. systemd-repart is the target's normal first-boot layout
# mechanism; running it now makes /data available without inventing a second partitioner.
install_restore_to_target() ( # <target-disk> <volatile-carry-dir> [<resolved-config>]
    local disk="$1" carry="$2" resolved="${3:-$PWD/config.json}" part mnt errf pass="" mounted=0 rc=1 rel reason="" trap_rc=0 cleanup_rc=0
    [ -f "$carry/archive" ] && [ -f "$carry/pass" ] || return 2
    [ -f "$resolved" ] || return 1
    { set +x; } 2>/dev/null
    if ! systemd-repart --dry-run=no "$disk" >/dev/null 2>&1; then
        printf '%s\n' 'Could not prepare the installed system for the restore.' >&2
        return 1
    fi
    udevadm settle --timeout=10 2>/dev/null || true
    part=$(lsblk -lnpo NAME,PARTLABEL "$disk" 2>/dev/null | awk '$2 == "data" {print $1; exit}')
    if [ -z "$part" ]; then
        printf '%s\n' 'Could not find the installed system data partition for the restore.' >&2
        return 1
    fi
    mnt=$(mktemp -d) || return 1
    errf=$(mktemp) || {
        rmdir "$mnt"
        return 1
    }
    trap 'trap_rc=$?; pass=""; cleanup_rc=0; rm -f "$errf" || cleanup_rc=1; if [ "$mounted" = 1 ] && ! umount "$mnt" 2>/dev/null; then cleanup_rc=1; fi; rmdir "$mnt" 2>/dev/null || cleanup_rc=1; if [ "$cleanup_rc" != 0 ]; then warn "Could not clear temporary target restore files safely — do not remove the disk yet."; trap_rc=1; fi; exit "$trap_rc"' EXIT
    if ! mount -t ext4 -o rw,nosuid,nodev,noexec "$part" "$mnt"; then
        printf '%s\n' 'Could not mount the installed system data partition for the restore.' >&2
        return 1
    fi
    mounted=1
    # An offered reinstall target is still untrusted input. Refuse existing symlinks in every
    # parent the restore traverses; otherwise a crafted data partition could redirect writes onto
    # the running installer or outside the established collision-rule directories.
    for rel in pithead pithead/data pithead/data/monero pithead/data/tari pithead/data/p2pool; do
        if [ -L "$mnt/$rel" ]; then
            printf '%s\n' 'Could not safely apply the restore to the installed system.' >&2
            return 1
        fi
    done
    mkdir -p "$mnt/pithead" || return 1
    # Durable before the first restored byte: any crash or finalization failure leaves first boot
    # fail-closed. A successful restore publishes ready, syncs it with the data, then disarms this.
    printf incomplete >"$errf"
    if ! restore_setup_publish_file "$errf" "$mnt/pithead/.restore-incomplete" ||
        ! rm -f -- "$mnt/pithead/.restore-pending" || ! sync; then
        reason='could not arm the installed system restore safely'
    else
        : >"$errf"
        pass=$(cat "$carry/pass")
        if ! restore_apply "$carry/archive" "$pass" "$errf" "" "$mnt/pithead" "$(restore_stage_root)"; then
            reason=$(tail -c 200 "$errf" 2>/dev/null | tr -d '[:cntrl:]')
        elif ! restore_setup_publish_file "$resolved" "$mnt/pithead/config.json"; then
            reason='could not publish the resolved configuration'
        else
            printf '%s\n' "$(machine_role_from_config "$resolved")" >"$errf"
            if ! restore_setup_publish_file "$errf" "$mnt/pithead/machine-role"; then
                reason='could not publish the installed machine role'
            else
                printf ready >"$errf"
                if restore_setup_publish_file "$errf" "$mnt/pithead/.restore-pending" && sync &&
                    rm -f -- "$mnt/pithead/.restore-incomplete"; then
                    rc=0
                else
                    reason='could not finalize the installed system restore'
                fi
            fi
        fi
    fi
    pass=""
    if [ "$rc" != 0 ]; then
        [ -n "$reason" ] || reason='could not apply the backup files'
        printf 'The installed system rejected the restore: %s\n' "$reason" >&2
    fi
    return "$rc"
)
