#!/usr/bin/env bash
# Execute the documented submissions without GitHub or a bench.
set -euo pipefail
echo "== release status recipe =="
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
recipe_doc="${1:-$ROOT/docs/dev/releasing.md}"
RECIPE_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$RECIPE_TEST_DIR"' EXIT
RECIPE_TEST_SHA=0123456789abcdef0123456789abcdef01234567
export RECIPE_TEST_DIR RECIPE_TEST_SHA

git() {
    if [ "$*" = 'rev-parse HEAD' ]; then
        printf '%s\n' "$RECIPE_TEST_SHA"
    elif [ "$*" = "push origin ${RECIPE_TEST_SHA}:refs/heads/release/${RECIPE_TEST_SHA}" ]; then
        touch "$RECIPE_TEST_DIR/ref-pushed"
    else
        return 1
    fi
}
uuidgen() {
    # Each submission keeps its own retry key, even across command substitutions.
    local n
    n=$(wc -l <"$RECIPE_TEST_DIR/keys")
    printf 'key-%s\n' "$n" | tee -a "$RECIPE_TEST_DIR/keys"
}
curl() {
    local payload id url=
    [ -f "$RECIPE_TEST_DIR/ref-pushed" ] || return 1
    for a in "$@"; do case $a in https://*) url=$a ;; esac done
    if [[ " $* " != *" -X POST "* ]]; then
        printf 'GET %s\n' "$url" >>"$RECIPE_TEST_DIR/urls"
        local conclusion=success
        [ "$url" != "${RECIPE_TEST_FAILED_LEG:-}" ] || conclusion=failure
        printf '{"job":{"status":"completed","conclusion":"%s"}}\n' "$conclusion"
        return
    fi
    payload=$(cat)
    printf 'POST %s\n' "$url" >>"$RECIPE_TEST_DIR/urls"
    printf '%s\n' "$payload" | jq -c . >>"$RECIPE_TEST_DIR/jobs.jsonl"
    id=$(wc -l <"$RECIPE_TEST_DIR/jobs.jsonl")
    printf '{"job":{"id":%s}}\n' "$id"
}
export -f git uuidgen curl
awk '
    /^### Which gates are automated/ { section=1 }
    section && /^\| Gate / { exit }
    section && /^```bash$/ { code=1; next }
    section && /^```$/ { code=0; next }
    code { print }
' "$recipe_doc" >"$RECIPE_TEST_DIR/recipe.sh"
BASE=1111111111111111111111111111111111111111
PREV=2222222222222222222222222222222222222222
PROV_URL=https://provision.invalid/bench-ci
CROSS_URL=https://crossupdate.invalid/bench-ci
run_recipe() {
    : >"$RECIPE_TEST_DIR/keys"
    : >"$RECIPE_TEST_DIR/jobs.jsonl"
    : >"$RECIPE_TEST_DIR/urls"
    rm -f "$RECIPE_TEST_DIR/ref-pushed"
    BENCH_CI_URL=https://bench.invalid/bench-ci BASELINE_SHA=$BASE PREVIOUS_RELEASE_SHA=$PREV \
        PROVISION_BENCH_URL=$PROV_URL CROSSUPDATE_BENCH_URL=$CROSS_URL \
        bash "$RECIPE_TEST_DIR/recipe.sh" </dev/null
}
run_recipe

jq -es --arg sha "$RECIPE_TEST_SHA" --arg base "$BASE" --arg prev "$PREV" '
    length == 5 and
    all(.[]; .repo == "pithead" and .commit == $sha and .ref == "release/" + $sha) and
    (map(.idempotency_key) | unique | length == 5) and
    all(.[0:4][]; .tier == "tier4-kvm" and .timeout_minutes == 240 and (.after // []) == [] and (.status_gate // false) == false) and
    (.[0].options.phases == ["boot","update","install"]) and
    (.[1].options.phases == ["rig","rigmedia","media","fault","reset","image-upgrade","stack"]) and
    (.[2].options == {phases:["provision","setup-defaults"],old_image_commit:$base} and .[2].local_only == true) and
    (.[3].options == {phases:["crossupdate"],old_image_commit:$prev} and .[3].local_only == true) and
    (.[4].tier == "tier4-e2e" and .[4].status_gate == true and .[4].after == [1,2]) and
    (.[4].options.mode == "targeted" and (.[4].options | has("no_rig") | not))
' "$RECIPE_TEST_DIR/jobs.jsonl" >/dev/null
diff -u - "$RECIPE_TEST_DIR/urls" <<EOF
POST https://bench.invalid/bench-ci/jobs
POST https://bench.invalid/bench-ci/jobs
POST $PROV_URL/jobs
POST $CROSS_URL/jobs
GET $PROV_URL/jobs/3
GET $CROSS_URL/jobs/4
POST https://bench.invalid/bench-ci/jobs
EOF

export RECIPE_TEST_FAILED_LEG=$CROSS_URL/jobs/4
if run_recipe; then
    echo 'recipe submitted the e2e gate after a failed crossupdate job' >&2
    exit 1
fi
[ "$(wc -l <"$RECIPE_TEST_DIR/jobs.jsonl")" -eq 4 ] || {
    echo 'a failed pinned leg still produced an e2e submission' >&2
    exit 1
}
unset RECIPE_TEST_FAILED_LEG

cut_doc=$(sed -n '/^## Cutting a release/,/^## Shipping a bad release/p' "$ROOT/docs/dev/appliance-release.md")
if [[ "$cut_doc" == *'phases: ["all"]'* ]]; then
    echo 'appliance cut still prescribes one all-phase KVM job' >&2
    exit 1
fi
echo 'release status recipe: KVM groups, pinned provision and crossupdate, and rig-backed e2e aggregate passed'
