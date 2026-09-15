# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: appliance image signature pins (#1891) =="
SIG="$SANDBOX/appliance-signature"
mkdir -p "$SIG/opt/pithead"
printf '%s\n' \
    'image: ${PITHEAD_REGISTRY:-example.invalid}/pithead-tor:${STACK_VERSION:-dev}' \
    'image: ${PITHEAD_REGISTRY:-example.invalid}/pithead-monero:${STACK_VERSION:-dev}' \
    'image: ${PITHEAD_REGISTRY:-example.invalid}/pithead-p2pool:${STACK_VERSION:-dev}' \
    'image: ${PITHEAD_REGISTRY:-example.invalid}/pithead-xmrig-proxy:${STACK_VERSION:-dev}' \
    'image: ${PITHEAD_REGISTRY:-example.invalid}/pithead-dashboard:${STACK_VERSION:-dev}' >"$SIG/compose.yml"
(
    export PITHEAD_BUILD_IMAGE_TEST=1
    set --
    source "$ROOT/os/build-image.sh"
    docker() { printf '{"Descriptor":{"digest":"sha256:%064d"}}\n' 1; }
    pin_first_party_images "$SIG/compose.yml" example.invalid v9.9.9
)
assert_eq "all five provision pulls are immutable" "$(grep -c '@sha256:' "$SIG/compose.yml")" 5

source "$ROOT/tests/os/verify-image-artifact-helpers.sh"
printf 'image: example.invalid/pithead-tor:v9@sha256:%064d\n' 2 >"$SIG/opt/pithead/docker-compose.yml"
printf 'image: example.invalid/pithead-tor:v9\n' >"$SIG/reference.yml"
compose_matches_source "$SIG" "$SIG/reference.yml"
assert_rc "the image verifier accepts a source compose plus only immutable pins" "$?" 0
printf 'image: example.invalid/pithead-tor:v10@sha256:%064d\n' 2 >"$SIG/opt/pithead/docker-compose.yml"
compose_matches_source "$SIG" "$SIG/reference.yml"
assert_rc "the image verifier refuses a changed source tag despite a digest" "$?" 1
