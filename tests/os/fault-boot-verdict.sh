# shellcheck shell=bash
#
# Distinguishes "the guest never booted" from "the guest booted but the probe could not reach it"
# in the fault-injection phase's power-cut legs (#2381). bench-ci job 101 saw phase_fault's A1 leg
# report BRICKED — the one disqualifying verdict — after a `phases: [all]` run, while the job's own
# pithead-os-serial.log.failed showed GRUB naming the current slot, the kernel booting, and
# "pithead login:" ten seconds later: the guest was up, and it was the SSH probe (not the boot)
# that failed to reach it late in a long run. Only a serial log showing none of GRUB, kernel or
# login evidence is a real brick; anything else is a probe failure and never disqualifying.

# The boot under test must be judged by its own console alone (#2746). Two ways to draw that line:
#
# fault_serial_cut <log> — for a power cut. Call after `virsh destroy` and before `virsh start`,
# while no QEMU holds the file. Moves the old console to <log>.pre-cut and empties <log>, so the
# next boot writes from byte 0 whether its file chardev appends or truncates. A file-position
# mark cannot do this: a restarted log re-grows, and the same disk prints the same banner
# byte for byte, so neither its size nor its prefix proves where the new boot began (job 220).
# Prints 0, the offset to judge from. A log that does not exist yet needs no move. A log that
# exists but cannot be moved aside and emptied prints nothing and returns 1: the leg must stop.
fault_serial_cut() {
    rm -f "$1.pre-cut" 2>/dev/null
    if [ -e "$1" ]; then
        cp "$1" "$1.pre-cut" 2>/dev/null && : 2>/dev/null >"$1" || return 1
    fi
    echo 0
}

# fault_serial_mark <log> — for a leg with no power cut (C), where the same QEMU keeps appending.
# Prints the log's size, the offset this leg's output starts at; 0 for a log not created yet.
# Prints nothing and returns 1 when an existing log's size cannot be read.
fault_serial_mark() {
    [ -e "$1" ] || {
        echo 0
        return 0
    }
    local size
    size=$(wc -c <"$1" 2>/dev/null | tr -d ' ')
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    echo "$size"
}

# fault_serial_since <log> <offset> — prints what was written after <offset>. Returns 1, printing
# nothing, when the boundary is not proven: an offset that is not a number, or one past the end
# of a log that has shrunk since it was taken.
fault_serial_since() {
    local log="$1" offset="$2" size
    [[ "$offset" =~ ^[0-9]+$ ]] || return 1
    size=$(wc -c <"$log" 2>/dev/null | tr -d ' ')
    [ "${size:-0}" -ge "$offset" ] || return 1
    tail -c "+$((offset + 1))" "$log" 2>/dev/null
}

# fault_boot_verdict <log> <offset from fault_serial_cut or fault_serial_mark>
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
