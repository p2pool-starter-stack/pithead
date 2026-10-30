# shellcheck shell=bash
# shellcheck disable=SC2034
NO_DEPLOYMENT_ELIGIBLE=0
NO_DEPLOYMENT_MUTATION_STARTED=0
NO_DEPLOYMENT_DIR=""
NO_DEPLOYMENT_JOB=""
NO_DEPLOYMENT_INVOCATION=""
NO_DEPLOYMENT_SHA=""

no_deployment_init() {
    local requested="${E2E_NO_DEPLOY_DIR:-}${E2E_JOB_ID:-}${E2E_INVOCATION_ID:-}${E2E_CANDIDATE_SHA:-}" actual
    [ -n "$requested" ] || return 0
    [[ "${E2E_JOB_ID:-}" =~ ^[1-9][0-9]{0,19}$ ]] || return 1
    [[ "${E2E_INVOCATION_ID:-}" =~ ^[0-9a-f]{32}$ ]] || return 1
    [[ "${E2E_CANDIDATE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
    [[ "${E2E_NO_DEPLOY_DIR:-}" = /* ]] || return 1
    [ -d "$E2E_NO_DEPLOY_DIR" ] && [ ! -L "$E2E_NO_DEPLOY_DIR" ] || return 1
    actual=$(git -C "$HERE/../.." rev-parse HEAD) || return 1
    [ "$actual" = "$E2E_CANDIDATE_SHA" ] || return 1
    NO_DEPLOYMENT_DIR=$(cd -P "$E2E_NO_DEPLOY_DIR" && pwd) || return 1
    [ ! -e "$NO_DEPLOYMENT_DIR/no-deployment.json" ] && [ ! -L "$NO_DEPLOYMENT_DIR/no-deployment.json" ] || return 1
    (umask 077 && mkdir "$NO_DEPLOYMENT_DIR/.no-deployment-claim") || return 1
    NO_DEPLOYMENT_JOB=$E2E_JOB_ID
    NO_DEPLOYMENT_INVOCATION=$E2E_INVOCATION_ID
    NO_DEPLOYMENT_SHA=$E2E_CANDIDATE_SHA
    NO_DEPLOYMENT_ELIGIBLE=1
}

no_deployment_candidate_matches() {
    [ "$NO_DEPLOYMENT_ELIGIBLE" = 1 ] || return 0
    local actual
    actual=$(on_bench "git -C $(quote_arg "$E2E_DIR") rev-parse HEAD") || return 1
    [ "$actual" = "$NO_DEPLOYMENT_SHA" ]
}

no_deployment_invalidate() {
    NO_DEPLOYMENT_ELIGIBLE=0
    NO_DEPLOYMENT_MUTATION_STARTED=1
}

no_deployment_refuse() {
    [ "$NO_DEPLOYMENT_MUTATION_STARTED" = 0 ] || die "No-deployment proof refused after the mutation boundary."
    RESTORED=1
    if [ "$NO_DEPLOYMENT_ELIGIBLE" = 1 ]; then
        NO_DEPLOYMENT_ELIGIBLE=0
        if ! (
            umask 077
            printf '{"schema_version":1,"job_id":"%s","invocation_id":"%s","candidate_sha":"%s","status":"refused","reason_code":"restore_compatibility_unverified","baseline_mutated":false}\n' \
                "$NO_DEPLOYMENT_JOB" "$NO_DEPLOYMENT_INVOCATION" "$NO_DEPLOYMENT_SHA" >"$NO_DEPLOYMENT_DIR/.no-deployment-claim/receipt.tmp" &&
                mv "$NO_DEPLOYMENT_DIR/.no-deployment-claim/receipt.tmp" "$NO_DEPLOYMENT_DIR/no-deployment.json"
        ); then
            die "No-deployment receipt unavailable; baseline state remains unknown to the caller."
        fi
    fi
    die "Candidate cannot restore the baseline configuration; refused before backup or deployment."
}

prepare_candidate() {
    if [ "$MODE" != check ]; then
        if ! no_deployment_candidate_matches; then
            RESTORED=1
            die "Candidate checkout does not match the no-deployment binding."
        fi
        if ! on_bench "cd $(quote_arg "$E2E_DIR") && python3 - config.json $(quote_arg "$CANONICAL_DIR/config.json")" <"$HERE/tools/check-restore-version.py"; then
            no_deployment_refuse
        fi
        ok "candidate can restore the baseline configuration version"
    fi
    no_deployment_invalidate
    on_bench "bash $(quote_arg "$E2E_DIR/scripts/build-pithead.sh") >/dev/null" || die "Failed to build the candidate CLI."
}
