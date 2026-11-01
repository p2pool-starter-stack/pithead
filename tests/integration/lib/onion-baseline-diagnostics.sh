# shellcheck shell=bash
onion_probe_note() { # <stage> <probe exit> <http status>
    ONION_PROBE_STAGE="$1" ONION_PROBE_EXIT="$2" ONION_PROBE_HTTP="$3"
    ONION_PROBE_ELAPSED=$(($(now_s) - ${ONION_PROBE_STARTED:-$(now_s)}))
}

onion_probe_classify() { # <exit> <output> -> "<stage> [http status]"
    local http=""
    case "$2" in *"HTTP "[0-9][0-9][0-9]*) http="${2##*HTTP }" http="${http:0:3}" ;; esac
    case "$1:$2" in
    0:*PROBE-OK*) echo "ok $http" ;;
    1:*PROBE-FAIL*"HTTP 000"*) echo "http-reachability 000" ;;
    1:*PROBE-FAIL*) echo "http-status $http" ;;
    2:*PROBE-FAIL*) echo "client-bootstrap" ;;
    4:*) echo "authorization" ;;
    *) echo "error" ;;
    esac
}

capture_onion_baseline_failure() {
    local file="$OUT_DIR/onion-baseline-probe.failure.json" stage="${ONION_PROBE_STAGE:-error}" rc http elapsed
    case "$stage" in
    input | build | authorization | client-bootstrap | http-reachability | http-status | error) ;;
    *) stage=error ;;
    esac
    rc="${ONION_PROBE_EXIT:-}"
    http="${ONION_PROBE_HTTP:-}"
    elapsed="${ONION_PROBE_ELAPSED:-}"
    case "$rc" in '' | *[!0-9]*) rc=null ;; esac
    case "$http" in [0-9][0-9][0-9]) http=$((10#$http)) ;; *) http=null ;; esac
    case "$elapsed" in '' | *[!0-9]*) elapsed=null ;; esac
    printf '{"stage":"%s","probe_exit":%s,"http_status":%s,"elapsed_seconds":%s}\n' \
        "$stage" "$rc" "$http" "$elapsed" >"$file" || {
        it_warn "onion baseline diagnostics could not be retained"
        return 1
    }
}
