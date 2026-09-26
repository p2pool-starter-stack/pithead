# shellcheck shell=bash
# Private snapshots for exact rollback of writable live mount sources: a CoW clone where the
# source's filesystem supports it, a full copy otherwise (a named volume's own storage — #2057).

capture_state_snapshots() { # <stateful mount TSV>
    local source parent base snap nonce prior covered kept=""
    nonce="$$-$(date +%s)"
    UPGRADE_STATE_SNAPSHOTS=""
    UPGRADE_STATE_OLD_DIRS=""
    UPGRADE_SNAPSHOT_REASON=""
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        # A named label per sub-check (job 1181's tmpfs fix cleared the mounts filter, but the
        # combined message it fed still hid which of these four steps a NEW failure stops at) —
        # never the source path itself, only the mount's own basename (e.g. "tor", "p2pool").
        if [[ "$source" != /* || "$source" = / ]]; then
            UPGRADE_SNAPSHOT_REASON="not-absolute"
            return 1
        fi
        covered=0
        while IFS= read -r prior; do
            [ -z "$prior" ] || case "$source/" in "$prior/"*) covered=1 ;; esac
        done <<<"$kept"
        [ "$covered" = 0 ] || continue
        parent="$(dirname "$source")" base="$(basename "$source")"
        snap="$parent/.pithead-live-$base-$nonce"
        if ! rx "test -d $(quote_arg "$source")"; then
            UPGRADE_SNAPSHOT_REASON="not-a-directory:$base"
        elif rx "test -L $(quote_arg "$source")"; then
            UPGRADE_SNAPSHOT_REASON="is-a-symlink:$base"
        elif rx "test -e $(quote_arg "$snap")"; then
            UPGRADE_SNAPSHOT_REASON="snapshot-path-exists:$base"
        elif ! rx "sudo -n cp -a --reflink=auto -- $(quote_arg "$source") $(quote_arg "$snap")"; then
            UPGRADE_SNAPSHOT_REASON="copy-failed:$base"
        fi
        if [ -n "$UPGRADE_SNAPSHOT_REASON" ]; then
            rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
            cleanup_state_snapshots
            return 1
        fi
        kept+="${kept:+$'\n'}$source"
        UPGRADE_STATE_SNAPSHOTS+="${UPGRADE_STATE_SNAPSHOTS:+$'\n'}$source"$'\t'"$snap"
    done < <(printf '%s\n' "$1" | cut -f3 | sort -u)
    [ -n "$UPGRADE_STATE_SNAPSHOTS" ] || UPGRADE_SNAPSHOT_REASON="${UPGRADE_SNAPSHOT_REASON:-no-stateful-mounts}"
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
        rx "test -d $(quote_arg "$snap") && test ! -e $(quote_arg "$replacement") && test ! -e $(quote_arg "$old") && sudo -n cp -a --reflink=auto -- $(quote_arg "$snap") $(quote_arg "$replacement")" || {
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
    # v1.20.0, the image gate's baseline, predates control_unit_dir (#2057, job 1152): guard the
    # call rather than requiring it, the same tolerance baseline_up already gives container_engine.
    # A CLI without it never installed the control-runner units either, so the loop below reports
    # them "absent" against an unresolved path, exactly as it does for any other genuinely-missing
    # file — the fingerprint still covers everything that CLI's host state actually has.
    rx 'set -euo pipefail; source ./pithead; d=""; declare -F control_unit_dir >/dev/null && d=$(control_unit_dir); { for p in .env Caddyfile; do [ -f "$p" ] && sha256sum "$p" || exit 1; done; [ -d build ] || exit 1; find build -type f -exec sha256sum {} +; for p in "$d/pithead-control.path" "$d/pithead-control.service" /run/systemd/system/ssh.service.d/pithead.conf /run/pithead-ssh/authorized_keys; do if [ -f "$p" ]; then sudo -n sha256sum "$p" || exit 1; else echo "absent $p"; fi; done; systemctl show -p UnitFileState --value pithead-control.path; systemctl show -p ActiveState --value pithead-control.path; sudo -n passwd -S root | awk "{print \$2}"; } | sort | sha256sum | cut -d" " -f1'
}

# Remove the control-runner units so the restored release's render re-provisions its own. A CLI
# that predates control_unit_dir (v1.20.0, which also turns on errexit when sourced — job 1229
# stopped here) never installed any: the units on the box are the ones the upgraded release put
# there, so ask that release's CLI where, and leave nothing behind that the old one cannot manage.
# Stop and disable the path unit first, the way the product's own removal does: a running unit
# stays active after its file is deleted, and v1.20.0's render never re-provisions it.
reset_control_units_for_render() { # [dir of the release that may have installed them]
    rx "[ \"\$(uname -s)\" = Linux ] || exit 0; ask() { (cd \"\$1\" 2>/dev/null && bash -c 'source ./pithead >/dev/null 2>&1 </dev/null; declare -F control_unit_dir >/dev/null && control_unit_dir' 2>/dev/null); }; d=\$(ask .) || d=\$(ask $(quote_arg "${1:-.}")) || exit 0; [ -n \"\$d\" ] || exit 0; sudo -n systemctl disable --now pithead-control.path >/dev/null 2>&1 || true; sudo -n rm -f \"\$d/pithead-control.path\" \"\$d/pithead-control.service\" && sudo -n systemctl daemon-reload"
}

# --baseline-schema reads a restored older release's DB, which lacks the candidate-only tables the
# post-upgrade read requires (job 1257: the restore's read of v1.20.0's DB came back empty).
dashboard_durable_rows() { # <fixed capture epoch> [--baseline-schema]
    local payload require=--require-current-schema
    [ "${2:-}" != --baseline-schema ] || require=""
    payload="$(base64 <"$HERE/lib/migration-state-probe.py" | tr -d '\n')"
    rx "printf %s $(quote_arg "$payload") | base64 -d | docker exec -i dashboard python3 - $require $(quote_arg "$1")" 2>/dev/null
}

archived_dashboard_durable_rows() { # <archive> <fixed capture epoch>
    local payload
    payload="$(base64 <"$HERE/lib/migration-state-probe.py" | tr -d '\n')"
    rx "d=\$(mktemp -d); cleanup() { rm -rf \"\$d\"; }; trap cleanup EXIT; member=\$(tar -tzf $(quote_arg "$1") | grep '/mining_data.db$'); [ \$(printf '%s\\n' \"\$member\" | grep -c .) = 1 ] && tar -xOf $(quote_arg "$1") \"\$member\" >\"\$d/db\" && printf %s $(quote_arg "$payload") | base64 -d | python3 - $(quote_arg "$2") \"\$d/db\"" 2>/dev/null
}

# Every comparison of durable rows here spans a dashboard recreate (a data_dir carry, an image
# upgrade, the rollback after it), and a recreated dashboard rewrites the volatile kv_store keys
# within seconds: their shape reflects what the new process has seen, not what was carried (#2421).
# So those lines are left out on both sides, in one place. The kv_store-key lines still require
# every key, volatile ones included, to arrive, and kv_store-stable still requires every stable value.
carried_rows() { grep -v '^kv_store-volatile-shape[: ]' || true; }
telemetry_rows_continue() { # <before-lines> <after-lines>
    [ -n "$1" ] && [ -z "$(comm -23 <(printf '%s\n' "$1" | carried_rows | sort) <(printf '%s\n' "$2" | carried_rows | sort))" ]
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

# Which pre-upgrade capture came back empty, and why, in fixed labels and public service names
# only: a ref carries the registry, which can be private topology (#2057, job 1089 reported only
# "stateful mounts or candidate refs are incomplete").
first_party_ref_shapes() { # <service/ref lines> -> service:reason for each ref first_party_registry refuses
    local service ref repo image registry found=""
    while read -r service ref; do
        [ -n "$service" ] || continue
        [ -n "$ref" ] || {
            printf '%s:no-ref\n' "$service"
            continue
        }
        repo="${ref%@*}"
        image="${repo##*/}"
        registry="${repo%/*}"
        # No trailing :tag is not a gap of its own: a container engine reporting a compound
        # tag@digest reference back as a bare digest is normal (first_party_registry's comment),
        # so only the base image name is checked here, matching that function.
        case "$service:${image%%:*}" in
        tor:pithead-tor | monerod:pithead-monero | p2pool:pithead-p2pool | xmrig-proxy:pithead-xmrig-proxy | dashboard:pithead-dashboard) ;;
        *)
            printf '%s:unexpected-image\n' "$service"
            continue
            ;;
        esac
        if [ "$registry" = "$repo" ] || ! [[ "$registry" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
            printf '%s:no-registry\n' "$service"
        elif [ -z "$found" ]; then
            found="$registry"
        elif [ "$found" != "$registry" ]; then
            printf '%s:mixed-registry\n' "$service"
        fi
    done <<<"$1"
}
services_missing_from() { # <service/ref lines> <candidate service/ref lines> -> missing service names
    local service _ref
    while read -r service _ref; do
        [ -n "$service" ] || continue
        awk -v s="$service" '$1==s {f=1} END {exit !f}' <<<"$2" || printf '%s\n' "$service"
    done <<<"$1"
}
upgrade_capture_gaps() { # <mounts> <mounts-rc> <all-refs> <first-refs> <registry> <candidate-refs> <candidate-all-refs>
    local gaps=()
    [ -n "$1" ] || gaps+=("stateful-mounts(exit=$2)")
    [ -n "$3" ] || gaps+=("running-refs")
    [ -n "$4" ] || gaps+=("first-party-refs")
    [ -n "$5" ] || [ -z "$4" ] || gaps+=("baseline-registry($(first_party_ref_shapes "$4" | paste -sd, -))")
    [ -n "$6" ] || [ -z "$4" ] || gaps+=("candidate-first-party(missing:$(services_missing_from "$4" "$UPGRADE_CANDIDATE_ALL_REFS" | paste -sd, -))")
    [ -n "$7" ] || [ -z "$3" ] || gaps+=("candidate-all(missing:$(services_missing_from "$3" "$UPGRADE_CANDIDATE_ALL_REFS" | paste -sd, -))")
    printf '%s\n' "${gaps[*]:-}"
}

# One canonical form for a "service ref" list, so a signed bundle's pin and what a container engine
# reports back compare equal when they name the same bytes (job 158 on a832bc1d): inspect drops
# the tag off a tag@digest ref and expands a short name to docker.io/[library/]. The digest is
# kept whole; only the tag and that registry prefix are dropped.
canonical_refs() { # <service/ref lines>
    local service ref name digest
    while read -r service ref; do
        [ -n "$service" ] || continue
        name="${ref%@*}" digest=""
        [ "$name" = "$ref" ] || digest="@${ref##*@}"
        case "${name##*/}" in *:*) name="${name%:*}" ;; esac
        name="${name#docker.io/}" && name="${name#library/}"
        printf '%s %s%s\n' "$service" "$name" "$digest"
    done <<<"$1" | sort
}

# Which data dir of the baseline resolves inside its own version dir, if any. `pithead upgrade`
# only deploys to a fresh version dir when none does; otherwise it upgrades in place, because the
# new release would re-derive its default paths under the new dir and come up beside its own data
# (44-control-upgrade-and-lifecycle.sh). This gate always stages a fresh dir, so it needs the same
# precondition, or it measures a layout the product refuses (job 158: chain, Tor and dashboard
# dirs re-derived empty under the candidate).
data_dirs_inside_install() { # <install dir> -> the variable names that resolve inside it
    rx "for v in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR; do d=\$(grep -m1 \"^\$v=\" .env | cut -d= -f2-); [ -n \"\$d\" ] || continue; d=\$(cd \"\$d\" 2>/dev/null && pwd -P || printf %s \"\$d\"); case \"\$d\" in $(quote_arg "$1") | $(quote_arg "$1")/*) printf '%s\n' \"\$v\" ;; esac; done"
}

# Which durable-row categories lost lines across the upgrade, as "<category>:<count>" — the probe's
# first field is a table or kv_store class name (migration-state-probe.py), never a value, so it is
# safe to print where the row hashes are not worth printing (job 1206 said only "one or more").
telemetry_rows_lost() { # <before-lines> <after-lines>
    comm -23 <(printf '%s\n' "$1" | carried_rows | sort) <(printf '%s\n' "$2" | carried_rows | sort) |
        awk 'NF { n[$1]++ } END { for (k in n) printf "%s:%d\n", k, n[k] }' | sort | paste -sd, -
}

# Whether the stack directory's CLI defines a function, asked in a contained bash so a CLI that
# turns on errexit when sourced (v1.20.0) cannot abort the caller.
stack_cli_has() { # <function>
    rx "bash -c 'source ./pithead >/dev/null 2>&1 </dev/null; declare -F $1 >/dev/null' 2>/dev/null"
}

# Run one start step in this shell (baseline_up's counted skip must survive), and keep the fixed
# text of its own [ERROR] line if it fails (job 1247 stopped at "render" with
# the output discarded).
start_step() { # <command...>
    local out rc=0
    out="$(mktemp)" || return 1
    "$@" >"$out" 2>&1 || rc=$?
    # Only the message's fixed text: v1.20.0's errors interpolate paths and hosts after a quote or
    # a slash ('/home/<user>', "host"), which redact does not mask, so cut there before redacting.
    [ "$rc" = 0 ] || BASELINE_START_ERROR="$(sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -E '\[ERROR\]|ERROR:' | tail -n1 | sed -E "s#['\"/].*##; s/[[:space:]]+$//" | redact | cut -c1-240)"
    rm -f "$out"
    return "$rc"
}

# Bring the restored baseline back up, one named step at a time; $BASELINE_START_STEP says which
# stopped it (job 1213 reported only "start"). Runs in this shell, not a subshell, so baseline_up's
# counted skip survives.
start_restored_baseline() {
    BASELINE_START_STEP=reset-units BASELINE_START_ERROR=""
    reset_control_units_for_render "$UPGRADE_CANDIDATE_DIR" || return 1
    BASELINE_START_STEP=render
    # `render` arrived after v1.20.0 (job 1256: "Unknown command: render"). A CLI without it has
    # nothing to re-derive: its `restore` already put config.json, .env and Caddyfile back from
    # the archive, and the checks below still compare them exactly.
    if stack_cli_has render_derived; then
        start_step pithead render || return 1
    fi
    BASELINE_START_STEP=up
    start_step baseline_up || return 1
    BASELINE_START_STEP=status
    wait_status_ok 300 || return 1
    BASELINE_START_STEP=worker-set
    wait_for 240 5 "the exact baseline worker set" _pred_worker_set "$UPGRADE_BEFORE_WORKERS" || return 1
    # Stratum hashes reset on a p2pool restart and climb once the proxy reconnects; resettle
    # before the restore samples state, as the pre-upgrade capture does (job 1257 read a cold 0).
    BASELINE_START_STEP=mining
    wait_miner_running || return 1
    wait_stratum_hashes || return 1
    BASELINE_START_STEP=""
}
