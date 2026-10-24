#!/usr/bin/env bash
set -euo pipefail
umask 077
scratch="$1"
cli="$2"
case "$3" in
prepare)
    cp -p config.json "$scratch/original.json"
    jq --slurpfile original "$scratch/original.json" '
        def candidate($saved):
            with_entries(select(.key != "_docs" and .key != "config_version") |
                .key as $key |
                select(($saved | type) == "object" and ($saved | has($key))) |
                .value |= if type == "object" then candidate($saved[$key]) else $saved[$key] end);
        candidate($original[0])
    ' config.reference.json >"$scratch/fixture.json"
    jq -e --slurpfile original "$scratch/original.json" '
        . as $fixture |
        all($original[0] | paths | select(any(.[]; type == "string" and test("wallet|payout|view_key|spend_public_key|donor_id")));
            . as $path | ($fixture | any(paths; . == $path)) and
                (($fixture | getpath($path)) == ($original[0] | getpath($path))))
    ' "$scratch/fixture.json" >/dev/null || {
        printf 'reset recovery fixture cannot preserve every wallet and payout field\n' >&2
        exit 1
    }
    touch "$scratch/mutated"
    cp "$scratch/fixture.json" config.json
    "$cli" apply -y
    ;;
restore)
    if [ -e "$scratch/mutated" ]; then
        "$cli" down
        cp -p "$scratch/original.json" config.json
        "$cli" apply -y
        cp -p "$scratch/original.json" config.json
        "$cli" up
    fi
    cmp -s "$scratch/original.json" config.json
    ;;
remove)
    cmp -s "$scratch/original.json" config.json
    rm -f -- "$scratch/original.json" "$scratch/fixture.json" "$scratch/mutated"
    rmdir -- "$scratch"
    ;;
*) exit 2 ;;
esac
