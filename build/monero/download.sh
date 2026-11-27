#!/bin/sh
set -eu

expected_hash=$1
seconds_per_source=$2
output=$3
shift 3

partial="${output}.part"
trap 'rm -f "$partial"' EXIT
trap 'exit 1' HUP INT TERM

for source in "$@"; do
    if curl --disable --fail --show-error --location --retry 0 --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time "$seconds_per_source" \
        --output "$partial" "$source"; then
        if ! printf '%s  %s\n' "$expected_hash" "$partial" | sha256sum -c -; then
            echo "Monero download: SHA-256 verification failed; refusing archive" >&2
            exit 1
        fi
        mv "$partial" "$output"
        exit 0
    fi
    echo "Monero download: source transfer failed (${seconds_per_source}s limit)" >&2
    rm -f "$partial"
done

echo "Monero download: all sources failed (${seconds_per_source}s maximum per source)" >&2
exit 1
