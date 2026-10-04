# shellcheck shell=bash
# Run the real CLI on the deployed candidate, keeping credentials inside the target shell.
connection_announcements_snippet() {
    cat <<'PROBE'
set -Eeuo pipefail
source ./pithead
stage=initialization
# EXIT alone preserves the integration harness's abort/unwind contract.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "connections: diagnostic: failed at %s\n" "$stage" >&2; fi' EXIT
    check_output() {
    local out=$1 bind host secret fp dir
    bind=$(env_get STRATUM_BIND)
    case "$bind" in
    '' | 0.0.0.0) host=$(env_get HOST_IP); [ -n "$host" ] || host=$(hostname) ;;
    *) host=$bind ;;
    esac
    [[ "$out" == *"Pool URL: $host:$(stratum_port_effective)"* ]]
    secret=$(env_get PROXY_STRATUM_PASSWORD)
    if [ -n "$secret" ]; then
        [[ "$out" == *"Stratum password: $secret"* ]]
    else
        [[ "$out" == *"Stratum password: none set"* ]]
    fi
    if [ "$(env_get PROXY_STRATUM_TLS)" = true ]; then
        dir=$(env_get PROXY_TLS_DIR)
        fp=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
        [ -n "$fp" ] && [[ "$out" == *"$fp"* ]]
    fi
    if [ "$(config_bool '.local_miner.enabled' false)" = true ]; then
        [[ "$out" == *"Local miner opt-in is ON"* || "$out" == *"built-in RigForge worker"* ]]
    fi
}
# setup on an already deployed box requires a real terminal. Confirm that supported rerun,
# preserve the hostname at its optional prompt, and decline stack startup. Skip host tuning.
inputs=$'y\n'
configured_host=$(jq -r '.dashboard.host // "auto"' config.json)
if [ "$configured_host" = auto ] || [ -z "$configured_host" ]; then inputs+=$'\n'; fi
inputs+=$'n\n'
stage=setup
out=$(printf '%s' "$inputs" | timeout 300 script -qec './pithead setup --skip-deps --skip-optimize' /dev/null) || {
    rc=$?
    printf '%s\n' 'connections: diagnostic: failed at setup'
    printf 'connections: diagnostic: setup command exit %s\n' "$rc"
    # Whitelist stage labels, never excerpts: even a failed setup can print credentials.
    for reached in 'Re-run setup' 'Skipping dependency checks' 'Enter Hostname' \
        'Initializing Tor service' 'Waiting for Tor hidden services' \
        'Deployment preparation complete' 'Start Pithead now' 'Another pithead operation'; do
        if [[ "$out" == *"$reached"* ]]; then
            printf 'connections: diagnostic: setup reached %s\n' "$reached"
        fi
    done
    exit "$rc"
}
[[ "$out" == *"You can start the stack later with:"* ]]
check_output "$out"
printf '%s\n' 'connections: setup with startup declined matches rendered credentials'
stage=up
out=$(./pithead up 2>&1)
check_output "$out"
printf '%s\n' 'connections: up matches rendered credentials'
stage=apply
out=$(./pithead apply -y 2>&1)
check_output "$out"
printf '%s\n' 'connections: apply matches rendered credentials'
before=$(sha256sum .env)
stage=no-change
out=$(./pithead apply -y 2>&1)
[[ "$out" == *"No configuration changes detected"* ]]
check_output "$out"
[ "$(sha256sum .env)" = "$before" ]
printf '%s\n' 'connections: no-change apply matches rendered credentials and preserves env'
PROBE
}

run_connection_announcements() {
    local out rc before="$IT_FAIL" marker
    it_step "checking setup/up/apply connection announcements on the candidate…"
    out="$(rx "$(connection_announcements_snippet)" 2>&1)"
    rc=$?
    # Never retain the raw CLI output: it intentionally contains the pool password.
    printf 'connection announcement probe exit: %s\n' "$rc" >"$OUT_DIR/connection-announcements.log"
    # Reconstruct only our fixed diagnostic labels; the remote output is never copied.
    for marker in initialization setup up apply no-change; do
        if [[ "$out" == *"connections: diagnostic: failed at $marker"* ]]; then
            printf 'Failed at: %s\n' "$marker" >>"$OUT_DIR/connection-announcements.log"
        fi
    done
    for marker in 'Re-run setup' 'Skipping dependency checks' 'Enter Hostname' \
        'Initializing Tor service' 'Waiting for Tor hidden services' \
        'Deployment preparation complete' 'Start Pithead now' 'Another pithead operation'; do
        if [[ "$out" == *"connections: diagnostic: setup reached $marker"* ]]; then
            printf 'Setup reached: %s\n' "$marker" >>"$OUT_DIR/connection-announcements.log"
        fi
    done
    assert_rc "coordinator connection announcement probe succeeds (#3090)" "$rc" 0
    for marker in \
        'setup with startup declined matches rendered credentials' \
        'up matches rendered credentials' \
        'apply matches rendered credentials' \
        'no-change apply matches rendered credentials and preserves env'; do
        if [[ "$out" == *"connections: $marker"* ]]; then
            it_pass "$marker (#3090)"
            printf 'PASS: %s\n' "$marker" >>"$OUT_DIR/connection-announcements.log"
        else
            it_fail "$marker (#3090)" "required credential assertions did not complete; CLI output withheld"
        fi
    done
    [ "$IT_FAIL" -eq "$before" ]
}
