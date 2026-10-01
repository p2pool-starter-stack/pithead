# shellcheck shell=bash
# Allowlisted transport metadata on stderr: callers capture stdout as the control result.
# No request body, free-text error, preview values, credentials or endpoint is printed.
control_request_evidence() { # <route> <stage> <curl-rc> <response-with-HTTP-footer> [request-id]
    local route="$1" stage="$2" crc="$3" raw="$4" rid="${5:-}" http
    case "$route" in preview | commit | backup | diag-doctor | diag-logs) ;; *) route=other ;; esac
    case "$stage" in post | poll | deadline) ;; *) stage=other ;; esac
    http=${raw##*$'\n'}
    if [[ $http =~ ^[0-9]{3}$ ]]; then raw=${raw%$'\n'*}; else http=none; fi
    printf '%s' "$raw" | jq -Rsc --arg route "$route" --arg stage "$stage" --arg http "$http" \
        --arg rid "$rid" --argjson curl "$crc" --argjson ts "$(date +%s)" '
        (try fromjson catch null) as $parsed |
        (if ($parsed | type) == "object" then $parsed else {} end) as $r |
        {route:$route, stage:$stage, ts:$ts, curl:$curl, http:$http, bytes:utf8bytelength,
         json:($parsed | type == "object"), error:($r | if type == "object" then has("error") else false end),
         id: ((if $rid != "" then $rid else $r.id end) |
              if type == "string" then
                if test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") then . else "unknown" end
              else "unknown" end),
         status: ($r.status | if IN("pending","accepted","running","downloading","installing",
                                   "previewed","applied","rejected","failed","updated","rolled_back") then . else "unknown" end)}' \
        2>/dev/null | sed 's/^/  control request: /' >&2
}

# A failed request keeps its normal failure verdict. Sample only unit state and spool counts;
# the runner's per-boot journals and control timeline retain the detailed guest history.
control_request_guest_evidence() {
    # shellcheck disable=SC2034 # _ssh reads its per-call deadline through dynamic scope
    local guest SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}"
    guest=$(_ssh 'set -euo pipefail
systemctl show pithead-control.service -p ActiveState -p SubState -p Result -p NRestarts -p ExecMainCode -p ExecMainStatus
cd /data/pithead/data/control
queued=$(find requests -maxdepth 1 -type f -name "*.json" | wc -l)
claimed=$(find . -maxdepth 1 -type f -name ".claim.*" | wc -l)
printf "queued=%s\nclaimed=%s\n" "$queued" "$claimed"' 2>/dev/null) || {
        printf '  control guest snapshot: unavailable\n' >&2
        return 0
    }
    printf '%s' "$guest" | jq -Rsc 'split("\n") | map(select(test(
        "^(ActiveState|SubState|Result)=[a-z-]{1,40}$|^(NRestarts|ExecMainCode|ExecMainStatus|queued|claimed)=[0-9]{1,10}$"))) | .[:8]' \
        2>/dev/null | sed 's/^/  control guest snapshot: /' >&2
}

_control_request_evidence_self_test() (
    # == Control request diagnostics ==
    # shellcheck disable=SC2034 # shared poller reads ip through Bash dynamic scope
    local dir shape result rc=0 ip=fixture
    local fixture_id=12345678-1234-1234-1234-123456789abc secret=must-not-reach-evidence
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    sleep() { :; }
    date() { printf '100\n'; }
    _ssh() {
        [ "${SSH_TIMEOUT:-}" = "${SSH_PROBE_TIMEOUT:-20}" ] || return 1
        printf 'ActiveState=active\nSubState=running\nResult=success\nNRestarts=2\nExecMainCode=0\nExecMainStatus=0\nqueued=1\nclaimed=1\n'
        printf 'untrusted=%s\n' "$secret"
    }
    dashboard_control_post() {
        case "$shape" in
        refused) printf '{"error":"%s","password":"%s"}\n401' "$secret" "$secret" ;;
        lost)
            printf '\n000'
            return 52
            ;;
        malformed) printf '<html>%s</html>\n502' "$secret" ;;
        pending) printf '{"id":"%s","status":"accepted","password":"%s"}\n202' "$fixture_id" "$secret" ;;
        terminal) printf '{"id":"%s","status":"previewed","password":"%s"}\n200' "$fixture_id" "$secret" ;;
        esac
    }
    dashboard_curl() {
        printf '{"status":"previewed","password":"%s"}\n200' "$secret"
    }
    # Definite refusal, transport loss without an id, and non-JSON proxy response all fail fast.
    for shape in refused lost malformed; do
        rc=0
        result=$(dashboard_control_request preview '{"config":{}}' 10 2>"$dir/$shape") || rc=$?
        [ "$rc" -eq 1 ] && [ -z "$result" ] || return 1
        grep -Fq '"queued=1"' "$dir/$shape" && grep -Fq '"NRestarts=2"' "$dir/$shape" || return 1
        ! grep -Fq "$secret" "$dir/$shape" || return 1
    done
    # Pin every published field, not just the presence of a diagnostic line.
    [ "$(sed -n '1p' "$dir/refused")" = '  control request: {"route":"preview","stage":"post","ts":100,"curl":0,"http":"401","bytes":72,"json":true,"error":true,"id":"unknown","status":"unknown"}' ] || return 1
    [ "$(sed -n '2p' "$dir/refused")" = '  control guest snapshot: ["ActiveState=active","SubState=running","Result=success","NRestarts=2","ExecMainCode=0","ExecMainStatus=0","queued=1","claimed=1"]' ] || return 1
    grep -Fq '"curl":52' "$dir/lost" && grep -Fq '"http":"000"' "$dir/lost" || return 1
    grep -Fq '"http":"502"' "$dir/malformed" && grep -Fq '"json":false' "$dir/malformed" || return 1
    # Polling retains the real response on stdout, including its id, without leaking it to logs.
    shape=pending
    result=$(dashboard_control_request preview '{"config":{}}' 10 2>"$dir/pending") || return 1
    [ "$(jq -r '.status + ":" + .id' <<<"$result")" = "previewed:$fixture_id" ] || return 1
    grep -Fq '"stage":"poll"' "$dir/pending" && grep -Fq '"http":"200"' "$dir/pending" || return 1
    jq -e --arg id "$fixture_id" '.id == $id and .status == "accepted"' < <(sed -n '1s/^  control request: //p' "$dir/pending") >/dev/null || return 1
    jq -e --arg id "$fixture_id" '.id == $id and .status == "previewed"' < <(sed -n '2s/^  control request: //p' "$dir/pending") >/dev/null || return 1
    ! grep -Fq "$secret" "$dir/pending" || return 1
    shape=terminal
    result=$(dashboard_control_request preview '{"config":{}}' 10 2>"$dir/terminal") || return 1
    [ "$(jq -r '.status' <<<"$result")" = previewed ] || return 1
    ! grep -Fq 'control guest snapshot:' "$dir/terminal" || return 1
    # An exhausted deadline stays a failure and preserves the last pending state and request id.
    shape=pending rc=0
    result=$(dashboard_control_request preview '{"config":{}}' 0 2>"$dir/deadline") || rc=$?
    [ "$rc" -eq 1 ] && [ -z "$result" ] || return 1
    grep -Fq '"stage":"deadline"' "$dir/deadline" && grep -Fq "$fixture_id" "$dir/deadline" || return 1
    ! grep -Fq "$secret" "$dir/deadline" || return 1
    SSH_PROBE_TIMEOUT=7 control_request_guest_evidence 2>"$dir/probe"
    grep -Fq '"queued=1"' "$dir/probe" || return 1
    _ssh() { return 255; }
    control_request_guest_evidence 2>"$dir/ssh"
    grep -Fxq '  control guest snapshot: unavailable' "$dir/ssh" || return 1
    # Hostile scalar/array JSON and free-text status/id cannot become metadata or stderr errors.
    for result in '[]' '"scalar"' "{\"id\":\"$secret\",\"status\":\"$secret\",\"error\":\"$secret\"}"; do
        control_request_evidence preview post 0 "$result" 2>"$dir/hostile"
        grep -Fq '"status":"unknown"' "$dir/hostile" || return 1
        ! grep -Fq "$secret" "$dir/hostile" || return 1
    done
    printf 'control-request-evidence self-test passed\n'
)
