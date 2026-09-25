#!/usr/bin/env bash
# tor's own account of a failed healthcheck (#2359), a recurrence of #1945's unresolved half.
# Sourced by tests/os/run.sh; uses its _ssh and its indentation idiom. Kept out of
# failure-evidence.sh, which is already at its docs/dev/file-budget.tsv ceiling — the same
# reason zero-container-evidence.sh lives apart from it.
#
# Job 40's guest firstboot journal showed the compose orchestration's own verdict — "dependency
# tor failed to start" / "container tor is unhealthy" — but never tor's own log, so nobody could
# tell WHY the healthcheck failed. Called from backup_failure_evidence(), which runs on the same
# restore-leg source machine this failure mode occurs on.
#
# Job 1194 (#2725) printed this header and nothing under it: the guest was rebooting, and a dump
# that reads nothing looked the same as one that was never asked. A failed ask now says so. The
# bootstrap and warn lines come from the whole log, since `--tail` drops tor's first minutes.
tor_health_evidence() {
    printf '     --- guest evidence (#2359) ---\n'
    _ssh "echo '-- tor container state --'; podman ps -a --filter name=tor --format '{{.Names}} {{.Status}}' 2>&1
          echo '-- tor healthcheck --'; podman inspect tor --format '{{json .State.Health}}' 2>&1
          echo '-- tor bootstrap and warnings --'; podman logs tor 2>&1 | grep -E 'Bootstrapped|\[warn\]|\[err\]' | tail -40
          echo '-- tor container log --'; podman logs --tail 100 tor 2>&1" |
        tr -d '\r' | sed 's/^/     | /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || printf '     | (the guest did not answer: %s)\n' "$(tr -d '\r' <"${SSH_ERR:-/dev/null}" 2>/dev/null | tail -1)"
}

# --- self-test (#2359): no guest, no network ----------------------------------------------------
_th_rc=0
_th_case() { # <label> <substring the asked command must contain>
    case "$(cat "$_th_ask" 2>/dev/null)" in
    *"$2"*) printf 'ok: %s\n' "$1" ;;
    *)
        printf 'FAIL: %s — the #2359 dump never asked for: %s\n' "$1" "$2"
        _th_rc=1
        ;;
    esac
}

_th_self_test() {
    local out
    _th_ask=$(mktemp)
    out=$(mktemp)
    _ssh() {
        printf '%s' "$*" >>"$_th_ask"
        printf -- '-- tor container state --'
    }
    printf '== unit: the #2359 dump asks for tor'"'"'s own evidence ==\n'
    tor_health_evidence >"$out"
    _th_case "it shows tor's container status" "podman ps -a --filter name=tor"
    _th_case "it reads tor's own healthcheck verdict" "podman inspect tor --format '{{json .State.Health}}'"
    _th_case "it captures tor's own container log, not just the orchestration journal" \
        "podman logs --tail 100 tor"
    _th_case "it reads tor's bootstrap progress from the whole log, not the tail" \
        "podman logs tor 2>&1 | grep -E 'Bootstrapped"
    if grep -q '^     | -- tor container state' "$out"; then
        printf 'ok: the dump is prefixed so it reads inside the battery output\n'
    else
        printf 'FAIL: the #2359 dump is not prefixed, got: %s\n' "$(cat "$out")"
        _th_rc=1
    fi
    # #2725: a guest that does not answer must say so, not print a bare header.
    _ssh() { return 255; }
    printf 'ssh: connect to host port 22: Connection refused\n' >"$_th_ask"
    SSH_ERR="$_th_ask" tor_health_evidence >"$out"
    if grep -q '^     | (the guest did not answer: ssh: connect to host port 22: Connection refused)' "$out"; then
        printf 'ok: an unanswered dump names the ssh failure\n'
    else
        printf 'FAIL: an unanswered #2359 dump did not say so, got: %s\n' "$(cat "$out")"
        _th_rc=1
    fi
    rm -f "$_th_ask" "$out"
    if [ "$_th_rc" -ne 0 ]; then
        printf '#2359 tor-health evidence self-test FAILED\n'
        return 1
    fi
    printf '#2359 tor-health evidence self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    _th_self_test
    exit $?
fi
