# shellcheck shell=bash

_pred_fresh_tari_synced() {
    local st
    if ! st="$(api_state)" || [ -z "$st" ]; then
        TARI_READINESS_OBSERVATION=read-error
        return 1
    fi
    TARI_READINESS_OBSERVATION="$(jq_get "$st" '.sync.tari.state')"
    [ "$TARI_READINESS_OBSERVATION" = "done" ]
}

# The required-Tari row needs its own post-restart sample. A successful predicate leaves the exact
# sample for the binding verdict; exhaustion remains a failure even if another scenario earned the
# shared post-restart lag tolerance earlier in the run (#746/#3059).
assert_fresh_tari_synced_required() {
    TARI_READINESS_OBSERVATION=read-error
    if wait_for 300 10 "fresh required-Tari sync state" _pred_fresh_tari_synced; then
        assert_tari_synced_required "$TARI_READINESS_OBSERVATION"
    elif [ "$TARI_READINESS_OBSERVATION" = "read-error" ]; then
        it_fail "tari synced (required)" "no readable final /api/state sample within 300s"
    else
        it_fail "tari synced (required)" \
            "expected fresh [done] within 300s, last fresh state [$TARI_READINESS_OBSERVATION]"
    fi
}
