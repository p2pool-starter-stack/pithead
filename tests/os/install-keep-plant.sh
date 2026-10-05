#!/usr/bin/env bash
# Streamed to the installer guest; stdout is an image ID only after cleanup succeeds.
set -uo pipefail

step() {
    local name=$1 rc=0
    shift
    printf 'keep-plant: sub-step=%s starting\n' "$name" >&2
    "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'keep-plant: sub-step=%s failed exit=%s\n' "$name" "$rc" >&2
    fi
    return "$rc"
}

T='' mounted=0 old_dash_id=''
cleanup() {
    local rc=$? cleanup_rc=0
    trap - EXIT
    if [ "$mounted" -eq 1 ]; then
        # The temporary graph root must not remain in the planted libpod database.
        step database-cleanup rm -rf "$T/containers/storage/db.sql" "$T/containers/storage/libpod" || cleanup_rc=$?
        step unmount umount "$T" || cleanup_rc=$?
    fi
    [ "$rc" -ne 0 ] || rc=$cleanup_rc
    if [ "$rc" -eq 0 ]; then printf '%s\n' "$old_dash_id"; fi
    exit "$rc"
}
trap cleanup EXIT

write_digest() {
    sha256sum /opt/pithead/images/dashboard.tar.gz | cut -d' ' -f1 | tr -d '\n' >"$T/pithead/data/.loaded-dashboard.tar.gz.sha"
}
lookup_image() {
    local images
    images=$(podman --root "$T/containers/storage" images --format '{{.Repository}} {{.ID}}') || return $?
    old_dash_id=$(printf '%s\n' "$images" | awk '/pithead-dashboard/ && !found {print $2; found=1}')
    [[ "$old_dash_id" =~ ^[0-9a-f]{12,64}$ ]] || {
        printf 'keep-plant: dashboard image ID missing or malformed\n' >&2
        return 1
    }
}

T=$(step mountpoint mktemp -d) || exit $?
step mount mount /dev/vda4 "$T" || exit $?
mounted=1
step directories mkdir -p "$T/pithead/data" "$T/containers/storage" || exit $?
step load podman --root "$T/containers/storage" load -qi /opt/pithead/images/dashboard.tar.gz >/dev/null || exit $?
step digest write_digest || exit $?
step image-lookup lookup_image || exit $?
