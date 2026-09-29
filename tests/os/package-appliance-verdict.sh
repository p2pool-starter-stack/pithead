#!/usr/bin/env bash
# Check the real release packager against the image and dev-signed bundle from phase_update.
package_appliance_verdict() { # image bundle [fixture-stage]
    local image=$1 bundle=$2 assets version image_name bundle_name
    PACKAGE_APPLIANCE_STAGE=${3:-$(mktemp -d "${TMPDIR:-/var/tmp}/pithead-package-kvm.XXXXXX")} || {
        bad "could not create the release packaging stage (#2824)"
        return 1
    }
    assets="$PACKAGE_APPLIANCE_STAGE/assets"
    version=$(tr -d '[:space:]' <VERSION)
    image_name="pithead-os-v${version}.img.xz"
    bundle_name="pithead-os-v${version}.raucb"
    if scripts/release/package-appliance.sh "$image" "$bundle" "$assets"; then
        ok "release packaging succeeded with the built image and dev-signed bundle (#2824)"
    else
        bad "release packaging failed for the built image and dev-signed bundle (#2824)"
        return 1
    fi
    package_appliance_verify "$image" "$assets" "$image_name" "$bundle_name"
}

package_appliance_cleanup() {
    [ -z "${PACKAGE_APPLIANCE_STAGE:-}" ] || rm -rf -- "$PACKAGE_APPLIANCE_STAGE"
}

package_appliance_verify() { # image output-dir image-name bundle-name
    local image=$1 assets=$2 image_name=$3 bundle_name=$4 name bytes
    for name in "$image_name" "$bundle_name"; do
        if [ ! -s "$assets/$name" ]; then
            bad "$name is missing or empty (#2824)"
            continue
        fi
        bytes=$(wc -c <"$assets/$name")
        if [ "$bytes" -lt 2147483648 ]; then
            ok "$name is below 2 GiB ($bytes bytes; #2824)"
        else
            bad "$name is at or above 2 GiB ($bytes bytes; #2824)"
        fi
        if (cd "$assets" && sha256sum -c "$name.sha256"); then
            ok "$name checksum verifies (#2824)"
        else
            bad "$name checksum failed (#2824)"
        fi
        cat "$assets/$name.sha256"
    done
    if xz -t "$assets/$image_name"; then
        ok "packaged image xz stream verifies (#2824)"
    else
        bad "packaged image xz stream failed (#2824)"
    fi
    if cmp "$image" <(xz -dc "$assets/$image_name"); then
        ok "packaged image decompresses byte-for-byte to system.img (#2824)"
    else
        bad "packaged image differs from system.img (#2824)"
    fi
}

if [ "${1:-}" = --self-test ]; then
    set -euo pipefail
    cd "$(dirname "$0")/../.."
    stage=$(mktemp -d "${TMPDIR:-/var/tmp}/pithead-package-verdict.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    printf 'image fixture\n' >"$stage/system.img"
    printf 'dev bundle fixture\n' >"$stage/update.raucb"
    PASS=0 FAIL=0
    ok() { PASS=$((PASS + 1)); }
    bad() { FAIL=$((FAIL + 1)); }
    package_appliance_verdict "$stage/system.img" "$stage/update.raucb" "$stage" >"$stage/proof.log"
    [ "$PASS" -eq 7 ] && [ "$FAIL" -eq 0 ]
    version=$(tr -d '[:space:]' <VERSION)
    printf 'damage\n' >>"$stage/assets/pithead-os-v${version}.raucb"
    PASS=0 FAIL=0
    package_appliance_verify "$stage/system.img" "$stage/assets" "pithead-os-v${version}.img.xz" "pithead-os-v${version}.raucb" >"$stage/proof.log"
    [ "$FAIL" -eq 1 ]
    package_appliance_verdict "$stage/system.img" "$stage/update.raucb" "$stage" >"$stage/proof.log"
    printf 'damage\n' >>"$stage/assets/pithead-os-v${version}.img.xz"
    PASS=0 FAIL=0
    package_appliance_verify "$stage/system.img" "$stage/assets" "pithead-os-v${version}.img.xz" "pithead-os-v${version}.raucb" >"$stage/proof.log"
    [ "$FAIL" -eq 2 ]
    echo 'package-appliance-verdict: PASS'
fi
