# shellcheck shell=bash
# Password round-trip cleanup: preserve failed assertions while restoring later legs' login.
_password_fixture_exercise() {
    local old_pass="$DASH_PASS"
    password_commit_via_host "os1966-repointed" || return 1
    DASH_PASS="os1966-repointed"
    if ! sensitive_live_config >/dev/null; then
        bad "dashboard did not accept the new password after the commit"
        return 1
    fi
    password_commit_via_host "$old_pass" || return 1
    DASH_PASS="$old_pass"
    if ! sensitive_live_config >/dev/null; then
        bad "dashboard did not accept the restored fixture password"
        return 1
    fi
}

password_fixture_round_trip() {
    local old_pass="$DASH_PASS" rc=0
    local DASH_PASS="$old_pass"
    # Snapshot after the hostname leg, before any password commit (even one with a lost verdict).
    approval_capture_restore_snapshot || {
        bad "dashboard-password fixture snapshot failed before the commit"
        return 1
    }
    _password_fixture_exercise || rc=1
    # The existing host restore waits for every queued/claimed request before applying. A lost
    # preview can finish staging, but is never committed as part of this cleanup.
    approval_restore_pending || {
        bad "dashboard-password fixture cleanup failed to restore the original configuration"
        return 1
    }
    DASH_PASS="$old_pass"
    sensitive_live_config >/dev/null || {
        bad "dashboard-password fixture cleanup left the original login unavailable"
        return 1
    }
    ok "dashboard-password fixture cleanup restores authenticated dashboard availability"
    [ "$rc" -eq 0 ] || return 1
    ok "dashboard-password repoint commits behind typed APPLY and the new login works"
}

_password_fixture_self_test() (
    local DASH_PASS=original changed=0 commits=0 restored=0 reads=0 errors=0 successes=0 shape
    approval_capture_restore_snapshot() { [ "$shape" != snapshot-fail ]; }
    password_commit_via_host() {
        commits=$((commits + 1))
        changed=1 # even a failed/lost verdict may follow a real credential change
        [ "$shape" != first-fail ] || return 1
        [ "$commits" -ne 2 ] || [ "$shape" != restoration-preview-fail ] || return 1
    }
    sensitive_live_config() {
        reads=$((reads + 1))
        [ "$DASH_PASS" != os1966-repointed ] || [ "$shape" != new-login-fail ] || return 1
        [ "$shape" != restored-login-fail ] || [ "$DASH_PASS" != original ] || [ "$restored" -gt 0 ] || return 1
        [ "$shape" != cleanup-login-fail ] || [ "$restored" -eq 0 ]
    }
    approval_restore_pending() {
        restored=$((restored + 1))
        [ "$shape" != cleanup-fail ] || return 1
        changed=0
    }
    bad() { errors=$((errors + 1)); }
    ok() { successes=$((successes + 1)); }
    for shape in first-fail restoration-preview-fail new-login-fail restored-login-fail; do
        changed=0 commits=0 restored=0 reads=0 errors=0 successes=0
        ! password_fixture_round_trip || return 1
        [ "$changed" -eq 0 ] && [ "$restored" -eq 1 ] && [ "$DASH_PASS" = original ] || return 1
        [ "$reads" -gt 0 ] && [ "$successes" -eq 1 ] || return 1
    done
    for shape in cleanup-fail cleanup-login-fail; do
        changed=0 commits=0 restored=0 errors=0 successes=0
        ! password_fixture_round_trip || return 1
        [ "$errors" -gt 0 ] && [ "$successes" -eq 0 ] || return 1
    done
    shape=snapshot-fail commits=0 restored=0
    ! password_fixture_round_trip && [ "$commits" -eq 0 ] && [ "$restored" -eq 0 ] || return 1
    shape=success changed=0 commits=0 restored=0 errors=0 successes=0
    password_fixture_round_trip || return 1
    [ "$changed" -eq 0 ] && [ "$commits" -eq 2 ] && [ "$restored" -eq 1 ] &&
        [ "$errors" -eq 0 ] && [ "$successes" -eq 2 ] && [ "$DASH_PASS" = original ]
)

_control_preview_retry_self_test() (
    local dir shape route result rc count fixture_id=12345678-1234-4234-8234-123456789abc
    dir=$(mktemp -d "${TMPDIR:-/tmp}/control-preview-retry.XXXXXX") || return 1
    trap 'rm -rf "$dir"' EXIT
    date() { cat "$dir/now"; }
    sleep() { [ "$shape" != elapsed ] || printf 200 >"$dir/now"; }
    control_request_guest_evidence() { :; }
    dashboard_control_post() {
        local n
        n=$(cat "$dir/count")
        n=$((n + 1))
        printf '%s' "$n" >"$dir/count"
        [ "$n" -ne 2 ] || [ "$3" = 10 ] || return 99
        case "$shape" in
        trackable)
            printf '{"id":"%s","status":"previewed"}\n200' "$fixture_id"
            return 56
            ;;
        partial-refusal)
            printf '\n401'
            return 56
            ;;
        refused)
            printf '{"error":"refused"}\n401'
            return 0
            ;;
        error)
            printf '{"error":"failed"}\n500'
            return 0
            ;;
        esac
        if [ "$n" -eq 1 ] || [ "$shape" = exhausted ]; then
            if [ "$shape" = proxy ]; then printf '\n502'; else
                printf '\n000'
                return 56
            fi
        else
            printf '{"id":"%s","status":"previewed"}\n200' "$fixture_id"
        fi
    }
    printf 100 >"$dir/now"
    for shape in lost proxy; do
        printf 0 >"$dir/count"
        result=$(dashboard_control_request preview '{"config":{}}' 10 2>"$dir/log") || return 1
        [ "$(cat "$dir/count")" -eq 2 ] && [ "$(jq -r '.id + ":" + .status' <<<"$result")" = "$fixture_id:previewed" ] || return 1
        [ "$(grep -c '"stage":"post"' "$dir/log")" -eq 2 ] || return 1
    done
    shape=trackable
    printf 0 >"$dir/count"
    result=$(dashboard_control_request preview '{"config":{}}' 10 2>"$dir/log") || return 1
    [ "$(cat "$dir/count")" -eq 1 ] && [ "$(jq -r '.id + ":" + .status' <<<"$result")" = "$fixture_id:previewed" ] || return 1
    grep -Fq '"curl":56' "$dir/log" || return 1
    for shape in refused partial-refusal error exhausted elapsed; do
        printf 0 >"$dir/count"
        printf 100 >"$dir/now"
        rc=0
        result=$(dashboard_control_request preview '{"config":{}}' 10 2>"$dir/log") || rc=$?
        count=1
        [ "$shape" != exhausted ] || count=3
        [ "$rc" -eq 1 ] && [ -z "$result" ] && [ "$(cat "$dir/count")" -eq "$count" ] || return 1
    done
    shape=lost
    printf 100 >"$dir/now"
    for route in preview commit backup; do
        printf 0 >"$dir/count"
        rc=0
        result=$(dashboard_control_request "$route" '{"config":{}}' 0 2>"$dir/log") || rc=$?
        [ "$rc" -eq 1 ] && [ -z "$result" ] && [ "$(cat "$dir/count")" -eq 1 ] || return 1
    done
)
