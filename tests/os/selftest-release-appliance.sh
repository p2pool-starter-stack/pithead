#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/var/tmp}}"
test_script="$PWD/tests/os/selftest-release-appliance.sh"

if [ "${1:-}" = --case ]; then
    scenario=$2
    fixture_dir=$3
    set --
    source scripts/release/release.sh
    WORKDIR=$fixture_dir
    DRAFT=1 UNSIGNED=0 DRY_RUN=0 COSIGN_ENABLED=1
    TAG=v$(tr -d '[:space:]' <VERSION)
    STACK_VERSION=${TAG#v}
    GIT_COMMIT=$(git rev-parse HEAD)
    BUILD_DATE=fixture
    PUBLISHED_IMAGES=()
    mkdir -p "$WORKDIR/appliance" "$WORKDIR/root/etc/rauc" "$WORKDIR/root/opt/pithead" "$WORKDIR/root/opt/rigforge"
    printf 'release root\n' >"$WORKDIR/keyring"
    cp "$WORKDIR/keyring" "$WORKDIR/root/etc/rauc/keyring.pem"
    printf '%s\n' "$GIT_COMMIT" >"$WORKDIR/root/opt/pithead/BUILD_COMMIT"
    printf '%s\n' "$STACK_VERSION" >"$WORKDIR/root/opt/pithead/VERSION"
    printf 'release\n' >"$WORKDIR/root/etc/pithead-variant"
    printf '1.2.3\n' >"$WORKDIR/root/opt/rigforge/VERSION"
    ref=$(pin rigforge)
    printf 'ref=%s version=1.2.3\n' "$ref" >"$WORKDIR/root/opt/rigforge/RIGFORGE_REF"
    printf 'image\n' >"$WORKDIR/image"
    printf 'signed bundle\n' >"$WORKDIR/bundle"
    scripts/release/package-appliance.sh "$WORKDIR/image" "$WORKDIR/bundle" "$WORKDIR/appliance"
    export PITHEAD_RAUC_KEYRING="$WORKDIR/keyring" PITHEAD_RAUC_CERT="$WORKDIR/keyring" PITHEAD_RAUC_KEY="$WORKDIR/keyring"
    export PITHEAD_DATA_MIGRATION=false PITHEAD_MIN_OS_VERSION=
    die() {
        printf '%s\n' "$*" >&2
        exit 1
    }
    wait_loop_partitions() { [ "$1" = fixture-loop ]; }
    losetup() {
        case "$*" in
        '--read-only -Pf --show '*) printf 'fixture-loop\n' ;;
        '-d fixture-loop') printf 'detached\n' >>"$WORKDIR/cleanup" ;;
        *) return 1 ;;
        esac
    }
    mount() { cp -R "$WORKDIR/root/." "$4/"; }
    umount() { printf 'unmounted\n' >>"$WORKDIR/cleanup"; }
    rauc() {
        [ "$scenario" != signature ] || return 1
        [ "$1" = info ] && [ "$2" = --keyring ] && [ "$4" = --output-format=shell ] && [ "$5" = "$WORKDIR/bundle" ]
        cmp "$3" "$WORKDIR/keyring"
        printf "RAUC_MF_COMPATIBLE='pithead-amd64'\nRAUC_MF_VERSION='%s'\n" "$STACK_VERSION"
        printf "RAUC_META_PITHEAD_VERSION='%s'\nRAUC_META_PITHEAD_VARIANT='release'\n" "$STACK_VERSION"
        printf "RAUC_META_PITHEAD_DATA_MIGRATION='%s'\n" "$([ "$scenario" = migration ] && echo true || echo false)"
    }
    case "$scenario" in
    no-draft)
        DRAFT=0
        require_appliance_draft
        ;;
    unsigned)
        UNSIGNED=1
        require_appliance_draft
        ;;
    no-key)
        unset PITHEAD_RAUC_KEY
        require_appliance_inputs
        ;;
    no-migration)
        unset PITHEAD_DATA_MIGRATION
        require_appliance_inputs
        ;;
    no-floor)
        unset PITHEAD_MIN_OS_VERSION
        require_appliance_inputs
        ;;
    bad-floor)
        PITHEAD_MIN_OS_VERSION=invalid
        require_appliance_inputs
        ;;
    missing)
        rm "$WORKDIR/appliance/pithead-os-$TAG.raucb"
        appliance_assets "$WORKDIR/appliance" "$TAG"
        ;;
    renamed)
        mv "$WORKDIR/appliance/pithead-os-$TAG.raucb" "$WORKDIR/appliance/wrong.raucb"
        appliance_assets "$WORKDIR/appliance" "$TAG"
        ;;
    checksum)
        printf 'damage\n' >>"$WORKDIR/appliance/pithead-os-$TAG.raucb"
        appliance_assets "$WORKDIR/appliance" "$TAG"
        ;;
    checksum-name)
        sed "s/pithead-os-$TAG.raucb/wrong.raucb/" "$WORKDIR/appliance/pithead-os-$TAG.raucb.sha256" >"$WORKDIR/wrong"
        mv "$WORKDIR/wrong" "$WORKDIR/appliance/pithead-os-$TAG.raucb.sha256"
        appliance_assets "$WORKDIR/appliance" "$TAG"
        ;;
    keyring) printf 'extra root\n' >>"$WORKDIR/root/etc/rauc/keyring.pem" ;;
    commit) printf '%040d\n' 0 >"$WORKDIR/root/opt/pithead/BUILD_COMMIT" ;;
    version) printf '0.0.0\n' >"$WORKDIR/root/opt/pithead/VERSION" ;;
    rigforge) printf 'ref=stale version=1.2.3\n' >"$WORKDIR/root/opt/rigforge/RIGFORGE_REF" ;;
    esac
    appliance_identity "$WORKDIR/image" "$WORKDIR/bundle" "$WORKDIR/keyring" "$STACK_VERSION" "$GIT_COMMIT" release >"$WORKDIR/appliance-rigforge.md"
    if [ "$scenario" = identity ]; then exit 0; fi
    make_bundle() { printf 'install bundle\n' >"$1"; }
    sign_bundle() {
        [ "$scenario" != no-install-signature ] || return 0
        printf 'signature\n' >"$2"
    }
    cosign() { [ "$scenario" != bad-install-signature ]; }
    confirm() { return 0; }
    git() { printf 'git %s\n' "$*" >>"$WORKDIR/writes"; }
    gh() {
        case "$*" in
        'api --method POST '*)
            printf '%s\n' "$@" >"$WORKDIR/create-args"
            [ "$scenario" != create-error ] || return 1
            if [ "$scenario" = bad-create-id ]; then printf 'invalid\n'; else printf '4242\n'; fi
            ;;
        'release upload '*)
            printf '%s\n' "$@" >"$WORKDIR/gh-args"
            [ "$scenario" != upload-failure ]
            ;;
        'api --method DELETE '*) printf '%s\n' "$4" >"$WORKDIR/deleted" ;;
        'api repos/p2pool-starter-stack/pithead/releases/4242')
            if [ "$scenario" = remote-mismatch ]; then
                printf '{"draft":true,"assets":[]}\n'
            else
                jq -n --slurpfile assets "$WORKDIR/remote-assets.json" '{draft:true,assets:$assets[0]}'
            fi
            ;;
        *) return 1 ;;
        esac
    }
    changelog_notes() { printf 'release notes\n'; }
    if [ "$scenario" = publish-missing ]; then rm "$WORKDIR/appliance/pithead-os-$TAG.raucb"; fi
    for asset in "$WORKDIR/pithead.tar.gz" "$WORKDIR/pithead.tar.gz.sig" "$WORKDIR/ingredients-$TAG.md"; do : >"$asset"; done
    make_bundle "$WORKDIR/pithead.tar.gz"
    sign_bundle "$WORKDIR/pithead.tar.gz" "$WORKDIR/pithead.tar.gz.sig"
    write_manifest "$WORKDIR/ingredients-$TAG.md"
    cat "$WORKDIR/appliance-rigforge.md" >>"$WORKDIR/ingredients-$TAG.md"
    append_bundle_sha256 "$WORKDIR/ingredients-$TAG.md" "$WORKDIR/pithead.tar.gz"
    for asset in "$WORKDIR/pithead.tar.gz" "$WORKDIR/pithead.tar.gz.sig" "$WORKDIR/ingredients-$TAG.md" "$WORKDIR"/appliance/*; do
        jq -n --arg name "${asset##*/}" --argjson size "$(wc -c <"$asset")" --arg digest "sha256:$(sha256sum "$asset" | cut -d' ' -f1)" '{name:$name,size:$size,digest:$digest}'
    done | jq -s . >"$WORKDIR/remote-assets.json"
    publish
    grep -Fxq draft=true "$WORKDIR/create-args"
    [ -s "$WORKDIR/writes" ]
    for name in pithead.tar.gz pithead.tar.gz.sig "ingredients-$TAG.md" "pithead-os-$TAG.img.xz" "pithead-os-$TAG.img.xz.sha256" "pithead-os-$TAG.raucb" "pithead-os-$TAG.raucb.sha256"; do
        grep -Eq "/$name$" "$WORKDIR/gh-args"
    done
    grep -Fq "baked RigForge: \`$ref\` (version \`1.2.3\`)" "$WORKDIR/ingredients-$TAG.md"
    exit 0
fi

stage=$(mktemp -d "${TMPDIR:?}/pithead-release-appliance-test.XXXXXX")
trap 'rm -r "$stage"' EXIT
for scenario in identity publish upload-failure remote-mismatch bad-create-id create-error no-draft unsigned no-key no-migration no-floor bad-floor missing renamed checksum checksum-name keyring commit version rigforge signature migration no-install-signature bad-install-signature publish-missing; do
    mkdir "$stage/$scenario"
    rc=0
    bash "$test_script" --case "$scenario" "$stage/$scenario" >"$stage/$scenario/output" 2>&1 || rc=$?
    case "$scenario" in
    identity | publish) [ "$rc" -eq 0 ] || {
        cat "$stage/$scenario/output"
        exit 1
    } ;;
    bad-create-id | create-error)
        [ "$rc" -ne 0 ] && [ ! -e "$stage/$scenario/deleted" ] || {
            echo "FAIL: ambiguous creation deleted an unowned draft"
            exit 1
        }
        grep -Eq 'owner must (reconcile|check)' "$stage/$scenario/output"
        ;;
    upload-failure | remote-mismatch)
        [ "$rc" -ne 0 ] && [ "$(cat "$stage/$scenario/deleted")" = repos/p2pool-starter-stack/pithead/releases/4242 ] || {
            echo "FAIL: $scenario did not delete the created draft"
            exit 1
        }
        ;;
    *)
        [ "$rc" -ne 0 ] || {
            echo "FAIL: accepted $scenario"
            exit 1
        }
        if [ -e "$stage/$scenario/writes" ] || [ -e "$stage/$scenario/gh-args" ]; then
            echo "FAIL: $scenario wrote release state"
            exit 1
        fi
        ;;
    esac
    case "$scenario" in
    identity | publish | upload-failure | remote-mismatch | bad-create-id | create-error | keyring | commit | version | rigforge | signature | migration | no-install-signature | bad-install-signature | publish-missing)
        [ "$(cat "$stage/$scenario/cleanup")" = $'unmounted\ndetached' ]
        ;;
    esac
    echo "PASS: $scenario"
done
consumer=$(grep -oE '[[:alnum:]_-]+-\$tag\.raucb' lib/pithead/48-os-update-verbs.sh | sort -u)
tag=v$(tr -d '[:space:]' <VERSION)
producer_name=${consumer//\$tag/$tag}
[ -n "$consumer" ] && [[ "$consumer" != *$'\n'* ]]
[ -s "$stage/publish/appliance/$producer_name" ]
grep -Fxq "$stage/publish/appliance/$producer_name" "$stage/publish/gh-args"
echo 'PASS: producer/consumer bundle filename equality'
echo 'release-appliance: PASS'
