# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The compose file an appliance image ships comes from the release it names, not the tree (#1215).
# Every `image:` in docker-compose.yml is pinned by STACK_VERSION, which the appliance derives from
# its baked VERSION, so a tree ahead of that release bakes a compose file assuming image content the
# pinned tags predate (#1098: a healthcheck script the published image did not carry). build-image's
# stage_compose takes the file from the tag `v<VERSION>` when that tag exists, from the tree while
# it does not (the release being prepared), and refuses the one silent case — a clone that has the
# tag on origin but never fetched it. verify-image's compose_reference reads the COMPOSE_SOURCE stamp
# the build writes and resolves the file the shipped one must equal, refusing a stamp that is
# missing, malformed, names another version than the shipped VERSION, or names a commit the
# checkout lacks. Both helpers sit above their script's test seam and are driven here against a
# scratch git repo: no docker, no image, no network (the refuse case's "origin" is a local bare
# repo). Sourced by tests/stack/run.sh.

echo "== unit: build-image stage_compose — the compose file comes from the STACK_VERSION tag, else the tree (#1215) =="
CS="$SANDBOX/compose-source"
rm -rf "$CS"
mkdir -p "$CS"
# A repo whose tagged compose file differs from its working-tree one, so the two sources are
# distinguishable by content, and a bare "origin" that holds a tag the clone deliberately lacks.
cs_repo() {
    (
        cd "$CS" || exit 1
        git -c init.defaultBranch=main init -q origin.git --bare
        git -c init.defaultBranch=main init -q repo
        cd repo || exit 1
        git remote add origin ../origin.git
        printf 'services:\n  a:\n    image: x:${STACK_VERSION:-dev}\n' >docker-compose.yml
        git add docker-compose.yml
        git -c user.email=t@t -c user.name=t commit -q -m "release compose"
        git tag v0.0.1
        git -c user.email=t@t -c user.name=t tag -a v0.0.2 -m "on origin only"
        git push -q origin v0.0.1 v0.0.2
        git tag -d v0.0.2 >/dev/null
        printf 'services:\n  a:\n    image: x:${STACK_VERSION:-dev}\n    healthcheck: {test: [CMD, true]}\n' >docker-compose.yml
    )
}
cs_repo
cs_stage() { # <tag> <dir> -> stdout+stderr of stage_compose, then "rc=N"
    (
        tag="$1" dir="$2"
        export PITHEAD_BUILD_IMAGE_TEST=1
        set -- # `source file` with no args keeps the caller's $@ — clear it so build-image.sh's
        # own arg loop does not parse the tag as a CLI flag.
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh"
        set +e # build-image.sh sets -e for itself; the refusal's rc is the thing under test here
        cd "$CS/repo" || exit 1
        stage_compose "$tag" "$dir" 2>&1
        echo "rc=$?"
    )
}
CS_SHA=$(git -C "$CS/repo" rev-parse v0.0.1)
cs_out=$(cs_stage v0.0.1 "$CS/tagged")
assert_contains "a present tag is staged, and the line names the tag AND its commit" "$cs_out" "tag v0.0.1 $CS_SHA"
assert_contains "the tag path exits 0" "$cs_out" "rc=0"
assert_eq "the staged file is the TAG's compose file, not the tree's" \
    "$(cat "$CS/tagged/docker-compose.yml")" "$(git -C "$CS/repo" show v0.0.1:docker-compose.yml)"
assert_not_contains "the tree's newer compose content did not leak into the staged file" \
    "$(cat "$CS/tagged/docker-compose.yml")" "healthcheck"
assert_eq "the stamp file carries the same line the build prints" "$(cat "$CS/tagged/COMPOSE_SOURCE")" "tag v0.0.1 $CS_SHA"

cs_out=$(cs_stage v0.0.9 "$CS/untagged")
assert_contains "no tag anywhere (the release being prepared) stages the tree and says so" "$cs_out" "tree"
assert_contains "the tree path exits 0" "$cs_out" "rc=0"
assert_eq "the tree path ships the working tree's compose file byte for byte" \
    "$(cat "$CS/untagged/docker-compose.yml")" "$(cat "$CS/repo/docker-compose.yml")"
assert_eq "the tree path's stamp is the bare word" "$(cat "$CS/untagged/COMPOSE_SOURCE")" "tree"

printf 'services:\n  immutable: {image: example.invalid/app@sha256:%064d}\n' 3 >"$CS/external-compose.yml"
cs_out="$(PITHEAD_OS_COMPOSE_FILE="$CS/external-compose.yml" cs_stage v0.0.1 "$CS/file")"
CS_FILE_SHA="$(sha256sum "$CS/external-compose.yml" | cut -d' ' -f1)"
assert_contains "an explicit compose file is stamped with its content hash" "$cs_out" "file sha256:$CS_FILE_SHA"
assert_eq "the explicit compose file is copied byte for byte" \
    "$(
        cmp -s "$CS/external-compose.yml" "$CS/file/docker-compose.yml"
        echo $?
    )" "0"
assert_eq "the file stamp carries the exact lowercase sha256" "$(cat "$CS/file/COMPOSE_SOURCE")" "file sha256:$CS_FILE_SHA"

cs_out="$(PITHEAD_OS_COMPOSE_FILE="$CS/missing-compose.yml" cs_stage v0.0.1 "$CS/missing-file")"
assert_contains "a missing explicit compose file is refused" "$cs_out" "rc=1"
assert_contains "the missing-file refusal names PITHEAD_OS_COMPOSE_FILE" "$cs_out" "PITHEAD_OS_COMPOSE_FILE"

mkdir -p "$CS/copy-failure"
printf 'stale\n' >"$CS/copy-failure/docker-compose.yml"
printf 'tree\n' >"$CS/copy-failure/COMPOSE_SOURCE"
cs_out="$(
    {
        export PITHEAD_BUILD_IMAGE_TEST=1 PITHEAD_OS_COMPOSE_FILE="$CS/external-compose.yml"
        set --
        source "$ROOT/os/build-image.sh"
        set +e
        cp() { return 44; }
        stage_compose v0.0.1 "$CS/copy-failure"
    } 2>&1
    printf 'rc=%s' "$?"
)"
assert_contains "a failed explicit compose copy is propagated" "$cs_out" "rc=1"
assert_eq "a failed copy leaves no stale compose or stamp" "$(ls -A "$CS/copy-failure")" ""

cs_out=$(cs_stage v0.0.2 "$CS/unfetched")
assert_contains "a tag on origin that this clone lacks is REFUSED, not built from the tree" "$cs_out" "rc=1"
assert_contains "the refusal names the tag and the remedy" "$cs_out" "tag v0.0.2 exists on origin but not in this clone"
assert_contains "the remedy is the fetch" "$cs_out" "git fetch --tags"
assert_eq "the refusal stages nothing a later COPY could pick up" "$(ls "$CS/unfetched" 2>/dev/null)" ""

cs_out="$(
    git() {
        [ "$1" != ls-remote ] || return 128
        command git "$@"
    }
    cs_stage v0.0.9 "$CS/remote-error"
)"
assert_contains "a failed remote tag query is refused, not read as tag absence" "$cs_out" "rc=1"
assert_contains "the remote-query refusal names the uncertainty" "$cs_out" "could not determine whether tag v0.0.9 exists"
assert_eq "the remote-query failure stages nothing" "$(ls "$CS/remote-error" 2>/dev/null)" ""

echo "== unit: build-image --stage-only parses, and stops after staging, before the first docker step (#1215) =="
# The CI rootfs scan runs the Dockerfile itself, so it needs the staging without the build. The
# seam returns before the staging line, so the flag's parse is the driven half; the stop is asserted
# by ORDER in the script (static): after the staging echo, before the wizard image is touched.
# Mutation run: drop the case arm -> the parse row goes red; move the stop below the wizard step ->
# the order row goes red.
assert_eq "--stage-only is accepted and recorded" \
    "$( (export PITHEAD_BUILD_IMAGE_TEST=1 && set -- --stage-only && source "$ROOT/os/build-image.sh" && echo "STAGE_ONLY=${STAGE_ONLY:-unset}") 2>&1)" "STAGE_ONLY=1"
rigforge_test_ref=0123456789abcdef0123456789abcdef01234567
rigforge_args_out="$( (export PITHEAD_BUILD_IMAGE_TEST=1 PITHEAD_RIGFORGE_REF="$rigforge_test_ref" && set -- && source "$ROOT/os/build-image.sh" && printf '%s' "${rigforge_build_args[*]}") 2>&1)"
assert_eq "an immutable RigForge test ref reaches docker build" "$rigforge_args_out" "--build-arg RIGFORGE_REF=$rigforge_test_ref"
(export PITHEAD_BUILD_IMAGE_TEST=1 PITHEAD_RIGFORGE_REF=main && set -- && source "$ROOT/os/build-image.sh" >/dev/null 2>&1)
assert_rc "a mutable RigForge ref is refused" "$?" "1"
bi_line() { grep -n -F -- "$1" "$ROOT/os/build-image.sh" | head -1 | cut -d: -f1; }
l_stage=$(bi_line 'COMPOSE_SOURCE="$(stage_compose "$STACK_VERSION" os/build/stage)" || exit 1')
l_build=$(bi_line 'bash scripts/build-pithead.sh')
l_stop=$(bi_line 'if [ "${STAGE_ONLY:-0}" = 1 ]; then')
l_wizard=$(bi_line 'echo "==> staging wizard image $WIZARD_IMAGE"')
assert_eq "the generated CLI is built before staging can stop" \
    "$([ "${l_build:-0}" -lt "${l_stage:-0}" ] && echo ordered)" "ordered"
assert_eq "the stop sits after the staging line and before the wizard image step" \
    "$([ "${l_stage:-0}" -lt "${l_stop:-0}" ] && [ "${l_stop:-0}" -lt "${l_wizard:-0}" ] && echo ordered)" "ordered"
unset -f bi_line
unset l_build l_stage l_stop l_wizard

caller="$CS/caller"
mkdir -p "$caller/os/build/stage" "$caller/scripts"
cp "$ROOT/os/build-image.sh" "$caller/os/build-image.sh"
printf '0.0.1\n' >"$caller/VERSION"
printf '#!/usr/bin/env bash\n' >"$caller/scripts/build-pithead.sh"
printf 'stale\n' >"$caller/os/build/stage/docker-compose.yml"
printf 'tree\n' >"$caller/os/build/stage/COMPOSE_SOURCE"
(cd "$caller" && PITHEAD_OS_COMPOSE_FILE="$caller/missing.yml" bash os/build-image.sh --stage-only >/dev/null 2>&1)
assert_rc "the build caller fails closed when explicit compose staging fails" "$?" 1
assert_eq "a staging failure removes stale files before a later COPY can use them" "$(ls -A "$caller/os/build/stage")" ""

echo "== unit: verify-image compose_reference — the stamp names the file the shipped compose must equal (#1215) =="
# A fake image root: only the two files the helper reads. Driven from inside the scratch repo so
# `./docker-compose.yml` and `git show` resolve against it, exactly as verify-image runs.
cs_ref() { # <stamp-line|-> <version> -> "rc=N" then the resolved file's content (if any)
    (
        stamp="$1" ver="$2"
        # shellcheck disable=SC1091  # sourcing defines the helper and returns before the checks
        source "$ROOT/tests/os/verify-image.sh"
        img="$CS/img-$RANDOM"
        mkdir -p "$img/opt/pithead"
        [ "$stamp" = "-" ] || printf '%s\n' "$stamp" >"$img/opt/pithead/COMPOSE_SOURCE"
        printf '%s\n' "$ver" >"$img/opt/pithead/VERSION"
        printf 'shipped-image-copy-is-not-the-ledger\n' >"$img/opt/pithead/docker-compose.yml"
        cd "$CS/repo" || exit 1
        out="$CS/ref-$RANDOM"
        PITHEAD_OS_COMPOSE_FILE="$CS/repo/docker-compose.yml" compose_reference "$img" "$out"
        echo "rc=$?"
        cat "$out" 2>/dev/null
    )
}
assert_eq "tree stamp resolves to the working tree's compose file" \
    "$(cs_ref tree 0.0.1)" "rc=0
$(cat "$CS/repo/docker-compose.yml")"
assert_eq "tag stamp resolves to the stamped COMMIT's compose file" \
    "$(cs_ref "tag v0.0.1 $CS_SHA" 0.0.1)" "rc=0
$(git -C "$CS/repo" show v0.0.1:docker-compose.yml)"
assert_eq "a tag stamp for another version than the shipped VERSION is refused" "$(cs_ref "tag v0.0.1 $CS_SHA" 0.0.2)" "rc=1"
assert_eq "a tag stamp naming a commit this checkout lacks is refused" "$(cs_ref "tag v0.0.1 0123456789abcdef0123456789abcdef01234567" 0.0.1)" "rc=1"
assert_eq "a missing stamp is refused" "$(cs_ref - 0.0.1)" "rc=1"
assert_eq "an unknown stamp kind is refused" "$(cs_ref "registry v0.0.1" 0.0.1)" "rc=1"
assert_eq "a tree stamp with trailing fields is refused" "$(cs_ref "tree garbage" 0.0.1)" "rc=1"
assert_eq "a tag stamp with trailing fields is refused" "$(cs_ref "tag v0.0.1 $CS_SHA garbage" 0.0.1)" "rc=1"
assert_eq "a multi-line stamp is refused" "$(cs_ref $'tree\njunk' 0.0.1)" "rc=1"
CS_TREE_SHA="$(sha256sum "$CS/repo/docker-compose.yml" | cut -d' ' -f1)"
assert_eq "a file stamp validates and uses the shipped compose" \
    "$(cs_ref "file sha256:$CS_TREE_SHA" 0.0.1)" "rc=0
$(cat "$CS/repo/docker-compose.yml")"
mkdir -p "$CS/toctou/opt/pithead"
printf 'file sha256:%s\n' "$CS_FILE_SHA" >"$CS/toctou/opt/pithead/COMPOSE_SOURCE"
toctou_rc="$(
    {
        source "$ROOT/tests/os/verify-image-artifact-helpers.sh"
        cp() {
            printf 'swapped\n' >"$1"
            command cp "$1" "$2"
        }
        PITHEAD_OS_COMPOSE_FILE="$CS/external-compose.yml" compose_reference "$CS/toctou" "$CS/ref-swapped"
    } 2>/dev/null
    printf '%s' "$?"
)"
assert_eq "a source swap between validation and copy is refused" "$toctou_rc" "1"
assert_eq "a mismatched verifier-owned copy is removed" "$(test -e "$CS/ref-swapped" && echo present || echo absent)" absent
mkdir -p "$CS/no-ledger/opt/pithead"
printf 'file sha256:%s\n' "$CS_TREE_SHA" >"$CS/no-ledger/opt/pithead/COMPOSE_SOURCE"
missing_source_rc="$(
    {
        source "$ROOT/tests/os/verify-image-artifact-helpers.sh"
        PITHEAD_OS_COMPOSE_FILE='' compose_reference "$CS/no-ledger" "$CS/ref-missing"
    } 2>/dev/null
    printf '%s' "$?"
)"
assert_eq "a file stamp without its external ledger source is refused" "$missing_source_rc" "1"
assert_eq "a file stamp whose hash does not match is refused" \
    "$(cs_ref "file sha256:$(printf '%064d' 9)" 0.0.1)" "rc=1"
assert_eq "an uppercase file digest is refused" \
    "$(cs_ref "file sha256:$(printf 'A%.0s' {1..64})" 0.0.1)" "rc=1"
assert_eq "a short file digest is refused" "$(cs_ref "file sha256:deadbeef" 0.0.1)" "rc=1"

echo "== unit: build-image immutable wizard source =="
IMMUTABLE_WIZARD="example.invalid/pithead-dashboard@sha256:$(printf '%064d' 4)"
wizard_ref_rc() {
    local ref="$1"
    (
        export PITHEAD_BUILD_IMAGE_TEST=1
        set --
        source "$ROOT/os/build-image.sh"
        set +e
        is_immutable_image_ref "$ref"
    ) 2>/dev/null
}
wizard_ref_rc "$IMMUTABLE_WIZARD"
assert_rc "lowercase repo@sha256 wizard refs are accepted" "$?" "0"
wizard_ref_rc example.invalid/app@sha256:deadbeef
assert_rc "short wizard digests are refused" "$?" "1"
wizard_ref_rc "example.invalid/app@sha256:$(printf 'A%.0s' {1..64})"
assert_rc "uppercase wizard digests are refused" "$?" "1"

echo "== unit: release smoke and promotion keep one immutable digest chain =="
REL="$ROOT/scripts/release.sh"
CHAIN="$SANDBOX/release-digest-chain"
mkdir -p "$CHAIN"
CHAIN_DIGEST="sha256:$(printf '%064d' 7)"
# shellcheck disable=SC1090,SC2034
chain_out="$({
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    DRY_RUN=0 SKIP_SMOKE=0 ASSUME_YES=1
    STACK_VERSION=v2.0.0 TAG=v2.0.0 STAGING_TAG=v2.0.0-rc.1
    PLATFORMS=linux/amd64 REGISTRY=ghcr.io/test IMAGES=(tor)
    WORKDIR="$CHAIN"
    set_digest tor "ghcr.io/test/pithead-tor@$CHAIN_DIGEST"
    docker() {
        printf 'docker %s\n' "$*" >>"$CHAIN/calls"
        [ "$1" = inspect ] && printf 'v2.0.0\n'
        return 0
    }
    buildx_inspect() {
        printf 'inspect %s\n' "$*" >>"$CHAIN/calls"
        case " $* " in
        *' --raw '*) printf '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}\n' ;;
        *) printf 'Digest: %s\n' "$CHAIN_DIGEST" ;;
        esac
    }
    ghcr_login() { :; }
    smoke_test
    promote
} 2>&1)"
assert_rc "immutable digest smoke and promotion pass" "$?" "0"
chain_calls="$(cat "$CHAIN/calls")"
assert_contains "smoke pulls the captured repo@sha256 ref" "$chain_calls" "docker pull --quiet --platform linux/amd64 ghcr.io/test/pithead-tor@$CHAIN_DIGEST"
assert_not_contains "smoke never re-reads the mutable staging tag" "$chain_calls" "v2.0.0-rc.1"
assert_contains "promotion verifies the v2.0.0 tag" "$chain_calls" "inspect ghcr.io/test/pithead-tor:v2.0.0"
assert_contains "promotion verifies latest" "$chain_calls" "inspect ghcr.io/test/pithead-tor:latest"

# shellcheck disable=SC1090,SC2034
mismatch_out="$({
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    DRY_RUN=0 ASSUME_YES=1 TAG=v2.0.0 REGISTRY=ghcr.io/test IMAGES=(tor)
    WORKDIR="$CHAIN-mismatch"
    mkdir -p "$WORKDIR"
    set_digest tor "ghcr.io/test/pithead-tor@$CHAIN_DIGEST"
    ghcr_login() { :; }
    docker() { :; }
    buildx_inspect() {
        if [ "$1" = ghcr.io/test/pithead-tor:latest ]; then printf 'Digest: sha256:%064d\n' 8; else printf 'Digest: %s\n' "$CHAIN_DIGEST"; fi
    }
    promote
} 2>&1)"
assert_rc "promotion refuses latest resolving away from the captured digest" "$?" "1"
assert_contains "promotion mismatch names latest and the captured digest" "$mismatch_out" "ghcr.io/test/pithead-tor:latest did not resolve to captured digest $CHAIN_DIGEST"

# Resume re-captures mutable staging tags, so those bytes must pass smoke before promotion.
resume_calls="$SANDBOX/resume-calls"
# shellcheck disable=SC1090,SC2034,SC2329
(
    cd "$ROOT" || exit 1
    set --
    # shellcheck disable=SC1090
    source "$REL" 2>/dev/null
    preflight() { :; }
    ghcr_login() { :; }
    manifest_digest() { printf 'sha256:%064d\n' 7; }
    smoke_test() { printf 'smoke\n' >>"$resume_calls"; }
    promote() { printf 'promote\n' >>"$resume_calls"; }
    sign_images() { :; }
    publish() { :; }
    DRY_RUN=0 RESUME_PROMOTE=1 IMAGES=(tor) TAG=v9.9.9 STAGING_TAG=v9.9.9-rc.1 REGISTRY=ghcr.io/test
    main
) >/dev/null 2>&1
assert_rc "--resume-promote succeeds with a captured digest" "$?" 0
assert_eq "--resume-promote smokes newly captured bytes before promotion" "$(tr '\n' ' ' <"$resume_calls")" "smoke promote "

# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    buildx_inspect() { printf 'Digest: sha256:%064d\n' 1 | tr 0 A; }
    manifest_digest some:tag >/dev/null
)
assert_rc "manifest_digest refuses uppercase hex" "$?" "1"

echo "== wiring: the build stages, the Dockerfile copies, verify-image compares (#1215) =="
# The three scripts cannot be run together at this tier; what CAN be proven is that each end
# speaks the other's path — the shape #1064's guard failed on when the two ends disagreed.
CS_BI="$(cat "$ROOT/os/build-image.sh")"
CS_DF="$(cat "$ROOT/os/rootfs/Dockerfile")"
CS_VI="$(cat "$ROOT/tests/os/verify-image.sh")"
assert_contains "build-image stages into os/build/stage from STACK_VERSION" "$CS_BI" 'COMPOSE_SOURCE="$(stage_compose "$STACK_VERSION" os/build/stage)" || exit 1'
assert_contains "an immutable wizard source is pulled by digest" "$CS_BI" 'docker pull -q "$WIZARD_SOURCE"'
assert_contains "the pulled wizard digest is tagged with the runtime name" "$CS_BI" 'docker tag "$WIZARD_SOURCE" "$WIZARD_IMAGE"'
assert_contains "the marker layer inherits from the immutable wizard source" "$CS_BI" '"$WIZARD_SOURCE" "$PITHEAD_TEST_MARKER"'
assert_contains "the runtime-tagged wizard image is saved" "$CS_BI" 'docker save "$WIZARD_IMAGE"'
assert_contains "the Dockerfile copies the STAGED compose file" "$CS_DF" 'os/build/stage/docker-compose.yml'
assert_contains "the Dockerfile copies the stamp beside it" "$CS_DF" 'os/build/stage/COMPOSE_SOURCE'
assert_eq "the appliance carries no documentation or source-only trees" "$(grep -cE '^COPY (docs|lib|scripts|tests|dashboard|\.github)/' "$ROOT/os/rootfs/Dockerfile" || true)" "0"
assert_contains "the appliance copies only Monero's runtime-mounted template" "$CS_DF" 'COPY build/monero/bitmonero.conf.template'
assert_not_contains "the appliance excludes Monero image-build sources" "$CS_DF" 'COPY build/monero/ /opt/pithead/build/monero/'
assert_not_contains "the Dockerfile no longer copies the tree's compose file" "$CS_DF" 'VERSION docker-compose.yml'
assert_contains "verify-image compares against what the stamp resolves to, not the tree" "$CS_VI" 'compose_reference "$ROOT" "$COMPOSE_REF"'
assert_not_contains "verify-image's old tree comparison is gone" "$CS_VI" 'docker-compose.yml" ./docker-compose.yml'
