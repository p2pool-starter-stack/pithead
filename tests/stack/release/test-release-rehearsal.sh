# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Rehearsal isolation, policy and builder routing need their own fragment to keep each under 400 lines.
echo "== unit: release rehearsal contracts =="
REL="$ROOT/scripts/release/release.sh"
REHEARSAL_TEST="$SANDBOX/rehearsal"
mkdir -p "$REHEARSAL_TEST"
# shellcheck disable=SC1090,SC2034 # dynamic source; globals consumed by release functions
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_case() (
    local action="$1"
    shift
    local params=("$@")
    set --
    source "$REL"
    DRY_RUN=0 ASSUME_YES=1 REGISTRY=registry.invalid/rehearsal TAG=v9.9.9 STAGING_TAG=v9.9.9-rc.1
    IMAGES=(tor) PUBLISHED_IMAGES=(tor) STACK_VERSION=v9.9.9 COSIGN_ENABLED=1
    REGISTRY_READ_RETRIES=1 REGISTRY_READ_BACKOFF=0
    WORKDIR="$REHEARSAL_TEST/work"
    mkdir -p "$WORKDIR"
    : >"$REHEARSAL_TEST/calls"
    : >"$REHEARSAL_TEST/stdin"
    : >"$REHEARSAL_TEST/gh"
    gh() {
        printf '%s\n' "$*" >>"$REHEARSAL_TEST/gh"
        printf github-sentinel
    }
    curl() {
        printf 'curl %s\n' "$*" >>"$REHEARSAL_TEST/calls"
        return 8
    }
    cosign() { printf 'cosign %s\n' "$*" >>"$REHEARSAL_TEST/calls"; }
    sleep() { printf 'sleep %s\n' "$*" >>"$REHEARSAL_TEST/calls"; }
    docker() {
        printf 'docker %s\n' "$*" >>"$REHEARSAL_TEST/calls"
        case "$*" in
        'login '*) cat >>"$REHEARSAL_TEST/stdin" ;;
        'inspect '*) printf 'v9.9.9 linux/amd64\n' ;;
        'buildx imagetools inspect '*--raw) printf '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}\n' ;;
        'buildx imagetools inspect '*) cat "$ROOT/tests/stack/fixtures/imagetools/inspect-padded.txt" ;;
        'buildx inspect '*) return 1 ;;
        esac
    }
    "$action" ${params[@]+"${params[@]}"}
)
# MUTATION PROOF: reusing GitHub login fallbacks on a scratch host leaks either sentinel or calls gh.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_credentials() {
    GITHUB_TOKEN=github-sentinel GHCR_TOKEN=ghcr-sentinel GHCR_USER=github-user
    unset PITHEAD_REGISTRY_USER PITHEAD_REGISTRY_TOKEN
    ghcr_login
    stage_push
    PUBLISHED_IMAGES=(os-rootfs)
    set_digest os-rootfs "$(image_for os-rootfs)@sha256:$(printf '%064d' 1)"
    rootfs_image_check() { :; }
    smoke_test
    promote
    sign_images
}
rehearsal_out="$(rehearsal_case rehearsal_credentials 2>&1)"
assert_rc "scratch stages complete without GitHub credentials" "$?" 0
assert_contains "missing scratch credentials warn" "$rehearsal_out" 'skipping login'
assert_contains "scratch rootfs reports skipped anonymous-read check" "$rehearsal_out" 'Skipping anonymous-read check'
assert_eq "scratch stages never call gh" "$(cat "$REHEARSAL_TEST/gh")" ''
for forbidden in ghcr.io github-sentinel ghcr-sentinel 'docker login' 'curl '; do
    assert_not_contains "scratch transport excludes $forbidden" "$(cat "$REHEARSAL_TEST/calls" "$REHEARSAL_TEST/stdin")" "$forbidden"
done
# MUTATION PROOF: ignoring scratch credentials, using argv for tokens, or falling back to gh breaks login.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_login() {
    PITHEAD_REGISTRY_USER=scratch-user PITHEAD_REGISTRY_TOKEN=scratch-token
    ghcr_login
}
rehearsal_out="$(rehearsal_case rehearsal_login 2>&1)"
assert_rc "explicit scratch credentials log in" "$?" 0
assert_contains "scratch login targets its own host" "$(cat "$REHEARSAL_TEST/calls")" 'docker login registry.invalid -u scratch-user --password-stdin'
assert_eq "scratch token goes only to stdin" "$(cat "$REHEARSAL_TEST/stdin")" scratch-token
assert_not_contains "scratch token stays out of argv and logs" "$(cat "$REHEARSAL_TEST/calls")$rehearsal_out" scratch-token
assert_eq "explicit scratch login never calls gh" "$(cat "$REHEARSAL_TEST/gh")" ''
# MUTATION PROOF: changing GHCR's token/user precedence or disabling its fallbacks breaks compatibility.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_ghcr_login() {
    REGISTRY=ghcr.io/test GHCR_USER=old-user
    GITHUB_TOKEN=github-sentinel GHCR_TOKEN=ghcr-sentinel
    ghcr_login
}
rehearsal_out="$(rehearsal_case rehearsal_ghcr_login 2>&1)"
assert_rc "GHCR explicit credentials still work" "$?" 0
assert_contains "GHCR keeps its login argv" "$(cat "$REHEARSAL_TEST/calls")" 'docker login ghcr.io -u old-user --password-stdin'
assert_eq "GHCR token keeps precedence" "$(cat "$REHEARSAL_TEST/stdin")" ghcr-sentinel
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_ghcr_fallback() {
    REGISTRY=ghcr.io/test
    unset GHCR_USER GHCR_TOKEN GITHUB_TOKEN
    ghcr_login
}
rehearsal_out="$(rehearsal_case rehearsal_ghcr_fallback 2>&1)"
assert_rc "GHCR gh fallbacks still work" "$?" 0
assert_contains "GHCR can request gh token" "$(cat "$REHEARSAL_TEST/gh")" 'auth token'
assert_contains "GHCR can request gh user" "$(cat "$REHEARSAL_TEST/gh")" 'api user --jq .login'
# MUTATION PROOF: consulting the ghcr.io suffix instead of the exact host leaks credentials.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_lookalike() {
    REGISTRY=ghcr.io.registry.invalid/test
    rehearsal_credentials
}
rehearsal_out="$(rehearsal_case rehearsal_lookalike 2>&1)"
assert_rc "lookalike GHCR host is treated as scratch" "$?" 0
assert_eq "lookalike GHCR host never calls gh" "$(cat "$REHEARSAL_TEST/gh")" ''
# MUTATION PROOF: bypassing policy in dry-run or checking after tool calls permits production rehearsals.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_production() {
    REGISTRY="$PROD_REGISTRY" PITHEAD_REHEARSAL=1 DRY_RUN="$1"
    git() {
        printf 'git %s\n' "$*" >>"$REHEARSAL_TEST/calls"
        return 8
    }
    "$2"
}
for dry in 0 1; do
    for action in check_registry_policy preflight; do
        rehearsal_out="$(rehearsal_case rehearsal_production "$dry" "$action" 2>&1)"
        assert_rc "production rehearsal fails before $action in mode $dry" "$?" 1
        assert_contains "production refusal explains the policy" "$rehearsal_out" 'requires a non-production registry namespace'
        assert_eq "production policy precedes all tools" "$(cat "$REHEARSAL_TEST/calls")" ''
    done
done
# MUTATION PROOF: removing validation from preflight lets invalid write tuning pass policy.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_invalid_policy() {
    REGISTRY_WRITE_RETRIES=0
    check_registry_policy
}
rehearsal_out="$(rehearsal_case rehearsal_invalid_policy 2>&1)"
assert_rc "policy validates write tuning" "$?" 1
assert_eq "invalid policy runs no tools" "$(cat "$REHEARSAL_TEST/calls")" ''
# MUTATION PROOF: aborting real custom-registry cuts or warning in dry-run changes documented policy.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_custom_policy() {
    unset PITHEAD_REHEARSAL
    DRY_RUN="$1"
    check_registry_policy
}
rehearsal_out="$(rehearsal_case rehearsal_custom_policy 0 2>&1)"
assert_rc "real custom-registry cuts are allowed" "$?" 0
assert_contains "real custom-registry cuts warn about bundles" "$rehearsal_out" 'real cut will publish a bundle naming registry.invalid/rehearsal'
rehearsal_out="$(rehearsal_case rehearsal_custom_policy 1 2>&1)"
assert_rc "custom-registry dry-run is allowed" "$?" 0
assert_eq "custom-registry dry-run needs no warning" "$rehearsal_out" ''
# MUTATION PROOF: stopping earlier skips a gate/signing; stopping later calls publish.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_main() {
    PITHEAD_REHEARSAL="$1"
    preflight() {
        check_registry_policy
        printf 'preflight\n' >>"$REHEARSAL_TEST/calls"
    }
    require_bench_tier4() { printf 'tier4\n' >>"$REHEARSAL_TEST/calls"; }
    test_gate() { printf 'test\n' >>"$REHEARSAL_TEST/calls"; }
    build_images() { printf 'build\n' >>"$REHEARSAL_TEST/calls"; }
    stage_push() { printf 'stage\n' >>"$REHEARSAL_TEST/calls"; }
    smoke_test() { printf 'smoke\n' >>"$REHEARSAL_TEST/calls"; }
    promote() { printf 'promote\n' >>"$REHEARSAL_TEST/calls"; }
    sign_images() { printf 'sign\n' >>"$REHEARSAL_TEST/calls"; }
    publish() { printf 'publish\n' >>"$REHEARSAL_TEST/calls"; }
    main
    rm -rf "$WORKDIR"
}
rehearsal_out="$(rehearsal_case rehearsal_main 1 2>&1)"
assert_rc "rehearsal main completes" "$?" 0
assert_eq "rehearsal runs every stage through signing" "$(cat "$REHEARSAL_TEST/calls")" $'preflight\ntier4\ntest\nbuild\nstage\nsmoke\npromote\nsign'
assert_contains "rehearsal announces its stop point" "$rehearsal_out" 'Rehearsal complete: nothing was tagged or published'
rehearsal_out="$(rehearsal_case rehearsal_main 0 2>&1)"
assert_rc "ordinary custom-registry main completes" "$?" 0
assert_contains "ordinary main still publishes" "$(cat "$REHEARSAL_TEST/calls")" $'sign\npublish'
# MUTATION PROOF: omitting config or builder selection routes private-CA/HTTP writes to the default.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_builder() {
    BUILDX_BUILDER=rehearsal-builder
    if [ "$1" = configured ]; then
        PITHEAD_BUILDKITD_CONFIG="$REHEARSAL_TEST/buildkitd.toml"
        printf '# fixture\n' >"$PITHEAD_BUILDKITD_CONFIG"
    else unset PITHEAD_BUILDKITD_CONFIG; fi
    check_registry_policy
    ensure_buildx_builder
    set_digest tor "$(image_for tor)@sha256:$(printf '%064d' 1)"
    # Keep this stub inside docker so buildx_inspect's real argv remains under test.
    docker() {
        printf 'docker %s\n' "$*" >>"$REHEARSAL_TEST/calls"
        case "$*" in 'buildx imagetools inspect '*) cat "$ROOT/tests/stack/fixtures/imagetools/inspect-padded.txt" ;; esac
    }
    promote
}
rehearsal_out="$(rehearsal_case rehearsal_builder configured 2>&1)"
assert_rc "configured builder promotes and verifies" "$?" 0
builder_calls="$(cat "$REHEARSAL_TEST/calls")"
assert_contains "builder create receives config" "$builder_calls" "--buildkitd-config $REHEARSAL_TEST/buildkitd.toml"
assert_contains "promotion selects configured builder" "$builder_calls" 'imagetools create --builder rehearsal-builder'
assert_contains "inspection selects configured builder" "$builder_calls" 'imagetools inspect --builder rehearsal-builder'
# MUTATION PROOF: always adding new flags changes the existing unconfigured argv.
rehearsal_out="$(rehearsal_case rehearsal_builder default 2>&1)"
assert_rc "default builder promotes and verifies" "$?" 0
builder_calls="$(cat "$REHEARSAL_TEST/calls")"
assert_eq "default builder create argv is unchanged" "$(printf '%s\n' "$builder_calls" | grep 'buildx create ')" 'docker buildx create --name rehearsal-builder --driver docker-container --bootstrap'
assert_eq "default promote argv is unchanged" "$(printf '%s\n' "$builder_calls" | grep 'imagetools create ')" "docker buildx imagetools create --tag registry.invalid/rehearsal/pithead-tor:v9.9.9 --tag registry.invalid/rehearsal/pithead-tor:latest registry.invalid/rehearsal/pithead-tor@sha256:$(printf '%064d' 1)"
assert_eq "default inspect argv is unchanged" "$(printf '%s\n' "$builder_calls" | grep 'imagetools inspect ')" $'docker buildx imagetools inspect registry.invalid/rehearsal/pithead-tor:v9.9.9\ndocker buildx imagetools inspect registry.invalid/rehearsal/pithead-tor:latest'
# MUTATION PROOF: reconfiguring an existing builder adds a create call.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_existing_builder() {
    PITHEAD_BUILDKITD_CONFIG="$REHEARSAL_TEST/buildkitd.toml"
    docker() { printf 'docker %s\n' "$*" >>"$REHEARSAL_TEST/calls"; }
    ensure_buildx_builder
}
rehearsal_out="$(rehearsal_case rehearsal_existing_builder 2>&1)"
assert_rc "existing builder is retained" "$?" 0
assert_not_contains "existing builder is never reconfigured" "$(cat "$REHEARSAL_TEST/calls")" 'buildx create'
# MUTATION PROOF: ignoring a missing config lets preflight reach external tools.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_missing_config() {
    PITHEAD_BUILDKITD_CONFIG="$REHEARSAL_TEST/missing"
    preflight
}
rehearsal_out="$(rehearsal_case rehearsal_missing_config 2>&1)"
assert_rc "missing buildkitd config fails preflight" "$?" 1
assert_contains "missing config is explained" "$rehearsal_out" 'must name a readable file'
assert_eq "missing config reaches no external tool" "$(cat "$REHEARSAL_TEST/calls")" ''
# MUTATION PROOF: readability alone accepts a directory instead of a configuration file.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # cross-source globals and recording stubs
rehearsal_directory_config() {
    PITHEAD_BUILDKITD_CONFIG="$REHEARSAL_TEST"
    check_registry_policy
}
rehearsal_out="$(rehearsal_case rehearsal_directory_config 2>&1)"
assert_rc "a directory is not a readable buildkitd config file" "$?" 1
unset -f rehearsal_case rehearsal_credentials rehearsal_login rehearsal_ghcr_login rehearsal_ghcr_fallback rehearsal_lookalike rehearsal_production rehearsal_invalid_policy rehearsal_custom_policy rehearsal_main rehearsal_builder rehearsal_existing_builder rehearsal_missing_config rehearsal_directory_config
