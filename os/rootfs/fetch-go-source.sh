#!/bin/sh
set -eu

repository=$1
destination=$2
commit=$3
version=$4

mkdir -p "$(dirname "$destination")"
scratch=$(mktemp -d "${destination}.fetch.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

for attempt in 1 2 3; do
    printf 'Source fetch %s: attempt %s/3 (180s deadline)\n' "$repository" "$attempt" >&2
    if timeout --kill-after=5s 180s sh -eu -c '
        git -c http.version=HTTP/1.1 clone --config http.version=HTTP/1.1 \
            --filter=blob:none --no-checkout "$1" "$2"
        git -C "$2" checkout --detach "$3"
    ' sh "$repository" "$scratch/source" "$commit"; then
        actual_version=$(git -C "$scratch/source" describe --tags --exact-match "$commit")
        if [ "$actual_version" != "$version" ]; then
            printf 'Source pin mismatch: %s is not tag %s\n' "$commit" "$version" >&2
            exit 1
        fi
        mv "$scratch/source" "$destination"
        exit 0
    else
        fetch_rc=$?
        printf 'Source fetch attempt %s/3 failed (exit %s)\n' "$attempt" "$fetch_rc" >&2
    fi
    rm -rf "$scratch/source"
    if [ "$attempt" -lt 3 ]; then sleep "$((attempt * 5))"; fi
done

printf 'Source fetch exhausted after 3 attempts: %s\n' "$repository" >&2
exit 1
