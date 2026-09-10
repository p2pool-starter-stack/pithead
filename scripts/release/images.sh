#!/usr/bin/env bash
# Sourced by release.sh; shares its configuration and stage state.

# --- Stage 2: test gate ---------------------------------------------------------------------------

test_gate() {
    stage "2/7  Test gate (blocking)"
    if [ "$SKIP_TESTS" -eq 1 ]; then
        warn "Skipping 'make test' (--skip-tests). A skipped gate means an unvalidated release."
    else
        log "Running 'make test' (lint + dashboard pytest + shell suite + compose)..."
        run make test
        ok "make test passed."
    fi
    if [ "$SKIP_INTEGRATION" -eq 1 ]; then
        warn "Skipping the #54 integration matrix (--skip-integration) — the live-node gate did NOT run."
    else
        log "Running the #54 integration matrix against the real nodes..."
        # shellcheck disable=SC2086  # RELEASE_INTEGRATION_ARGS is an intentional word-split arg list
        run make test-integration ARGS="${RELEASE_INTEGRATION_ARGS:-}"
        ok "Integration matrix passed."
    fi
}

# --- Stage 3: build --------------------------------------------------------------------------------

# Multi-arch build+push needs a builder with the "docker-container" driver — the default "docker" driver
# can only build for the host platform (and can't --push a manifest list). Create a dedicated one if it's
# absent; --bootstrap also wires up QEMU so the non-native arch (e.g. amd64 on an Apple-Silicon host) can
# be cross-built. Idempotent.
ensure_buildx_builder() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if ! docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1; then
        log "Creating cross-build buildx builder '$BUILDX_BUILDER' (docker-container driver + QEMU)..."
        run docker buildx create --name "$BUILDX_BUILDER" --driver docker-container --bootstrap >/dev/null
    fi
}

build_images() {
    stage "3/7  Build + push images ($PLATFORMS, staging $STAGING_TAG)"
    # buildx builds the target platform(s) and --push uploads the result in one step — a buildx --push
    # image isn't loaded into the local docker store, so there is no separate local-build + push. Auth
    # and the builder must therefore be ready here, not in stage 4.
    ghcr_login
    ensure_buildx_builder
    local suffix context repo
    for suffix in "${IMAGES[@]}"; do
        context=$([ "$suffix" = "dashboard" ] && echo "dashboard" || echo "build/$suffix") # #1106
        repo="$(image_for "$suffix")"
        log "Building $repo:$STAGING_TAG  ($PLATFORMS, from $context)"
        local args=(
            docker buildx build "$context"
            --builder "$BUILDX_BUILDER"
            --platform "$PLATFORMS"
            --push
            -t "$repo:$STAGING_TAG"
            --label "org.opencontainers.image.title=Pithead ($suffix)"
            --label "org.opencontainers.image.version=$STACK_VERSION"
            --label "org.opencontainers.image.revision=$GIT_COMMIT"
            --label "org.opencontainers.image.source=$SOURCE_URL"
            --label "org.opencontainers.image.created=$BUILD_DATE"
        )
        # The dashboard bakes the version badge from build args; a release build flags PITHEAD_RELEASE=1
        # so the badge shows the clean vX.Y.Z instead of "dev · branch @ hash" (#58).
        if [ "$suffix" = "dashboard" ]; then
            args+=(
                --build-arg "PITHEAD_VERSION=$STACK_VERSION"
                --build-arg "PITHEAD_RELEASE=1"
                --build-arg "PITHEAD_GIT_COMMIT=$GIT_COMMIT"
                --build-arg "PITHEAD_GIT_BRANCH=$GIT_BRANCH"
            )
        fi
        run "${args[@]}"
    done
    ok "Built + pushed all 5 images for $PLATFORMS."
}

# --- Stage 4: stage (push to the RC tag, capture digests) -----------------------------------------

stage_push() {
    stage "4/7  Capture pushed manifest digests"
    # build_images already pushed each image (buildx --push). Record the manifest-LIST digest (the index
    # sha that spans every built platform) — promote re-tags it by digest, so :vX.Y.Z and :latest point
    # at the exact bytes the smoke stage validates.
    local suffix repo digest
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        if [ "$DRY_RUN" -eq 1 ]; then
            set_digest "$suffix" "$repo@sha256:$(printf '%064d' 0)"
            log "  digest: $repo@sha256:$(printf '%064d' 0)"
            continue
        fi
        # #557: plain `digest="$(...)"` aborts under errexit once retries are exhausted, BEFORE this
        # die() fires — `if !` suspends errexit for the assignment so the message is reachable.
        if ! digest="$(manifest_digest "$repo:$STAGING_TAG")" || [ -z "$digest" ]; then
            die "Could not read the pushed manifest digest for $repo:$STAGING_TAG."
        fi
        set_digest "$suffix" "$repo@$digest"
        log "  digest: $repo@$digest"
    done
    ok "Captured $STAGING_TAG digests for all 5 images."
}

ghcr_login() {
    local registry_host="${REGISTRY%%/*}" user token
    user="${GHCR_USER:-}"
    token="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
    [ -n "$token" ] || token="$(gh auth token 2>/dev/null || true)"
    [ -n "$user" ] || user="$(gh api user --jq .login 2>/dev/null || true)"
    if [ -z "$token" ]; then
        warn "No registry token (GHCR_TOKEN / GITHUB_TOKEN / gh auth) — assuming docker is already logged in to $registry_host."
        return 0
    fi
    # IMPORTANT: never route the token through run()/any echo. Pipe it straight to docker via stdin.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   %s[dry-run]%s docker login %s -u %s --password-stdin  (token not shown)\n' \
            "$C_YELLOW" "$C_RESET" "$registry_host" "${user:-<token-user>}"
        return 0
    fi
    log "Logging in to $registry_host as ${user:-<token-user>} (token not shown)..."
    printf '%s' "$token" | docker login "$registry_host" -u "${user:-x}" --password-stdin >/dev/null ||
        die "docker login to $registry_host failed."
    ok "Registry login OK."
}

# --- Stage 5: smoke test (validate the PUSHED artifacts) ------------------------------------------

smoke_test() {
    stage "5/7  Staging smoke test"
    if [ "$SKIP_SMOKE" -eq 1 ]; then
        warn "Skipping smoke test (--skip-smoke) — the pushed artifacts were NOT re-validated from the registry."
        return 0
    fi
    # Validate the captured bytes, never the mutable staging tag.
    local suffix repo digest got
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        digest="$(get_digest "$suffix")"
        is_digest_ref_for "$digest" "$repo" || die "Smoke: captured digest for $suffix is not a lowercase sha256 ref for $repo ('$digest')."
        log "Verifying $digest from the registry..."
        # Pull the target platform explicitly so an arm64 build host can inspect an amd64-only release.
        run docker pull --quiet --platform "${PLATFORMS%%,*}" "$digest"
        if [ "$DRY_RUN" -eq 0 ]; then
            got="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$digest" 2>/dev/null || true)"
            [ "$got" = "$STACK_VERSION" ] ||
                die "Smoke: $digest reports version '$got', expected '$STACK_VERSION'."
            # Require every target platform in the captured manifest list (#429 retries registry lag).
            local arches raw
            raw="$(retry_registry_read buildx_inspect "$digest" --raw)" ||
                die "Smoke: could not read the pushed manifest for $digest from the registry (after $REGISTRY_READ_RETRIES tries)."
            arches="$(printf '%s' "$raw" |
                python3 -c 'import sys,json;d=json.load(sys.stdin);print(" ".join(sorted({m.get("platform",{}).get("os","")+"/"+m["platform"]["architecture"] for m in d.get("manifests",[]) if m.get("platform",{}).get("architecture") not in (None,"unknown")})))' 2>/dev/null || true)"
            local p
            for p in ${PLATFORMS//,/ }; do
                case " $arches " in *" $p "*) ;; *) die "Smoke: $digest is missing target platform $p (got: ${arches:-none}). A wrong-arch build leaked through (the v1.0.0 arm64-only bug)." ;; esac
            done
            log "  $digest OK ($arches)"
        fi
    done
    if [ -n "${RELEASE_SMOKE_CMD:-}" ]; then
        log "Running RELEASE_SMOKE_CMD..."
        run bash -c "$RELEASE_SMOKE_CMD"
    fi
    ok "Staged images pull cleanly and report version $STACK_VERSION."
}

# --- Stage 6: promote by digest -------------------------------------------------------------------

promote() {
    stage "6/7  Promote by digest -> $TAG + latest"
    confirm "Promote the smoke-tested digests to $TAG and :latest (publishes user-facing tags)?" ||
        die "Promotion cancelled — nothing user-facing was published."
    ghcr_login
    local suffix repo digest expected got tag_ref
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        digest="$(get_digest "$suffix")"
        is_digest_ref_for "$digest" "$repo" || die "No valid lowercase sha256 digest for $suffix — run without --resume-promote, or stage first."
        log "Promoting $digest -> :$TAG, :latest"
        run docker buildx imagetools create --tag "$repo:$TAG" --tag "$repo:latest" "$digest"
        if [ "$DRY_RUN" -eq 0 ]; then
            expected="${digest##*@}"
            for tag_ref in "$repo:$TAG" "$repo:latest"; do
                got="$(REGISTRY_READ_EXPECT_DIGEST="$expected" manifest_digest "$tag_ref")" || die "Promotion: $tag_ref did not resolve to captured digest $expected."
                [ "$got" = "$expected" ] || die "Promotion: $tag_ref resolves to $got, expected captured digest $expected."
            done
        fi
    done
    ok "Promoted all 5 images to $TAG + latest."
}

# --- Stage 6b: sign the promoted digests (#376) ----------------------------------------------------

# A cosign key signature on each promoted image so `pithead upgrade` can refuse a re-pointed tag or
# a tampered registry. Sign the manifest-LIST digest promote just re-tagged — NEVER a per-arch child
# digest (that makes `cosign verify <tag>` fail) and never the tag (a tag is mutable; the signature
# must pin the bytes that were smoke-tested). No Rekor upload (--tlog-upload=false): the key is
# private infrastructure, installs verify with the committed cosign.pub via
# `cosign verify --key cosign.pub --private-infrastructure`. COSIGN_PASSWORD is read by cosign from
# the environment — it never touches argv, run(), or the log.
sign_images() {
    if [ "${COSIGN_ENABLED:-0}" -ne 1 ]; then
        log "Release signing off — skipping image signatures; the bundle stays digest-pinned."
        return 0
    fi
    stage "6b/7 Sign the promoted digests (cosign, #376)"
    local suffix digest
    for suffix in "${IMAGES[@]}"; do
        digest="$(get_digest "$suffix")"
        [ -n "$digest" ] || die "No staged digest for $suffix — nothing to sign."
        log "Signing $digest"
        run cosign sign --key "${COSIGN_KEY:-}" --tlog-upload=false --yes "$digest"
    done
    ok "Signed all 5 promoted digests (verify with the committed cosign.pub)."
}

# Detached signature for the install bundle (#376): the #59 dashboard upgrade downloads
# pithead.tar.gz (not images) and verifies it against the cosign.pub already on the host BEFORE
# extracting, so the tarball needs its own signature published next to it on the GitHub Release.
sign_bundle() { # <bundle> <sig-out>
    log "Signing the install bundle -> $(basename "$2")"
    run cosign sign-blob --key "${COSIGN_KEY:-}" --tlog-upload=false --yes --output-signature "$2" "$1"
}
