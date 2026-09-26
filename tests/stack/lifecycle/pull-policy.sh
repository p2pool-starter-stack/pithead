# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# compose_up_checked's image fetch (#2654): a source checkout ups with `--pull never` so the
# unpublished first-party `:dev` tags are built, never pulled (#44). The digest-pinned third-party
# images have no build context, so compose_up_checked fetches the missing ones first — otherwise
# `uninstall` then `setup` came back with only tor running.
echo "== unit: compose_up_checked fetches missing non-buildable images on a source checkout (#2654) =="
PP="$SANDBOX/pull2654"
mkdir -p "$PP/src/dashboard" "$PP/rel/build/tari"
: >"$PP/src/dashboard/Dockerfile"
# $1 = checkout dir, $2 = `fail` to make the pull fail. Prints every docker argv in call order.
pp_up() {
    (
        cd "$1" || exit
        set --
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +eu
        docker() {
            echo "docker $*"
            [ "$PP_FAIL" != fail ] || [ "$2" != pull ]
        }
        remove_deactivated_profile_containers() { :; }
        mutation_lock_path() { echo /dev/null; }
        compose_up_checked -d
    )
}
out="$(PP_FAIL="" pp_up "$PP/src" 2>&1)"
assert_eq "source checkout: pull the missing non-buildable images, then up --pull never" "$out" \
    "docker compose pull --policy missing --ignore-buildable
docker compose up --pull never -d"
out="$(PP_FAIL="" pp_up "$PP/rel" 2>&1)"
assert_eq "release install: up --pull missing fetches everything itself, no separate pull" "$out" \
    "docker compose up --no-build --pull missing -d"
out="$(PP_FAIL="" PITHEAD_PULL=never pp_up "$PP/src" 2>&1)"
assert_eq "an explicit PITHEAD_PULL is honoured as-is, no separate pull" "$out" "docker compose up --pull never -d"
out="$(PP_FAIL=fail pp_up "$PP/src" 2>&1)"
rc=$?
assert_rc "a failed pull does not abort; up runs and decides" "$rc" "0"
assert_contains "a failed pull is reported, not swallowed" "$out" "Could not pull the missing third-party images"
assert_contains "the up still runs after a failed pull" "$out" "docker compose up --pull never -d"
rm -rf "$PP"
unset PP PP_FAIL
unset -f pp_up
