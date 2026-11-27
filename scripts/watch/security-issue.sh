#!/usr/bin/env bash
#
# Renders scan output into security-labelled tracking issues and upserts them (security-sweep.yml,
# scheduled-run-watch.yml). One open issue per title, edited in place, a comment only when the
# finding set changes, closed when the finding set is empty. It does no scanning.
#
#   security-issue.sh render-ref <dir>        osv.json + zizmor.json + ref.txt of one swept ref -> body (empty when clean)
#   security-issue.sh render-red <cadence>    latest red scheduled runs from scheduled-run-watch's cadence.json
#   security-issue.sh title-ref <ref>         the issue title for a swept ref
#   security-issue.sh upsert <title> <file>   create/edit/close; an empty <file> means clean
#   security-issue.sh --self-test

set -Eeuo pipefail

RED_TITLE="Security: a scheduled scan or watch run is red"

usage() {
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

title_ref() { printf 'Security sweep: vulnerable dependencies or workflows on %s\n' "$1"; }

osv_rows() { # <osv.json> -> "id<TAB>cve<TAB>package<TAB>version<TAB>severity<TAB>fixed" for fixable HIGH/CRITICAL
    jq -r '
        [.results[]?.packages[]? | . as $p | .vulnerabilities[]? |
            (([.affected[]?.ranges[]?.events[]?.fixed] | map(select(. != null)) | unique | join(", "))) as $fixed |
            {id, cve: ((.aliases // []) | map(select(startswith("CVE-"))) | .[0] // "-"),
             pkg: $p.package.name, ver: $p.package.version, sev: (.database_specific.severity // "UNKNOWN"), fixed: $fixed}
            | select((.sev == "HIGH" or .sev == "CRITICAL") and .fixed != "")]
        | unique_by(.id + .pkg + .ver) | sort_by(.pkg, .id)[]
        | [.id, .cve, .pkg, .ver, .sev, .fixed] | @tsv' "$1"
}

zizmor_rows() { # <zizmor.json> -> "ident<TAB>severity<TAB>file:line<TAB>description"
    jq -r '[.[] | {ident, sev: .determinations.severity, desc,
            file: (.locations[0].symbolic.key.Local.given_path // "?"),
            line: ((.locations[0].concrete.location.start_point.row // 0) + 1)}]
        | unique_by(.ident + .file + (.line | tostring)) | sort_by(.file, .line)[]
        | [.ident, .sev, "\(.file):\(.line)", .desc] | @tsv' "$1"
}

hash_of() { sort | cksum | cut -d' ' -f1; }

render_ref() { # <dir>
    local dir="$1" ref osv zz table="" n=0 hash run
    ref="$(cat "$dir/ref.txt")"
    run="${RUN_URL:-}"
    osv="$([ -s "$dir/osv.json" ] && osv_rows "$dir/osv.json" || true)"
    zz="$([ -s "$dir/zizmor.json" ] && zizmor_rows "$dir/zizmor.json" || true)"
    [ -n "$osv$zz" ] || return 0
    hash="$(printf '%s\n%s\n' "$osv" "$zz" | grep -v '^$' | cut -f1-4 | hash_of)"
    if [ -n "$osv" ]; then
        n=$((n + $(printf '%s\n' "$osv" | wc -l)))
        table="${table}Fixable HIGH or CRITICAL advisories in lockfile dependencies:"$'\n\n'
        table="${table}| Advisory | CVE | Package | Version | Severity | Fixed in |"$'\n'"|---|---|---|---|---|---|"$'\n'
        table="${table}$(printf '%s\n' "$osv" | awk -F'\t' '{ printf "| %s | %s | `%s` | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6 }')"$'\n\n'
    fi
    if [ -n "$zz" ]; then
        n=$((n + $(printf '%s\n' "$zz" | wc -l)))
        table="${table}Workflow audit findings (online zizmor):"$'\n\n'
        table="${table}| Audit | Severity | Location | Finding |"$'\n'"|---|---|---|---|"$'\n'
        table="${table}$(printf '%s\n' "$zz" | awk -F'\t' '{ printf "| %s | %s | `%s` | %s |\n", $1, $2, $3, $4 }')"$'\n\n'
    fi
    printf '<!-- findings:%s -->\n' "$hash"
    printf "## What's the problem\n\nThe daily security sweep found %s finding(s) on \`%s\`.\n\n%s" "$n" "$ref" "$table"
    printf '## What it impacts\n\nWhatever ships from %s: a vulnerable dependency or an exploitable workflow.\n\n' "\`$ref\`"
    printf '## How I found it\n\nosv-scanner over the lockfiles and online zizmor over the workflows at this ref in the daily sweep%s.\n\n' "${run:+ ($run)}"
    printf '## How important is it\n\nSecurity fixes go first: a fixable HIGH or CRITICAL is a patch-release trigger. Advisories with no fix are not listed.\n\n'
    printf '## Acceptance criteria\n\nThe next daily sweep reports nothing for this ref; this issue then closes itself.\n\n'
    printf '## Possible solutions\n\nBump the listed packages to the fixed version, or pin and fix the flagged workflow step.\n'
}

render_red() { # <cadence.json>
    local rows hash
    rows="$(jq -r '.workflows[]? | select(.path != ".github/workflows/scheduled-run-watch.yml") |
        if .runs == null then [.path, "unknown", "-", "history could not be read"]
        else ([.runs[] | select(.status == "completed")] | sort_by(.createdAt) | reverse | .[0]) as $r |
            if $r == null then empty
            elif ($r.conclusion == "success" or $r.conclusion == "cancelled" or $r.conclusion == "skipped") then empty
            else [.path, $r.conclusion, $r.createdAt, $r.url] end end | @tsv' "$1")"
    [ -n "$rows" ] || return 0
    hash="$(printf '%s\n' "$rows" | cut -f1-2 | hash_of)"
    printf '<!-- findings:%s -->\n' "$hash"
    printf "## What's the problem\n\nThe newest completed scheduled run of these workflows is not green, so the scan it performs may not be covering the stack:\n\n"
    printf '| Workflow | Result | Started | Run |\n|---|---|---|---|\n'
    printf '%s\n' "$rows" | awk -F'\t' '{ printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }'
    printf '\n## What it impacts\n\nNew CVEs or stale pins can go unreported while a sweep is red. Vulnerabilities in the monerod, p2pool and xmrig-proxy binaries are not detected by any scanner here.\n\n'
    printf '## How I found it\n\nThe daily scheduled-run watch compared each workflow'"'"'s newest completed scheduled run with its conclusion.\n\n'
    printf '## How important is it\n\nA broken sweep hides CVEs, so fix it ahead of feature work.\n\n'
    printf '## Acceptance criteria\n\nEvery listed workflow'"'"'s newest scheduled run is green; this issue then closes itself.\n\n'
    printf '## Possible solutions\n\nOpen the linked run, fix the cause, and run the workflow once with workflow_dispatch.\n'
}

upsert() { # <title> <bodyfile>
    local title="$1" file="$2" n old new
    n="$(bash "$(dirname "${BASH_SOURCE[0]}")/find-open-issue.sh" "$title")"
    if [ ! -s "$file" ]; then
        if [ -n "$n" ]; then
            gh issue close "$n" --comment "The sweep found nothing on $(date -u +%F); closing."
            echo "closed #$n"
        else
            echo "clean, no open issue"
        fi
        return 0
    fi
    if [ -n "$n" ]; then
        old="$(gh issue view "$n" --json body --jq .body | grep -a -m1 '^<!-- findings:' || true)"
        new="$(grep -a -m1 '^<!-- findings:' "$file")"
        gh issue edit "$n" --body-file "$file"
        [ "$old" = "$new" ] || gh issue comment "$n" --body "The finding set changed on $(date -u +%F); the body is current."
        echo "updated #$n"
    else
        gh issue create --title "$title" --label security --body-file "$file"
    fi
}

if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st() {
        if [ "$2" = "$3" ]; then echo "  self-test ok: $1"; else
            echo "  self-test FAIL: $1 (got [$2], want [$3])"
            st_fail=1
        fi
    }
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' EXIT
    mkdir "$t/r"
    echo develop-v9.9.9 >"$t/r/ref.txt"
    echo '{"results":[]}' >"$t/r/osv.json"
    echo '[]' >"$t/r/zizmor.json"
    st "a clean ref renders nothing" "$(render_ref "$t/r" | wc -c | tr -d ' ')" "0"
    cat >"$t/r/osv.json" <<'E'
{"results":[{"packages":[{"package":{"name":"lodash","version":"4.17.15"},"vulnerabilities":[
{"id":"GHSA-a","aliases":["CVE-1"],"database_specific":{"severity":"HIGH"},"affected":[{"ranges":[{"events":[{"introduced":"0"},{"fixed":"4.17.21"}]}]}]},
{"id":"GHSA-b","aliases":[],"database_specific":{"severity":"MODERATE"},"affected":[{"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]},
{"id":"GHSA-c","aliases":[],"database_specific":{"severity":"CRITICAL"},"affected":[{"ranges":[{"events":[{"introduced":"0"}]}]}]}]}]}]}
E
    out="$(render_ref "$t/r")"
    st "only fixable HIGH/CRITICAL is listed" "$(printf '%s' "$out" | grep -c 'GHSA-')" "1"
    st "the body carries the six headings" "$(printf '%s' "$out" | grep -c '^## ')" "6"
    st "the marker is first" "$(printf '%s' "$out" | head -1 | cut -c1-14)" "<!-- findings:"
    cat >"$t/r/zizmor.json" <<'E'
[{"ident":"template-injection","desc":"code injection","determinations":{"severity":"High"},"locations":[{"symbolic":{"key":{"Local":{"given_path":".github/workflows/a.yml"}}},"concrete":{"location":{"start_point":{"row":6}}}}]}]
E
    out2="$(render_ref "$t/r")"
    st "a zizmor finding is listed with its line" "$(printf '%s' "$out2" | grep -c 'a.yml:7')" "1"
    st "a changed finding set changes the marker" "$([ "$(printf '%s' "$out" | head -1)" != "$(printf '%s' "$out2" | head -1)" ] && echo yes)" "yes"
    st "the same findings keep the marker" "$([ "$(printf '%s' "$out2" | head -1)" = "$(render_ref "$t/r" | head -1)" ] && echo yes)" "yes"
    cat >"$t/c.json" <<'E'
{"workflows":[
{"path":".github/workflows/ok.yml","runs":[{"status":"completed","conclusion":"success","createdAt":"2026-11-02T00:00:00Z","url":"u1"}]},
{"path":".github/workflows/healed.yml","runs":[{"status":"completed","conclusion":"failure","createdAt":"2026-11-01T00:00:00Z","url":"u2"},{"status":"completed","conclusion":"success","createdAt":"2026-11-02T00:00:00Z","url":"u3"}]},
{"path":".github/workflows/red.yml","runs":[{"status":"completed","conclusion":"failure","createdAt":"2026-11-02T00:00:00Z","url":"u4"}]},
{"path":".github/workflows/scheduled-run-watch.yml","runs":[{"status":"completed","conclusion":"failure","createdAt":"2026-11-02T00:00:00Z","url":"u5"}]},
{"path":".github/workflows/blind.yml","runs":null}]}
E
    red="$(render_red "$t/c.json")"
    st "a red workflow is listed" "$(printf '%s' "$red" | grep -c 'red.yml')" "1"
    st "an unreadable history is listed" "$(printf '%s' "$red" | grep -c 'blind.yml')" "1"
    st "a healed workflow is not" "$(printf '%s' "$red" | grep -c 'healed.yml')" "0"
    st "the watch never lists itself" "$(printf '%s' "$red" | grep -c 'scheduled-run-watch.yml')" "0"
    echo '{"workflows":[]}' >"$t/e.json"
    st "no workflows renders nothing" "$(render_red "$t/e.json" | wc -c | tr -d ' ')" "0"
    st "the ref title names the ref" "$(title_ref main)" "Security sweep: vulnerable dependencies or workflows on main"

    mkdir "$t/bin"
    cat >"$t/bin/gh" <<'E'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$1 $2" in
"api --paginate") printf '%s' "$GH_LIST" | jq -r '.[] | "\(.number)\t\(.title)"' ;;
"issue view") printf '%s\n' "$GH_OLD_BODY" ;;
esac
E
    chmod +x "$t/bin/gh"
    export GH_LOG="$t/log" PATH="$t/bin:$PATH"
    : >"$t/empty"
    printf '<!-- findings:1 -->\nbody\n' >"$t/body"
    GH_LIST='[]' upsert T "$t/body" >/dev/null
    st "no open issue and findings creates one with the security label" "$(grep -c 'issue create --title T --label security' "$t/log")" "1"
    : >"$t/log"
    GH_LIST='[{"number":7,"title":"T"}]' GH_OLD_BODY='<!-- findings:1 -->' upsert T "$t/body" >/dev/null
    st "unchanged findings edit in place" "$(grep -c 'issue edit 7' "$t/log")" "1"
    st "unchanged findings add no comment" "$(grep -c 'issue comment' "$t/log")" "0"
    : >"$t/log"
    GH_LIST='[{"number":7,"title":"T"}]' GH_OLD_BODY='<!-- findings:2 -->' upsert T "$t/body" >/dev/null
    st "changed findings add one comment" "$(grep -c 'issue comment 7' "$t/log")" "1"
    : >"$t/log"
    GH_LIST='[{"number":7,"title":"T"}]' upsert T "$t/empty" >/dev/null
    st "clean closes the open issue" "$(grep -c 'issue close 7' "$t/log")" "1"
    : >"$t/log"
    GH_LIST='[]' upsert T "$t/empty" >/dev/null
    st "clean with no issue does nothing else" "$(grep -c 'issue' "$t/log")" "1"
    [ "$st_fail" = 0 ] && echo "security-issue self-test OK"
    exit "$st_fail"
fi

case "${1:-}" in
render-ref)
    [ $# -eq 2 ] || usage
    render_ref "$2"
    ;;
render-red)
    [ $# -eq 2 ] || usage
    render_red "$2"
    ;;
title-ref)
    [ $# -eq 2 ] || usage
    title_ref "$2"
    ;;
title-red) printf '%s\n' "$RED_TITLE" ;;
upsert)
    [ $# -eq 3 ] || usage
    upsert "$2" "$3"
    ;;
*) usage ;;
esac
