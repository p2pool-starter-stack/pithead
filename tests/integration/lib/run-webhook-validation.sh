# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

run_webhook_validation() {
    local cdir="$1" baseline="$2" before containers_before id candidate st result kind
    if ! before="$(rx 'sha256sum config.json .env')" ||
        ! containers_before="$(rx 'docker compose ps -aq | sort | xargs -r docker inspect --format "{{.Id}} {{.State.StartedAt}} {{.RestartCount}}"')" ||
        [ -z "$before" ] || [ -z "$containers_before" ]; then
        it_fail "webhook validation baseline captured (#3388)" "missing config/env or container snapshot"
        return 1
    fi
    assert_eq "webhook trigger baseline is empty (#3388)" \
        "$(printf '%s' "$baseline" | jq -c '.notifications.webhooks')" '[]'
    for kind in energy null mixed; do
        id="$(_uuid4)"
        candidate="$(printf '%s' "$baseline" | jq -c --arg kind "$kind" '
            if $kind != "null" then .dashboard.energy.cost_per_kwh=0.18 else . end
            | if $kind != "energy" then .notifications.webhooks=[null] else . end')"
        _spool_write "$cdir/requests/$id.json" \
            "$(printf '%s' "$candidate" | jq -c --arg id "$id" '{id:$id,action:"preview",actor:"itest",config:.}')"
        st="$(_wait_control_status "$cdir" "$id" "" 90 || echo timeout)"
        result="$(rx "cat $(quote_arg "$cdir/results/$id.json") 2>/dev/null")"
        if [ "$kind" = energy ]; then
            assert_eq "Energy-only webhook control previews (#3388)" "$st" previewed
            assert_eq "Energy-only preview discloses the Energy change (#3388)" \
                "$(printf '%s' "$result" | jq -r 'any(.changes[]?; .key == "dashboard.energy")')" true
        else
            assert_eq "$kind null webhook preview is rejected (#3388)" "$st" rejected
            assert_contains "$kind webhook refusal names its index (#3388)" \
                "$(printf '%s' "$result" | jq -r '.error // ""')" "notifications.webhooks[0]"
            if ! rx "rm -f $(quote_arg "$cdir/results/$id.json")"; then
                it_fail "$kind webhook commit result reset (#3388)" "could not remove the prior preview result"
                return 1
            fi
            _spool_write "$cdir/requests/$id.json" \
                "$(jq -nc --arg id "$id" '{id:$id,action:"commit",actor:"itest",confirm:"APPLY"}')"
            st="$(_wait_control_status "$cdir" "$id" "" 90 || echo timeout)"
            assert_eq "$kind rejected preview cannot commit (#3388)" "$st" rejected
        fi
    done
    assert_eq "webhook refusals preserve config.json and rendered env (#3388)" \
        "$(rx 'sha256sum config.json .env')" "$before"
    assert_eq "webhook previews and refusals preserve container instances (#3388)" \
        "$(rx 'docker compose ps -aq | sort | xargs -r docker inspect --format "{{.Id}} {{.State.StartedAt}} {{.RestartCount}}"')" "$containers_before"
}
