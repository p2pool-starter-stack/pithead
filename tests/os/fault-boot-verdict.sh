# shellcheck shell=bash
#
# Distinguishes "the guest never booted" from "the guest booted but the probe could not reach it"
# in the fault-injection phase's power-cut legs (#2381). bench-ci job 101 saw phase_fault's A1 leg
# report BRICKED — the one disqualifying verdict — after a `phases: [all]` run, while the job's own
# pithead-os-serial.log.failed showed GRUB naming the current slot, the kernel booting, and
# "pithead login:" ten seconds later: the guest was up, and it was the SSH probe (not the boot)
# that failed to reach it late in a long run. Only a serial log showing none of GRUB, kernel or
# login evidence is a real brick; anything else is a probe failure and never disqualifying.

# fault_serial_mark <log> — call just before the power cut. Prints the log's size, the byte offset
# the next boot starts at, and keeps a copy of what the log held at that moment in <log>.mark.
# A log that does not exist yet prints 0: everything the next boot writes is its own. A log that
# exists but cannot be copied prints nothing and returns 1: without the copy there is no proven
# boundary between the old boot and the next, so the caller must not cut power (#2746).
fault_serial_mark() {
    rm -rf "$1.mark" 2>/dev/null
    if [ ! -e "$1" ]; then
        echo 0
        return 0
    fi
    cp "$1" "$1.mark" 2>/dev/null || return 1
    wc -c <"$1.mark" | tr -d ' '
}

# fault_serial_since <log> <offset> — prints only what the boot after the cut wrote. A power cycle
# may append to <log> or, with a file chardev lacking append=on, restart it at byte 0 (#2746).
# Size alone cannot tell them apart: a restarted log soon grows past the old offset, and reading
# from there skips the new boot's GRUB and kernel lines. So the offset holds only while the log
# still begins with the bytes fault_serial_mark saw; a log that no longer does was restarted and
# is read whole. Returns 1, printing nothing, when there is no proven boundary: an offset that is
# not a number, or a non-zero one whose <log>.mark copy is gone.
fault_serial_since() {
    local log="$1" offset="$2"
    [[ "$offset" =~ ^[0-9]+$ ]] || return 1
    if [ "$offset" -gt 0 ]; then
        [ -f "$log.mark" ] || return 1
        cmp -s <(head -c "$offset" "$log" 2>/dev/null) "$log.mark" || offset=0
    fi
    tail -c "+$((offset + 1))" "$log" 2>/dev/null
}

# fault_boot_verdict <log> <offset from fault_serial_mark>
# Prints the verdict on stdout; exit 0 = booted (a probe failure, not a brick), 1 = no boot
# evidence at all (BRICKED), 2 = no proven boundary, so this boot cannot be judged either way.
# Whatever the verdict, the console is first kept at <log>.failed: a failed leg returns, and the
# next phase's boot would otherwise overwrite this boot's console (#2746).
fault_boot_verdict() {
    local log="$1" offset="$2" serial hit
    cp -f "$log" "$log.failed" 2>/dev/null ||
        printf 'could not keep the console at %s.failed — ' "$log"
    serial=$(fault_serial_since "$log" "$offset") || {
        printf 'no console snapshot from before the cut (offset "%s") — this boot cannot be judged' "$offset"
        return 2
    }
    hit=$(grep -oE 'GNU GRUB|Loading Linux|Linux version [0-9][^[:space:]]*|Debian GNU/Linux|[Ll]ogin:|Pithead setup wizard|Setup wizard is up' <<<"$serial" | tail -1)
    if [ -n "$hit" ]; then
        printf 'guest booted (serial shows "%s") — the PROBE failed to reach it, not the boot' "$hit"
        return 0
    fi
    printf 'no GRUB, kernel or login on the serial console — last lines: %s' \
        "$(tail -3 <<<"$serial" | tr -s ' \t\r\n' ' ' | cut -c1-200)"
    return 1
}
