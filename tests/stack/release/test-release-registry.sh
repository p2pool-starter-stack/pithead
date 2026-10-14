# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # release globals/stubs are consumed across dynamic sources
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Registry writes and index-digest parsing; every external operation is a recording stub.
REL="$ROOT/scripts/release/release.sh"
REG_TEST="$SANDBOX/registry"
mkdir -p "$REG_TEST"
INDEX="sha256:$(printf '%064d' 1)"
CHILD="sha256:$(printf '%064d' 2)"
PADDED="$ROOT/tests/stack/fixtures/imagetools/inspect-padded.txt"
# shellcheck disable=SC1090,SC2034
registry_case() (
    local action="$1"
    shift
    local params=("$@")
    set --
    source "$REL"
    DRY_RUN=0 ASSUME_YES=1 REGISTRY=registry.invalid/rehearsal TAG=v9.9.9 STAGING_TAG=v9.9.9-rc.1
    IMAGES=(tor) PUBLISHED_IMAGES=(tor) STACK_VERSION=v9.9.9 COSIGN_ENABLED=1
    REGISTRY_READ_BACKOFF=0 REGISTRY_READ_RETRIES=3
    WORKDIR="$REG_TEST/work"
    mkdir -p "$WORKDIR"
    set_digest tor "$(image_for tor)@$INDEX"
    printf 0 >"$REG_TEST/count"
    : >"$REG_TEST/sleeps"
    : >"$REG_TEST/calls"
    sleep() { printf '%s\n' "$1" >>"$REG_TEST/sleeps"; }
    ghcr_login() { :; }
    buildx_inspect() { cat "$PADDED"; }
    docker() { printf '%s\n' "$*" >>"$REG_TEST/calls"; }
    cosign() { printf '%s\n' "$*" >>"$REG_TEST/calls"; }
    "$action" ${params[@]+"${params[@]}"}
)
# MUTATION PROOF: restoring the one-space Digest grep makes padded promotion fail.
registry_out="$(registry_case promote 2>&1)"
assert_rc "promote accepts the padded index digest" "$?" 0
# MUTATION PROOF: accepting any digest or an indented child makes these promotions succeed.
registry_mismatch() {
    REGISTRY_READ_RETRIES=4
    buildx_inspect() {
        printf '%s' "$(($(cat "$REG_TEST/count") + 1))" >"$REG_TEST/count"
        cat "$PADDED"
    }
    set_digest tor "$(image_for tor)@$1"
    promote
}
for expected in "sha256:$(printf '%064d' 3)" "$CHILD"; do
    registry_out="$(registry_case registry_mismatch "$expected" 2>&1)"
    assert_rc "promotion refuses a wrong or child digest" "$?" 1
    assert_eq "mismatch exhausts exactly the read bound" "$(cat "$REG_TEST/count")" 4
    assert_contains "mismatch names the tag and captured digest" "$registry_out" "registry.invalid/rehearsal/pithead-tor:v9.9.9 did not resolve to captured digest $expected"
done
# MUTATION PROOF: dropping the anchor or parsing a child breaks the release/appliance parity.
parsed="$(registry_case manifest_digest fixture)"
pinned="$(
    export PITHEAD_BUILD_IMAGE_TEST=1
    set --
    # shellcheck disable=SC1091
    source "$ROOT/os/build-image.sh"
    docker() { cat "$PADDED"; }
    printf 'image: registry.invalid/rehearsal/pithead-tor:v9.9.9\n' >"$REG_TEST/compose"
    pin_first_party_images "$REG_TEST/compose" registry.invalid/rehearsal v9.9.9
    cat "$REG_TEST/compose"
)"
assert_eq "release parser returns the fixture's index" "$parsed" "$INDEX"
assert_contains "appliance parser pins the same index" "$pinned" "@$parsed"
assert_not_contains "appliance parser rejects child digest" "$pinned" "$CHILD"
# The command's final stderr line is the failure: classification must wait for tee to flush.
registry_write_stub() {
    local n
    n="$(($(cat "$REG_TEST/count") + 1))"
    printf '%s' "$n" >"$REG_TEST/count"
    if [ "$n" -le "${FAIL_WRITES:-2}" ]; then
        printf '%s\n' "${WRITE_ERROR:-received unexpected HTTP status: 502 Bad Gateway}" >&2
        return 7
    fi
}
registry_write_stage() {
    local verb="$1"
    REGISTRY_WRITE_RETRIES=3 REGISTRY_WRITE_BACKOFF=10
    ensure_buildx_builder() { :; }
    docker() {
        printf '%s\n' "$*" >>"$REG_TEST/calls"
        registry_write_stub
    }
    cosign() { registry_write_stub; }
    case "$verb" in
    build_images) build_rootfs_image() { :; } ;;
    build_rootfs_image)
        mkdir -p "$REG_TEST/rootfs/os/build"
        cd "$REG_TEST/rootfs" || exit
        printf 0 >"$REG_TEST/build-count"
        rm -f os/build/pithead-root.tar.sha256*
        run() {
            if [ "$1" = env ]; then
                printf '%s' "$(($(cat "$REG_TEST/build-count") + 1))" >"$REG_TEST/build-count"
                printf rootfs >os/build/pithead-root.tar
            else "$@"; fi
        }
        verify_release_rootfs_tar() { :; }
        docker() {
            [ ! -e os/build/pithead-root.tar.sha256 ] || return 9
            registry_write_stub
        }
        ;;
    esac
    "$verb"
}
# MUTATION PROOF: removing any one of the four wrappers leaves that stage at one failed attempt.
for verb in build_images build_rootfs_image promote sign_images; do
    registry_out="$(registry_case registry_write_stage "$verb" 2>&1)"
    assert_rc "$verb retries two final-line 502s then succeeds" "$?" 0
    assert_eq "$verb makes exactly three writes" "$(cat "$REG_TEST/count")" 3
    assert_eq "$verb doubles its delay" "$(cat "$REG_TEST/sleeps")" $'10\n20'
    assert_contains "$verb warns on first attempt" "$registry_out" "attempt 1/3"
    assert_contains "$verb warns on second attempt" "$registry_out" "attempt 2/3"
    assert_contains "$verb names the status and delay" "$registry_out" "502 Bad Gateway — retrying in 20s"
done
assert_eq "rootfs builds only once" "$(cat "$REG_TEST/build-count")" 1
assert_eq "rootfs publishes its handoff after push succeeds" "$([ -s "$REG_TEST/rootfs/os/build/pithead-root.tar.sha256" ] && echo yes)" yes
# MUTATION PROOF: ignoring limits, returning 1, or dropping the final status breaks exhaustion.
registry_exhaust() {
    FAIL_WRITES=20
    retry_registry_write registry_write_stub
}
registry_out="$(registry_case registry_exhaust 2>&1)"
assert_rc "exhaustion preserves command status 7" "$?" 7
assert_eq "persistent failure uses exactly the bound" "$(cat "$REG_TEST/count")" 3
assert_contains "final warning names attempts and last status" "$registry_out" "after 3 attempts: received unexpected HTTP status: 502 Bad Gateway"
# MUTATION PROOF: retrying unknown/permanent failures or scanning all stderr breaks single-shot cases.
registry_permanent() {
    WRITE_ERROR="$1" FAIL_WRITES=20
    failing() { registry_write_stub; }
    if [ "$WRITE_ERROR" = empty ]; then
        failing() {
            printf 1 >"$REG_TEST/count"
            return 7
        }
    elif [ "$WRITE_ERROR" = old ]; then
        failing() {
            printf 1 >"$REG_TEST/count"
            printf 'received unexpected HTTP status: 502 Bad Gateway\n' >&2
            local i=0
            while [ "$i" -lt 20 ]; do
                printf 'progress\n' >&2
                i=$((i + 1))
            done
            return 7
        }
    fi
    retry_registry_write failing
}
for error in 'denied: permission_denied' unauthorized '403 Forbidden' 'manifest unknown' 'name unknown' 'digest mismatch' 'invalid digest' empty old 'bytes: 502' 'digest sha256:502000' $'received unexpected HTTP status: 502 Bad Gateway\n403 Forbidden'; do
    registry_out="$(registry_case registry_permanent "$error" 2>&1)"
    assert_rc "unclassified/permanent write preserves status" "$?" 7
    assert_eq "unclassified/permanent write is never retried" "$(cat "$REG_TEST/count")" 1
done
# MUTATION PROOF: missing status-context or network-error classification leaves transient writes red.
for error in 'unexpected status from PUT request to registry.invalid: 500 Internal Server Error' 'unexpected status code 503 Service Unavailable' 'received unexpected HTTP status: 504 Gateway Timeout' 'connection reset by peer' 'TLS handshake timeout' 'i/o timeout' 'unexpected EOF'; do
    registry_out="$(WRITE_ERROR="$error" registry_case retry_registry_write registry_write_stub 2>&1)"
    assert_rc "classified transient write recovers" "$?" 0
    assert_eq "classified transient write attempts three times" "$(cat "$REG_TEST/count")" 3
done
# MUTATION PROOF: changing defaults or removing the 60-second cap changes recorded delays.
registry_cap() {
    REGISTRY_WRITE_RETRIES=10
    FAIL_WRITES=9
    retry_registry_write registry_write_stub
}
registry_out="$(registry_case registry_cap 2>&1)"
assert_rc "ten attempts can recover" "$?" 0
assert_eq "write backoff doubles then caps at 60" "$(cat "$REG_TEST/sleeps")" $'10\n20\n40\n60\n60\n60\n60\n60\n60'
registry_defaults() { printf '%s %s %s %s' "$REGISTRY_READ_RETRIES" "$REGISTRY_READ_BACKOFF" "$REGISTRY_WRITE_RETRIES" "$REGISTRY_WRITE_BACKOFF"; }
# Read defaults in their own sourced shell, without registry_case's focused overrides.
# shellcheck disable=SC1090
registry_out="$(
    set --
    source "$REL"
    registry_defaults
)"
assert_eq "read/write defaults are 12x10 and 3x10" "$registry_out" '12 10 3 10'
# MUTATION PROOF: moving/removing per-call validation lets an invalid policy run the command.
registry_invalid() {
    if [ "$1" = retries ]; then REGISTRY_WRITE_RETRIES="$2"; else REGISTRY_WRITE_BACKOFF="$2"; fi
    retry_registry_write registry_write_stub
}
for value in 0 abc 11; do
    registry_out="$(registry_case registry_invalid retries "$value" 2>&1)"
    assert_rc "invalid write attempt bound fails" "$?" 1
    assert_eq "invalid attempt bound executes nothing" "$(cat "$REG_TEST/count")" 0
done
for value in -1 abc 61; do
    registry_out="$(registry_case registry_invalid backoff "$value" 2>&1)"
    assert_rc "invalid write delay fails" "$?" 1
    assert_eq "invalid delay executes nothing" "$(cat "$REG_TEST/count")" 0
done
# MUTATION PROOF: bypassing run or retrying printed commands creates writes/sleeps in dry-run.
registry_dry() {
    DRY_RUN=1
    "$1"
}
for verb in build_images promote; do
    registry_out="$(registry_case registry_dry "$verb" 2>&1)"
    assert_rc "dry-run $verb completes" "$?" 0
    assert_eq "dry-run $verb invokes no docker" "$(cat "$REG_TEST/calls")" ''
    assert_eq "dry-run $verb never sleeps" "$(cat "$REG_TEST/sleeps")" ''
    if [ "$verb" = build_images ]; then pattern='docker buildx build build/tor'; else pattern='docker buildx imagetools create'; fi
    assert_eq "dry-run $verb prints write once" "$(printf '%s\n' "$registry_out" | grep -c "$pattern")" 1
done
unset -f registry_case registry_mismatch registry_write_stub registry_write_stage registry_exhaust registry_permanent registry_cap registry_defaults registry_invalid registry_dry
