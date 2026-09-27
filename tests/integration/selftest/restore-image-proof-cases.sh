#!/usr/bin/env bash
# Sourced by selftest-e2e-restore-proof.sh; exercises its shipped classifier and build proof.
# Cache reuse is accepted only with build evidence from BOTH checkouts. The fake Compose
# returns each checkout's resolved context and arguments; the helper reads its real files.
echo "== cached image reuse proof =="
proof_tmp="$(mktemp -d)"
trap 'rm -rf "$proof_tmp"' EXIT
mkdir -p "$proof_tmp/base/build/monero" "$proof_tmp/branch/build/monero" "$proof_tmp/bin"
base_ref="ubuntu@sha256:$(printf 'a%.0s' {1..64})"
printf 'FROM %s\nCOPY payload /payload\n' "$base_ref" >"$proof_tmp/base/build/monero/Dockerfile"
printf 'same\n' >"$proof_tmp/base/build/monero/payload"
cp -a "$proof_tmp/base/build/monero/." "$proof_tmp/branch/build/monero/"
cat >"$proof_tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'compose config --format' ] || exit 1
jq -n --arg c "$PWD/build/monero" --arg w "${PROOF_WALLET_CONTEXT:-$PWD/build/monero}" --arg a "${PROOF_ARG:-}" '{services:{monerod:{image:"monero:dev",build:{context:$c,args:{PIN:$a}}},"wallet-rpc":{image:"monero:dev",build:{context:$w,args:{PIN:$a}}}}}'
DOCKER
chmod +x "$proof_tmp/bin/docker"
proof_cmd="$HERE/../lib/image-build-proof.sh"
proof_base="$(PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/base" wallet-rpc)"
proof_branch="$(PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc)"
assert_eq "identical pinned inputs prove a reused wallet image" "$proof_base" "$proof_branch"
mkdir -p "$proof_tmp/branch/tests/integration/lib"
cp "$proof_cmd" "$proof_tmp/branch/tests/integration/lib/image-build-proof.sh"
# shellcheck disable=SC2034  # read by proved_image_reuse, sourced from restore-proof.sh
E2E_DIR="$proof_tmp/branch" RESTORE_DIR="$proof_tmp/base"
on_bench() { PATH="$proof_tmp/bin:$PATH" bash -c "$1"; }
# shellcheck disable=SC2034  # read by proved_image_reuse, sourced from restore-proof.sh
BASELINE_UPGRADE_OK=1 BASELINE_UPGRADE_IMAGES='wallet-rpc=sha256:AAA'
stack_image_census() { echo 'wallet-rpc=sha256:AAA'; }
assert_eq "the restore proof accepts identical build inputs through the bench command" \
    "$(
        proved_image_reuse wallet-rpc
        echo $?
    )" "0"
BASELINE_UPGRADE_OK=0
assert_eq "a failed baseline upgrade cannot authorize reuse" "$(
    proved_image_reuse wallet-rpc
    echo $?
)" "1"
# shellcheck disable=SC2034  # read by proved_image_reuse
BASELINE_UPGRADE_OK=1
assert_eq "the classifier accepts only named proved reuse" \
    "$(grade_image_census "$BASE" "$BRANCH" "$BRANCH" 'dashboard' | sed -n 's/ dashboard$//p')" "reused"
assert_eq "stale image control remains rejected" "$(verdict_for "$BRANCH" dashboard)" "stale"
assert_ne "changed build arguments are not equal proof" \
    "$(PATH="$proof_tmp/bin:$PATH" PROOF_ARG=changed bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc)" "$proof_base"
assert_ne "shared image with different build specs fails closed" "$(
    PATH="$proof_tmp/bin:$PATH" PROOF_WALLET_CONTEXT=/other bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "0"
printf 'changed\n' >"$proof_tmp/branch/build/monero/payload"
assert_eq "the restore proof rejects changed context" "$(
    proved_image_reuse wallet-rpc
    echo $?
)" "1"
assert_ne "changed effective context is not equal proof" \
    "$(PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc)" "$proof_base"
sed -i "s/$base_ref/ubuntu@sha256:$(printf 'b%.0s' {1..64})/" "$proof_tmp/branch/build/monero/Dockerfile"
assert_ne "changed resolved base digest is not equal proof" \
    "$(PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc)" "$proof_base"
cp "$proof_tmp/base/build/monero/Dockerfile" "$proof_tmp/branch/build/monero/Dockerfile"
assert_eq "external-input controls start from a supported Dockerfile" "$(
    PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "0"
printf 'from alpine:latest AS extra\n' >>"$proof_tmp/branch/build/monero/Dockerfile"
assert_eq "a second lowercase unpinned base fails closed" "$(
    PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "1"
sed -i '$d' "$proof_tmp/branch/build/monero/Dockerfile"
printf 'COPY --from=alpine:latest /x /x\n' >>"$proof_tmp/branch/build/monero/Dockerfile"
assert_eq "an external COPY image fails closed" "$(
    PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "1"
sed -i '$d' "$proof_tmp/branch/build/monero/Dockerfile"
printf 'COPY \\\n  --from=alpine:latest /x /x\n' >>"$proof_tmp/branch/build/monero/Dockerfile"
assert_eq "a continued external COPY image fails closed" "$(
    PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "1"
sed -i '$d;$d' "$proof_tmp/branch/build/monero/Dockerfile"
printf 'ADD --checksum=sha256:abc https://example.invalid/x /x\n' >>"$proof_tmp/branch/build/monero/Dockerfile"
assert_eq "a remote ADD input fails closed" "$(
    PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "1"
sed -i '$d' "$proof_tmp/branch/build/monero/Dockerfile"
printf 'RUN --mount=type=bind,from=alpine:latest,target=/x true\n' >>"$proof_tmp/branch/build/monero/Dockerfile"
assert_eq "a RUN mount from an external image fails closed" "$(
    PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
    echo $?
)" "1"
touch "$proof_tmp/branch/build/monero/.dockerignore"
assert_eq "unmodelled ignore rules fail closed" \
    "$(
        PATH="$proof_tmp/bin:$PATH" bash "$proof_cmd" "$proof_tmp/branch" wallet-rpc >/dev/null 2>&1
        echo $?
    )" "1"
