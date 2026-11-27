#!/usr/bin/env bash
#
# Shipped-image CVE sweep report (#1313).
#
# The Monday sweep in ci.yml rebuilds every image from the branch and scans the rebuild. That
# cannot answer the question users care about. A rebuild resolves apt at scan time, so it picks up
# archive fixes the published image never got — the sweep goes green while the bytes people are
# running still carry the CVE. It also scans the default branch, not the release. This report
# covers the other half: the images published at cut time, promoted by digest with no rebuild
# (release.sh stage 6 is `buildx imagetools create`, a re-tag), scanned exactly as published.
#
# REPORT-ONLY, and that posture is deliberate. A CVE in a shipped image is a fact to act on — it
# means "consider cutting a patch release", a decision a person makes — not a build to fail. The
# run goes red only when the sweep itself could not do its job.
#
# INCOMPLETE IS NEVER CLEAN. Every refusal below exits 1 and says UNCHECKED in the report rather
# than printing a reassuring zero. This is the defect class the whole currency lane exists for: a
# watcher with nothing to say and a watcher that has quietly died look identical from the Actions
# tab, and "0 findings" off a partial run is the most expensive kind of false green.
#
#   - the artifact directory is missing, or holds no scan output at all
#   - an expected image produced no report (its matrix leg failed)
#   - a report cannot be parsed
#   - a report names an artifact that is NOT a digest reference, so the run cannot honestly claim
#     it scanned published bytes rather than a moving tag
#   - a report's artifact is a different image than the leg it arrived as
#   - the legs disagree about which release tag they swept (a cut landed mid-run)
#
# Usage:
#   scripts/watch/shipped-image-sweep-report.sh <dir>   Render the report for the artifacts in <dir> on
#                                                  stdout. rc 1 if the sweep was incomplete.
#   scripts/watch/shipped-image-sweep-report.sh --title  Print the tracking issue's title, nothing else.
#   scripts/watch/shipped-image-sweep-report.sh --self-test
#                                                  Drive the render + every refusal above through
#                                                  fixtures. No network, no docker, no gh.

set -Eeuo pipefail

SWEEP_ISSUE_TITLE="Shipped-image CVE sweep (daily report)"

SWEPT_IMAGES="monero p2pool tor xmrig-proxy dashboard os-rootfs"

# Only fixable HIGH/CRITICAL are counted, the same scope ci.yml's gate uses (`ignore-unfixed`), and
# the same scope every `.config/trivyignore` entry is written against. It is also the only scope that maps
# to a decision: a patch release can only ship a fix that exists. Unfixed findings are left to the
# gate's own reporting rather than counted here as if someone could act on them. This is the label
# the table header prints; the jq filter below spells the same two out literally.
SEVERITY_LABEL="HIGH/CRITICAL"

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- render helpers ---------------------------------------------------------------------------

# Shorten a digest for the summary table; the full value is printed in the per-image section, so
# nothing is lost. `sha256:5da0208411…` is enough to eyeball against `docker inspect` output.
short_digest() {
    printf '%s…' "${1:0:20}"
}

# Every HIGH/CRITICAL row in a trivy JSON report, as TSV: id, severity, package, installed, fixed.
# `.Results[]?` and `.Vulnerabilities[]?` are both optional-indexed on purpose — a clean image
# reports Results with no Vulnerabilities key at all, which is a legitimate zero, not a parse
# failure. A genuinely unreadable file fails in render_report() before this runs.
findings_tsv() {
    jq -r '
        [ .Results[]? | .Vulnerabilities[]? ]
        | map(select(.Severity == "HIGH" or .Severity == "CRITICAL"))
        | sort_by(.Severity, .VulnerabilityID)
        | .[]
        | [ .VulnerabilityID, .Severity, .PkgName,
            (.InstalledVersion // ""), (.FixedVersion // "") ]
        | @tsv
    ' "$1"
}

# --- the report -------------------------------------------------------------------------------

# Reads <dir>, prints the markdown body on stdout, returns 1 if the sweep was incomplete.
render_report() {
    local dir="$1"
    local rc=0
    local svc file tagfile ref tag
    local summary="" details="" problems=""
    local tag_seen="" tag_conflict=0
    local expected

    if [ ! -d "$dir" ]; then
        printf 'The sweep produced no artifact directory at all (`%s` does not exist).\n' "$dir"
        printf '\nEvery shipped image is UNCHECKED. See the run log.\n'
        return 1
    fi

    for file in "$dir"/sweep-*.json; do
        [ -e "$file" ] || continue
        svc="$(basename "$file" .json)"
        svc="${svc#sweep-}"
        expected=0
        for s in $SWEPT_IMAGES; do
            [ "$s" = "$svc" ] && expected=1 && break
        done
        if [ "$expected" -eq 0 ]; then
            problems="${problems}- \`$svc\` was swept but is not in this report's image list — security-sweep.yml's \`sweep-shipped\` matrix and \`SWEPT_IMAGES\` in \`scripts/watch/shipped-image-sweep-report.sh\` have drifted apart.
"
            rc=1
        fi
    done

    for svc in $SWEPT_IMAGES; do
        file="$dir/sweep-$svc.json"
        tagfile="$dir/sweep-$svc.tag"

        if [ ! -s "$file" ]; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\` produced no scan report; its matrix leg did not finish. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi

        if ! ref="$(jq -er '
            select((.Results | type) == "array")
            | select(all(.Results[]; (type == "object") and (.Vulnerabilities == null or
                ((.Vulnerabilities | type) == "array" and all(.Vulnerabilities[]; type == "object")))))
            | select(any(.Results[]; .Class == "os-pkgs" and (.Target | type) == "string" and (.Target | length) > 0))
            | .ArtifactName
        ' "$file" 2>/dev/null)"; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\`'s scan report could not be parsed. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi

        # The whole point of the change is that we scanned published bytes. A tag reference here
        # would mean the digest resolve fell through, and reporting it as a shipped-image result
        # would be a lie of exactly the shape #1313 was filed about.
        if ! printf '%s' "$ref" | grep -Eq "/pithead-$svc@sha256:[0-9a-f]{64}\$"; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\` reports artifact \`$ref\`, which is not a digest reference to \`pithead-$svc\`. Nothing here proves the published image was scanned, so it is UNCHECKED.
"
            rc=1
            continue
        fi

        if [ ! -s "$tagfile" ] || ! tag="$(tr -d '[:space:]' <"$tagfile")" || [ -z "$tag" ]; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\` produced no release-tag metadata. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi
        if [ -z "$tag_seen" ]; then
            tag_seen="$tag"
        elif [ "$tag" != "$tag_seen" ]; then
            tag_conflict=1
        fi

        # Captured, not piped in from a process substitution: a jq failure inside `< <(...)` is
        # invisible to `set -e`, so a report whose Results array is malformed would render as a
        # confident zero. Same rule as everywhere else here — unreadable is UNCHECKED.
        local tsv
        if ! tsv="$(findings_tsv "$file")"; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\`'s findings could not be read out of its scan report. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi

        local fixable=0 id sev pkg installed fixed rows=""
        while IFS=$'\t' read -r id sev pkg installed fixed; do
            [ -n "$id" ] || continue
            [ -n "$fixed" ] || continue
            fixable=$((fixable + 1))
            rows="${rows}| \`$id\` | $sev | \`$pkg\` | \`$installed\` | \`$fixed\` |
"
        done <<<"$tsv"

        if [ "$fixable" -eq 0 ]; then
            summary="${summary}| \`pithead-$svc\` | \`$(short_digest "${ref#*@}")\` | 0 |
"
        else
            summary="${summary}| \`pithead-$svc\` | \`$(short_digest "${ref#*@}")\` | **$fixable** |
"
            details="${details}
### \`pithead-$svc\` — $fixable fixable

Scanned \`$ref\`.

| CVE | severity | package | installed | fixed in |
| --- | --- | --- | --- | --- |
${rows}"
        fi
    done

    if [ "$tag_conflict" -eq 1 ]; then
        problems="${problems}- The legs did not sweep the same release tag, so this report mixes two releases. A cut probably landed mid-run; the next run will settle it.
"
        rc=1
    fi

    printf 'The images users actually pull, scanned as published. Each tag is resolved to a digest\n'
    printf 'first and the digest is what trivy reads, so this reports the bytes on the registry — not\n'
    printf 'a rebuild, which would resolve apt afresh and hide the very CVEs this exists to find.\n'
    if [ -n "$tag_seen" ]; then
        printf '\nRelease swept: **%s** (from `main`, scanned against `main`'"'"'s own `.config/trivyignore`).\n' "$tag_seen"
    fi
    printf '\n| image | digest | fixable %s |\n| --- | --- | --- |\n' "$SEVERITY_LABEL"
    printf '%s' "$summary"

    if [ -n "$problems" ]; then
        printf '\n## This sweep did not complete\n\n%s' "$problems"
    fi

    if [ -n "$details" ]; then
        printf '%s' "$details"
        printf '\nA finding here means the published image carries a CVE with a fix available. The\n'
        printf 'decision it asks for is whether to cut a patch release, so this reports and never\n'
        printf 'fails the build.\n'
    elif [ "$rc" -eq 0 ]; then
        printf '\nNo fixable HIGH/CRITICAL in any shipped image.\n'
    fi

    return "$rc"
}

# --- entry points -------------------------------------------------------------------------------

if [ "${1:-}" = "--title" ]; then
    printf '%s\n' "$SWEEP_ISSUE_TITLE"
    exit 0
fi

if [ "${1:-}" = "--self-test" ]; then
    SWEEP_REPORT="${BASH_SOURCE[0]}"
    # shellcheck source=shipped-image-sweep-report-selftest.sh
    source "$(dirname "$SWEEP_REPORT")/shipped-image-sweep-report-selftest.sh"
fi

if [ $# -ne 1 ] || [ "${1:0:2}" = "--" ]; then
    usage >&2
    exit 2
fi

render_report "$1"
