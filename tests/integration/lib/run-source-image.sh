# shellcheck shell=bash
# Exercise upgrade's image guard with real Docker, after a build moves a live service's tag.
source_image_reconcile_snippet() {
    cat <<'PROBE'
    set -Eeuo pipefail
    source ./pithead
    export STACK_VERSION=dev
    mutation_lock_acquire upgrade
    ref=$(docker compose config --format json | jq -er '.services["xmrig-proxy"].image')
    old_cid=$(docker compose ps -q xmrig-proxy)
    [ -n "$old_cid" ]
    old_id=$(docker inspect --format '{{.Image}}' "$old_cid")
    [ "$(docker image inspect --format '{{.Id}}' "$ref")" = "$old_id" ]
    owner=$(pwd -P)
    fixture=$(mktemp -d "${TMPDIR:?runner must provide scratch storage}/pithead-source-image.XXXXXX")
    backup_ref="pithead-source-image-backup:${fixture##*/}"
    new_id=""
    cleanup() {
        local rc=$?
        trap - EXIT
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
    docker image tag "$old_id" "$backup_ref"
    # A label-only build keeps the actual proxy binary/config while producing a distinct image ID.
    printf 'FROM %s\nLABEL pithead.test.source-image="%s"\n' "$ref" "${fixture##*/}" >"$fixture/Dockerfile"
    docker build --pull=false -q -t "$ref" "$fixture"
    new_id=$(docker image inspect --format '{{.Id}}' "$ref")
    [ "$new_id" != "$old_id" ]
    [ "$(docker compose ps -q xmrig-proxy)" = "$old_cid" ]
    [ "$(docker inspect --format '{{.Image}}' "$old_cid")" = "$old_id" ]
    [ "$(docker inspect --format '{{.State.Running}}' "$old_cid")" = true ]
    printf '%s\n' 'source-image: live old image differs from built declaration'
    # Call the same post-build guard as stack_upgrade, without an intervening Compose up.
    reconcile_source_upgrade_images
    cid=$(docker compose ps -q xmrig-proxy)
    [ -n "$cid" ] && [ "$cid" != "$old_cid" ]
    [ "$(docker inspect --format '{{.Image}}' "$cid")" = "$new_id" ]
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
