# shellcheck shell=bash
#
# Judges monerod's height across one M10 power cut (#2557). bench-ci job 840 failed M10.1 with
# "before: 56540, after: 56040": a readable node exactly 500 blocks lower. The pre-cut height was
# read from RPC with nothing flushed, and monerod's default db-sync-mode (fast:async, LMDB
# MDB_NOSYNC) commits blocks it never fsyncs, so a cut legitimately discards whatever the guest
# had not written back yet. The leg now flushes the guest right after the pre-cut read, which
# makes that height persisted; this verdict then fails any readable height below it as a real
# chain loss, and keeps an unreadable post-cut RPC (the #2452/#2471 class) apart from it.

# $1 = monerod height read, then flushed to disk, before the cut; $2 = height read after it
# Prints the verdict on stdout; exit 0 = at or above the persisted height, 1 = otherwise.
m10_height_verdict() {
    local before="$1" after="$2"
    if ! [[ "$before" =~ ^[0-9]+$ ]]; then
        printf 'could not read a persisted monerod height before the cut (read: %s)' "${before:-unreadable}"
        return 1
    fi
    if ! [[ "$after" =~ ^[0-9]+$ ]]; then
        printf 'monerod RPC unreadable after the cut (persisted before: %s, after: %s)' "$before" "${after:-unreadable}"
        return 1
    fi
    if [ "$after" -lt "$before" ]; then
        printf 'monerod LOST %s persisted blocks across the cut (persisted before: %s, after: %s)' \
            "$((before - after))" "$before" "$after"
        return 1
    fi
    printf 'monerod reports height %s, at or past the persisted pre-cut height %s' "$after" "$before"
}
