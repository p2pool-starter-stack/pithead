# shellcheck shell=bash
# Password fixture round trip, sourced by the config-approval leg.
password_fixture_round_trip() {
    # #2367: the password left the physical-presence set and commits behind APPLY + the envelope.
    # Once it applies, Caddy wants the NEW login, so the dashboard's result poll (old login) only
    # sees 401s: read the verdict from the host spool, then restore the fixture password the same
    # way so every later leg still signs in with the credentials it was handed.
    local old_pass="$DASH_PASS"
    password_commit_via_host "os1966-repointed" || return
    DASH_PASS="os1966-repointed" # dashboard_curl reads DASH_USER/DASH_PASS from this frame by dynamic scope
    if ! sensitive_live_config >/dev/null; then
        bad "dashboard did not accept the new password after the commit"
        return
    fi
    password_commit_via_host "$old_pass" || return
    DASH_PASS="$old_pass"
    if ! sensitive_live_config >/dev/null; then
        bad "dashboard did not accept the restored fixture password"
        return
    fi
    ok "dashboard-password repoint commits behind typed APPLY and the new login works"
}
