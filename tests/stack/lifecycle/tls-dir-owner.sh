# shellcheck shell=bash disable=SC2034
: "${STACK_SUITE:?source via the stack suite}"
echo "== regression: ensure_directories owns PROXY_TLS_DIR before generating the stratum cert (#4341) =="
tls_order=$(
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
    log() { :; }
    sudo() { return 0; }
    prepare_control_dirs() { :; }
    ensure_owner() { if [ "$1" = "$PROXY_TLS_DIR" ]; then [ "$2:$3" = "$APP_UID:$APP_GID" ] && echo owner || echo owner-wrong; fi; return 0; }
    ensure_stratum_tls_cert() { echo cert; }
    ensure_directories
)
assert_eq "ensure_directories chowns PROXY_TLS_DIR to the app uid before the cert is generated" \
    "$(printf '%s,' $tls_order)" "owner,cert,"
