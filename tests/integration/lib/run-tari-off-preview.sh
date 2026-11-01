# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
tari_preview_diagnostic() {
    local rc="$1" err="$2"
    [ "$rc" -eq 0 ] && return 0
    printf 'Tari-off preview: remote exit status %s; stderr tail:\n' "$rc"
    tail -n 40 "$err" | cut -c1-300 | redact | head -c 4000
}

run_tari_off_preview() {
    local out rc err
    err="$(mktemp "${TMPDIR:-/tmp}/tari-preview-err.XXXXXX")" || return 1
    out=$(rx "cli=$(quote_arg "$IT_PITHEAD")"$'\n'"$(
        cat <<'REMOTE'
        set -eu
        scratch=$(mktemp -d "${TMPDIR:?}/tari-preview.XXXXXX")
        trap 'rm -rf "$scratch"' EXIT
        cp .env "$scratch/baseline.env"
        jq '.tari.mode="remote" | .tari.remote.host="baseline-tari.example" | .tari.remote.grpc_port=18142 | .tari.clearnet_initial_sync=false' config.json >"$scratch/baseline.json"
        (
            export PITHEAD_CONFIG_FILE="$scratch/baseline.json" PITHEAD_ENV_FILE="$scratch/baseline.env" PITHEAD_DRY_RUN=1
            source "$cli"
            parse_and_validate_config
            load_preserved_state
            resolve_dashboard_host
            DEPLOYMENT_COMPLETED=true
            render_env "$ENV_FILE"
        ) >/dev/null
        jq '.tari.mode="off" | .tari.clearnet_initial_sync=true' "$scratch/baseline.json" >"$scratch/candidate.json"
        PITHEAD_CONFIG_FILE="$scratch/candidate.json" PITHEAD_ENV_FILE="$scratch/baseline.env" "$cli" apply --dry-run --porcelain
REMOTE
    )" 2>"$err")
    rc=$?
    tari_preview_diagnostic "$rc" "$err"
    rm -f "$err"
    assert_rc "Tari-off combined CLI preview succeeds (#3383)" "$rc" 0
    assert_contains "Tari-off preview confirms disabled merge-mining (#3383)" "$out" "Tari merge-mining OFF"
    assert_contains "Tari-off preview retains chain data (#3383)" "$out" "chain data on disk is KEPT"
    local guidance
    for guidance in 'CLEARNET initial sync' 'tari is recreated' 'node endpoint' 'trusts the chain data'; do
        if [[ "$out" == *"$guidance"* ]]; then
            it_fail "Tari-off preview omits inactive $guidance (#3383)"
        else
            it_pass "Tari-off preview omits inactive $guidance (#3383)"
        fi
    done
}
