# shellcheck shell=bash
BAKED_FIRST_PARTY_SERVICES="tor monero p2pool xmrig-proxy"

baked_third_party_refs() { # <staged compose>
    grep -oE '^[[:space:]]*image: (caddy|tecnativa/docker-socket-proxy):[^[:space:]@]+@sha256:[0-9a-f]{64}$' "$1" |
        sed -E 's/^[[:space:]]*image: //' | sort -u
}

verify_baked_image() { # <first-party ref with @sha256 digest>
    [ -z "${TEST_REGISTRY:-}" ] || return 0
    local cosign_image
    cosign_image=$(grep -oE '^readonly COSIGN_IMAGE="[^"]+"' lib/pithead/03-release-verify.sh | cut -d'"' -f2)
    [ -n "$cosign_image" ] && [ -s cosign.pub ] || {
        echo "build-image: no pinned cosign image or cosign.pub to verify $1" >&2
        return 1
    }
    docker run --rm -e HOME=/tmp -v "$PWD:/w:ro" -w /w "$cosign_image" verify --key cosign.pub --private-infrastructure "$1" >/dev/null || {
        echo "build-image: signature verification FAILED for $1" >&2
        return 1
    }
}

bake_image_archive() { # <ref with @sha256 digest> <archive name>
    local ref="$1" archive="$2" tag="${1%@*}"
    docker pull -q "$ref" >/dev/null || {
        echo "build-image: could not pull $ref to bake it" >&2
        return 1
    }
    docker tag "$ref" "$tag" || return 1
    docker save "$tag" | gzip -1 >"os/rootfs/images/$archive.tar.gz" || return 1
    [ -s "os/rootfs/images/$archive.tar.gz" ] || return 1
}

bake_service_images() { # <staged compose> <registry> <version>
    local compose="$1" registry="$2" version="$3" svc digest ref
    [ "$(baked_third_party_refs "$compose" | wc -l | tr -d ' ')" = 2 ] || {
        echo "build-image: expected the caddy and docker-socket-proxy pins in the staged compose" >&2
        return 1
    }
    for svc in $BAKED_FIRST_PARTY_SERVICES; do
        digest="$(grep -oE "pithead-${svc}:[^[:space:]]*@sha256:[0-9a-f]{64}" "$compose" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
        [ -n "$digest" ] || {
            echo "build-image: pithead-${svc} is not digest-pinned in the staged compose" >&2
            return 1
        }
        echo "==> baking pithead-${svc}:${version}"
        verify_baked_image "${registry}/pithead-${svc}:${version}@${digest}" || return 1
        bake_image_archive "${registry}/pithead-${svc}:${version}@${digest}" "$svc" || return 1
    done
    while read -r ref; do
        echo "==> baking ${ref%@*}"
        bake_image_archive "$ref" "$(basename "${ref%%:*}")" || return 1
    done < <(baked_third_party_refs "$compose")
}
