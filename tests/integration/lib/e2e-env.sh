# shellcheck shell=bash
# bench-ci's tier4-e2e reads this line to tell a bench abort from a branch failure (docs/dev/integration-testing.md).
E2E_ENV_SENT=""
e2e_env() { # <key>
    case "$1" in
    workers-offline | tari-not-done | tari-sync-timeout | readiness | chains-behind) ;;
    *) return 1 ;;
    esac
    [ -z "$E2E_ENV_SENT" ] || return 0
    E2E_ENV_SENT="$1"
    printf 'e2e-env: %s\n' "$1"
}
