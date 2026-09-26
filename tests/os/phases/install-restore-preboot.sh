# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# The restore leg's pre-first-boot verdicts (#1854): the installer applies an accepted restore to
# the target's data before the target ever boots, so both powered-off disks are inspected from the
# host — no restore secret on the target ESP or data, none left on the installer medium.
_restore_target_preboot_verdict() { # <powered-off target image>
    local disk="$1" loop esp="" data="" mnt tries=0 rc=0
    loop=$(losetup -Pf --show "$disk") || {
        bad "restore leg: could not inspect the installed disk before its first boot"
        return 1
    }
    udevadm settle 2>/dev/null || true
    while [ "$tries" -lt 50 ]; do
        esp=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "esp" {print $1; exit}')
        data=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "data" {print $1; exit}')
        [ -b "$esp" ] && [ -b "$data" ] && break
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    if [ -b "$esp" ] && mount -o ro "$esp" "$mnt"; then
        if [ ! -e "$mnt/pithead-restore.enc" ] && [ ! -e "$mnt/pithead-restore-pass" ] &&
            [ ! -e "$mnt/pithead-config.json" ] && [ ! -e "$mnt/pithead-token.txt" ] && [ ! -e "$mnt/pithead-rig.json" ]; then
            ok "restore leg: no restore or unrelated pre-seed credential persisted on the target ESP before first boot"
        else
            bad "restore leg: restore carry persisted on the target ESP before first boot"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect the target ESP before first boot"
        rc=1
    fi
    if [ -b "$data" ] && mount -o ro "$data" "$mnt"; then
        if [ -f "$mnt/pithead/config.json" ] && [ -f "$mnt/pithead/.restore-pending" ] &&
            [ ! -e "$mnt/pithead/.restore-incomplete" ] &&
            [ -z "$(find "$mnt" \( -name pithead-restore-pass -o -name pithead-restore.enc \) -print -quit)" ]; then
            ok "restore leg: validated state and only a non-secret handoff marker reached target data"
        else
            bad "restore leg: validated state did not reach target data before first boot"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect target data before first boot"
        rc=1
    fi
    rmdir "$mnt"
    losetup -d "$loop"
    return "$rc"
}

_restore_installer_preboot_verdict() { # <powered-off installer image>
    local disk="$1" loop esp="" data="" mnt tries=0 rc=0
    loop=$(losetup -Pf --show "$disk") || return 1
    udevadm settle 2>/dev/null || true
    while [ "$tries" -lt 50 ]; do
        esp=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "esp" {print $1; exit}')
        data=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "data" {print $1; exit}')
        [ -b "$esp" ] && [ -b "$data" ] && break
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    if [ -b "$data" ] && mount -o ro "$data" "$mnt"; then
        if [ -z "$(find "$mnt/pithead" \( -name config.json -o -name handoff.json -o -name '*restore*pass*' -o -name '*restore*archive*' -o -name pithead-restore.enc -o -name restore-inflight \) -print -quit 2>/dev/null)" ]; then
            ok "restore leg: the powered-off installer medium retained no restore credentials"
        else
            bad "restore leg: the powered-off installer medium retained restore credentials"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect installer data after shutdown"
        rc=1
    fi
    if [ -b "$esp" ] && mount "$esp" "$mnt"; then
        # The pre-seeds are this leg's fixture: cleared once seen, or they outrank the next leg's reinstall pre-fill.
        if [ -f "$mnt/pithead-config.json" ] && [ -f "$mnt/pithead-token.txt" ] && [ -f "$mnt/pithead-rig.json" ] &&
            rm -f "$mnt/pithead-config.json" "$mnt/pithead-token.txt" "$mnt/pithead-rig.json"; then
            ok "restore leg: unrelated fleet pre-seeds returned only to the installer medium"
        else
            bad "restore leg: installer fleet pre-seeds were not restored after the install, or could not be cleared"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect installer pre-seeds after shutdown"
        rc=1
    fi
    rmdir "$mnt"
    losetup -d "$loop"
    return "$rc"
}
