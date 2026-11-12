#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck source=tests/os/data-floor-fallback-leg.sh
SCRIPT_DIR="$HERE" source "$HERE/data-floor-fallback-leg.sh"

fail() {
    echo "FAIL: $1"
    exit 1
}

TAGS="$T/tags"
: >"$TAGS"
: >"$TAGS.seen"
mkdir -p "$T/bin" "$T/tree/os/rauc" "$T/leg"
cat >"$T/bin/docker" <<EOF
#!/bin/sh
case "\$1" in
build)
    while [ \$# -gt 0 ]; do
        if [ "\$1" = -t ]; then
            shift
            printf '%s\n' "\$1" >>"$TAGS"
            printf '%s\n' "\$1" >>"$TAGS.seen"
        fi
        shift
    done
    ;;
rmi)
    shift
    while [ \$# -gt 0 ]; do
        grep -vxF -- "\$1" "$TAGS" >"$TAGS.next" || true
        mv "$TAGS.next" "$TAGS"
        shift
    done
    ;;
esac
EOF
cat >"$T/tree/os/build-image.sh" <<EOF
#!/bin/sh
echo "fake build-image rootfs=\$PITHEAD_ROOTFS_TAG"
docker build -f os/rootfs/Dockerfile -t "\$PITHEAD_ROOTFS_TAG" .
if [ -n "\${BUILD_FAIL:-}" ]; then
    echo "fake build-image failed"
    exit 1
fi
exit 0
EOF
cat >"$T/tree/os/rauc/mkbundle.sh" <<EOF
#!/bin/sh
mkdir -p os/rauc/build
printf raucb-payload >os/rauc/build/update.raucb
echo "fake mkbundle done"
EOF
cat >"$T/bin/git" <<EOF
#!/bin/sh
tar -c -C "$T/tree" .
EOF
chmod +x "$T/bin/docker" "$T/bin/git" "$T/tree/os/build-image.sh" "$T/tree/os/rauc/mkbundle.sh"

resolve_signing_material() {
    : >"$T/fake.crt"
    : >"$T/fake.key"
    : >"$T/fake.keyring"
    : >"$T/key.pub"
    KEY="$T/key"
    RAUC_CERT="$T/fake.crt" RAUC_KEY="$T/fake.key" RAUC_KEYRING="$T/fake.keyring"
}

FLOOR_LEG_TMP="$T/leg"

out=$(PATH="$T/bin:$PATH" _build_bundle_stamped vfail 99.0.0 99.0.0)
rc=$?
[ "$rc" -eq 0 ] || fail "stamped build returned $rc: $(cat "$FLOOR_LEG_TMP/build.log" 2>/dev/null)"
case "$out" in
"$T/leg"/*) ;;
*) fail "bundle printed at $out, want it under the leg directory" ;;
esac
[ -s "$out" ] || fail "bundle missing at $out"
grep -q 'fake build-image' "$FLOOR_LEG_TMP/build.log" || fail "build log not written under the leg directory"
grep -qxF 'pithead-os-rootfs-vfail' "$TAGS.seen" || fail "rootfs tag never built"
[ ! -s "$TAGS" ] || fail "rootfs image tag left on the host: $(cat "$TAGS")"

out=$(PATH="$T/bin:$PATH" BUILD_FAIL=1 _build_bundle_stamped vfail2 99.0.0 99.0.0)
rc=$?
[ "$rc" -ne 0 ] || fail "failing build returned success"
grep -qxF 'pithead-os-rootfs-vfail2' "$TAGS.seen" || fail "failing build never tagged the rootfs"
[ ! -s "$TAGS" ] || fail "rootfs tag left after a failed build: $(cat "$TAGS")"
[ ! -e "$FLOOR_LEG_TMP/os-floor-fallback-vfail2.raucb" ] || fail "failed build left a bundle in the leg dir"
grep -q 'fake build-image failed' "$FLOOR_LEG_TMP/build.log" || fail "failed build left no log in the leg dir"

ok() { :; }
info() { :; }
bad() { :; }
CAPTURED=""
BODY_FAIL=""
_floor_fallback_leg_body() {
    { [ -n "$FLOOR_LEG_TMP" ] && [ -d "$FLOOR_LEG_TMP" ]; } || fail "leg body entered without its directory"
    printf x >"$FLOOR_LEG_TMP/artifact"
    CAPTURED="$FLOOR_LEG_TMP"
    [ -z "$BODY_FAIL" ]
}
phase_provision_floor_fallback_leg "$T/bundle"
rc=$?
[ "$rc" -eq 0 ] || fail "successful leg body reported rc $rc"
[ -n "$CAPTURED" ] || fail "leg body never ran"
[ ! -e "$CAPTURED" ] || fail "the leg left $CAPTURED behind"
CAPTURED=""
BODY_FAIL=1
phase_provision_floor_fallback_leg "$T/bundle"
rc=$?
[ "$rc" -ne 0 ] || fail "failed leg body returned success"
[ ! -e "$CAPTURED" ] || fail "the failed leg left $CAPTURED behind"

printf 'selftest-floor-cleanup: ok\n'
