# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2329  # fake functions and dynamic globals are the controls
# Verdicts and pure self-tests for appliance-config-approval-leg.sh.
#
# #2076 removed the Telegram approval round-trip, and with it the fake-provider transport this file
# used to carry: approval_fixture_arm/bind/quiesce/disarm, approval_fixture_post/preview, the
# prompt and approver verdicts, and the four fixture self-tests that existed only to prove that
# harness could not silently no-op. A sensitive commit now goes through the ordinary authenticated
# control route, so the leg needs no privileged loopback identity and no guest-side fake at all.
#
# What is left is what the removal did not touch: the consumer proof that a repointed Tari endpoint
# is the one p2pool actually merge-mines against, and the two pure self-tests that keep this file
# honest without a guest.

# WHICH of the four bindings failed, for the row that reported only that one of them did (#2060).
# The row's own `if` is a four-way conjunction and prints one red for all four. The three cheap
# legs are re-derived HERE by calling the same verdicts with the same arguments the caller passed
# — not by re-spelling their logic, which would leave the copy free to drift from the original.
# The fourth, live identity, prints its own row above this one and says so rather than guessing.
# #2076 removed the Telegram leg, and with it the prompt this payload used to bind: there is no
# prompt to be unbound from any more, and `approver` now has no writer at all. The remaining two
# legs are the ones that can still disagree — what the commit returned, and whether the audit row
# is the one for THIS request. The audit leg is spelled out here rather than delegated, because
# the verdict it used to call (approval_audit_verdict) went with the Telegram leg.
approval_bind_payload() { # <result-json> <audit-jsonl> <request-id>
    local result="$1" audit="$2" rid="$3" apply audit_v
    apply=$(printf '%s' "${result:-null}" | jq -r '"\(.status // "none")/\(.error // "no error")"' 2>/dev/null) ||
        apply="unparseable: ${result:0:120}"
    [ -n "$result" ] || apply="no result — the commit never returned"
    # stderr suppressed: on a malformed audit jq writes a parse error, and the row's own `if`
    # already ran this check once — a second copy would land mid-payload, where it reads like a
    # harness crash rather than part of the evidence.
    if printf '%s\n' "$audit" | jq -se --arg id "$rid" 'any(.[];
        .id == $id and .status == "applied" and (.approver // "") == "")' >/dev/null 2>&1; then
        audit_v="bound"
    else
        audit_v="unbound (want id=$rid applied with no approver; last line: $(printf '%s\n' "$audit" | tail -n 1))"
    fi
    printf 'apply=%s audit=%.240s; live identity is the row printed above this one' "$apply" "$audit_v"
}

tari_endpoint_roundtrip_verdict() { # <p2pool-startup-log> <expected-host:port>
    local plain
    plain=$(printf '%s\n' "$1" | mm_strip_ansi)
    printf '%s\n' "$plain" | grep -aF "MergeMiningClientTari tari://$2 uses chain_id " | grep -aqE 'uses chain_id [0-9a-f]{16,}'
}

_control_request_transport_self_test() (
    local secret='os1966-secret-not-in-argv' body result ip=fixture transport_fail=0
    body=$(jq -nc --arg password "$secret" '{config:{monero:{node_password:$password}}}')
    dashboard_curl() {
        local arg stdin_body
        stdin_body=$(cat)
        [ "$stdin_body" = "$body" ] || return 92
        while [ "$#" -gt 0 ]; do
            arg="$1"
            case "$arg" in *"$secret"*) return 91 ;; esac
            if [ "$arg" = --data-binary ]; then
                [ "$2" = @- ] || return 93
                shift 2
            else
                shift
            fi
        done
        [ "$transport_fail" -eq 0 ] || return 94
        printf '{"id":"fixture","status":"previewed"}'
    }
    result=$(dashboard_control_request preview "$body") || return 1
    [ "$result" = '{"id":"fixture","status":"previewed"}' ] || return 1
    transport_fail=1
    dashboard_control_request preview "$body" >/dev/null 2>&1 && return 1
    return 0
)

# A POST that DIES in flight is not a request that never happened (#2060). The apply a confirmed
# commit triggers recreates containers, restarting the dashboard underneath its own request: on the
# bench the runner's answer reached disk (`commit-confirmed -> applied`, a result document with
# {"status":"applied"}) while the caller reported "the commit never returned". The caller sent the
# id, so it can still poll — and the two halves are asserted together, because a fallback that also
# fires when the server ANSWERED a refusal would turn every rejection into a full deadline of
# polling, which is the opposite failure and just as expensive on a 2.5-hour battery.
_control_request_lost_response_self_test() (
    local body ip=fixture result polls
    body='{"id":"rid-7","confirm":"APPLY"}'
    # A file, not a variable: every poll happens inside a command substitution, so a counter
    # incremented in the shim would be discarded with that subshell and read 0 however many times
    # it ran — a control that cannot fail.
    polls=$(mktemp)
    # The POST always dies; the result poll answers, exactly as the guest's disk did.
    dashboard_curl() {
        case "$*" in
        *'/api/control/result?id=rid-7'*)
            printf 'x' >>"$polls"
            printf '{"id":"rid-7","status":"applied"}'
            ;;
        *)
            cat >/dev/null
            return 52
            ;;
        esac
    }
    result=$(dashboard_control_request commit "$body" 30) || return 1
    case "$result" in *'"status":"applied"'*) ;; *) return 1 ;; esac
    [ -s "$polls" ] || return 1
    rm -f "$polls"
    # A body with no id of its own has nothing to fall back to and must still fail fast.
    dashboard_curl() {
        cat >/dev/null
        return 52
    }
    dashboard_control_request diag-doctor '{}' 30 >/dev/null 2>&1 && return 1
    # And a server that ANSWERED without an id refused: fail fast, do not poll the deadline out.
    dashboard_curl() {
        cat >/dev/null
        printf '{"error":"Missing X-Pithead-Control header."}'
    }
    local began ended
    began=$(date +%s)
    dashboard_control_request commit "$body" 30 >/dev/null 2>&1 && return 1
    ended=$(date +%s)
    [ "$((ended - began))" -lt 5 ] || return 1
)

_runtime_epoch_self_test() (
    local count_file ip=fixture n
    count_file=$(mktemp)
    printf '0\n' >"$count_file"
    trap 'rm -f "$count_file"' EXIT
    _ssh() {
        case "$1" in
        *".State.StartedAt"*)
            n=$(cat "$count_file")
            n=$((n + 1))
            printf '%s\n' "$n" >"$count_file"
            [ "$n" -lt 4 ] && printf 'epoch-one\n' || printf 'epoch-two\n'
            ;;
        *"sed -n"*) printf 'MONERO_NODE_HOST=monero.fixture\nMONERO_RPC_PORT=18081\nMONERO_ZMQ_PORT=18083\nTARI_GRPC_ADDRESS=tari.fixture:18142\n' ;;
        *".Config.Cmd"*) printf 'monero.fixture\t18081\t18083\ttari://tari.fixture:18142\n' ;;
        *".Config.Env"*) return 0 ;;
        esac
    }
    local snapshot='PITHEAD_P2POOL_STARTED=epoch-one
MergeMiningClientTari tari://tari.fixture:18142 uses chain_id 0123456789abcdef'
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" || return 1
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" && return 1
    return 0
)

# The one invariant behind #2060's control rows: the POST must outlast the window the dashboard
# itself waits before handing back a pollable id. Both numbers are read from their own sources — a
# literal repeated here would keep passing after either side moved, which is exactly how an 8s cap
# survived beside a 30s server wait and a 420s outer deadline.
_control_post_timeout_self_test() (
    local here cap window
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    cap=$(awk '/^dashboard_control_post\(\)/, /^}/' "$here/appliance-config-approval-leg.sh" |
        sed -n 's/.* -m \([0-9][0-9]*\) .*/\1/p')
    window=$(sed -n 's/^CONTROL_WAIT_S *= *float(os.environ.get("CONTROL_WAIT_S", *\([0-9][0-9.]*\))).*/\1/p' \
        "$here/../../dashboard/mining_dashboard/config/config.py")
    # Either read coming back empty means the shape it keys on moved; that is a failure, not a pass.
    [ -n "$cap" ] && [ -n "$window" ] || return 1
    awk -v c="$cap" -v w="$window" 'BEGIN { exit !(c > w) }'
)

# --- self-test (#2060) -------------------------------------------------------------------------
#
# Driven by tests/stack/test-harness-tooling.sh. The leg that consumes this file is at its file
# budget, so the payload's controls live here with it rather than in the leg's own self-test.
#
# What must be proven is DISCRIMINATION: the row this feeds already prints one red for four
# different defects, so a payload that printed one sentence for all four would leave it exactly
# where it was. Each leg is asserted bound in the good case and named in its own failing case.
_approval_bind_payload_self_test() {
    local f=0 rid=r1 out
    local audit='{"id":"r1","action":"commit-confirmed","status":"applied","approver":""}'
    local applied='{"status":"applied"}'
    _control_post_timeout_self_test || f=$((f + 1))
    _control_request_lost_response_self_test || f=$((f + 1))
    out=$(approval_bind_payload "$applied" "$audit" "$rid")
    case "$out" in 'apply=applied/no error audit=bound;'*) ;; *) f=$((f + 1)) ;; esac
    # One failing leg at a time: the other must still read `bound`, or the row cannot say which broke.
    out=$(approval_bind_payload '{"status":"rejected","error":"typed payout confirmations"}' "$audit" "$rid")
    case "$out" in *'apply=rejected/typed payout confirmations'*'audit=bound'*) ;; *) f=$((f + 1)) ;; esac
    # The audit row for a DIFFERENT request must not read as bound.
    out=$(approval_bind_payload "$applied" "${audit//r1/r2}" "$rid")
    case "$out" in *'audit=unbound (want id=r1'*) ;; *) f=$((f + 1)) ;; esac
    # #2076's own regression: an audit row carrying an approver means the removed Telegram leg is
    # back, so it must NOT read as bound even though its id and status match.
    out=$(approval_bind_payload "$applied" '{"id":"r1","status":"applied","approver":"tg-1966"}' "$rid")
    case "$out" in *'audit=unbound'*) ;; *) f=$((f + 1)) ;; esac
    # The empty shapes — how #2060's rows were produced in the first place.
    out=$(approval_bind_payload '' '' "$rid")
    case "$out" in *'no result — the commit never returned'*) ;; *) f=$((f + 1)) ;; esac
    # `unbound` CONTAINS `bound`, so the absence check has to carry the field prefix or it matches
    # the very failure it is meant to exclude.
    case "$out" in *'audit=bound'*) f=$((f + 1)) ;; esac
    out=$(approval_bind_payload '{"status":' "$audit" "$rid")
    case "$out" in *'apply=unparseable: {"status":'*) ;; *) f=$((f + 1)) ;; esac
    # A malformed audit must produce a payload and NOTHING on stderr.
    out=$(approval_bind_payload '{"status":"applied"}' 'not json at all' "$rid" 2>&1 >/dev/null)
    [ -z "$out" ] || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'approval-bind-payload self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'approval-bind-payload self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _approval_bind_payload_self_test
fi
