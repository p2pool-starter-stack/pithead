# shellcheck shell=bash
egress_boot_unit_state() {
    local u="${1:-pithead-egress.service}" s="" rc=0 err
    err="$(mktemp)"
    for _ in 1 2 3; do
        s="$(on_bench "s=\$(systemctl show -p LoadState --value $u 2>/dev/null); case \"\$s\" in '') systemctl cat $u >/dev/null 2>&1 && echo present ;; not-found) echo absent ;; *) echo present ;; esac" 2>"$err")" && rc=0 || rc=$?
        [ -n "$s" ] && break || sleep "${UNIT_STATE_RETRY_DELAY:-3}"
    done
    [ -n "$s" ] || warn "unit state: $u unread after 3 attempts (bench command exit $rc, stderr: $(head -c 200 "$err" | tr '\n' ' '))  (#3814)." >&2
    rm -f "$err"
    printf '%s' "$s"
}
