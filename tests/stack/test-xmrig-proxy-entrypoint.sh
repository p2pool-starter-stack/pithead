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

echo "== p2pool and xmrig-proxy entrypoints rate-limit only their known retry lines (#4159) =="
RL_BIN="$SANDBOX/retry-filter/bin"
mkdir -p "$RL_BIN"
cat >"$RL_BIN/emit" <<'STUB'
#!/bin/sh
for i in 1 2 3 4 5; do echo "$RL_RETRY"; done
echo "ERROR real failure"
echo "$RL_RETRY"
echo "partial-no-newline" | tr -d '\n'
exit "${RL_EXIT:-0}"
STUB
chmod +x "$RL_BIN/emit"
rl_once="" rl_hidden="" rl_err="" rl_tail="" rl_rc="" rl_term=""
for svc in p2pool xmrig-proxy; do
    cp "$RL_BIN/emit" "$RL_BIN/$svc"
    case $svc in
    p2pool) retry="NOTICE monerod is not synchronized, trying again in 1 second" ;;
    *) retry='net 10.0.0.1:3333 connect error: "connection refused"' ;;
    esac
    rl_sh='bash'
    [ "$svc" != xmrig-proxy ] || rl_sh='sh'
    out=$(PATH="$RL_BIN:$PATH" RL_RETRY="$retry" RL_EXIT=7 "$rl_sh" "$ROOT/build/$svc/entrypoint.sh" --flag 2>&1)
    rc=$?
    rl_once="$rl_once $svc:$(printf '%s\n' "$out" | grep -cF -e "$retry")"
    rl_hidden="$rl_hidden $svc:$(printf '%s\n' "$out" | grep -c 'similar lines hidden')"
    rl_err="$rl_err $svc:$(printf '%s\n' "$out" | grep -c 'ERROR real failure')"
    rl_tail="$rl_tail $svc:$(printf '%s\n' "$out" | grep -c 'partial-no-newline')"
    rl_rc="$rl_rc $svc:$rc"
    rm -f "$RL_BIN/pidfile" "$RL_BIN/termfile"
    printf '#!/bin/sh\necho $$ >"%s/pidfile"\ntrap '"'"'echo term >"%s/termfile"; exit 0'"'"' TERM\nwhile :; do sleep 0.2; done\n' "$RL_BIN" "$RL_BIN" >"$RL_BIN/$svc"
    PATH="$RL_BIN:$PATH" "$rl_sh" "$ROOT/build/$svc/entrypoint.sh" >/dev/null 2>&1 &
    rl_pid=$!
    for _ in $(seq 1 50); do
        [ -s "$RL_BIN/pidfile" ] && break
        sleep 0.1
    done
    rl_same=no
    [ "$(readlink "/tmp/$svc.proc")" = "/proc/$(cat "$RL_BIN/pidfile" 2>/dev/null)" ] && rl_same=yes
    kill -TERM "$rl_pid" 2>/dev/null
    wait "$rl_pid" 2>/dev/null
    rl_term="$rl_term $svc:$rl_same:$(cat "$RL_BIN/termfile" 2>/dev/null)"
    rm -f "/tmp/$svc.proc"
done
assert_eq "known retry line shows once per minute" "${rl_once# }" "p2pool:1 xmrig-proxy:1"
assert_eq "hidden repeats are counted" "${rl_hidden# }" "p2pool:1 xmrig-proxy:1"
assert_eq "a non-retry error line passes through" "${rl_err# }" "p2pool:1 xmrig-proxy:1"
assert_eq "a final line without a newline passes through" "${rl_tail# }" "p2pool:1 xmrig-proxy:1"
assert_eq "the child's exit status propagates" "${rl_rc# }" "p2pool:7 xmrig-proxy:7"
assert_eq "the proc link names the daemon and TERM to the wrapper reaches it" "${rl_term# }" "p2pool:yes:term xmrig-proxy:yes:term"
