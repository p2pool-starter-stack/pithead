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
    local payload id
    [ -f "$RECIPE_TEST_DIR/ref-pushed" ] || return 1
    payload=$(cat)
    printf '%s\n' "$payload" | jq -c . >>"$RECIPE_TEST_DIR/jobs.jsonl"
    id=$(wc -l <"$RECIPE_TEST_DIR/jobs.jsonl")
    printf '{"job":{"id":%s}}\n' "$id"
}
export -f git uuidgen curl
: >"$RECIPE_TEST_DIR/keys"
: >"$RECIPE_TEST_DIR/jobs.jsonl"

awk '
    /^### Which gates are automated/ { section=1 }
    section && /^\| Gate / { exit }
    section && /^```bash$/ { code=1; next }
    section && /^```$/ { code=0; next }
    code { print }
' "$recipe_doc" >"$RECIPE_TEST_DIR/recipe.sh"
BENCH_CI_URL=https://bench.invalid/bench-ci bash "$RECIPE_TEST_DIR/recipe.sh"

jq -es --arg sha "$RECIPE_TEST_SHA" '
    length == 3 and
    all(.[]; .repo == "pithead" and .commit == $sha and .ref == "release/" + $sha) and
    (map(.idempotency_key) | unique | length == 3) and
    (.[0].tier == "tier4-kvm" and .[1].tier == "tier4-kvm") and
    (.[0].options.phases == ["boot","update","install","provision"]) and
    (.[1].options.phases == ["rig","rigmedia","media","fault","reset","image-upgrade","stack"]) and
    all(.[0:2][]; .timeout_minutes == 240 and (.after // []) == [] and (.status_gate // false) == false) and
    (.[2].tier == "tier4-e2e" and .[2].status_gate == true and .[2].after == [1,2]) and
    (.[2].options.mode == "targeted" and (.[2].options | has("no_rig") | not))
' "$RECIPE_TEST_DIR/jobs.jsonl" >/dev/null

cut_doc=$(sed -n '/^## Cutting a release/,/^## Shipping a bad release/p' "$ROOT/docs/dev/appliance-release.md")
if [[ "$cut_doc" == *'phases: ["all"]'* ]]; then
    echo 'appliance cut still prescribes one all-phase KVM job' >&2
    exit 1
fi
echo 'release status recipe: independent KVM groups and rig-backed e2e aggregate passed'
