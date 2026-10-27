# shellcheck shell=bash
# Read only fixed booleans/enums, never snapshot values or endpoint/credential strings.
lifecycle_gate_snippet() {
    cat <<'SAMPLE'
    lifecycle_gate_sample_target() {
    local stage=$1 state running p2pool=unknown proxy=unknown
    state=$(timeout --kill-after=2 10 docker compose exec -T dashboard python3 -c '
import json, os, sqlite3
marker = "present" if os.path.exists("/data/sync-gate-reset") else "absent"
release = "unavailable"
try:
    with sqlite3.connect("file:/data/mining_data.db?mode=ro", uri=True, timeout=1) as db:
        row = db.execute("SELECT substr(value, 1, 2097153) FROM kv_store WHERE key = ?", ("snapshot_latest_data",)).fetchone()
    if row is None:
        release = "missing"
    elif len(row[0]) <= 2097152:
        snapshot = json.loads(row[0])
        value = snapshot.get("miner_released")
        release = "true" if value is True else "false" if value is False else "missing"
except Exception:
    pass
print("marker=" + marker + " snapshot_release=" + release)
' 2>/dev/null) || state='marker=unknown snapshot_release=unavailable'
    if running=$(timeout --kill-after=2 10 docker compose ps --services --status running 2>/dev/null); then
        p2pool=stopped proxy=stopped
        grep -Fxq p2pool <<<"$running" && p2pool=running
        grep -Fxq xmrig-proxy <<<"$running" && proxy=running
    fi
    printf 'lifecycle-gate: %s %s p2pool=%s proxy=%s\n' "$stage" "$state" "$p2pool" "$proxy"
}
SAMPLE
}

retain_lifecycle_gate_samples() { # Only the sampler's fixed grammar is publishable.
    grep -E '^lifecycle-gate: (before-wizard-defaults|after-wizard-up|before-wizard-restore|after-wizard-restore-apply|before-restart|after-restart|before-setup|after-setup|after-up|after-apply|after-no-change|before-image-down|after-image-up|before-source-image) marker=(present|absent|unknown) snapshot_release=(true|false|missing|unavailable) p2pool=(running|stopped|unknown) proxy=(running|stopped|unknown)$' | head -n 10 || true
}

lifecycle_gate_sample() {
    local out
    out=$(rx "$(lifecycle_gate_snippet)
lifecycle_gate_sample_target $(quote_arg "$1")" 2>/dev/null) || out=""
    out=$(printf '%s\n' "$out" | retain_lifecycle_gate_samples)
    if [ -z "$out" ]; then
        out="lifecycle-gate: $1 marker=unknown snapshot_release=unavailable p2pool=unknown proxy=unknown"
    fi
    printf '%s\n' "$out" | retain_lifecycle_gate_samples >>"$OUT_DIR/lifecycle-gate.log"
}

# Exercise upgrade's image guard with real Docker, after a build moves a live service's tag.
source_image_reconcile_snippet() {
    cat <<'PROBE'
    set -Eeuo pipefail
    stage=cli-load
    trap 'rc=$?; [ "$rc" -eq 0 ] || printf "source-image: diagnostic: failed at %s\n" "$stage" >&2' EXIT
    source ./pithead
    export STACK_VERSION=dev
    stage=mutation-lock
    mutation_lock_acquire upgrade
    stage=compose-ref
    ref=$(docker compose config --format json | jq -er '.services["xmrig-proxy"].image')
    stage=live-container
    old_cid=$(docker compose ps -q xmrig-proxy)
    [ -n "$old_cid" ]
    stage=live-image
    old_id=$(docker inspect --format '{{.Image}}' "$old_cid")
    stage=declared-image
    [ "$(docker image inspect --format '{{.Id}}' "$ref")" = "$old_id" ]
    owner=$(pwd -P)
    stage=scratch
    fixture=$(mktemp -d "${TMPDIR:?runner must provide scratch storage}/pithead-source-image.XXXXXX")
    backup_ref="pithead-source-image-backup:${fixture##*/}"
    new_id=""
    cleanup() {
        local rc=$?
        trap - EXIT
        [ "$rc" -eq 0 ] || printf "source-image: diagnostic: failed at %s\n" "$stage" >&2
        # Even a failed assertion must put the declaration and live image back before later phases.
        if docker image tag "$backup_ref" "$ref" && reconcile_source_upgrade_images &&
            [ "$(docker inspect --format '{{.Image}}' "$(docker compose ps -q xmrig-proxy)")" = "$old_id" ]; then
            printf '%s\n' 'source-image: original image restored'
            docker image rm "$backup_ref" >/dev/null || rc=1
        else
            rc=1
        fi
        [ -z "$new_id" ] || docker image rm "$new_id" >/dev/null || rc=1
        rm -rf -- "$fixture"
        exit "$rc"
    }
    trap cleanup EXIT
    # Keep the restore image named after the build replaces its tag and recreation removes its container.
    stage=backup-tag
    docker image tag "$old_id" "$backup_ref"
    # A label-only build keeps the actual proxy binary/config while producing a distinct image ID.
    printf 'FROM %s\nLABEL pithead.test.source-image="%s"\n' "$ref" "${fixture##*/}" >"$fixture/Dockerfile"
    stage=build
    docker build --pull=false -q -t "$ref" "$fixture"
    stage=stale-live-image
    new_id=$(docker image inspect --format '{{.Id}}' "$ref")
    [ "$new_id" != "$old_id" ]
    [ "$(docker compose ps -q xmrig-proxy)" = "$old_cid" ]
    [ "$(docker inspect --format '{{.Image}}' "$old_cid")" = "$old_id" ]
    [ "$(docker inspect --format '{{.State.Running}}' "$old_cid")" = true ]
    printf '%s\n' 'source-image: live old image differs from built declaration'
    # Call the same post-build guard as stack_upgrade, without an intervening Compose up.
    stage=reconcile
    reconcile_source_upgrade_images
    cid=$(docker compose ps -q xmrig-proxy)
    [ -n "$cid" ] && [ "$cid" != "$old_cid" ]
    [ "$(docker inspect --format '{{.Image}}' "$cid")" = "$new_id" ]
    stage=compose-owner
    [ "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid")" = "$owner" ]
    printf '%s\n' 'source-image: guarded recreate matches declared image and Compose owner'
PROBE
}

run_source_image_reconcile() {
    if ! rx 'test -f dashboard/Dockerfile'; then
        it_skip_leg "source upgrade image reconciliation (#2934)" "release install: no local builds" "by-design"
        return 0
    fi
    local out rc before="$IT_FAIL"
    lifecycle_gate_sample before-source-image
    assert_mining_probe_ready "source image fixture (bench-ci#1276)"
    it_step "building a new proxy declaration while its old image remains live (#2934)…"
    out="$(rx "$(source_image_reconcile_snippet)" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | redact >"$OUT_DIR/source-image-reconcile.log"
    assert_rc "source upgrade image reconciliation and cleanup (#2934)" "$rc" 0
    assert_contains "source upgrade fixture starts with a real stale live image (#2934)" "$out" \
        'source-image: live old image differs from built declaration'
    assert_contains "source upgrade recreates through the guarded path (#2934)" "$out" \
        'Recreating xmrig-proxy: its container still uses the previous image.'
    assert_contains "source upgrade proves immutable image and Compose owner (#2934)" "$out" \
        'source-image: guarded recreate matches declared image and Compose owner'
    assert_contains "source upgrade fixture restores its original image (#2934)" "$out" \
        'source-image: original image restored'
    if [ "$IT_FAIL" -eq "$before" ]; then
        if wait_status_ok 240; then
            it_pass "status OK after source image fixture restoration (#2934)"
            return 0
        fi
        it_fail "status OK after source image fixture restoration (#2934)" "stack did not recover"
    fi
    capture_artifacts "source-image-reconcile" "$OUT_DIR"
    return 1
}
