#!/usr/bin/env bash
#
# Weekly upstream-currency watch (#1128).
#
# REPORTS ONLY. It never bumps a pin or opens a PR: Tari and monerod minors are scheduled data migrations (#1129).
# RigForge's xmrig-bump.yml opens a build-verified PR; the watchers share shape, not output.
#
# The pins come from scripts/release/release.sh's pin(), the release-notes source of truth.
#
# Two questions for Tari: is the pinned VERSION behind upstream, and would its gRPC schema break the vendored client?
#
# NOT asked here: whether an image `tag@sha256:...` still matches its tag. The digest is authoritative,
# but checking it needs a registry client with separate quay.io and Docker Hub token flows.
# It is its own source type and change.
#
# UNREACHABLE IS NOT CURRENT. Failures increment a counter, return non-zero, and name what was not checked.
# Otherwise a stopped watcher looks current; one scheduled workflow here once ran zero times unnoticed.
#
# Usage:
#   scripts/watch/pin-watch.sh              Print the markdown report on stdout; rc 1 if anything failed.
#   scripts/watch/pin-watch.sh --self-test  Drive the comparison logic against fixtures. No network.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Upstream release feed per component. Everything here is compared against
# `repos/<owner>/<repo>/releases/latest`, which also excludes prereleases — load-bearing, since
# tari's newest tags are v5.6.0-pre.* and proposing those onto the merge-mining leg would be worse
# than saying nothing.
#
# NOT WATCHED, on purpose, because they have no GitHub release feed: the alpine base in
# build/tor/Dockerfile, ubuntu:24.04 and python:3.11-slim. Dependabot's docker ecosystem does see
# those (it reads FROM lines), so they are covered — just not here. They are named in the report so
# their absence is a statement rather than a silence.
upstream_for() {
    case "$1" in
    monero) echo monero-project/monero ;;
    p2pool) echo SChernykh/p2pool ;;
    xmrig-proxy) echo xmrig/xmrig-proxy ;;
    tari) echo tari-project/tari ;;
    caddy) echo caddyserver/caddy ;;
    socket-proxy) echo Tecnativa/docker-socket-proxy ;;
    compose) echo docker/compose ;;
    cosign) echo sigstore/cosign ;;
    rigforge) echo p2pool-starter-stack/rigforge ;;
    esac
}

# Our pins do not spell versions the way upstream tags them, and this is the part that decides
# whether the watcher is useful or muted: `caddy:2.11.4` vs `v2.11.4` and `xmrig-proxy 6.26.0` vs
# `v6.26.0` are CURRENT, and `minotari_node:v5.3.1-mainnet` vs `v5.6.0` is stale. A plain string
# comparison calls the first two stale every week for ever, and a watcher that cries wolf weekly
# gets ignored — exactly as useless as one that never runs.
#
# Strips, in order: a digest suffix, an image name up to the last colon, a leading `v`, and a
# `-mainnet`/`-testnet` network suffix.
norm() {
    local v="$1"
    # Digest FIRST: `${v##*:}` cuts to the LAST colon, and a digest suffix carries one — so the
    # other order turns caddy:2.11.4@sha256:abc into "abc". (Caught by the self-test below on the
    # first run, which is the only reason it is not shipping that way.)
    v="${v%%@*}"
    v="${v##*:}"
    v="${v#v}"
    v="${v%-mainnet}"
    v="${v%-testnet}"
    printf '%s' "$v"
}

# Compare the numeric release core first, then put pre.N before its matching stable release.
# Prints older/equal/newer; refuse unfamiliar spellings instead of guessing an upgrade.
version_order() { # <pinned> <upstream>
    local a b i a_label b_label
    local -a left right
    a=$(norm "$1")
    b=$(norm "$2")
    [[ "$a" =~ ^[0-9]+(\.[0-9]+){2,3}(-[a-z]+\.[0-9]+)?$ &&
        "$b" =~ ^[0-9]+(\.[0-9]+){2,3}(-[a-z]+\.[0-9]+)?$ ]] || return 1
    IFS=. read -r -a left <<<"${a%%-*}"
    IFS=. read -r -a right <<<"${b%%-*}"
    for ((i = 0; i < 4; i++)); do
        if ((10#${left[i]:-0} < 10#${right[i]:-0})); then
            echo older
            return
        fi
        if ((10#${left[i]:-0} > 10#${right[i]:-0})); then
            echo newer
            return
        fi
    done
    if [[ "$a" == *-* && "$b" != *-* ]]; then
        echo older
        return
    fi
    if [[ "$a" != *-* && "$b" == *-* ]]; then
        echo newer
        return
    fi
    if [[ "$a" == *-* && "$b" == *-* ]]; then
        a_label=${a#*-}
        a_label=${a_label%%.*}
        b_label=${b#*-}
        b_label=${b_label%%.*}
        if [[ "$a_label" < "$b_label" ]]; then
            echo older
            return
        fi
        if [[ "$a_label" > "$b_label" ]]; then
            echo newer
            return
        fi
        a=${a##*.}
        b=${b##*.}
        if ((10#$a < 10#$b)); then
            echo older
            return
        fi
        if ((10#$a > 10#$b)); then
            echo newer
            return
        fi
    fi
    echo equal
}

version_status() { # <pinned> <upstream> -> report classification
    local order
    order=$(version_order "$1" "$2") || return 1
    case "$order" in
    older) echo stale ;;
    equal) echo current ;;
    newer) echo ahead ;;
    esac
}

newer_tari_prereleases() { # <pinned tag> -> newer prerelease tags, one per line
    local tag order feed
    feed=$(gh api 'repos/tari-project/tari/releases?per_page=100' \
        --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name' 2>/dev/null) || return 1
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        [[ "$tag" == *-* ]] || continue # Older upstream rows have a stable tag marked prerelease.
        [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+){2}(-[a-z]+\.[0-9]+)$ ]] || return 1
        order=$(version_order "$1" "$tag") || return 1
        if [ "$order" = older ]; then printf '%s\n' "$tag"; fi
    done <<<"$feed"
}

# The one lookup, wrapped so a failure is a COUNTED failure and never a quiet "current".
latest_release() { # <owner/repo> -> tag on stdout, rc 1 on any failure
    local tag
    tag=$(gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null) || return 1
    # Third-party input. A tag that is not shaped like a version must not be compared, printed into
    # an issue body, or otherwise trusted.
    [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+){2,3}(-[a-z]+\.[0-9]+)?$ ]] || return 1
    printf '%s' "$tag"
}

# Every pin above spells a VERSION, so the release tag is directly comparable to it. RIGFORGE_REF
# does not: os/rootfs/Dockerfile pins rigforge by COMMIT so that a moved tag cannot change the bake,
# and comparing a sha against `v1.16.0` reads **stale** every week for ever — including the hour
# after a correct bump. That is a different lie from the silence this row was added to end, not a
# fix for it. So the tag is resolved to the commit it names, with the same idiom this script already
# prints in its _COMMIT warning below, and the comparison is sha against sha.
#
# The resolution is a SECOND network call, and it gets the first one's treatment: a failure returns
# rc 1 so the caller renders an unchecked row. MEASURED with both refusals removed, so this names the
# real failure rather than the one it is tempting to assume: the fall-through is not a wrong verdict
# but a CONFIDENT one — the row reads `stale`, `failed` stays 0, the run exits 0 and stamps itself
# fully successful. A watcher that has stopped working then looks exactly like one with nothing to
# report, which is the defect this script's own header says it exists to prevent.
comparable() { # <component> <owner/repo> <tag> -> the tag in that pin's spelling, rc 1 on failure
    local sha
    case "$1" in
    rigforge)
        # `commits/<tag>`, never `git/refs/tags/<tag>`: every rigforge release tag is annotated, so
        # the refs endpoint answers with the TAG object's sha, which is also 40 hex and so passes
        # the shape check below. It can never equal a commit pin, and the row would read stale for
        # ever — including right after a correct bump, which is the failure this row exists to catch.
        sha=$(gh api "repos/$2/commits/$3" --jq .sha 2>/dev/null) || return 1
        # Third-party input, under the same rule as the tag itself: a value that is not shaped like
        # a commit must not be compared, and must not be printed into an issue body.
        printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$' || return 1
        printf '%s' "$sha"
        ;;
    *) printf '%s' "$3" ;;
    esac
}

tari_proto_ref() { # <node image pin> -> upstream tag
    local ref="${1%%@*}"
    ref="${ref##*:}"
    ref="${ref%-mainnet}"
    printf '%s' "$ref" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+(-pre\.[0-9]+)?$' || return 1
    printf '%s' "$ref"
}
run_buf() {
    docker run --rm \
        -v "$ROOT/dashboard/mining_dashboard/client/tari/proto:/workspace" \
        --workdir /workspace bufbuild/buf:1.71.0@sha256:7f3e3dfb8650f39878625bbc9f2016a51a781693b209165671d5a61d11c74992 "$@"
}
check_tari_protos() { # <upstream tag> -> 0 compatible, 1 local, 2 upstream, 3 drift, 4 comparison failure
    local upstream="https://github.com/tari-project/tari.git#tag=$1,subdir=applications/minotari_app_grpc/proto" rc=0
    run_buf build . >&2 || return 1
    run_buf build "$upstream" >&2 || return 2
    run_buf breaking "$upstream" --against . >&2 || rc=$?
    [ "$rc" -eq 100 ] && return 3
    [ "$rc" -eq 0 ] || return 4
}
add_tari_proto_row() {
    local raw ref rc=0
    raw=$(tree_pin tari 2>/dev/null) || raw=""
    if ! ref=$(tari_proto_ref "$raw"); then
        row "tari gRPC schema" "\`f42e14d\`" "—" "**could not read the pinned node tag — NOT checked**"
        failed=$((failed + 1))
        return
    fi
    check_tari_protos "$ref" || rc=$?
    case "$rc" in
    0) row "tari gRPC schema" "\`f42e14d\`" "\`$ref\`" "compatible" ;;
    1)
        row "tari gRPC schema" "\`f42e14d\`" "\`$ref\`" "**vendored schema build failed — NOT checked**"
        failed=$((failed + 1))
        ;;
    2)
        row "tari gRPC schema" "\`f42e14d\`" "\`$ref\`" "**upstream schema fetch/build failed — NOT checked**"
        failed=$((failed + 1))
        ;;
    3)
        row "tari gRPC schema" "\`f42e14d\`" "\`$ref\`" "**breaking drift**"
        stale=$((stale + 1))
        ;;
    *)
        row "tari gRPC schema" "\`f42e14d\`" "\`$ref\`" "**schema comparison failed — NOT checked**"
        failed=$((failed + 1))
        ;;
    esac
}
run_go_raise_watch() { bash "$ROOT/scripts/watch/go-raise-watch.sh"; }
finish_report() {
    local raise_rc=0
    if [ -f "$ROOT/os/rootfs/Dockerfile" ]; then
        run_go_raise_watch || raise_rc=$?
    fi
    if [ "$failed" -eq 0 ] && [ "$raise_rc" -eq 0 ]; then
        printf '\n%s\n' "_Last fully successful check: $(date -u '+%Y-%m-%d %H:%M UTC')_"
        return 0
    fi
    return 1
}

if [ "${1:-}" = "--self-test" ]; then
    # shellcheck source=tests/watch/test-pin-watch.sh
    source "$ROOT/tests/watch/test-pin-watch.sh"
fi

# --- the report ----------------------------------------------------------------------------------

# Sourcing only defines the functions; release.sh guards its main() behind a BASH_SOURCE check.
# shellcheck source=/dev/null
set -- # release.sh's arg parser must not see ours
# shellcheck disable=SC1091
source "$ROOT/scripts/release/release.sh"

# The appliance rootfs builds three more things from an `ARG` — two binaries compiled from source
# and the RigForge tree fetched as a source tarball — and dependabot has no ecosystem for an ARG
# consumed by a download, so nothing else can see any of them. They live under `os/`, hence the
# guard: a checkout without the appliance tree runs the shorter loop, not a wrong one.
#
# BOUNDARY, stated because a silent one is what this whole issue is about: GitHub runs `schedule:`
# from the DEFAULT branch, so a single-job workflow only ever reads `develop` and these two rows
# were simply absent from a run that looks complete while the default branch had no `os/`
# (#1146). Since 2026-09-06 `develop` carries the appliance tree, so one run reads every pin and
# the report below carries the appliance block whenever the tree has `os/rootfs/Dockerfile`.
components="monero p2pool xmrig-proxy tari caddy socket-proxy"
lane="the product stack"
# A real `if`, for the same reason the publish step in pin-watch.yml uses one: `[ -f X ] && var=…`
# evaluates to 1 on a checkout without `os/`, which is only safe while nothing depends on the exit status.
if [ -f "$ROOT/os/rootfs/Dockerfile" ]; then
    components="$components compose cosign rigforge"
    lane="the product stack and the appliance rootfs"
fi

# release.sh's pin() is the one place pins are read from the tree; the three rootfs `ARG`s have no
# case there because a release does not bundle them.
tree_pin() {
    case "$1" in
    compose) sed -n 's/^ARG COMPOSE_VERSION=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    cosign) sed -n 's/^ARG COSIGN_VERSION=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    rigforge) sed -n 's/^ARG RIGFORGE_REF=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    *) pin "$1" ;;
    esac
}

failed=0
stale=0
rows=""
tari_prereleases=""

row() { rows="${rows}| $1 | $2 | $3 | $4 |"$'\n'; }

for component in $components; do
    raw=$(tree_pin "$component" 2>/dev/null) || raw=""
    if [ -z "$raw" ]; then
        row "$component" "—" "—" "**could not read the pin from the tree**"
        failed=$((failed + 1))
        continue
    fi
    repo=$(upstream_for "$component")
    if ! latest=$(latest_release "$repo"); then
        row "$component" "\`$(norm "$raw")\`" "—" "**upstream lookup failed — NOT checked**"
        failed=$((failed + 1))
        continue
    fi
    # A resolution failure is its own row, with its own sentence. Sharing the string above would
    # let either guard silently cover for the other's deletion, which this repo has already shipped
    # once. The tag IS known here, so it is still reported — only the verdict is withheld.
    if ! cmp_to=$(comparable "$component" "$repo" "$latest"); then
        row "$component" "\`$(norm "$raw")\`" "\`$(norm "$latest")\`" "**upstream tag could not be resolved to a commit — NOT checked**"
        failed=$((failed + 1))
        continue
    fi
    if [ "$component" = rigforge ]; then
        if [ "$(norm "$raw")" = "$(norm "$cmp_to")" ]; then
            verdict=current
        else
            verdict="**stale** → \`$latest\`"
            stale=$((stale + 1))
        fi
    elif ! status=$(version_status "$raw" "$cmp_to"); then
        verdict="**version could not be compared — NOT checked**"
        failed=$((failed + 1))
    elif [ "$status" = current ]; then
        verdict="current"
    elif [ "$status" = stale ]; then
        verdict="**stale** → \`$latest\`"
        stale=$((stale + 1))
    else
        verdict="pinned version is newer than latest stable"
    fi
    row "$component" "\`$(norm "$raw")\`" "\`$(norm "$latest")\`" "$verdict"
    if [ "$component" = tari ]; then
        if ! tari_prereleases=$(newer_tari_prereleases "$raw"); then
            tari_prereleases="**prerelease lookup failed — NOT checked**"
            failed=$((failed + 1))
        elif [ -n "$tari_prereleases" ]; then
            tari_prereleases=${tari_prereleases//$'\n'/, }
        else
            tari_prereleases="none in the latest 100 releases"
        fi
    fi
done

add_tari_proto_row

printf '%s\n\n' "Upstream currency for $lane, checked weekly by \`scripts/watch/pin-watch.sh\`. This never bumps anything."
printf '| component | pinned | upstream latest | |\n|---|---|---|---|\n%s\n' "$rows"
printf '%s\n' "Newer Tari prereleases (review separately; release policy does not automatically accept them): ${tari_prereleases:-not checked}."
printf '%s\n' "Not watched here, because they publish no GitHub release feed: the alpine base image, \`ubuntu:24.04\`, \`python:3.11-slim\`. Dependabot's docker ecosystem reads those \`FROM\` lines and does cover them."
# Both arms stay: the else-arm is what a checkout without `os/` reports (a branch cut before the
# appliance tree existed), and it says so instead of printing a table that silently lacks two rows.
if [ -f "$ROOT/os/rootfs/Dockerfile" ]; then
    # The rootfs COMPILES these two from source on a pinned Go toolchain rather than downloading a
    # release binary, so each carries a paired _COMMIT ARG and the VERSION alone decides nothing.
    # Bumping the version and leaving the commit still builds the old code — the same half-done bump
    # #1137 describes for image digests. (This warning came from the appliance-lane watcher this
    # script replaced; the fact outlived the file.)
    printf '%s\n' "\`compose\` and \`cosign\` are compiled from source in \`os/rootfs/Dockerfile\`, so each bump is TWO ARGs — the version AND its paired \`_COMMIT\`. Resolve the commit with \`gh api repos/<owner>/<repo>/commits/<tag> --jq .sha\`; bumping the version alone still builds the old code."
    # RIGFORGE_REF is the opposite spelling and needs the same idiom pointed the other way: the
    # table resolves the tag to a commit to reach its verdict, and whoever acts on a stale row has
    # to write that commit into the ARG. Saying which commit here saves them repeating the lookup.
    printf '%s\n' "\`RIGFORGE_REF\` pins a COMMIT, not a tag, so a moved tag cannot change the bake. The row above compares it against the commit its latest release points at; to bump it, write that commit — \`gh api repos/p2pool-starter-stack/rigforge/commits/<tag> --jq .sha\` — into \`ARG RIGFORGE_REF\`, release by release."
else
    printf '%s\n' "The appliance rootfs's own pins (its docker-compose, cosign and baked RigForge tree, all built from \`ARG\` values that no dependabot ecosystem can read) are NOT in this table because this checkout has no \`os/rootfs/Dockerfile\`. A run on \`develop\`, which carries the appliance tree, lists them (#1146)."
fi
printf '%s\n' "Also NOT checked: whether each image pin's digest still corresponds to its tag. The digest is what actually runs, so a half-done bump is invisible to the table above."
if [ "$failed" -gt 0 ]; then
    printf '\n%s\n' "**$failed lookup(s) could not run — those rows are unchecked, not current.**"
fi
printf '\n%s\n' "<!-- pin-watch: stale=$stale failed=$failed -->"

printf '\n'
finish_report
