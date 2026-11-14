#!/bin/sh
set -eu

url=$1
destination=$2

for attempt in 1 2 3; do
    printf 'Archive fetch %s: attempt %s/3 (180s deadline)\n' "$url" "$attempt" >&2
    if code=$(timeout --kill-after=5s 180s curl -fsSL -o "${destination}.part" -w '%{http_code}' "$url"); then
        mv "${destination}.part" "$destination"
        exit 0
    else
        fetch_rc=$?
        printf 'Archive fetch attempt %s/3 failed (exit %s, status %s)\n' "$attempt" "$fetch_rc" "${code:-000}" >&2
    fi
    rm -f "${destination}.part"
    if [ "$attempt" -lt 3 ]; then sleep "$((attempt * 5))"; fi
done

printf 'Archive fetch exhausted after 3 attempts: %s (final status %s)\n' "$url" "${code:-000}" >&2
exit 1
