# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment}"
: "${LGD:?}"

echo "== normal-user startup replaces a root-created guard marker (#2946) =="
# Use real root only for the marker fixture; firewall, engine and systemd remain stubbed.
lg_real_sudo=$(command -v sudo)
export LG_REAL_SUDO="$lg_real_sudo"
lg_marker() {
    lg 'sudo() {
        [ "${1:-}" != -n ] || shift
        case "$1" in
        mkdir | mktemp | tee | chmod | mv | rm)
            [ "${LG_MARKER_SUDO_FAIL:-0}" = 0 ] || return 1
            "$LG_REAL_SUDO" -n "$@" ;;
        *) command sudo "$@" ;;
        esac
    }; '"$1"
}
lg_rc=0
"$lg_real_sudo" -n chown 0:0 "$LGD/data/lan-guard" &&
    "$lg_real_sudo" -n chmod 755 "$LGD/data/lan-guard" || lg_rc=$?
assert_rc "root-created 0755 marker fixture is required" "$lg_rc" 0
assert_eq "the runtime user cannot write the root-created directory" "$(test -w "$LGD/data/lan-guard" && echo writable || echo denied)" denied
: >"$LG_COMPOSE"
lg_rc=0
lg_out=$(LG_LIVE=1 lg_marker 'compose_up -d') || lg_rc=$?
assert_rc "normal-user startup retains requested LAN access" "$lg_rc" 0
assert_eq "startup preserves the configured bind" "$(cat "$LG_COMPOSE")" "compose-bind=from-env-file"
assert_eq "the marker matches the current boot" "$(cat "$LGD/data/lan-guard/enforced")" boot-1
assert_eq "the root-created directory metadata is preserved" "$(stat -c '%u:%g:%a' "$LGD/data/lan-guard")" 0:0:755
assert_eq "the privileged marker remains readable by the nodes" "$(stat -c '%a' "$LGD/data/lan-guard/enforced")" 644
assert_eq "atomic replacement leaves no temporary marker" "$(find "$LGD/data/lan-guard" -name 'enforced.*' | wc -l | tr -d ' ')" 0

: >"$LG_COMPOSE"
lg_rc=0
lg_out=$(LG_LIVE=1 LG_RUNNING=0 LG_MARKER_SUDO_FAIL=1 lg_marker 'compose_up -d') || lg_rc=$?
assert_rc "a marker write refused by sudo makes startup fail" "$lg_rc" 1
assert_contains "startup names the marker failure" "$lg_out" "marker the node containers check could not be written"
assert_eq "failed marker write still starts only on loopback" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
lg_rc=0
"$lg_real_sudo" -n chown "$(id -u):$(id -g)" "$LGD/data/lan-guard" || lg_rc=$?
assert_rc "restore marker fixture ownership" "$lg_rc" 0

lg_rc=0
LG_LIVE=0 LG_RUNNING=0 lg 'compose_up -d' >/dev/null || lg_rc=$?
assert_rc "a missing live rule also reports unavailable LAN access" "$lg_rc" 1
lg_rc=0
LG_LIVE=1 LG_COMPOSE_RC=17 lg 'compose_up -d' >/dev/null || lg_rc=$?
assert_rc "a Compose failure keeps its own exit code" "$lg_rc" 17
lg_rc=0
LG_LIVE=0 LG_RUNNING=0 LG_COMPOSE_RC=17 lg 'compose_up -d' >/dev/null || lg_rc=$?
assert_rc "a Compose failure is preserved during loopback fallback" "$lg_rc" 17
lg_rc=0
lg_out=$(lg 'lan_guard_mark() { return 1; }; lan_guard_watched_ports() { :; }; compose_up -d') || lg_rc=$?
assert_rc "no requested or running LAN port needs no marker" "$lg_rc" 0
unset LG_REAL_SUDO
