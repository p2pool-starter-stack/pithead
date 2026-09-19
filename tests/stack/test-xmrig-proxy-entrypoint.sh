# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# xmrig-proxy wrapper-entrypoint domain (#152/#261): the argv build/xmrig-proxy/entrypoint.sh execs.
# Lifted verbatim out of run.sh, which is a domain REGISTRY and had this one block of test content
# inlined in it. Sourced by tests/stack/run.sh.

echo "== unit: xmrig-proxy wrapper entrypoint argv (#152/#261) =="
# xmrig-proxy wrapper entrypoint: optional stratum access-password (#152). The flag moved out of the
# compose command (a `${VAR:+--flag}` list element rendered a stray '' positional arg when the password
# was unset — xmrig-proxy warns `unsupported non-option argument ''`) into this wrapper, which appends
# it only when PROXY_STRATUM_PASSWORD is set. Exercise the real script with a stub xmrig-proxy on PATH
# that echoes its argv, so the set/unset branch is actually run.
XP_ENTRY="$ROOT/build/xmrig-proxy/entrypoint.sh"
xp_argv() { # <password value> -> the argv the wrapper would exec
    local d
    mk_tmpdir d
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD="$1" sh "$XP_ENTRY" --http-no-restricted --donate-level=0
    rm -rf "$d"
}
assert_eq "xmrig-proxy entrypoint: unset password appends no flag (#152)" \
    "$(xp_argv '')" "[--http-no-restricted][--donate-level=0]"
assert_eq "xmrig-proxy entrypoint: set password appends --access-password (#152)" \
    "$(xp_argv 's3cret')" "[--http-no-restricted][--donate-level=0][--access-password=s3cret]"
# #261: the TLS cert flags append only when the toggle is on AND both keypair files exist at the
# mount (PROXY_TLS_MOUNT overrides the fixed /tls so the suite can use a temp dir).
xp_tls_argv() { # <PROXY_STRATUM_TLS value> <tls dir>
    local d
    mk_tmpdir d
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD='' PROXY_STRATUM_TLS="$1" PROXY_TLS_MOUNT="$2" sh "$XP_ENTRY" -b 0.0.0.0:3333
    rm -rf "$d"
}
mk_tmpdir XPTLS
printf 'cert' >"$XPTLS/cert.pem"
printf 'key' >"$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on + keypair appends the cert flags (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333][--tls-cert=$XPTLS/cert.pem][--tls-cert-key=$XPTLS/key.pem]"
assert_eq "xmrig-proxy entrypoint: TLS off appends nothing (#261)" \
    "$(xp_tls_argv false "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -f "$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on but keypair incomplete appends nothing (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -rf "$XPTLS"
