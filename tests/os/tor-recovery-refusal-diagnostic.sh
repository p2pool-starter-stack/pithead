#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C head -c 8193 -- "${2:?}" 2>/dev/null | LC_ALL=C awk -v result="${1:?}" '
BEGIN { reason="diagnostic_unavailable"; command_exit="unavailable" }
{
    bytes += length($0) + 1
    if (bytes > 8192) { clipped=1; next }
    if ($0 == "FAIL: live Tor data mount could not be verified (#3262)") reason="mount_unverified"
    if ($0 == "FAIL: live Tor state is missing, linked or unreadable (#3262)") reason="state_unavailable"
    if ($0 == "FAIL: live Tor state could not be read (#3262)") reason="state_read_failed"
    if ($0 == "FAIL: Tor history is saturated; the healthy-refusal precondition is not established (#3262)") reason="saturated_precondition"
    if ($0 == "FAIL: Tor history classification failed (#3262)") reason="state_classification_failed"
    if ($0 == "FAIL: healthy Tor recovery check lacks the unsaturated-history warning on stderr (#3262)") reason="missing_warning"
    if ($0 == "FAIL: healthy Tor recovery stderr has unexpected-abort advice or cannot be read (#3262)") reason="unexpected_abort_or_unreadable_stderr"
    if ($0 ~ /^FAIL: healthy Tor recovery check exits [0-9][0-9]?[0-9]?, expected 1 \(#3262\)$/) {
        split($0, fields, " ")
        sub(/,$/, "", fields[7])
        if (fields[7] + 0 <= 255) { reason="command_exit"; command_exit=fields[7] + 0 }
    }
}
END {
    if (result == 124) reason="ssh_or_guest_deadline"
    if (result == 137) reason="ssh_or_guest_killed"
    if (result == 255) reason="ssh_transport"
    printf "ssh_exit=%d reason=%s command_exit=%s clipped=%s\n", result, reason, command_exit, clipped ? "yes" : "no"
}'
