#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPONENTS="monero p2pool xmrig-proxy rigforge"
HEX64_RE='^[0-9a-f]{64}$'
HEX40_RE='^[0-9a-f]{40}$'

cfg() {
    case "$1:$2" in
    monero:file) echo build/monero/Dockerfile ;;
    monero:repo) echo monero-project/monero ;;
    monero:vvar) echo MONERO_VERSION ;;
    monero:hvar) echo MONERO_HASH ;;
    monero:tag_re) echo '^v0\.[0-9]+\.[0-9]+\.[0-9]+$' ;;
    monero:asset) echo "monero-linux-x64-$3.tar.bz2" ;;
    monero:url) echo "https://downloads.getmonero.org/cli/monero-linux-x64-$3.tar.bz2" ;;
    p2pool:file) echo build/p2pool/Dockerfile ;;
    p2pool:repo) echo SChernykh/p2pool ;;
    p2pool:vvar) echo P2POOL_VERSION ;;
    p2pool:hvar) echo P2POOL_HASH ;;
    p2pool:tag_re) echo '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' ;;
    p2pool:asset) echo "p2pool-$3-linux-x64.tar.gz" ;;
    p2pool:url) echo "https://github.com/SChernykh/p2pool/releases/download/$3/p2pool-$3-linux-x64.tar.gz" ;;
    xmrig-proxy:file) echo build/xmrig-proxy/Dockerfile ;;
    xmrig-proxy:repo) echo xmrig/xmrig-proxy ;;
    xmrig-proxy:vvar) echo XMRIG_PROXY_VERSION ;;
    xmrig-proxy:hvar) echo XMRIG_PROXY_HASH ;;
    xmrig-proxy:tag_re) echo '^v[0-9]+\.[0-9]+\.[0-9]+$' ;;
    xmrig-proxy:asset) echo "xmrig-proxy-${3#v}-linux-static-x64.tar.gz" ;;
    xmrig-proxy:url) echo "https://github.com/xmrig/xmrig-proxy/releases/download/$3/xmrig-proxy-${3#v}-linux-static-x64.tar.gz" ;;
    rigforge:file) echo os/rootfs/Dockerfile ;;
    rigforge:repo) echo p2pool-starter-stack/rigforge ;;
    rigforge:tag_re) echo '^v[0-9]+\.[0-9]+\.[0-9]+$' ;;
    *)
        echo "unknown component or key: $1 $2" >&2
        return 1
        ;;
    esac
}

dockerfile() {
    printf '%s' "${PIN_BUMP_ROOT:-$ROOT}/$(cfg "$1" file)"
}

pin_spelling() {
    case "$1" in
    xmrig-proxy) printf '%s' "${2#v}" ;;
    *) printf '%s' "$2" ;;
    esac
}

current_version() {
    local c="$1" f v
    f="$(dockerfile "$c")"
    if [ "$c" = rigforge ]; then
        sed -nE 's/^# (v[0-9]+\.[0-9]+\.[0-9]+) \([0-9a-f]{8}\); pin releases by commit\.$/\1/p' "$f" | head -1
        return
    fi
    v="$(sed -n "s/^ARG $(cfg "$c" vvar)=//p" "$f" | head -1)"
    [ "$c" = xmrig-proxy ] && v="v$v"
    printf '%s' "$v"
}

current_value() {
    local c="$1" f
    f="$(dockerfile "$c")"
    if [ "$c" = rigforge ]; then
        sed -n 's/^ARG RIGFORGE_REF=//p' "$f" | head -1
    else
        sed -n "s/^ARG $(cfg "$c" hvar)=//p" "$f" | head -1
    fi
}

newer_than() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | tail -1)" = "${1#v}" ]
}

same_minor() {
    [ "$(printf '%s' "${1#v}" | cut -d. -f1-2)" = "$(printf '%s' "${2#v}" | cut -d. -f1-2)" ]
}

release_json() {
    if [ -n "${PIN_BUMP_RELEASE_JSON:-}" ]; then
        cat "$PIN_BUMP_RELEASE_JSON"
        return
    fi
    if [ "$1" = monero ]; then
        gh api "repos/$(cfg "$1" repo)/releases?per_page=100"
    else
        gh api "repos/$(cfg "$1" repo)/releases/latest"
    fi
}

monero_in_minor() {
    jq -c --arg p "v$(printf '%s' "${1#v}" | cut -d. -f1-2)." '
        [.[] | select((.draft // false) == false and (.prerelease // false) == false and ((.tag_name // "") | startswith($p)))][0] // empty'
}

monero_newest() {
    jq -r '[.[] | select((.draft // false) == false and (.prerelease // false) == false) | .tag_name][0] // empty'
}

release_tag() {
    local c="$1" tag
    tag="$(jq -r 'select((.draft // false) == false and (.prerelease // false) == false) | .tag_name // empty')"
    [[ "$tag" =~ $(cfg "$c" tag_re) ]] || {
        echo "latest release tag '$tag' is not a stable $c version" >&2
        return 1
    }
    printf '%s' "$tag"
}

asset_digest() {
    jq -r --arg n "$1" '[.assets[]? | select(.name == $n) | .digest // empty][0] // "" | sub("^sha256:"; "")'
}

download_sha256() {
    if [ -n "${PIN_BUMP_ASSET_FILE:-}" ]; then
        sha256sum <"$PIN_BUMP_ASSET_FILE" | cut -d' ' -f1
        return
    fi
    curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 600000000 --retry 3 "$1" | sha256sum | cut -d' ' -f1
}

monero_listed_hash() {
    local text
    if [ -n "${PIN_BUMP_HASHES_FILE:-}" ]; then
        text="$(cat "$PIN_BUMP_HASHES_FILE")"
    else
        text="$(curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 2000000 --retry 3 https://www.getmonero.org/downloads/hashes.txt)" || return 1
    fi
    printf '%s\n' "$text" | { grep -F -- "$1" || true; } | { grep -oE '[0-9a-f]{64}' || true; } | head -1
}

resolve_hash() {
    local c="$1" tag="$2" json="$3" asset digest got listed
    asset="$(cfg "$c" asset "$tag")"
    got="$(download_sha256 "$(cfg "$c" url "$tag")")" || return 1
    [[ "$got" =~ $HEX64_RE ]] || {
        echo "could not hash $asset" >&2
        return 1
    }
    if [ "$c" = monero ]; then
        listed="$(monero_listed_hash "$asset")" || return 1
        [ "$listed" = "$got" ] || {
            echo "published hashes.txt ('${listed:-none}') does not match the download ($got) for $asset" >&2
            return 1
        }
    else
        digest="$(printf '%s' "$json" | asset_digest "$asset")"
        [ -n "$digest" ] || {
            echo "release carries no published digest for $asset; nothing to verify the download against" >&2
            return 1
        }
        [ "$digest" = "$got" ] || {
            echo "release asset digest $digest does not match the download $got for $asset" >&2
            return 1
        }
    fi
    printf '%s' "$got"
}

resolve_commit() {
    local sha
    if [ -n "${PIN_BUMP_COMMIT_SHA:-}" ]; then
        sha="$PIN_BUMP_COMMIT_SHA"
    else
        sha="$(gh api "repos/$(cfg rigforge repo)/commits/$1" --jq .sha)"
    fi
    [[ "$sha" =~ $HEX40_RE ]] || {
        echo "tag $1 did not resolve to a commit: '$sha'" >&2
        return 1
    }
    printf '%s' "$sha"
}

emit() {
    printf 'stale=%s\ncomponent=%s\ncurrent=%s\nlatest=%s\npin=%s\nbranch=bot/%s-%s\nheld=%s\n' "$1" "$2" "$3" "$4" "$5" "$2" "$4" "$6"
}

detect() {
    local c="$1" cur latest json pin newest held=none
    cur="$(current_version "$c")"
    [[ "$cur" =~ $(cfg "$c" tag_re) ]] || {
        echo "no valid $c pin in $(dockerfile "$c"): '$cur'" >&2
        return 1
    }
    json="$(release_json "$c")" || return 1
    if [ "$c" = monero ]; then
        newest="$(printf '%s' "$json" | monero_newest)" || return 1
        same_minor "$newest" "$cur" || held=minor
        json="$(printf '%s' "$json" | monero_in_minor "$cur")" || return 1
        [ -n "$json" ] || {
            emit false "$c" "$cur" "$cur" "" "$held"
            return
        }
    fi
    latest="$(printf '%s' "$json" | release_tag "$c")" || return 1
    if ! newer_than "$latest" "$cur"; then
        emit false "$c" "$cur" "$latest" "" "$held"
        return
    fi
    if [ "$c" = rigforge ]; then
        pin="$(resolve_commit "$latest")" || return 1
        [ "$pin" != "$(current_value "$c")" ] || {
            emit false "$c" "$cur" "$latest" "" "$held"
            return
        }
    else
        pin="$(resolve_hash "$c" "$latest" "$json")" || return 1
    fi
    emit true "$c" "$cur" "$latest" "$pin" "$held"
}

apply_pin() {
    local c="$1" version="$2" value="$3" f tmp
    [[ "$version" =~ $(cfg "$c" tag_re) ]] || {
        echo "refusing malformed version '$version'" >&2
        return 1
    }
    f="$(dockerfile "$c")"
    tmp="$(mktemp)"
    if [ "$c" = rigforge ]; then
        [[ "$value" =~ $HEX40_RE ]] || {
            echo "refusing malformed commit '$value'" >&2
            rm -f "$tmp"
            return 1
        }
        sed -E "s/^ARG RIGFORGE_REF=.*/ARG RIGFORGE_REF=${value}/; s/^# v[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{8}\); pin releases by commit\.\$/# ${version} (${value:0:8}); pin releases by commit./" "$f" >"$tmp"
    else
        [[ "$value" =~ $HEX64_RE ]] || {
            echo "refusing malformed hash '$value'" >&2
            rm -f "$tmp"
            return 1
        }
        sed -E "s/^ARG $(cfg "$c" vvar)=.*/ARG $(cfg "$c" vvar)=$(pin_spelling "$c" "$version")/; s/^ARG $(cfg "$c" hvar)=.*/ARG $(cfg "$c" hvar)=${value}/" "$f" >"$tmp"
    fi
    cat "$tmp" >"$f"
    rm -f "$tmp"
    [ "$(current_version "$c")" = "$version" ] && [ "$(current_value "$c")" = "$value" ]
}

superseded() {
    local c="$1" want="${2:-}"
    jq -r --arg want "$want" --arg prefix "bot/$c-" '
        def trusted: ((.author.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) == "github-actions";
        def ours: ((.headRefName // "") | startswith($prefix));
        (map(select(trusted and ours and .headRefName == $want)) | .[0].headRefName // "") as $keep |
        map(select(trusted and ours))[] |
        [ (.number | tostring), .headRefName, (if .headRefName == $keep then "keep" else "close" end) ] | @tsv'
}

pr_body() {
    local c="$1" cur="$2" latest="$3" proof how
    case "$c" in
    rigforge)
        how="The workflow resolved the release tag to its commit and wrote the commit and the version comment together."
        proof="the \`tier4-kvm\` phases that exercise the baked RigForge tree must be green at this head before merge, and \`tests/stack/appliance/test-appliance-build-compose-source.sh\` names the pinned commit, so a human updates it in this PR"
        ;;
    monero)
        how="The workflow downloaded the release tarball and refused to continue unless its sha256 equals the one in Monero's published hashes.txt (the file's signature is not verified), then wrote the version and the hash together."
        proof="a \`tier4-e2e\` \`targeted\` run on the \`${c}\` phase must be green at this head before merge: it builds the image from the new version and hash and shows the service healthy"
        ;;
    *)
        how="The workflow downloaded the release asset and refused to continue unless its sha256 equals the digest GitHub publishes for that asset, then wrote the version and the hash together."
        proof="a \`tier4-e2e\` \`targeted\` run on the \`${c}\` phase must be green at this head before merge: it builds the image from the new version and hash and shows the service healthy"
        ;;
    esac
    cat <<EOF
## What's the problem

Upstream released ${latest}; \`$(cfg "$c" file)\` pins ${cur}. Part of #4133.

## How I fixed it

Automated bump of the $c pin to ${latest} only, opened by \`.github/workflows/pin-bump.yml\` running \`scripts/watch/pin-bump.sh\`. ${how}

## Here is the proof

Pending: ${proof}. A PR opened with the Actions token triggers no \`pull_request\` checks of its own, so tiers 1 to 3 run once a maintainer pushes to this branch.
EOF
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

case "${1:-}" in
detect) detect "${2:?usage: pin-bump.sh detect COMPONENT}" ;;
file) cfg "${2:?usage: pin-bump.sh file COMPONENT}" file ;;
apply) apply_pin "${2:?usage: pin-bump.sh apply COMPONENT VERSION VALUE}" "${3:?}" "${4:?}" ;;
superseded) superseded "${2:?usage: pin-bump.sh superseded COMPONENT [WANT]}" "${3:-}" ;;
body) pr_body "${2:?usage: pin-bump.sh body COMPONENT CURRENT LATEST}" "${3:?}" "${4:?}" ;;
--self-test) bash "$ROOT/scripts/watch/pin-bump-selftest.sh" ;;
*)
    echo "usage: pin-bump.sh detect|file|apply|superseded|body COMPONENT ... | --self-test (components: $COMPONENTS)" >&2
    exit 2
    ;;
esac
