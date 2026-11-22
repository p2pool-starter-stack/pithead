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
        gh api "repos/$(cfg "$1" repo)/releases?per_page=50"
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

self_test() {
    local fail=0 t d out
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' RETURN
    check() {
        if [ "$2" = "$3" ]; then
            echo "ok   $1"
        else
            echo "FAIL $1: got '$2', want '$3'"
            fail=1
        fi
    }
    local h_old h_new sha_old sha_new
    h_old="$(printf 'a%.0s' {1..64})"
    h_new="$(printf 'b%.0s' {1..64})"
    sha_old="$(printf '1%.0s' {1..40})"
    sha_new="$(printf '2%.0s' {1..40})"
    export PIN_BUMP_ROOT="$t"
    mkdir -p "$t/build/monero" "$t/build/p2pool" "$t/build/xmrig-proxy" "$t/os/rootfs"
    printf 'FROM x\nARG MONERO_VERSION=v0.18.5.1\nARG MONERO_HASH=%s\nRUN y\n' "$h_old" >"$t/build/monero/Dockerfile"
    printf 'FROM x\nARG P2POOL_VERSION=v4.18.1\nARG P2POOL_HASH=%s\nRUN y\n' "$h_old" >"$t/build/p2pool/Dockerfile"
    printf 'FROM x\nARG XMRIG_PROXY_VERSION=6.26.0\nARG XMRIG_PROXY_HASH=%s\nRUN y\n' "$h_old" >"$t/build/xmrig-proxy/Dockerfile"
    printf '# pins the commit of RigForge\n# v1.18.1 (11111111); pin releases by commit.\nARG RIGFORGE_REF=%s\nRUN y\n' "$sha_old" >"$t/os/rootfs/Dockerfile"
    printf 'asset-bytes' >"$t/asset"
    export PIN_BUMP_ASSET_FILE="$t/asset"
    h_new="$(sha256sum <"$t/asset" | cut -d' ' -f1)"
    rel() { printf '{"tag_name":"%s","draft":false,"prerelease":false,"assets":[{"name":"%s","digest":"%s"}]}' "$1" "$2" "$3" >"$t/release.json"; }
    export PIN_BUMP_RELEASE_JSON="$t/release.json"

    check "current version reads each pin's spelling" \
        "$(current_version monero) $(current_version p2pool) $(current_version xmrig-proxy) $(current_version rigforge)" \
        "v0.18.5.1 v4.18.1 v6.26.0 v1.18.1"
    newer_than v4.18.10 v4.18.9 && d=newer || d=not
    check "version order is numeric, not lexical" "$d" newer
    newer_than v4.18.1 v4.18.1 && d=newer || d=not
    check "an equal version is not newer" "$d" not
    newer_than v4.17.9 v4.18.1 && d=newer || d=not
    check "an older release is not newer" "$d" not
    same_minor v0.18.6.0 v0.18.5.1 && d=same || d=other
    check "a monero patch stays in the pinned minor" "$d" same
    same_minor v0.19.0.0 v0.18.5.1 && d=same || d=other
    check "a monero minor is a different minor" "$d" other

    rel v4.19.0 p2pool-v4.19.0-linux-x64.tar.gz "sha256:$h_new"
    out="$(detect p2pool)"
    check "p2pool detect reports stale with the downloaded hash" "$(printf '%s' "$out" | grep -E '^(stale|latest|pin|branch)=' | tr '\n' ' ')" \
        "stale=true latest=v4.19.0 pin=$h_new branch=bot/p2pool-v4.19.0 "
    rel v4.19.0 p2pool-v4.19.0-linux-x64.tar.gz "sha256:$h_old"
    check "a release digest that disagrees with the download is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused
    rel v4.19.0 p2pool-v4.19.0-linux-x64.tar.gz ""
    check "a release without a digest is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused
    check "the command line exits non-zero when detect refuses" "$(bash "${BASH_SOURCE[0]}" detect p2pool >/dev/null 2>&1 && echo exit0 || echo nonzero)" nonzero
    rel v4.18.1 p2pool-v4.18.1-linux-x64.tar.gz "sha256:$h_new"
    check "an equal release is not stale" "$(detect p2pool | sed -n 's/^stale=//p')" false
    printf '{"tag_name":"v9.9.9","draft":false,"prerelease":true,"assets":[]}' >"$t/release.json"
    check "a prerelease is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused
    printf '{"tag_name":"nightly","draft":false,"prerelease":false,"assets":[]}' >"$t/release.json"
    check "a tag that is not a version is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused

    rel v6.27.0 xmrig-proxy-6.27.0-linux-static-x64.tar.gz "sha256:$h_new"
    out="$(detect xmrig-proxy)"
    check "xmrig-proxy detect names the tag spelling and the branch" "$(printf '%s' "$out" | grep -E '^(stale|current|latest)=' | tr '\n' ' ')" \
        "stale=true current=v6.26.0 latest=v6.27.0 "

    mrel() { jq -n --arg t "$1" --arg u "$2" '[{tag_name: $t, draft: false, prerelease: false}, {tag_name: $u, draft: false, prerelease: false}, {tag_name: "v0.18.5.1", draft: false, prerelease: false}]' >"$t/release.json"; }
    mrel v0.18.5.2 v0.18.5.0
    printf 'monero-linux-x64-v0.18.5.2.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    export PIN_BUMP_HASHES_FILE="$t/hashes.txt"
    out="$(detect monero)"
    check "monero patch bump is stale with the published hash" "$(printf '%s' "$out" | grep -E '^(stale|pin|held)=' | tr '\n' ' ')" "stale=true pin=$h_new held=none "
    printf 'monero-linux-x64-v0.18.5.2.tar.bz2, %s\n' "$h_old" >"$t/hashes.txt"
    check "monero refuses a download that hashes.txt contradicts" "$(detect monero 2>/dev/null && echo accepted || echo refused)" refused
    printf 'monero-linux-x64-v0.18.5.1.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    check "monero refuses a release hashes.txt does not list" "$(detect monero 2>/dev/null && echo accepted || echo refused)" refused
    printf 'monero-linux-x64-v0.19.0.0.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    mrel v0.19.0.0 v0.18.5.1
    out="$(detect monero)"
    check "a monero minor is held and the pinned minor has nothing newer" "$(printf '%s' "$out" | grep -E '^(stale|held)=' | tr '\n' ' ')" "stale=false held=minor "
    printf 'monero-linux-x64-v0.18.5.2.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    mrel v0.19.0.0 v0.18.5.2
    out="$(detect monero)"
    check "a monero patch in the pinned minor is still proposed after a new minor ships" "$(printf '%s' "$out" | grep -E '^(stale|latest|held)=' | tr '\n' ' ')" "stale=true latest=v0.18.5.2 held=minor "

    rel v1.18.2 "" ""
    export PIN_BUMP_COMMIT_SHA="$sha_new"
    out="$(detect rigforge)"
    check "rigforge resolves the tag to its commit" "$(printf '%s' "$out" | grep -E '^(stale|pin|branch)=' | tr '\n' ' ')" "stale=true pin=$sha_new branch=bot/rigforge-v1.18.2 "
    export PIN_BUMP_COMMIT_SHA="not-a-sha"
    check "rigforge refuses a value that is not a commit" "$(detect rigforge 2>/dev/null && echo accepted || echo refused)" refused
    export PIN_BUMP_COMMIT_SHA="$sha_old"
    check "rigforge at the pinned commit is not stale" "$(detect rigforge | sed -n 's/^stale=//p')" false
    rel v1.18.0 "" ""
    export PIN_BUMP_COMMIT_SHA="$sha_new"
    check "rigforge never moves backwards" "$(detect rigforge | sed -n 's/^stale=//p')" false

    apply_pin p2pool v4.19.0 "$h_new"
    check "apply rewrites the p2pool version and hash together" "$(cat "$t/build/p2pool/Dockerfile")" \
        "$(printf 'FROM x\nARG P2POOL_VERSION=v4.19.0\nARG P2POOL_HASH=%s\nRUN y' "$h_new")"
    apply_pin xmrig-proxy v6.27.0 "$h_new"
    check "apply writes xmrig-proxy without the v" "$(current_version xmrig-proxy)" v6.27.0
    check "xmrig-proxy file carries the bare version" "$(sed -n 's/^ARG XMRIG_PROXY_VERSION=//p' "$t/build/xmrig-proxy/Dockerfile")" 6.27.0
    apply_pin monero v0.18.5.2 "$h_new"
    check "apply rewrites the monero pair" "$(current_version monero) $(current_value monero)" "v0.18.5.2 $h_new"
    apply_pin rigforge v1.18.2 "$sha_new"
    check "apply rewrites the rigforge ref and its comment" "$(cat "$t/os/rootfs/Dockerfile")" \
        "$(printf '# pins the commit of RigForge\n# v1.18.2 (22222222); pin releases by commit.\nARG RIGFORGE_REF=%s\nRUN y' "$sha_new")"
    check "apply refuses a malformed hash" "$(apply_pin p2pool v4.20.0 abc 2>/dev/null && echo applied || echo refused)" refused
    check "apply refuses a malformed version" "$(apply_pin p2pool '1; rm' "$h_new" 2>/dev/null && echo applied || echo refused)" refused
    check "refusal leaves the pin untouched" "$(current_version p2pool)" v4.19.0

    printf '[{"number":1,"headRefName":"bot/p2pool-v4.19.0","author":{"login":"app/github-actions"}},{"number":2,"headRefName":"bot/p2pool-v4.18.9","author":{"login":"github-actions[bot]"}},{"number":3,"headRefName":"bot/monero-v0.18.5.2","author":{"login":"github-actions"}},{"number":4,"headRefName":"bot/p2pool-v1.0.0","author":{"login":"some-human"}},{"number":5,"headRefName":null,"author":{"login":"app/github-actions"}}]' >"$t/prs.json"
    check "superseded keeps the wanted head and closes older ones of the same component only" \
        "$(superseded p2pool bot/p2pool-v4.19.0 <"$t/prs.json")" $'1\tbot/p2pool-v4.19.0\tkeep\n2\tbot/p2pool-v4.18.9\tclose'
    check "superseded with no want closes every own head of the component" "$(superseded p2pool '' <"$t/prs.json" | grep -c close)" 2
    check "superseded leaves another component alone" "$(superseded monero bot/monero-v0.18.5.2 <"$t/prs.json")" $'3\tbot/monero-v0.18.5.2\tkeep'
    check "pr body has the three house sections" "$(pr_body p2pool v4.18.1 v4.19.0 | grep -c '^## ')" 3
    [ "$fail" = 0 ] && echo "pin-bump self-test OK"
    return "$fail"
}

case "${1:-}" in
detect) detect "${2:?usage: pin-bump.sh detect COMPONENT}" ;;
file) cfg "${2:?usage: pin-bump.sh file COMPONENT}" file ;;
apply) apply_pin "${2:?usage: pin-bump.sh apply COMPONENT VERSION VALUE}" "${3:?}" "${4:?}" ;;
superseded) superseded "${2:?usage: pin-bump.sh superseded COMPONENT [WANT]}" "${3:-}" ;;
body) pr_body "${2:?usage: pin-bump.sh body COMPONENT CURRENT LATEST}" "${3:?}" "${4:?}" ;;
--self-test) self_test ;;
*)
    echo "usage: pin-bump.sh detect|file|apply|superseded|body COMPONENT ... | --self-test (components: $COMPONENTS)" >&2
    exit 2
    ;;
esac
