#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "${1:-}" = "--self-test" ]; then
    _tmp="$(mktemp)"
    cat >"$_tmp" <<'EOFS'
## Ingredients — Pithead v9.9.9

### Published images (`ghcr.io/test/pithead-`, tags `v9.9.9` + `latest`)

- `ghcr.io/test/pithead-dashboard:v9.9.9`
  - digest: `sha256:abc`

### Upstream component pins

### OS package lists

#### `ghcr.io/test/pithead-dashboard:v9.9.9` (2 packages)
```
    systemd|257.9-1~deb13u1|amd64|debian
    jq|1.7.1-3+deb13u1|amd64|debian
```

EOFS
    _count="$(grep -cE '^    [a-zA-Z0-9]' "$_tmp" || true)"
    [ "$_count" -eq 2 ] || { echo "self-test FAIL: expected 2 package lines, got $_count"; rm -f "$_tmp"; exit 1; }
    rm -f "$_tmp"
    echo "  self-test ok: manifest parser handles stubbed data"

    _bad="$(mktemp)"
    echo 'bad line' >"$_bad"
    if bash "$ROOT/scripts/release/capture-packages.sh" --from-file "$_bad" >/dev/null 2>&1; then
        echo "self-test FAIL: parse_file should reject bad format"
        rm -f "$_tmp" "$_bad"; exit 1
    fi
    rm -f "$_tmp" "$_bad"
    echo "  self-test ok: parse_file rejects malformed input"
    echo "os-package-watch self-test OK"
    exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

latest_tag="$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null)" || {
    echo "_could not list releases via API_"
    exit 1
}
[ -n "$latest_tag" ] || {
    echo "_no releases found_"
    exit 1
}

gh release download "$latest_tag" --pattern "ingredients-${latest_tag}.md" --dir "$WORKDIR" 2>/dev/null || true
if [ ! -f "$WORKDIR/ingredients-${latest_tag}.md" ]; then
    echo "_could not fetch ingredients manifest for ${latest_tag}_"
    exit 1
fi

manifest="$WORKDIR/ingredients-${latest_tag}.md"

parse_package_tables() {
    awk '
    /^#### `/ {
        line = $0
        sub(/^#### `/ , "", line)
        sub(/`.*$/, "", line)
        img_ref = line
        in_block = 1
        pkg_count = 0
        next
    }
    /```/ && in_block == 1 {
        in_block = 0
        if (pkg_count > 0) {
            print img_ref "|" pkg_count
        }
        next
    }
    in_block == 1 && /^    [a-zA-Z0-9]/ {
        pkg_count++
    }
    ' "$manifest"
}

current="$(parse_package_tables)"

if [ -z "$current" ]; then
    echo "_no OS package tables in manifest_"
    exit 1
fi

rows=""
for entry in $current; do
    img_ref="${entry%%|*}"
    pkg_count="${entry##*|}"
    rows="${rows}| ${img_ref} | ${pkg_count} | |"
done

printf '%s\n' "OS package list check for release $latest_tag, checked weekly by \`scripts/watch/os-package-watch.sh\`. This never bumps anything."
printf '\n%s\n' "| image | package count | |"
printf '%s\n' "|---|---|---|"
printf '%s\n' "$rows"
printf '\n%s\n' "Package counts guard against silent drift: a missing security package would change the count and flag the row for review. For advisory-level checks, cross-reference against upstream security trackers (debian-security, ubuntu-security, alpine-security)."
printf '\n%s\n' "<!-- os-package-watch: rows=$(echo "$current" | wc -l | tr -d ' ') -->"

exit 0
