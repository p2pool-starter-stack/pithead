# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# compose_up_checked renames a container an interrupted recreate left under compose's temporary
# "<12-hex>_<name>" (#2595). Sourced by tests/stack/test-lifecycle.sh.

echo "== unit: an apply never ends with a service under compose's recreate name (#2595) =="
# Replays bench job 840: the first pass creates 4556c4f42f1d_monerod, then aborts on p2pool's
# state conflict before removing the old monerod; the #2293 retry removes the old monerod as
# surplus and starts the replacement without renaming it. The stub's container list is a file.
RN="$SANDBOX/recreate-names"
mkdir -p "$RN"
printf 'COMPOSE_PROFILES=local_node\n' >"$RN/.env"
printf 'monerod\np2pool\n' >"$RN/names"
rn_out=$(
    cd "$RN" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    sleep() { :; }
    docker() {
        case "$*" in
        "compose up"*)
            if ! grep -qx 4556c4f42f1d_monerod names; then
                echo 4556c4f42f1d_monerod >>names
                echo "container deadbeef must be in Created or Stopped state to be started" >&2
                return 1
            fi
            sed -i.bak '/^monerod$/d' names
            ;;
        "ps -a --filter label=com.docker.compose.project=pithead --format {{.Names}}") cat names ;;
        "rename "*)
            grep -qx "$3" names && return 1
            sed -i.bak "s/^$2\$/$3/" names
            ;;
        esac
    }
    compose_up_checked -d --remove-orphans
    echo "rc=$?"
)
assert_contains "the apply succeeds on the retry pass" "$rn_out" "rc=0"
assert_eq "the chain node ends the apply under its own name" "$(sort "$RN/names" | tr '\n' ' ')" "monerod p2pool "
assert_eq "the rename waits until the old container is gone" "$(grep -c 'Renamed 4556c4f42f1d_monerod to monerod' <<<"$rn_out")" "1"
assert_not_contains "a rename blocked by the old container is not reported as a fault" "$rn_out" "should be named"

echo "== unit: compose_up_checked retries once when the engine's stop API times out (#3300) =="
# Replays bench job 267: the old dashboard outlived its grace period, was SIGKILLed, and Podman
# answered the stop with a 500 about the exit file. The container is stopped on the second pass.
ST="$SANDBOX/stop-timeout"
mkdir -p "$ST"
printf 'COMPOSE_PROFILES=local_node\n' >"$ST/.env"
st_out=$(
    cd "$ST" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    sleep() { :; }
    docker() {
        case "$*" in
        "compose up"*)
            n=$(($(cat ups 2>/dev/null || echo 0) + 1))
            echo "$n" >ups
            if [ "$n" -eq 1 ]; then
                echo "Error response from daemon: timed out waiting for file /run/libpod/exits/2dcbcabe8329" >&2
                return 1
            fi
            ;;
        esac
    }
    compose_up_checked -d --remove-orphans 2>&1
    echo "rc=$?"
)
assert_contains "the recreate succeeds on the retry pass" "$st_out" "rc=0"
assert_contains "the retry is announced" "$st_out" "retrying once"
assert_eq "compose up ran exactly twice" "$(cat "$ST/ups")" "2"
