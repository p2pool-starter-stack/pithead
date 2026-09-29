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
            [ "$1" != ps ] || return 0 # no running node in this pull-policy fixture
            echo "docker $*"
            [ "$PP_FAIL" != fail ] || [ "$2" != pull ]
        }
        remove_deactivated_profile_containers() { :; }
        lan_guard_watched_ports() { :; } # the image-pull probe has no published node ports
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

echo "== unit: source upgrade reconciles rebuilt image IDs (#2934) =="
upgrade_reconcile_probe() { # <starting image ID> <recreate result> -> outcome and calls
    local starting="$1" replacement="$2"
    (
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +eu
        UR_RUNNING="$starting"
        docker() {
            case "$*" in
            "compose config --format json") printf '%s\n' '{"services":{"xmrig-proxy":{"image":"xmrig-proxy:dev"},"dashboard":{"image":"dashboard:dev"}}}' ;;
            "compose config --services") printf 'xmrig-proxy\ndashboard\n' ;;
            "compose ps -a -q xmrig-proxy") printf 'old-proxy\n' ;;
            "compose ps -a -q dashboard") printf 'same-dashboard\n' ;;
            "image inspect --format {{.Id}} xmrig-proxy:dev") printf 'new-proxy-image\n' ;;
            "image inspect --format {{.Id}} dashboard:dev") printf 'dashboard-image\n' ;;
            "inspect --format {{.Image}} old-proxy") printf '%s\n' "$UR_RUNNING" ;;
            "inspect --format {{.Image}} same-dashboard") printf 'dashboard-image\n' ;;
            *) return 1 ;;
            esac
        }
        compose_up_checked() {
            printf 'recreate %s\n' "$*"
            UR_RUNNING="$replacement"
        }
        reconcile_source_upgrade_images
        printf 'result=%s\n' "$?"
    )
}
out="$(upgrade_reconcile_probe old-proxy-image new-proxy-image)"
assert_contains "old running image is recreated after the tag changes" "$out" "recreate -d --no-deps --force-recreate xmrig-proxy"
assert_contains "a successful recreate verifies the new image ID" "$out" "result=0"
assert_eq "the unchanged dashboard is not recreated" "$(printf '%s\n' "$out" | grep -c '^recreate ' )" "1"
out="$(upgrade_reconcile_probe old-proxy-image old-proxy-image)"
assert_contains "a recreate that leaves the old image fails the upgrade" "$out" "result=1"
out="$(upgrade_reconcile_probe new-proxy-image new-proxy-image)"
assert_eq "already-matching images need no recreation" "$(printf '%s\n' "$out" | grep -c '^recreate ')" "0"
assert_contains "matching images pass identity verification" "$out" "result=0"
assert_contains "source upgrade invokes image reconciliation" \
    "$(sed -n '/^stack_upgrade() {$/,/^}$/p' "$ROOT/lib/pithead/03-release-verify.sh")" \
    "reconcile_source_upgrade_images || error"
unset -f upgrade_reconcile_probe
