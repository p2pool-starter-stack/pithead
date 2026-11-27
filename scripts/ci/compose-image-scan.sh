#!/usr/bin/env bash
set -Eeuo pipefail

TRIVY="${TRIVY:-trivy}"

digest_images() {
    grep -Eo 'image:[[:space:]]*[^[:space:]]+@sha256:[0-9a-f]{64}' "$1" | sed -E 's/^image:[[:space:]]*//' | sort -u
}

image_name() {
    local n="${1%%@*}"
    printf '%s' "${n%:*}"
}

scan_ids() {
    local ref="$1" ignore="$2" out
    out="$(mktemp)"
    for _ in 1 2; do
        if "$TRIVY" image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
            --ignorefile "$ignore" --format json --output "$out" "$ref"; then
            jq -r '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique[]' "$out"
            rm -f "$out"
            return 0
        fi
        sleep "${SCAN_RETRY_SLEEP:-30}"
    done
    rm -f "$out"
    echo "::error::could not scan $ref" >&2
    return 1
}

previous_ref() {
    local base="$1" name="$2" ref
    while read -r ref; do
        if [ "$(image_name "$ref")" = "$name" ]; then
            printf '%s' "$ref"
            return 0
        fi
    done < <(digest_images "$base")
}

run() {
    local base="$1" head="$2" ignore="$3" rc=0 new old name ids_old ids_new added
    while read -r new; do
        name="$(image_name "$new")"
        old="$(previous_ref "$base" "$name")"
        [ "$old" = "$new" ] && continue
        ids_new="$(scan_ids "$new" "$ignore")" || {
            rc=1
            continue
        }
        ids_old=""
        if [ -n "$old" ]; then
            ids_old="$(scan_ids "$old" "$ignore")" || {
                rc=1
                continue
            }
        fi
        added="$(comm -23 <(printf '%s\n' "$ids_new" | sed '/^$/d' | sort) <(printf '%s\n' "$ids_old" | sed '/^$/d' | sort))"
        if [ -n "$added" ]; then
            echo "FAIL $name: new fixable HIGH/CRITICAL in the changed digest: $(echo "$added" | tr '\n' ' ')"
            rc=1
        else
            echo "ok   $name: no new fixable HIGH/CRITICAL"
        fi
    done < <(digest_images "$head")
    return "$rc"
}

self_test() {
    local d fail=0 rc a b
    d="$(mktemp -d)"
    trap 'rm -rf "$d"' RETURN
    a="sha256:$(printf 'a%.0s' {1..64})"
    b="sha256:$(printf 'b%.0s' {1..64})"
    printf '    image: r.io/x/app:1@%s\n    image: r.io/x/same:1@%s\n' "$a" "$a" >"$d/base.yml"
    printf '    image: r.io/x/app:2@%s\n    image: r.io/x/same:1@%s\n' "$b" "$a" >"$d/head.yml"
    : >"$d/ignore"
    cat >"$d/trivy" <<'FAKE'
#!/usr/bin/env bash
ref="${*: -1}"
out=""
while [ $# -gt 0 ]; do
    [ "$1" = --output ] && out="$2"
    shift
done
case "$ref" in
*"@sha256:aaaa"*) ids="$FAKE_OLD" ;;
*"@sha256:bbbb"*) ids="$FAKE_NEW" ;;
*)
    echo "unexpected scan of $ref" >&2
    exit 2
    ;;
esac
jq -n --arg ids "$ids" '{Results: [{Vulnerabilities: ($ids | split(" ") | map(select(. != "") | {VulnerabilityID: .}))}]}' >"$out"
FAKE
    chmod +x "$d/trivy"
    export TRIVY="$d/trivy" SCAN_RETRY_SLEEP=0
    FAKE_OLD="CVE-1" FAKE_NEW="CVE-1" run "$d/base.yml" "$d/head.yml" "$d/ignore" >/dev/null && rc=0 || rc=$?
    [ "$rc" = 0 ] || {
        echo "FAIL: id present in old digest must not fail"
        fail=1
    }
    FAKE_OLD="CVE-1" FAKE_NEW="CVE-1 CVE-2" run "$d/base.yml" "$d/head.yml" "$d/ignore" >/dev/null && rc=0 || rc=$?
    [ "$rc" = 1 ] || {
        echo "FAIL: new id must fail"
        fail=1
    }
    FAKE_OLD="CVE-1" FAKE_NEW="" run "$d/base.yml" "$d/base.yml" "$d/ignore" >/dev/null && rc=0 || rc=$?
    [ "$rc" = 0 ] || {
        echo "FAIL: unchanged compose must pass without scanning"
        fail=1
    }
    [ "$fail" = 0 ] && echo "compose-image-scan self-test ok"
    return "$fail"
}

case "${1:-}" in
--self-test) self_test ;;
"")
    echo "usage: $0 <base-compose> <head-compose> <ignorefile> | --self-test" >&2
    exit 2
    ;;
*) run "$@" ;;
esac
