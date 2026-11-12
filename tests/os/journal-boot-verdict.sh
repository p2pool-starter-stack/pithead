# shellcheck shell=bash
#
# Shared by tests/os/run.sh's phase_boot (across the real KVM guest's #895 reboot) and
# tests/stack's fixture test: the second-boot journal verdict, #1659. journald reads the
# machine-id once, at its own start — the transient one PID 1 binds on an empty-baked image — and
# before the fix kept writing under it all boot, so every boot after the first opened a new
# persistent journal directory and `journalctl -b`, which resolves the directory by the RESTORED
# id, read a stale one. The first boot cannot show this (the adopted id IS the transient one); the
# reboot the #895 check already makes is the first boot that can, which is why the verdict rides it.

# $1 = journal directories under /var/log/journal before the reboot
# $2 = the same count after it
# $3 = lines `journalctl -b -u pithead-machine-id` prints after it (0 = the unit's own record
#      landed under another id and a plain -b cannot see it)
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
journal_boot_verdict() {
    local before="$1" after="$2" lines="$3" v
    for v in "$before" "$after" "$lines"; do
        case "$v" in '' | *[!0-9]*)
            echo "journal state unreadable across the reboot (dirs before: ${before:-?}, after: ${after:-?}, -b lines: ${lines:-?})"
            return 1
            ;;
        esac
    done
    if [ "$after" -gt "$before" ]; then
        echo "journald opened a new journal directory on the second boot ($before -> $after): it kept the transient machine-id (#1659)"
        return 1
    fi
    if [ "$lines" -eq 0 ]; then
        echo "journalctl -b shows nothing from pithead-machine-id on the second boot — this boot's journal is under another id (#1659)"
        return 1
    fi
    echo "journald follows the restored machine-id across a reboot (journal directories: $after, -b sees this boot's unit record)"
    return 0
}

# #1791 rides the same reboot. Two persistent homes for the journal exist on /data: the #1030 bind's
# /data/pithead/journal and the /var overlay's upper dir /data/overlay/var/log/journal. Before the
# fix, var.mount and pithead-journal-persist were both After=data.mount and unordered against each
# other, so whichever finished LAST owned /var/log/journal: a boot's journal landed in one of the
# two, and `journalctl --list-boots` silently dropped every boot that went the other way. A single
# boot cannot show it (the bytes persist either way), and neither can `findmnt --target`, which
# names the bind by its mountpoint even while the overlay covers it. What tells the two apart is the
# directory the VFS actually resolves: `stat -c %m` walks up by device, so it answers /var (the
# overlay) or /var/log/journal (the bind), and the inode says whether that is the /data directory.
# Run on the guest as root. Prints five lines: "<mountpoint> <inode>" of /var/log/journal, the inode
# of /data/pithead/journal, the filesystem type seen through /var/log/journal, yes/no for this
# machine-id's journal directory under the bind, and the number of boots the persistent journal
# lists (0 when it finds none). Read by run.sh after it sources this file, which shellcheck cannot
# see from here (the same shape as the verdict functions, which it does not flag).
# shellcheck disable=SC2034
JOURNAL_HOME_PROBE='stat -c "%m %i" /var/log/journal 2>/dev/null || echo "missing ?"; stat -c %i /data/pithead/journal 2>/dev/null || echo missing; stat -f -c %T /var/log/journal 2>/dev/null || echo unknown; test -d "/data/pithead/journal/$(cat /etc/machine-id)" && echo yes || echo no; journalctl --list-boots --no-pager 2>/dev/null | grep -cE "^ *-?[0-9]+ [0-9a-f]{32} "'

# $1 = the probe's output. Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
journal_home_verdict() {
    local mnt tino hino fstype subdir boots v
    {
        read -r mnt tino
        read -r hino
        read -r fstype
        read -r subdir
        read -r boots
    } <<<"$1"
    for v in "$tino" "$hino" "$boots"; do
        case "$v" in '' | *[!0-9]*)
            echo "journal home unreadable after the reboot (mount: ${mnt:-?}, inodes: ${tino:-?}/${hino:-?}, boots: ${boots:-?})"
            return 1
            ;;
        esac
    done
    if [ "$mnt" != /var/log/journal ] || [ "$tino" != "$hino" ]; then
        echo "journald's directory is the $fstype mount at $mnt (inode $tino), not the /data/pithead/journal bind (inode $hino): the /var overlay covered it (#1791)"
        return 1
    fi
    if [ "$subdir" != yes ]; then
        echo "/var/log/journal is the /data/pithead/journal bind, but journald flushed nothing under it this boot (#1791)"
        return 1
    fi
    if [ "$boots" -lt 2 ]; then
        echo "the persistent journal lists $boots boot(s) after a reboot: the previous boot went to the other home (#1791)"
        return 1
    fi
    echo "journald writes the /data/pithead/journal bind (inode $tino, $fstype) and the persistent boot list holds $boots boots across the reboot"
    return 0
}

# shellcheck disable=SC2034
JOURNAL_STATE_PROBE='c=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)
printf "%s\n" "$c" | sed -n "s/^Storage=//p" | tail -n1 | { IFS= read -r x || x=; printf "%s\n" "${x:-missing}"; }
printf "%s\n" "$c" | sed -n "s/^SystemMaxUse=//p" | tail -n1 | { IFS= read -r x || x=; printf "%s\n" "${x:-missing}"; }
u=$(systemctl is-active pithead-journal-persist.service 2>/dev/null || true)
printf "%s\n" "${u:-unreadable}"
b=$(journalctl --no-pager -q 2>/dev/null | wc -c)
printf "%s\n" "${b:-missing}"
o=$(journalctl --no-pager -q -o short-unix 2>/dev/null | head -n1 | cut -d" " -f1 | cut -d. -f1)
case "$o" in "" | *[!0-9]*) o= ;; esac
if [ -n "$o" ]; then echo $(($(date +%s) - o)); else echo -1; fi'

journal_cap_kib() {
    local v="$1" n s
    case "$v" in
    '' | *[!0-9]*) : ;;
    *)
        echo $((v / 1024))
        return 0
        ;;
    esac
    n="${v%[KMGT]}"
    s="${v#"$n"}"
    case "$n" in '' | *[!0-9]*) return 1 ;; esac
    case "$s" in
    K) echo "$n" ;;
    M) echo $((n * 1024)) ;;
    G) echo $((n * 1048576)) ;;
    T) echo $((n * 1073741824)) ;;
    *) return 1 ;;
    esac
}

journal_config_verdict() {
    local storage="$1" maxuse="$2" unit="$3" cap
    if [ "$storage" = "persistent" ] && cap=$(journal_cap_kib "$maxuse") && [ "$cap" -gt 0 ] &&
        [ "$unit" = "active" ]; then
        echo "journald runs Storage=persistent with the $maxuse cap and the journal bind unit is active (evidence survives reboots; rigs stay volatile by design)"
        return 0
    fi
    echo "journald is not pinned to the persistent journal (Storage=${storage:-missing}, SystemMaxUse=${maxuse:-missing}, pithead-journal-persist ${unit:-unreadable})"
    return 1
}

journal_window_verdict() {
    local before="$1" after="$2" secs="$3" cap="$4" age="$5" load="${6:-boot load}" v grow rate horizon ages
    for v in "$before" "$after" "$secs" "$cap"; do
        case "$v" in '' | *[!0-9]*)
            echo "journal window unreadable (content ${before:-?} -> ${after:-?} bytes over ${secs:-?} s, cap ${cap:-?} KiB)"
            return 1
            ;;
        esac
    done
    grow=$((after - before))
    if [ "$secs" -le 0 ]; then
        echo "journal window sample had no elapsed time (${secs} s) — the measurement did not happen"
        return 1
    fi
    if [ "$cap" -le 0 ]; then
        echo "journal cap is not a finite size (${cap} KiB) — the window cannot be measured against the 72 h bundle default"
        return 1
    fi
    if [ "$grow" -le 0 ]; then
        echo "journal window measurement made no reading: the journal grew ${grow} bytes across the sample"
        return 1
    fi
    rate=$((grow * 3600 / 1024 / secs))
    horizon=$((cap * 1024 * secs / grow / 3600))
    case "$age" in '' | *[!0-9]*) ages="unreadable" ;; *) ages="${age} s" ;; esac
    echo "journal measurement (${load}): ${grow} bytes of content in ${secs} s — an upper bound of ${rate} KiB/h uncompressed, so the ${cap} KiB cap covers at least ${horizon} h at that load; oldest surviving entry ${ages}"
}
