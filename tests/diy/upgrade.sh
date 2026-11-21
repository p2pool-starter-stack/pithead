# shellcheck shell=bash
previous_release_check() {
    local tag dir=$DIY_WORK/verify image
    tag=$(git ls-remote --tags --refs "$DIY_REPO_URL.git" | diy_previous_tag "$(cat "$DIY_ROOT/VERSION")")
    [ -n "$tag" ] || {
        echo "no release tag below $(cat "$DIY_ROOT/VERSION")"
        return 1
    }
    printf '%s\n' "$tag" >"$DIY_STATE_DIR/previous-tag"
    echo "resolved previous release: $tag"
    rm -rf "$dir"
    mkdir -p "$dir"
    curl -fsSL -o "$dir/pithead.tar.gz" "$DIY_REPO_URL/releases/download/$tag/pithead.tar.gz" &&
        curl -fsSL -o "$dir/pithead.tar.gz.sig" "$DIY_REPO_URL/releases/download/$tag/pithead.tar.gz.sig" || return 1
    cp "$DIY_ROOT/cosign.pub" "$dir/cosign.pub"
    image=$(grep -o 'ghcr.io/sigstore/cosign/cosign@sha256:[0-9a-f]*' "$DIY_ROOT/lib/pithead/03-release-verify.sh" | head -n 1)
    docker pull -q "$image" >/dev/null || return 1
    docker run --rm -e HOME=/tmp -v "$dir:/w:ro" -w /w "$image" verify-blob --key cosign.pub \
        --signature pithead.tar.gz.sig --insecure-ignore-tlog=true pithead.tar.gz
}

install_previous() {
    DIY_DIR=$DIY_WORK/live
    rm -rf "$DIY_DIR"
    mkdir -p "$DIY_DIR"
    tar xzf "$DIY_WORK/verify/pithead.tar.gz" -C "$DIY_DIR" --strip-components=1
}

image_ids() {
    (cd "$DIY_DIR" && docker compose ps -q | xargs -r docker inspect \
        --format '{{index .Config.Labels "com.docker.compose.service"}} {{.Image}}' | sort)
}

upgrade_check() {
    local before_config after
    before_config=$(jq -S 'del(.config_version)' "$DIY_DIR/config.json")
    image_ids >"$DIY_STATE_DIR/images-before"
    tar -C "$DIY_ROOT" --exclude=./config.json --exclude=./data --exclude=./backups -cf - . | tar -C "$DIY_DIR" -xf - || return 1
    (cd "$DIY_DIR" && bash scripts/build-pithead.sh && timeout 3600 ./pithead upgrade) || return 1
    pt version | grep -F "$(cat "$DIY_ROOT/VERSION")" || {
        echo "version after upgrade is not the candidate"
        return 1
    }
    [ "$(jq -S 'del(.config_version)' "$DIY_DIR/config.json")" = "$before_config" ] || {
        echo "config.json changed across upgrade beyond config_version"
        return 1
    }
    after=$(image_ids)
    [ "$(grep '^dashboard ' "$DIY_STATE_DIR/images-before")" != "$(grep '^dashboard ' <<<"$after")" ] || {
        echo "dashboard image identity did not change"
        return 1
    }
}
