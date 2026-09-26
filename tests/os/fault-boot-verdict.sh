# shellcheck shell=bash
#
# Distinguishes "the guest never booted" from "the guest booted but the probe could not reach it"
# in the fault-injection phase's power-cut legs (#2381). bench-ci job 101 saw phase_fault's A1 leg
# report BRICKED — the one disqualifying verdict — after a `phases: [all]` run, while the job's own
# pithead-os-serial.log.failed showed GRUB naming the current slot, the kernel booting, and
# "pithead login:" ten seconds later: the guest was up, and it was the SSH probe (not the boot)
# that failed to reach it late in a long run. Only a serial log showing none of GRUB, kernel or
# login evidence is a real brick; anything else is a probe failure and never disqualifying.

# $1 = path to the captured serial console log ($SERIAL)
# $2 = byte offset the boot under test started at, so an earlier boot's console appended to the
#      same file does not count as this boot's evidence. `virsh start` may instead TRUNCATE
#      $SERIAL (a file chardev without append=on restarts at byte 0): a log now shorter than the
#      offset holds only the new boot, so it is read from byte 0 (#2746: job 1262 read past EOF
#      and called a booted guest BRICKED with empty "last lines").
# Prints the verdict on stdout; exit 0 = booted (a probe failure, not a brick), 1 = no boot
# evidence at all (BRICKED). Either way the console is copied to $1.failed first: a failed leg
# returns, and the next phase's boot would otherwise overwrite this boot's console (#2746).
fault_boot_verdict() {
    local log="$1" offset="$2" serial hit
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    [ "$(wc -c <"$log" 2>/dev/null | tr -d ' ')" -ge "$offset" ] 2>/dev/null || offset=0
    cp -f "$log" "$log.failed" 2>/dev/null || true
    serial=$(tail -c "+$((offset + 1))" "$log" 2>/dev/null)
    hit=$(grep -oE 'GNU GRUB|Loading Linux|Linux version [0-9][^[:space:]]*|Debian GNU/Linux|[Ll]ogin:|Pithead setup wizard|Setup wizard is up' <<<"$serial" | tail -1)
    if [ -n "$hit" ]; then
        printf 'guest booted (serial shows "%s") — the PROBE failed to reach it, not the boot' "$hit"
        return 0
    fi
    printf 'no GRUB, kernel or login on the serial console — last lines: %s' \
        "$(tail -3 <<<"$serial" | tr -s ' \t\r\n' ' ' | cut -c1-200)"
    return 1
}
