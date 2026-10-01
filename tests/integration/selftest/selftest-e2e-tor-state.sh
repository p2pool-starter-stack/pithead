#!/usr/bin/env bash
# Exercise real fixture provisioning with different live and disposable Tor identities.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
subject="$(sed -n '/^provision() {$/,/^}$/p' "$HERE/../e2e.sh")"
assert_eq "extract complete fixture provision function" \
    "$(printf '%s\n' "$subject" | sed -n '1p;$p' | tr '\n' ' ')" 'provision() { } '
eval "$subject"
eval "$(sed -n '/^resolve_default() {$/,/^}$/p' "$ROOT/lib/pithead/19-small-utilities.sh")"
eval "$(sed -n '/^dotenv_render_value() {$/,/^}$/p' "$ROOT/lib/pithead/19-small-utilities.sh")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

drive() { # <case>
    (
        # These globals and stubs are consumed by the extracted provision function.
        # shellcheck disable=SC2034,SC2329
        CANONICAL_DIR="$T/$1/canonical" E2E_DIR="$T/$1/e2e" BENCH_HOST=fixture BRANCH=fixture GIT_REMOTE_URL=fixture
        local seed="$T/$1/live" path configured
        mkdir -p "$CANONICAL_DIR" "$seed" "$E2E_DIR/data/tor/monero"
        cp "$ROOT/pithead" "$E2E_DIR/pithead"
        printf 'other.onion\n' >"$E2E_DIR/data/tor/monero/hostname"
        path="$seed/kept tor \$state"
        [ "$1" != relative ] || path=data/tor
        mkdir -p "$seed/data/tor/monero" "$seed/kept tor \$state/monero"
        printf 'kept.onion\n' >"$seed/data/tor/monero/hostname"
        printf 'kept.onion\n' >"$seed/kept tor \$state/monero/hostname"
        configured="$1"
        case "$1" in
        empty) configured="" ;;
        relative) configured=data/tor ;;
        absolute) configured="$path" ;;
        fallback | missing-env-path | missing-directory) configured=auto ;;
        esac
        jq -n --arg d "$configured" '{monero:{wallet_address:"fixture"},tor:{data_dir:$d}}' >"$seed/config.json"
        if [ "$1" = omitted ]; then
            jq 'del(.tor.data_dir)' "$seed/config.json" >"$seed/cfg" && mv "$seed/cfg" "$seed/config.json"
        fi
        [ "$1" != missing-directory ] || path="$seed/absent"
        printf 'TOR_DATA_DIR=%s\nMONERO_ONION_ADDRESS=kept.onion\nPROXY_AUTH_TOKEN=fixture-token\n' \
            "$(dotenv_render_value "$path")" >"$seed/.env"
        [ "$1" != missing-env-path ] || sed -i '/^TOR_DATA_DIR=/d' "$seed/.env"
        cp "$seed/config.json" "$CANONICAL_DIR/config.json"
        cp "$seed/.env" "$CANONICAL_DIR/.env"
        if [ "$1" = fallback ]; then
            cp -a "$seed/data" "$seed/kept tor \$state" "$CANONICAL_DIR/"
            seed="$CANONICAL_DIR"
        else
            ln -s "$seed" "$T/$1/current"
        fi
        parent_lock_checkpoint() { :; }
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        on_bench() {
            case "$1" in
            *'git clone --quiet'*) : ;; # No Git or Docker; only the fixture-copy commands execute.
            *'rev-parse --short HEAD'*) echo fixture ;;
            *) bash -c "$1" ;;
            esac
        }
        provision >"$E2E_DIR/provision.log" || exit 1
        case "$1" in
        auto | omitted | empty | DYNAMIC_DATA | fallback)
            grep -Fx 'Tor fixture: default path would change the live mount (#2951)' "$E2E_DIR/provision.log" >/dev/null || exit 5
            ;;
        *) grep -Fx 'Tor fixture: live mount preserved (#2951)' "$E2E_DIR/provision.log" >/dev/null || exit 5 ;;
        esac
        cmp -s "$seed/.env" "$E2E_DIR/.env" || exit 2
        local resolved address
        resolved="$(resolve_default "$(jq -r '.tor.data_dir // empty' "$E2E_DIR/config.json")" "$E2E_DIR/data/tor")"
        address="$(cat "$resolved/monero/hostname")" || exit 3
        [ "$address" = kept.onion ] || exit 4
        printf 'kept identity; unchanged secrets\n'
    )
}
for case_name in auto omitted empty DYNAMIC_DATA relative absolute fallback; do
    assert_eq "fixture keeps live Tor identity and secret baseline: $case_name" \
        "$(drive "$case_name")" 'kept identity; unchanged secrets'
done
for case_name in missing-env-path missing-directory; do
    drive "$case_name" >/dev/null 2>&1
    assert_rc "invalid Tor path refuses fixture provision: $case_name" "$?" 1
done
printf 'e2e Tor state: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
