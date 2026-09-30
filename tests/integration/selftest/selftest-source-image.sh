#!/usr/bin/env bash
# The live fixture must reject a missing recreate or wrong owner, and restore even on failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$HERE/../lib/run-source-image.sh"
echo "== source upgrade stale-image reconciliation and failure cleanup (#2934) =="
td=$(mktemp -d)
trap 'rm -rf -- "$td"' EXIT
mkdir -p "$td/bin" "$td/stack" "$td/scratch"
# Read the real reconciler; only Docker and guarded up are substituted in this pure selftest.
sed -n '/^reconcile_source_upgrade_images() {$/,/^}$/p' "$HERE/../../../lib/pithead/03-release-verify.sh" >"$td/stack/pithead"
cat >>"$td/stack/pithead" <<'CLI'
mutation_lock_acquire() { :; }
log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
compose_up_checked() {
    [ "$*" = '-d --no-deps --force-recreate xmrig-proxy' ] || return 1
    [ "$CASE" != no-recreate ] || return 0
    cp "$STATE/declared" "$STATE/live"
    printf recreated >"$STATE/cid"
}
CLI
cat >"$td/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
'compose config --format json') printf '%s\n' '{"services":{"xmrig-proxy":{"image":"proxy:dev"}}}' ;;
'compose config --services') echo xmrig-proxy ;;
'compose ps -q xmrig-proxy'|'compose ps -a -q xmrig-proxy') cat "$STATE/cid" ;;
'image inspect --format {{.Id}} proxy:dev') cat "$STATE/declared" ;;
'inspect --format {{.Image}} '*) cat "$STATE/live" ;;
'inspect --format {{.State.Running}} '*) echo true ;;
'inspect --format {{index .Config.Labels "com.docker.compose.project.working_dir"}} '*)
    if [ "$CASE" = wrong-owner ]; then echo /wrong; else pwd -P; fi ;;
'build --pull=false -q -t proxy:dev '*)
    [ "$CASE" != build-fails ] || exit 1
    grep -q '^FROM proxy:dev$' "${@: -1}/Dockerfile"
    echo new >"$STATE/declared" ;;
'image tag old proxy:dev') echo old >"$STATE/declared" ;;
'image rm new') [ "$(cat "$STATE/live")" = old ] && touch "$STATE/removed" ;;
*) printf 'unexpected Docker call: %s\n' "$*" >&2; exit 1 ;;
esac
DOCKER
chmod +x "$td/bin/docker"
source_image_reconcile_snippet >"$td/probe.sh"
for CASE in success no-recreate wrong-owner build-fails; do
    export CASE STATE="$td/state-$CASE"
    mkdir "$STATE"
    printf old >"$STATE/declared"
    printf old >"$STATE/live"
    printf original >"$STATE/cid"
    rc=0
    (cd "$td/stack" && PATH="$td/bin:$PATH" TMPDIR="$td/scratch" bash "$td/probe.sh") >"$td/$CASE.log" 2>&1 || rc=$?
    [ "$(cat "$STATE/declared")" = old ] && [ "$(cat "$STATE/live")" = old ]
    grep -q 'source-image: original image restored' "$td/$CASE.log"
    if [ "$CASE" = success ]; then
        [ "$rc" -eq 0 ]
        grep -q 'source-image: live old image differs from built declaration' "$td/$CASE.log"
        grep -q 'Recreating xmrig-proxy' "$td/$CASE.log"
        grep -q 'source-image: guarded recreate matches declared image and Compose owner' "$td/$CASE.log"
    else
        [ "$rc" -ne 0 ]
        ! grep -q 'source-image: guarded recreate matches declared image and Compose owner' "$td/$CASE.log"
    fi
    [ "$CASE" = build-fails ] || [ -f "$STATE/removed" ]
done
[ -z "$(ls -A "$td/scratch")" ]
echo 'selftest-source-image: 4 cases passed (success, missing recreate, wrong owner, build failure)'
