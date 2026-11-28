# shellcheck shell=bash disable=SC2034
: "${STACK_SUITE:?source via the stack suite}"
echo "== regression: apply generates the stratum cert in an existing foreign-owned empty PROXY_TLS_DIR (#4341) =="
if [ "$(id -u)" = 0 ] || [ "$(id -u)" = 1000 ]; then
    echo "  - skipped: needs a non-root caller whose uid differs from APP_UID (1000)"
else
    tls_gen=$(
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        MONERO_DIR="$SANDBOX/tls-monero"
        TARI_DIR="$SANDBOX/tls-tari"
        P2POOL_DIR="$SANDBOX/tls-p2pool"
        TOR_DATA_DIR="$SANDBOX/tls-tor"
        DASHBOARD_DIR="$SANDBOX/tls-dashboard"
        PROXY_TLS_DIR="$SANDBOX/tls-proxy"
        STRATUM_TLS=true
        mkdir -p "$PROXY_TLS_DIR"
        chmod 555 "$PROXY_TLS_DIR"
        log() { :; }
        announce_stratum_tls() { :; }
        prepare_control_dirs() { :; }
        sudo() {
            if [ "$1" = chown ]; then
                chmod -R u+w "${@: -1}"
            fi
            return 0
        }
        stat_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
        crt="$PROXY_TLS_DIR/cert.pem"
        key="$PROXY_TLS_DIR/key.pem"
        ensure_directories >/dev/null 2>&1
        rc=$?
        first=$(cksum "$crt" 2>/dev/null)
        ensure_directories >/dev/null 2>&1
        echo "$rc $(stat_mode "$key") $(stat_mode "$crt") $([ -n "$first" ] && [ "$first" = "$(cksum "$crt")" ] && echo same)"
    )
    assert_eq "apply generates the stratum cert in a foreign-owned empty dir: rc 0, key 600, cert 644, stable across applies" \
        "$tls_gen" "0 600 644 same"
fi
