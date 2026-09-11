#!/usr/bin/env bash
# Sourced by release.sh; shares its configuration and stage state.

# --- Stage 7: publish (git tag, GitHub Release, manifest, bundle) ---------------------------------

# The manifest line install.sh greps for (`bundle sha256: \`<64 hex>\``) — its only integrity check
# on a fresh download, since cosign may not be present yet. Its own function so the tests can drive
# this exact producer against install.sh's parser rather than hand-writing the format twice.
append_bundle_sha256() { # <manifest> <bundle>
    printf -- '- bundle sha256: `%s`\n' "$(sha256sum "$2" | cut -d' ' -f1)" >>"$1"
}

publish() {
    stage "7/7  Publish GitHub Release $TAG"
    local manifest="$WORKDIR/ingredients-$TAG.md"
    write_manifest "$manifest"
    local bundle="$WORKDIR/pithead.tar.gz" # versionless name → stable /releases/latest/download/ URL
    make_bundle "$bundle"
    # Bundle checksum into the manifest (#77 phase 1): install.sh verifies its download against
    # this line before it extracts anything. Appended here because write_manifest runs before the
    # bundle exists.
    append_bundle_sha256 "$manifest" "$bundle"
    local bundle_sig="" # pithead.tar.gz.sig — absent only on a deliberate --unsigned cut (#960)
    if [ "${COSIGN_ENABLED:-0}" -eq 1 ]; then
        bundle_sig="$bundle.sig" # the #59 upgrade runner fetches it by name
        sign_bundle "$bundle" "$bundle_sig"
    fi

    confirm "Create git tag $TAG, push it, fast-forward main to it, and publish the GitHub Release?" ||
        {
            warn "Publish cancelled. Images are promoted; re-run --resume-promote to finish, or publish by hand."
            return 0
        }

    run git tag -a "$TAG" -m "Pithead $TAG"
    run git push origin "$TAG"

    # Move main to the released commit (docs/dev/releasing.md § Branch mechanics). A plain push can
    # only fast-forward, so main gains no object the tag does not already name — which is what makes
    # the old post-release back-merge unnecessary (#1076). The Main Branch ruleset admits this via
    # the same admin bypass the protected tag push above already used.
    run git push origin "$GIT_COMMIT:refs/heads/main" ||
        warn "main was not fast-forwarded — run: git push origin $GIT_COMMIT:refs/heads/main  (the release is unaffected; main lags until this runs)."

    local notes="$WORKDIR/notes.md"
    changelog_notes >"$notes"
    cat "$manifest" >>"$notes"

    if command -v gh >/dev/null 2>&1; then
        # --draft holds the GitHub Release for review (not visible/announced until published by hand).
        # The images are already promoted, so the draft's install bundle works the moment it's published.
        local gh_args=(release create "$TAG" --title "Pithead $TAG" --notes-file "$notes")
        [ "$DRAFT" -eq 1 ] && gh_args+=(--draft)
        gh_args+=("$bundle")
        [ -n "$bundle_sig" ] && gh_args+=("$bundle_sig") # the .sig only exists when signing is on
        gh_args+=("$manifest")
        run gh "${gh_args[@]}"
        ok "GitHub Release $TAG $([ "$DRAFT" -eq 1 ] && echo 'created as a DRAFT (publish it from the Releases page when ready)' || echo published)."
    else
        warn "gh CLI not found — tag pushed, but create the release by hand. Notes: $notes  Assets: $bundle $bundle_sig $manifest"
    fi
}

# Ingredients manifest — exactly what's inside this release: the promoted image digests + upstream pins.
write_manifest() {
    local out="$1" suffix repo dg
    {
        printf '## Ingredients — Pithead %s\n\n' "$TAG"
        printf -- '- **Version:** %s\n- **Commit:** `%s`\n- **Built:** %s\n\n' "$STACK_VERSION" "$GIT_COMMIT" "$BUILD_DATE"
        printf '### Published images (`%s`, tags `%s` + `latest`)\n\n' "$REGISTRY" "$TAG"
        for suffix in "${IMAGES[@]}"; do
            repo="$(image_for "$suffix")"
            dg="$(get_digest "$suffix")"
            printf -- '- `%s`\n  - digest: `%s`\n' "$repo:$TAG" "${dg:-<not staged>}"
        done
        printf '\n### Upstream component pins\n\n'
        printf -- '- p2pool: `%s`\n' "$(pin p2pool)"
        printf -- '- monerod: `%s`\n' "$(pin monero)"
        printf -- '- xmrig-proxy: `%s`\n' "$(pin xmrig-proxy)"
        printf -- '- tor base: `%s`\n' "$(pin tor-base)"
        printf -- '- tari node: `%s`\n' "$(pin tari)"
        printf -- '- tari console wallet: `%s`\n' "$(pin tari-wallet)"
        printf -- '- caddy: `%s`\n' "$(pin caddy)"
        printf -- '- docker-socket-proxy: `%s`\n' "$(pin socket-proxy)"
    } >"$out"
    log "Wrote ingredients manifest: $out"
}

# The host paths under ./build/ that docker-compose.yml MOUNTS at runtime (volumes:), as opposed to
# build: contexts. A pull-based bundle builds nothing and the images do NOT bake these in — monerod, for
# instance, reads /home/ubuntu/bitmonero.conf.template purely from this host mount — so every one MUST ship in
# the bundle, or the container mounts an empty dir and fails to start (the v1.0.0 bundle missed monerod's
# template this way). Matches the volume short-syntax source (between "- " and the first ":"); ignores
# build:/context: lines so no Dockerfile lands in the bundle (which would flip is_source_checkout to true
# and make pithead build instead of pull). Sourced + unit-tested.
compose_build_mounts() {
    grep -oE '^[[:space:]]*-[[:space:]]+\./build/[^:[:space:]]+:' "${1:-docker-compose.yml}" |
        sed -E 's/^[[:space:]]*-[[:space:]]+//; s/:$//' | sort -u
}

# A pinned, pull-based install bundle: the runtime files needed to `./pithead setup` WITHOUT building.
# Deliberately ships NO image Dockerfiles — so pithead detects release mode (is_source_checkout=false),
# resolves STACK_VERSION from the bundled VERSION, and pulls the published `:vX.Y.Z` images. Every
# ./build/* path the compose mounts at runtime (compose_build_mounts) IS shipped, so the pulled
# containers find the config templates they render at setup.
make_bundle() {
    # Unpacks to a versionless "pithead/" dir. Ships only the operator docs needed to run the stack.
    local out="$1" d="$WORKDIR/pithead"
    mkdir -p "$d"
    cp pithead pithead-completion.bash VERSION docker-compose.yml config.minimal.json config.reference.json config.core-keys.json "$d/" 2>/dev/null || die "make_bundle: failed to copy required runtime files."
    # The bundle's own provenance anchor: the exact commit these bytes were cut from. The tier-4
    # --image-upgrade gate reads it to tie a candidate archive to a commit, and the promoted images
    # carry the same value in org.opencontainers.image.revision — so the two must agree or the
    # upgrade is not the one we think it is. Refuse a short or absent sha HERE rather than ship a
    # bundle that only fails much later, at the gate, on a box someone reserved to run it.
    [[ "${GIT_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || die "make_bundle: GIT_COMMIT must be a full 40-hex commit, got '${GIT_COMMIT:-<unset>}'."
    printf '%s\n' "$GIT_COMMIT" >"$d/PITHEAD_COMMIT" || die "make_bundle: failed to write PITHEAD_COMMIT."
    [ -e cosign.pub ] || [ "${COSIGN_ENABLED:-0}" -eq 0 ] || die "make_bundle: signing is enabled but cosign.pub is missing."
    [ ! -e cosign.pub ] || cp cosign.pub "$d/" 2>/dev/null || die "make_bundle: failed to copy cosign.pub."
    mkdir -p "$d/docs"
    local doc docs_url="https://github.com/p2pool-starter-stack/pithead/blob/$TAG"
    for doc in docs/{configuration,dashboard,faq,getting-started,hardware,monitoring,operations,privacy,telegram,workers}.md; do
        sed -E -e "s|]\\(\\.\\./([^):]+)\\)|]($docs_url/\\1)|g" -e "s|]\\(([^#./][^):]*)\\)|]($docs_url/docs/\\1)|g" -e "s|]\\(\\./([^):]+)\\)|]($docs_url/docs/\\1)|g" -e "s|(src(set)?=\")\\./images/|\\1https://raw.githubusercontent.com/p2pool-starter-stack/pithead/$TAG/docs/images/|g" "$doc" >"$d/$doc"
    done
    local m
    while IFS= read -r m; do
        [ -e "$m" ] || {
            warn "bundle: compose mounts '$m' but it is missing from the tree — skipping"
            continue
        }
        mkdir -p "$d/$(dirname "$m")"
        cp -R "$m" "$d/$(dirname "$m")/"
    done < <(compose_build_mounts docker-compose.yml)
    printf 'Pithead %s — pinned install bundle (images pulled from %s, no local build).\n\nQuick start:\n  1. cp config.minimal.json config.json   # then set your Monero + Tari payout addresses\n     (more options: config.reference.json)\n  2. ./pithead setup\n\nOffline operator guides are in docs/; start with docs/getting-started.md.\nThere are no build contexts here, so pithead pulls the published %s images instead of building.\n' \
        "$TAG" "$REGISTRY" "$TAG" >"$d/README.txt"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   %s[dry-run]%s would tar -> %s\n' "$C_YELLOW" "$C_RESET" "$out"
        return 0
    fi
    # Digest-pin the first-party images in the BUNDLED compose (#376). The released images pull by
    # mutable `:vX.Y.Z` tag, so a re-pointed tag / leaked registry token could substitute a
    # root-running image under the same tag. Pinning each to the immutable @sha256 digest promote just
    # published makes the pull content-addressed — this is what actually closes that vector (cosign
    # signing, when on, is the additional layer). The tag stays for readability; the digest wins.
    local suffix digest sha
    for suffix in "${IMAGES[@]}"; do
        digest="$(get_digest "$suffix")"
        [ -n "$digest" ] ||
            die "make_bundle: no promoted digest for $suffix — refusing to ship an un-pinned bundle (#376)."
        # get_digest stores a FULL ref ($repo@sha256:…); we append only the @sha256 part to the
        # existing image line (which already has the repo + tag), so pin by the bare digest.
        is_digest_ref_for "$digest" "$(image_for "$suffix")" ||
            die "make_bundle: digest for $suffix is not a lowercase sha256 ref ('$digest') — cannot pin (#376)."
        sha="${digest##*@}"
        sed -i.bak "s|\(pithead-${suffix}:\${STACK_VERSION:-dev}\)|\1@${sha}|" "$d/docker-compose.yml"
    done
    rm -f "$d/docker-compose.yml.bak"
    # Post-condition: NEVER ship a partially-pinned bundle. Every first-party image line must now
    # carry an @sha256 digest.
    local unpinned
    unpinned="$(grep -E "pithead-(tor|monero|p2pool|xmrig-proxy|dashboard):" "$d/docker-compose.yml" | grep -v "@sha256:" || true)"
    [ -z "$unpinned" ] ||
        die "make_bundle: first-party image(s) left un-pinned in the bundle compose (#376):"$'\n'"$unpinned"
    # --no-xattrs: we cut releases on macOS, where tar is bsdtar and stores each file's extended
    # attributes (incl. macOS's com.apple.provenance) as LIBARCHIVE.xattr.* pax headers. GNU tar on
    # a user's Linux box doesn't know that keyword and warns once per file on extract (#252). Stripping
    # xattrs makes the bundle clean; the flag is a portable no-op on GNU tar (xattrs aren't stored by
    # default), so release.sh stays correct if a release is ever cut on Linux.
    tar --no-xattrs -czf "$out" -C "$WORKDIR" "pithead"
    # Guard the fix (#252): the bundle must carry no extended-attribute pax headers
    # (LIBARCHIVE.xattr.* from bsdtar / SCHILY.xattr.* from GNU tar) — those make GNU tar warn once
    # per file on a Linux extract. pax headers store the keyword as plain text in the tar stream, so
    # grepping the decompressed bytes detects them regardless of which tar built the archive.
    if gzip -dc "$out" 2>/dev/null | grep -qa -e 'LIBARCHIVE.xattr' -e 'SCHILY.xattr'; then
        die "Bundle $out carries xattr pax headers (#252) — GNU tar will warn on extract. Does this tar honor --no-xattrs?"
    fi
    log "Wrote install bundle: $out"
}

# Release notes = the top (newest) section of CHANGELOG.md — the curated, user-facing summary.
changelog_notes() {
    if [ ! -f CHANGELOG.md ]; then
        printf 'Pithead %s\n' "$TAG"
        return
    fi
    # Print from the first "## [" heading up to (but not including) the next one.
    awk '/^## \[/{ if (seen) exit; seen=1 } seen' CHANGELOG.md
}
