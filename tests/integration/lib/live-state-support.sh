# shellcheck shell=bash
# Private CoW snapshots for exact rollback of writable live mount sources.

capture_state_snapshots() { # <stateful mount TSV>
    local source parent base snap nonce prior covered kept=""
    nonce="$$-$(date +%s)"
    UPGRADE_STATE_SNAPSHOTS=""
    UPGRADE_STATE_OLD_DIRS=""
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        [[ "$source" = /* && "$source" != / ]] || return 1
        covered=0
        while IFS= read -r prior; do
            [ -z "$prior" ] || case "$source/" in "$prior/"*) covered=1 ;; esac
        done <<<"$kept"
        [ "$covered" = 0 ] || continue
        parent="$(dirname "$source")" base="$(basename "$source")"
        snap="$parent/.pithead-live-$base-$nonce"
        rx "test -d $(quote_arg "$source") && test ! -L $(quote_arg "$source") && test ! -e $(quote_arg "$snap") && sudo -n cp -a --reflink=always -- $(quote_arg "$source") $(quote_arg "$snap")" || {
            rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
            cleanup_state_snapshots
            return 1
        }
        kept+="${kept:+$'\n'}$source"
        UPGRADE_STATE_SNAPSHOTS+="${UPGRADE_STATE_SNAPSHOTS:+$'\n'}$source"$'\t'"$snap"
    done < <(printf '%s\n' "$1" | cut -f3 | sort -u)
    [ -n "$UPGRADE_STATE_SNAPSHOTS" ]
}

restore_state_snapshots() {
    local source snap replacement old nonce journal=""
    nonce="$$-$(date +%s)"
    while IFS=$'\t' read -r source snap; do
        if [ -z "$source" ] || [ -z "$snap" ] || [[ "$source" != /* || "$source" = / || "$snap" != "$(dirname "$source")/.pithead-live-"* ]]; then
            cleanup_restore_replacements "$journal"
            return 1
        fi
        replacement="$source.pithead-restore-$nonce" old="$source.pithead-old-$nonce"
        rx "test -d $(quote_arg "$snap") && test ! -e $(quote_arg "$replacement") && test ! -e $(quote_arg "$old") && sudo -n cp -a --reflink=always -- $(quote_arg "$snap") $(quote_arg "$replacement")" || {
            cleanup_restore_replacements "$journal"
            return 1
        }
        journal+="${journal:+$'\n'}$source"$'\t'"$replacement"$'\t'"$old"
    done <<<"$UPGRADE_STATE_SNAPSHOTS"
    while IFS=$'\t' read -r source replacement old; do
        # Record the entry BEFORE attempting the swap, never after. The swap can fail in the middle:
        # `mv source old` succeeds, `mv replacement source` fails, and the inner recovery
        # `mv old source` fails too — leaving the live path ABSENT and the only copy of the original
        # data at $old. Recording afterwards means that entry is missing from the very list
        # rollback_restored_state walks, so the one mount that actually needs undoing is the one
        # nothing undoes. Recording first can only over-describe, and rollback_restored_state
        # distinguishes "never swapped" from "swapped" by looking at the box.
        UPGRADE_STATE_OLD_DIRS="$source"$'\t'"$old${UPGRADE_STATE_OLD_DIRS:+$'\n'$UPGRADE_STATE_OLD_DIRS}"
        rx "sudo -n mv -- $(quote_arg "$source") $(quote_arg "$old") && { sudo -n mv -- $(quote_arg "$replacement") $(quote_arg "$source") || { sudo -n mv -- $(quote_arg "$old") $(quote_arg "$source"); false; }; }" || {
            rollback_restored_state
            cleanup_restore_replacements "$journal"
            return 1
        }
    done <<<"$journal"
}

cleanup_restore_replacements() { # <source/replacement/old TSV>
    local _source replacement _old
    while IFS=$'\t' read -r _source replacement _old; do
        [ -z "$replacement" ] || rx "sudo -n rm -rf -- $(quote_arg "$replacement")" >/dev/null 2>&1 || true
    done <<<"$1"
}

# Undo the swaps restore_state_snapshots recorded. Entries are recorded before their swap is
# attempted, so an entry may describe a swap that never happened ($old absent, live path intact) —
# that is a clean no-op, not a failure. An entry with $old absent AND the live path absent is the
# genuinely broken case and must stay loud: the data is somewhere the caller has to be told about.
rollback_restored_state() {
    local source old failed=0 replacement nonce
    nonce="$$-$(date +%s)"
    while IFS=$'\t' read -r source old; do
        [ -z "$old" ] || {
            replacement="$source.pithead-failed-$nonce"
            rx "if test -d $(quote_arg "$old"); then
                    test ! -e $(quote_arg "$replacement") || exit 1
                    if test -e $(quote_arg "$source"); then sudo -n mv -- $(quote_arg "$source") $(quote_arg "$replacement") || exit 1; fi
                    if sudo -n mv -- $(quote_arg "$old") $(quote_arg "$source"); then
                        test ! -e $(quote_arg "$replacement") || sudo -n rm -rf -- $(quote_arg "$replacement")
                    else
                        test ! -e $(quote_arg "$replacement") || sudo -n mv -- $(quote_arg "$replacement") $(quote_arg "$source")
                        exit 1
                    fi
                else
                    test -e $(quote_arg "$source")
                fi" || failed=1
        }
    done <<<"${UPGRADE_STATE_OLD_DIRS:-}"
    [ "$failed" != 0 ] || UPGRADE_STATE_OLD_DIRS=""
    return "$failed"
}

cleanup_state_snapshots() {
    local _source snap
    while IFS=$'\t' read -r _source snap; do
        [ -z "$snap" ] || rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
    done <<<"${UPGRADE_STATE_SNAPSHOTS:-}"
    while IFS=$'\t' read -r _source snap; do
        [ -z "$snap" ] || rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
    done <<<"${UPGRADE_STATE_OLD_DIRS:-}"
}

derived_state_fingerprint() {
    rx 'set -euo pipefail; source ./pithead; d=$(control_unit_dir); { for p in .env Caddyfile; do [ -f "$p" ] && sha256sum "$p" || exit 1; done; [ -d build ] || exit 1; find build -type f -exec sha256sum {} +; for p in "$d/pithead-control.path" "$d/pithead-control.service" /run/systemd/system/ssh.service.d/pithead.conf /run/pithead-ssh/authorized_keys; do if [ -f "$p" ]; then sudo -n sha256sum "$p" || exit 1; else echo "absent $p"; fi; done; systemctl show -p UnitFileState --value pithead-control.path; systemctl show -p ActiveState --value pithead-control.path; sudo -n passwd -S root | awk "{print \\$2}"; } | sort | sha256sum | cut -d" " -f1'
}

reset_control_units_for_render() {
    rx 'source ./pithead; [ "$OS_TYPE" != Linux ] || { d=$(control_unit_dir); sudo -n rm -f "$d/pithead-control.path" "$d/pithead-control.service" && sudo -n systemctl daemon-reload; }'
}

dashboard_durable_rows() { # <fixed capture epoch>
    local payload
    payload="$(base64 <"$HERE/lib/migration-state-probe.py" | tr -d '\n')"
    rx "printf %s $(quote_arg "$payload") | base64 -d | docker exec -i dashboard python3 - --require-current-schema $(quote_arg "$1")" 2>/dev/null
}

archived_dashboard_durable_rows() { # <archive> <fixed capture epoch>
    local payload
    payload="$(base64 <"$HERE/lib/migration-state-probe.py" | tr -d '\n')"
    rx "d=\$(mktemp -d); cleanup() { rm -rf \"\$d\"; }; trap cleanup EXIT; member=\$(tar -tzf $(quote_arg "$1") | grep '/mining_data.db$'); [ \$(printf '%s\\n' \"\$member\" | grep -c .) = 1 ] && tar -xOf $(quote_arg "$1") \"\$member\" >\"\$d/db\" && printf %s $(quote_arg "$payload") | base64 -d | python3 - $(quote_arg "$2") \"\$d/db\"" 2>/dev/null
}

telemetry_rows_continue() { # <before-lines> <after-lines>
    [ -n "$1" ] && [ -z "$(comm -23 <(printf '%s\n' "$1" | sort) <(printf '%s\n' "$2" | sort))" ]
}

proxy_active_route() {
    rx "docker exec dashboard python3 -c 'import json;from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient;from mining_dashboard.config.config import PROXY_HOST,PROXY_API_PORT,PROXY_AUTH_TOKEN;c=XMRigProxyClient(PROXY_HOST,PROXY_API_PORT,PROXY_AUTH_TOKEN).get_config();p=next((p for p in c.get(\"pools\",[]) if p.get(\"enabled\")),{});print(json.dumps({\"url\":p.get(\"url\",\"\"),\"socks5\":p.get(\"socks5\",\"\")}))' 2>/dev/null"
}
proxy_active_pool() { proxy_active_route | jq -r '.url // empty' 2>/dev/null; }
proxy_active_socks5() { proxy_active_route | jq -r '.socks5 // empty' 2>/dev/null; }

_pred_proxy_route() { # <mode-substring> <active-pool-url>
    local st
    st="$(api_state)"
    [[ "$(jq_get "$st" '.hashrate.mode_name')" == *"$1"* ]] &&
        [ "$(proxy_active_pool)" = "$2" ] &&
        [ "$(jq_get "$st" '.proxy_workers')" -gt 0 ] 2>/dev/null
}

_pred_xvb_feed_fresh() {
    local st ts
    st="$(api_state)"
    ts="$(rx 'curl -fsS --max-time 8 http://127.0.0.1:8000/api/xvb-standby 2>/dev/null' | jq -r '(.ts // 0) | floor' 2>/dev/null)"
    [ "$(jq_get "$st" '.hashrate.xvb_stale')" = "false" ] &&
        [ "${ts:-0}" -gt "$XVB_FEED_TS_BEFORE" ] 2>/dev/null
}

_pred_xvb_routed_visible() {
    local st routed
    st="$(api_state)"
    routed="$(jq_get "$st" '.hashrate.xvb_routed_1h')"
    [[ "$(jq_get "$st" '.hashrate.mode_name')" == *XVB* ]] &&
        [ "$(jq_get "$st" '.shares_window.count')" -gt 0 ] 2>/dev/null &&
        [ -n "$routed" ] && [ "$routed" != "0.00 H/s" ]
}
