#!/usr/bin/env bash
# Bounded, plain-text excerpts for build and serial-log diagnosis. Raw evidence stays intact.
# This removes terminal controls and limits output; it does not certify a log as secret-free.
set -euo pipefail

usage() {
    echo 'Usage: scripts/sanitize-test-log.sh [--lines 120] [--width 240] [FILE|-]'
    echo 'Print the start, first failure markers, and end; omitted lines are counted.'
}

lines=120 width=240 input=-
while [ "$#" -gt 0 ]; do
    case "$1" in
    --lines | --width)
        option=$1
        [ "$#" -ge 2 ] || {
            usage >&2
            exit 2
        }
        case "$2" in '' | *[!0-9]*)
            echo "$option requires an integer" >&2
            exit 2
            ;;
        esac
        [ "${#2}" -le 4 ] || {
            echo "$option is too large" >&2
            exit 2
        }
        value=$((10#$2))
        if [ "$option" = --lines ]; then lines=$value; else width=$value; fi
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    --)
        shift
        [ "$#" -eq 1 ] || {
            usage >&2
            exit 2
        }
        input=$1
        shift
        ;;
    -*)
        [ "$1" = - ] || {
            usage >&2
            exit 2
        }
        input=-
        shift
        ;;
    *)
        [ "$#" -eq 1 ] || {
            usage >&2
            exit 2
        }
        input=$1
        shift
        ;;
    esac
done
[ "$lines" -ge 12 ] && [ "$lines" -le 1000 ] && [ "$width" -ge 40 ] && [ "$width" -le 1000 ] || {
    echo 'Bounds: --lines 12..1000, --width 40..1000' >&2
    exit 2
}

summarize() {
    # POSIX awk works on macOS and Linux. Memory is bounded by the selected lines plus
    # one input record; a single unterminated record still has to fit in awk memory.
    LC_ALL=C awk -v limit="$lines" -v width="$width" -v esc=$'\033' '
        function emit(n, text) {
            if (!(n in emitted)) {
                printf "%7d | %s\n", n, text
                emitted[n] = 1
                shown++
            }
        }
        BEGIN {
            start = int(limit / 6)
            errors = int(limit / 3)
            finish = limit - start - errors
        }
        {
            # OSC title/hyperlink sequences end in BEL or ST; CSI includes SGR colors.
            gsub(esc "\\][^\007]*\007", "")
            gsub(esc "[][PX^_][^" esc "]*" esc "\\\\", "")
            gsub(esc "\\[[0-?]*[ -/]*[@-~]", "")
            gsub(esc "[@-_]", "")
            gsub(/[[:cntrl:]]/, " ")
            matched = tolower($0) ~ /(^|[^a-z])(error|fail(ed|ure)?|fatal|panic|traceback|exception|timeout|killed|oom|no space left|not ok)([^a-z]|$)/
            if (matched) failures++
            text = length($0) > width ? substr($0, 1, width - 14) " ... [clipped]" : $0
            if (NR <= start) first[NR] = text
            if (matched && found < errors) {
                failure_number[++found] = NR
                failure_text[found] = text
            }
            last[NR % finish] = text
        }
        END {
            printf "Log excerpt: %d input lines; %d failure-marker lines (not a test verdict).\n", NR, failures
            print "--- start ---"
            for (n = 1; n <= start && n <= NR; n++) emit(n, first[n])
            print "--- first failure markers ---"
            for (i = 1; i <= found; i++) emit(failure_number[i], failure_text[i])
            print "--- end ---"
            for (n = (NR > finish ? NR - finish + 1 : 1); n <= NR; n++) emit(n, last[n % finish])
            printf "--- %d lines shown; %d omitted; long lines clipped to %d columns ---\n", shown, NR - shown, width
        }
    '
}

if [ "$input" = - ]; then
    summarize
else
    summarize <"$input"
fi
