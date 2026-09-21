# --- disk installer (appliance only) -------------------------------------------------------
# The appliance can boot from the installation medium itself. When it does, the wizard leads with
# a disk picker instead of the setup form: the operator installs first, reboots, and configures
# the installed machine. Config is never transplanted between machines.
# Overridable so the shell suite can point it at a fake — the real one partitions disks.
install_bin() { printf '%s' "${PITHEAD_INSTALL_BIN:-/usr/local/sbin/pithead-install}"; }
# --- pre-seeding from the installation medium ----------------------------------------------
# The ESP is FAT, so an operator can drop files on the stick from any laptop right after
# flashing — before the machine has ever booted. Two are honoured:
#
#   pithead-config.json   a complete configuration: first boot provisions with no browser
#   pithead-token.txt     a chosen one-time token, so a box with no display can be reached
#
# This is what makes a headless or fleet install possible at all: without it the token exists
# only on the console, so every machine needs a monitor walked to it once.
PRESEED_DIR="${PITHEAD_PRESEED_DIR:-/boot/efi}"
# A pre-seeded token, sanitised. Anything outside the token alphabet is dropped rather than
# interpreted — this string is operator input arriving from a filesystem anyone can write.
preseed_token() {
    local f="$PRESEED_DIR/pithead-token.txt" t
    [ -f "$f" ] || return 1
    t=$(tr -dc 'A-Za-z0-9-' <"$f" 2>/dev/null | head -c 32)
    [ "${#t}" -ge 4 ] || return 1
    printf '%s' "$t"
}
# The note pithead-data-reset leaves on the ESP when it reinitializes /data (#1062, #1121): an
# append-only log, one "<UTC timestamp> <reason>" line per wipe. Reads only the LAST line — the
# most recent event is the one an operator needs — and prints one JSON object on success:
# {when, reason, recovery}. "recovery" is false for a deliberate factory-reset (nothing to warn
# about, the operator asked for it) and true for the wedged-/data case, where the next move is
# restoring a backup rather than walking through setup as if this were a fresh machine.
#
# One-shot (#1208): the log is never cleared, so gate on a SEPARATE ".pending" marker
# record_wipe() drops beside it and consume that marker (never the log) on a successful read — the
# first caller to surface the note, doctor's check_data_wipe_note or the wizard's
# publish_data_wipe_note, is the only one that ever sees it. A later record_wipe() re-arms the
# marker, so a genuinely new wipe still gets reported.
#
# Cached in a tmpfs file for the rest of THIS BOOT after the first read (#1208): every caller
# reads through `note=$(data_wipe_note)`, and command substitution always forks a subshell — a
# shell variable set inside one is invisible to the next `$(...)` call, so a plain in-memory cache
# is a no-op here (a real bug this fix went through once: #1208 job 557/560). stage_wizard_spool
# re-stages the whole spool on every wizard loop iteration — including the very first, before the
# container has even started once — so without a cache that SURVIVES across subshells, that second
# call finds the marker the first one already consumed and overwrites the still-unseen banner with
# "{}". /run is tmpfs: gone on reboot, so a later boot reads the marker file fresh with no cache.
DATA_WIPE_NOTE_CACHE="${PITHEAD_DATA_WIPE_NOTE_CACHE:-/run/pithead-data-wipe-note.json}"
#
# rc 1: no wipe pending (never happened, or already surfaced), unreadable, or a line with no
# "<when> <reason>" shape to parse.
data_wipe_note() {
    local f="$PRESEED_DIR/pithead-data-wiped" line when reason note
    if [ ! -f "$f.pending" ]; then
        [ -s "$DATA_WIPE_NOTE_CACHE" ] || return 1
        cat "$DATA_WIPE_NOTE_CACHE"
        return 0
    fi
    [ -f "$f" ] || return 1
    line=$(tail -n 1 "$f" 2>/dev/null) || return 1
    case "$line" in *' '*) ;; *) return 1 ;; esac
    when="${line%% *}"
    reason="${line#* }"
    [ -n "$when" ] && [ -n "$reason" ] || return 1
    note=$(jq -cn --arg when "$when" --arg reason "$reason" \
        '{when: $when, reason: $reason, recovery: ($reason != "factory-reset requested")}') || return 1
    rm -f "$f.pending" 2>/dev/null || true
    (umask 077 && printf '%s' "$note" >"$DATA_WIPE_NOTE_CACHE") 2>/dev/null || true
    printf '%s' "$note"
}
# Carries the wipe note to the wizard's spool (#1121): the wizard runs in a container whose only
# mount is the spool (`-v "$spool":/wizard-spool`), so it cannot reach $PRESEED_DIR itself —
# unlike doctor, which runs on the host. Same shape as publish_rig_defaults: derive fresh, write
# atomically, always write SOMETHING (an empty object when there is no note) so a fleet stick's
# spool never hands machine 2 machine 1's note. Skipped on removable boot media, where
# PRESEED_DIR is the STICK's own ESP and would describe the stick, not this machine.
publish_data_wipe_note() { # <spool-dir>
    local note
    if boot_is_removable; then
        note="{}"
    else
        note=$(data_wipe_note) || note="{}"
    fi
    wizard_spool_publish "$1" data-wiped.json printf '%s' "$note"
}
# Legacy restore pre-seed (#909): targets written by an older installer may still carry an
# encrypted archive beside its passphrase on the ESP. Consume and scrub that pair for upgrade
# compatibility; current installers apply from volatile memory before the target's first boot.
# rc: 0 restored, 1 present but rejected, 2 none, 3 cleanup unsafe.
consume_preseed_restore() {
    local a="$PRESEED_DIR/pithead-restore.enc" pf="$PRESEED_DIR/pithead-restore-pass" pass errf rc=0
    if [ ! -f "$a" ] || [ ! -f "$pf" ]; then
        [ -e "$a" ] || [ -L "$a" ] || [ -e "$pf" ] || [ -L "$pf" ] || return 2
        mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
        if rm -f "$a" "$pf" 2>/dev/null; then
            warn "An incomplete legacy restore handoff was cleared — submit the backup again."
            return 1
        fi
        warn "Could not clear an incomplete legacy restore handoff — reboot before continuing."
        return 3
    fi
    { set +x; } 2>/dev/null # xtrace would print the passphrase below
    pass=$(cat "$pf" 2>/dev/null || true)
    errf=$(mktemp)
    restore_apply "$a" "$pass" "$errf" || rc=$?
    if [ "$rc" = 0 ]; then
        pass=""
        log "Restored this machine from the carried backup archive."
        mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
        rm -f "$a" "$pf" 2>/dev/null || rc=3
        [ "$rc" = 0 ] || warn "Could not remove every consumed restore carry file — reboot before continuing."
        rm -f "$errf"
        return "$rc"
    fi
    pass=""
    if [ "$rc" = 3 ]; then
        warn "Could not clear temporary restore files safely — reboot before continuing."
        rm -f "$errf"
        mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
        rm -f "$a" "$pf" 2>/dev/null || warn "Could not remove every consumed restore carry file — remove both before leaving the machine unattended."
        return 3
    fi
    warn "The carried restore archive was rejected — falling back to the setup page."
    warn "  $(tail -c 200 "$errf" 2>/dev/null | tr -d '[:cntrl:]')"
    rm -f "$errf"
    mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
    rm -f "$a" "$pf" 2>/dev/null || rc=3
    [ "$rc" = 1 ] || warn "Could not remove every rejected restore carry file — reboot before continuing."
    return "$rc"
}
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
# rc: 0 a valid pre-seeded config was installed, 1 one was present but rejected, 2 none.
# Validated through a COPY: parse_and_validate_config fills in generated fields as it goes, and
# writing those back would mutate the operator's stick — and on a fleet, every machine would
# inherit the first one's generated credentials.
consume_preseed_config() { # <dest-config-path>
    local f="$PRESEED_DIR/pithead-config.json" dest="$1" tmp err
    [ -f "$f" ] || return 2
    tmp=$(mktemp) || return 1
    cp "$f" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if err=$(PITHEAD_CONFIG_FILE="$tmp" PITHEAD_CONFIG_SET=1 bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        mv "$tmp" "$dest"
        rm -f "${tmp}.bak-1x"
        log "Using the pre-seeded configuration from $f."
        return 0
    fi
    rm -f "$tmp" "${tmp}.bak-1x"
    warn "The pre-seeded $f was rejected — falling back to the setup page."
    warn "  $(printf '%s' "$err" | tail -n 1 | tr -d '[:cntrl:]' | tail -c 200)"
    return 1
}

# Is this host a Pithead OS appliance? Decides which UPGRADE path is legal: the appliance's
# program tree is delivered by OS images and resynced from the system slot at every boot, so a
# DIY tarball upgrade would "succeed" and then silently revert at the next reboot. Probes two
# files only the appliance image bakes; PITHEAD_APPLIANCE=0/1 overrides for tests.
is_appliance() {
    case "${PITHEAD_APPLIANCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
    esac
    [ -f /etc/rauc/system.conf ] && [ -x /usr/local/sbin/pithead-install ]
}

# Did this system boot from removable media (a USB stick)?
boot_is_removable() {
    local root_src boot_dev
    root_src=$(findmnt -no SOURCE / 2>/dev/null) || return 1
    boot_dev=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
    [ -n "$boot_dev" ] || return 1
    [ "$(cat "/sys/block/$boot_dev/removable" 2>/dev/null)" = "1" ]
}

# Staged rig settings that are spent OR unusable must not sit on the ESP: they may carry a
# stratum password, and a VFAT ESP keeps no mode 600 to protect one. Never on removable media —
# that stick is the operator's own fleet tool, theirs to keep for the next machine. $1 names which.
scrub_staged_rig() { # <consumed|unusable>
    boot_is_removable && return 0
    mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
    rm -f "$PRESEED_DIR/pithead-rig.json" 2>/dev/null ||
        warn "Could not remove the $1 rig settings from $PRESEED_DIR — they may hold a password; delete the file."
}

# Booted from removable media AND some other disk is available to install onto. Both halves
# matter: a box running from its internal disk must never offer to reinstall itself, and an
# installer with nowhere to install is just a broken setup page.
installer_mode_available() {
    [ -x "$(install_bin)" ] || return 1
    boot_is_removable || return 1
    # The gate runs ~18s into boot and RACES udev's settling of a multi-partition internal
    # disk: an empty first probe put a reinstall boot into SETUP mode while the same --list
    # answered fine seconds later over SSH (KVM keep leg, deterministic after an unrelated
    # boot-timing shift). Settle, then give the inventory a few honest tries — a stick with
    # genuinely no target pays ~10 extra seconds once, against a wizard that otherwise opens
    # in the wrong mode with no way back short of a power cycle.
    udevadm settle --timeout=10 2>/dev/null || true
    local tries=0
    while [ "$tries" -lt 5 ]; do
        [ -n "$("$(install_bin)" --list 2>/dev/null)" ] && return 0
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

# The HOST enumerates disks; the container only renders what it is given. A browser must never be
# able to name a target the host did not offer — that is the same boundary the #33 control
# channel draws, and here the action erases a disk.
publish_disk_inventory() { # <spool-dir>
    wizard_spool_publish "$1" disks.tsv "$(install_bin)" --list
}

# The strip a previous install's config passes through before any of it may be SHOWN (#794):
# every leaf CONTROL_SECRET_PATHS names, plus the whole objects whose value IS access — the
# dashboard login, the worker inventory (its per-entry tokens live in a variable-length array
# the fixed paths cannot reach), alert credentials, the ssh key. Wallet addresses, node modes
# and hosts, the pool tier stay: those are the answers the operator came back for, and none of
# them is a secret. Errs toward stripping more — a lost convenience beats a leaked credential.
#
# The two ENABLEMENTS go with the login, and that is the half this was missing (#1846). The
# validator fails closed on dashboard.control.enabled and on dashboard.onion.enabled whenever
# the password is empty — deliberately, since both are reachable control surfaces. Deleting the
# login while leaving either switch on therefore publishes a pre-fill that CANNOT be submitted:
# the page offers it back, "Generate a strong password for me" leaves the password empty because
# the HOST generates one only AFTER the candidate has validated, and the first validation refuses
# the operator's own answers. Dropping control.enabled costs nothing — apply_appliance_defaults
# puts it back on any appliance whose password is non-empty. onion.enabled the operator re-ticks,
# which is the same trade the paragraph above already makes.
# rc non-zero when the file is not a usable config object; callers treat that as "no pre-fill".
#
# .dashboard.workers STAYS in the del list although 2.0.0 removed that alias (#1832), and this is
# the one site where that distinction is load-bearing: prefill_from_previous_install reads a
# FOREIGN disk's config.json directly, so it never passes through parse_and_validate_config and
# the 1.x migration NEVER runs on it. A machine reinstalled from a pre-2.0 disk would otherwise
# publish its per-rig API tokens onto the setup page. A redaction predicate is not alias
# acceptance — the same ruling os/overlay/pithead-media-config:163 already carries.
strip_config_secrets() { # <config-file> -> stripped JSON on stdout
    jq -e --argjson paths "$CONTROL_SECRET_PATHS" '
        delpaths($paths)
        | del(.dashboard.auth, .dashboard.workers, .workers, .telegram,
              .healthchecks, .notifications, .ssh, .tari.spend_public_key,
              .dashboard.control.enabled, .dashboard.onion.enabled)' "$1" 2>/dev/null
}

# Reinstall pre-fill (#794). When the offered targets include exactly one disk that already
# carries an install, mount its data partition READ-ONLY, read the previous config, strip the
# secrets and publish the remainder as the page's starting point — the same last-attempt.json
# channel the pre-seed path fills. The operator sees the answers the machine already knew and
# changes what they came to change; a bench box once had its remote-Tari setting silently
# defaulted back to a local chain by this gap. Host-side only (the container never mounts
# anything) and pure convenience: every failure path returns 1 and the page simply opens
# blank — nothing here may block an install. rc 0 = a pre-fill was published.
prefill_from_previous_install() { # <spool-dir>
    local spool="$1" disk part mnt cfg rc=1
    disk=$(wizard_spool_read "$spool" disks.tsv | awk -F'\t' '$5 == "pithead-with-data" {print $1}')
    # Two candidates would make the pre-fill a guess about WHICH machine's answers; offer none.
    [ -n "$disk" ] && [ "$(printf '%s\n' "$disk" | wc -l)" -eq 1 ] || return 1
    part=$(lsblk -lnpo NAME,PARTLABEL "/dev/$disk" 2>/dev/null | awk '$2 == "data" {print $1; exit}')
    [ -n "$part" ] || return 1
    mnt=$(mktemp -d) || return 1
    # -t ext4 pinned: the appliance only ever formats data partitions as ext4, and an
    # auto-probed type would let an arbitrary disk pick which filesystem parser the kernel
    # runs against its content.
    if mount -t ext4 -o ro,nosuid,nodev,noexec "$part" "$mnt" 2>/dev/null; then
        cfg="$mnt/pithead/config.json"
        # The -L guards close a symlink escape: a crafted disk could point pithead/ or
        # config.json at a file on the RUNNING host, and jq follows symlinks — the read-only
        # mount keeps both components stable under the checks. The size cap bounds what an
        # arbitrary disk can make this boot path chew on; jq's parse (and the object shape
        # it needs) rejects everything else.
        if [ ! -L "$mnt/pithead" ] && [ ! -L "$cfg" ] &&
            [ -f "$cfg" ] && [ "$(wc -c <"$cfg" 2>/dev/null || echo 0)" -le 1048576 ] &&
            [ -s "$cfg" ] && wizard_spool_publish "$spool" last-attempt.json strip_config_secrets "$cfg"; then
            rc=0
        fi
        umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
    return "$rc"
}

# rc: 0 installed, 1 failed, 2 nothing requested. The request is "disk<TAB>wipe" written by
# the wizard's combined submit; both fields are re-validated HERE because they arrive through
# a web form — the disk against the inventory this host published, the wipe mode against the
# fixed set. The container asks, the host decides.
consume_install_request() ( # <spool-dir> [required-wipe] [volatile-restore-carry] [resolved-config]
    local spool="$1" req="$1/install-request" target wipe err carry="${3:-}" resolved="${4:-$PWD/config.json}"
    local snap rc=0 install_args
    snap=$(wizard_spool_request "$spool" install-request) || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    trap 'wizard_spool_clean "${snap%/*}"' EXIT
    req="$snap"
    target=$(cut -f1 <"$req" | tr -dc 'a-zA-Z0-9_-')
    wipe=$(cut -f2 <"$req" | tr -dc 'a-z')
    rm -f "$spool/install-request"
    case "$wipe" in keep | data | all) ;; *) wipe="keep" ;; esac
    # The bare-reinstall door may only preserve data, even if the page replaces its request
    # after that door's readiness check. Enforce the policy on THIS consumed snapshot.
    if [ -n "${2:-}" ] && [ "$wipe" != "$2" ]; then
        wizard_spool_publish "$spool" error.txt printf '%s' 'The install request changed — submit the settings again.'
        return 1
    fi
    if ! "$(install_bin)" --list 2>/dev/null | cut -f1 | grep -qx "$target"; then
        printf 'not an offered target: %s' "$target" | wizard_spool_publish "$spool" error.txt cat
        return 1
    fi
    log "Installing to /dev/$target (data: $wipe) ..."
    install_args=(--target "/dev/$target" --wipe "$wipe" --yes)
    [ -z "$carry" ] || [ ! -f "$carry/archive" ] || install_args+=(--no-preseeds)
    if err=$("$(install_bin)" "${install_args[@]}" 2>&1); then
        if [ -n "$carry" ] && [ -f "$carry/archive" ] &&
            ! err=$(install_restore_to_target "/dev/$target" "$carry" "$resolved" 2>&1); then
            printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 | wizard_spool_publish "$spool" error.txt cat
            warn "Install to /dev/$target completed, but its restore failed."
            return 1
        fi
        wizard_spool_publish "$spool" installed true
        log "Installed to /dev/$target."
        return 0
    fi
    printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 | wizard_spool_publish "$spool" error.txt cat
    warn "Install to /dev/$target failed."
    return 1
)
