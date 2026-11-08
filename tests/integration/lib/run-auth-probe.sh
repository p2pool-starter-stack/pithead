# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_env_token_cmd() {
    printf '%s' "(
        umask 077
        tmp=\$(mktemp .env.itest.XXXXXX) || exit 1
        trap 'rm -f \"\$tmp\"' EXIT
        awk -v t=$(quote_arg "$1") '/^PROXY_AUTH_TOKEN=/{print \"PROXY_AUTH_TOKEN=\" t; next} {print}' .env > \"\$tmp\" &&
            chown --reference=.env \"\$tmp\" && mv -f \"\$tmp\" .env
    )"
}

_set_env_token() {
    rx "$(_env_token_cmd "$1")"
}

_empty_token_probe() {
    local wait="${AUTH_PROBE_ADMIT_SECS:-300}" hold=1
    case "$IT_PITHEAD" in sudo*) hold=0 ;; esac
    rx "(
        restore() { $(_env_token_cmd "$1"); }
        if [ $hold = 1 ]; then
            lock=\${PITHEAD_LOCK_FILE:-}
            if [ -z \"\$lock\" ]; then
                here=\$(cd -P . && pwd -P)
                if printf '%s' \"\$(basename \"\$here\")\" | grep -Eq '^pithead-v[0-9]+\\.[0-9]+\\.[0-9]+\$'; then
                    lock=\$(dirname \"\$here\")/.pithead.lock
                else
                    lock=\$here/.pithead.lock
                fi
            fi
            exec 9>>\"\$lock\" || { echo 'auth-probe: cannot open the mutation lock'; exit 70; }
            start=\$SECONDS
            if ! flock -w $wait 9; then
                echo 'auth-probe: not admitted within ${wait}s'
                exit 75
            fi
            export PITHEAD_LOCK_HELD=\$\$
            echo \"auth-probe: admitted after \$((SECONDS - start))s\"
        else
            echo 'auth-probe: admitted after 0s without a held window (privileged invocation)'
        fi
        trap restore EXIT
        $(_env_token_cmd '') || { echo 'auth-probe: token replacement failed'; exit 76; }
        if grep -qx 'PROXY_AUTH_TOKEN=' .env; then
            echo 'auth-probe: token empty at evaluation'
        else
            echo 'auth-probe: token not empty at evaluation'
        fi
        $IT_PITHEAD up 2>&1
        rc=\$?
        echo \"auth-probe: up exit \$rc\"
        trap - EXIT
        restore || echo 'auth-probe: token restore failed'
        exit \$rc
    )"
}
