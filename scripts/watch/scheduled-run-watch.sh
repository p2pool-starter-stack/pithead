#!/usr/bin/env bash
#
# Scheduled-run watch (#1377, #1418).
#
# The Monday run of ci.yml IS the CVE sweep: `build-images` rebuilds every image and scans the
# rebuild (#833), `sweep-shipped` scans the published digests (#1313). A scheduled run has no pull
# request, so nothing draws a person to it — and on 2026-08-17 `build-images` went red and nobody
# was told for seven days. This watcher is that run's reader.
#
# REPORT-ONLY. A scheduled failure, LATE run or MISSED run is a finding. This watcher fails only
# when its inputs are unreadable or incomplete; those paths say UNCHECKED rather than clean.
# The workflow performs GitHub lookups and this script renders its JSON, keeping every decision
# fixture-testable without network access.
# CADENCE. cadence.json names every schedule declared in the checked-out workflows and carries
# server-filtered run history for each. A missing run becomes LATE after 12 hours and MISSED after
# one full period. Both are report findings; only unreadable inputs make the watcher fail.
#
# ONE UNWATCHED WATCHER REMAINS. This script can include its own workflow in the table, but a
# GitHub-wide schedule shutdown also stops this run. The carried-forward success stamp makes that
# absence readable to an observer outside GitHub; it cannot make the absence self-announcing.
# Usage:
#   scripts/watch/scheduled-run-watch.sh <dir>    Render the report for the JSON in <dir> on stdout.
#                                           <dir>/cadence.json = declared schedules + run history
#                                           <dir>/runs.json  = gh run list --json ... (an array)
#                                           <dir>/jobs.json  = gh run view --json jobs (an object)
#                                           rc 1 if the watch could not do its job.
#   scripts/watch/scheduled-run-watch.sh --title  Print the tracking issue's title, nothing else.
#   scripts/watch/scheduled-run-watch.sh --schedules <workflow-dir>
#                                           Print path<TAB>cron for every declared schedule.
#   scripts/watch/scheduled-run-watch.sh --self-test
#                                           Drive the render and every refusal above through
#                                           fixtures. No network, no gh.

set -Eeuo pipefail

# The exact title is the issue-upsert key. Changing it files a second report.
WATCH_ISSUE_TITLE="Scheduled CI run watch (weekly report)"

# Six rows expose a failure streak that a single newest-run row cannot (#1419).
HISTORY_ROWS=6

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_schedules() {
    local file line cron
    for file in "$1"/*.yml "$1"/*.yaml; do
        [ -f "$file" ] || continue
        while IFS= read -r line; do
            cron="$(printf '%s\n' "$line" | sed -E "s/^[[:space:]]*- cron: [\"']([^\"']+)[\"'].*/\1/")"
            printf '%s\t%s\n' "$file" "$cron"
        done < <(awk '$0 == "  schedule:" { inside=1; next } inside && /^[^ ]/ { inside=0 } inside && /^    - cron:/ { print }' "$file")
    done
}

# Keep non-success conclusions verbatim; the self-test pins both rendered tables to one spelling.
conclusion_cell() {
    case "$1" in
    success) printf 'ok' ;;
    "") printf '**UNCHECKED**' ;;
    *) printf '**%s**' "$1" ;;
    esac
}

render_cadence() {
    local file="$1/cadence.json" rows unchecked
    if [ ! -s "$file" ]; then
        printf '## Declared schedule cadence\n\nUNCHECKED: no declared-schedule history was collected.\n\n'
        return 1
    fi
    if jq -e '.workflows | group_by(.path) | any(length != 1)' "$file" >/dev/null 2>&1; then
        printf '## Declared schedule cadence\n\nUNCHECKED: a workflow declares more than one cron slot; Actions history does not identify which slot fired.\n\n'
        return 1
    fi
    rows="$(jq -c '
        def parts:
            if .cron | test("^[0-9]{1,2} \\* \\* \\* \\*$") then
                (.cron | split(" ") | {minute: (.[0] | tonumber), period: 3600, kind: "hourly"})
            elif .cron | test("^[0-9]{1,2} [0-9]{1,2} \\* \\* [0-6]$") then
                (.cron | split(" ") | {minute: (.[0] | tonumber), hour: (.[1] | tonumber), weekday: (.[4] | tonumber), period: 604800, kind: "weekly"})
            else null end;
        def slot($now; $p):
            if $p.kind == "hourly" then
                ((($now - ($p.minute * 60)) / 3600 | floor) * 3600) + ($p.minute * 60)
            else
                (($now / 86400 | floor) * 86400) + ($p.hour * 3600) + ($p.minute * 60)
                - (((((($now / 86400 | floor) + 4) % 7) - $p.weekday + 7) % 7) * 86400)
                | if . > $now then . - 604800 else . end
            end;
        (.checkedAt | fromdateiso8601) as $now
        | [.workflows[] | . as $w | ($w | parts) as $p
            | ([.runs[]? | . + {epoch: (try (.createdAt | fromdateiso8601) catch null)} | select(.epoch != null)] | sort_by(.epoch) | last) as $new
            | if $p == null or $p.minute > 59 or ($p.hour // 0) > 23 or (.runs | type) != "array"
                 or (($w.runs | length) == 0 and ($w.declaredAt | type) != "number") then
                {workflow: .path, cron: .cron, last: "unknown", state: "**UNCHECKED**"}
              else (slot($now; $p)) as $latest
                | (slot(($w.declaredAt // $now); $p)) as $before_declared
                | (if $before_declared < ($w.declaredAt // $now) then $before_declared + $p.period else $before_declared end) as $first
                | {workflow: .path, cron: .cron, last: ($new.createdAt // "none"),
                   state: (if .path == ".github/workflows/scheduled-run-watch.yml" then "external stamp only"
                           elif $new == null and $now >= ($first + $p.period) then "**MISSED**"
                           elif $new == null and $now >= ($first + 43200) then "LATE"
                           elif $new == null then "within 12h grace"
                           elif $new.epoch < ($latest - $p.period) then "**MISSED**"
                           elif $new.epoch < $latest and $now >= ($latest + 43200) then "LATE"
                           elif $new.epoch < $latest then "within 12h grace"
                           else "ok" end)}
              end]
    ' "$file" 2>/dev/null || true)"
    if [ -z "$rows" ] || [ "$rows" = "[]" ]; then
        printf '## Declared schedule cadence\n\nUNCHECKED: the declared-schedule history could not be parsed.\n\n'
        return 1
    fi
    printf '## Declared schedule cadence\n\n'
    printf '| Workflow | Cron | Last observed run | Cadence |\n|---|---|---|---|\n'
    printf '%s' "$rows" | jq -r '.[] | "| `\(.workflow)` | `\(.cron)` | \(.last) | \(.state) |"'
    printf '\nMISSED means no run appeared for a full period after an expected slot. LATE is informational\n'
    printf 'after 12 hours; neither finding fails this report. UNCHECKED means the watch itself failed.\n\n'
    printf 'This scheduled watcher cannot announce its own absence or a GitHub-wide schedule shutdown.\n'
    printf 'The carried-forward successful-check stamp is the external observer signal for that gap.\n\n'
    unchecked="$(printf '%s' "$rows" | jq '[.[] | select(.state == "**UNCHECKED**")] | length')"
    [ "$unchecked" = 0 ]
}

render_report() {
    local dir="$1" runs newest id url created status conclusion rc=0

    printf 'Every workflow schedule declared on the default branch is compared with its run history.\n'
    printf 'The Monday run of `ci.yml` is also the CVE sweep — `build-images` scans a rebuild of this\n'
    printf 'branch (#833) and `sweep-shipped` scans the published digests (#1313). A scheduled run\n'
    printf 'has no pull request, so nothing draws anyone to its red tick. This issue is its reader\n'
    printf '(#1377); it is rewritten in place every week.\n\n'

    render_cadence "$dir" || rc=$?

    if [ ! -d "$dir" ] || [ ! -s "$dir/runs.json" ]; then
        printf 'UNCHECKED: no run history was collected, so this report cannot say whether the\n'
        printf 'scheduled sweep ran, passed, or failed. See the run log.\n'
        return 1
    fi

    # Sort here rather than trusting gh to return newest-first: the ordering is not part of the
    # documented contract, and a report that names the wrong run as "newest" is worse than none.
    runs="$(jq -c 'sort_by(.createdAt) | reverse' "$dir/runs.json" 2>/dev/null || true)"
    if [ -z "$runs" ] || [ "$runs" = "null" ] || [ "$(printf '%s' "$runs" | jq -r 'length')" = "0" ]; then
        printf 'UNCHECKED: the run history could not be parsed, or lists no scheduled run at all.\n'
        printf 'A watcher that cannot see the runs it watches has not checked anything.\n'
        return 1
    fi

    newest="$(printf '%s' "$runs" | jq -c '.[0]')"
    id="$(printf '%s' "$newest" | jq -r '.databaseId // empty')"
    url="$(printf '%s' "$newest" | jq -r '.url // empty')"
    created="$(printf '%s' "$newest" | jq -r '.createdAt // empty')"
    status="$(printf '%s' "$newest" | jq -r '.status // empty')"
    conclusion="$(printf '%s' "$newest" | jq -r '.conclusion // empty')"

    printf '## The most recent scheduled run\n\n'
    printf '| Run | Started | Result |\n|---|---|---|\n'
    printf '| [%s](%s) | %s | %s |\n\n' "$id" "$url" "$created" "$(conclusion_cell "$conclusion")"

    if [ "$status" != "completed" ]; then
        printf 'UNCHECKED: that run has not finished (`status: %s`), so nothing here says whether\n' "${status:-unknown}"
        printf 'the sweep passed. An unfinished run is not a passing one.\n\n'
        rc=1
    elif [ "$conclusion" = "success" ]; then
        printf 'The sweep completed and found nothing it had to report.\n\n'
    else
        render_failed_jobs "$dir" || rc=$?
    fi

    render_history "$runs"
    return "$rc"
}

render_failed_jobs() {
    local dir="$1" failed count
    if [ ! -s "$dir/jobs.json" ]; then
        printf 'UNCHECKED: the run failed, but its job list was not collected — this report cannot\n'
        printf 'name which job failed. See the run log.\n\n'
        return 1
    fi
    failed="$(jq -r '[.jobs[]? | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != null)]' "$dir/jobs.json" 2>/dev/null || true)"
    if [ -z "$failed" ] || [ "$failed" = "null" ]; then
        printf 'UNCHECKED: the run failed, but its job list could not be parsed.\n\n'
        return 1
    fi
    count="$(printf '%s' "$failed" | jq -r 'length')"
    if [ "$count" = "0" ]; then
        printf 'UNCHECKED: the run failed, but no failing job could be identified in its job list.\n'
        printf 'The failure is real — something outside the jobs, or a job list read too early.\n\n'
        return 1
    fi
    printf '## Jobs that did not pass\n\n'
    printf '| Job | Result |\n|---|---|\n'
    printf '%s' "$failed" | jq -r '.[] | "| `\(.name)` | \(.conclusion) |"'
    printf '\n'
    return 0
}

render_history() {
    printf '## Recent scheduled runs\n\n'
    printf '| Run | Started | Result |\n|---|---|---|\n'
    printf '%s' "$1" | jq -r --argjson n "$HISTORY_ROWS" \
        '.[:$n][] | "| [\(.databaseId)](\(.url)) | \(.createdAt) | \(if .conclusion == "success" then "ok" elif .conclusion == null or .conclusion == "" then "**UNCHECKED**" else "**" + .conclusion + "**" end) |"'
    printf '\n'
}

if [ "${1:-}" = "--title" ]; then
    printf '%s\n' "$WATCH_ISSUE_TITLE"
    exit 0
fi

if [ "${1:-}" = "--schedules" ] && [ $# -eq 2 ]; then
    list_schedules "$2"
    exit 0
fi

if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st() { # <label> <got> <want>
        if [ "$2" = "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (got [$2], want [$3])"
            st_fail=1
        fi
    }

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # <dir> <conclusion-of-newest> [older-conclusions...]
    runs_fixture() {
        local dir="$1" i=0 c
        shift
        mkdir -p "$dir"
        cadence_fixture "$dir"
        for c in "$@"; do
            printf '{"databaseId":%d,"url":"https://x/%d","createdAt":"2026-08-%02dT05:00:00Z","status":"completed","conclusion":"%s"}\n' \
                $((100 + i)) $((100 + i)) $((28 - i)) "$c"
            i=$((i + 1))
        done | jq -s '.' >"$dir/runs.json"
    }
    jobs_fixture() { # <dir> <name:conclusion>...
        local dir="$1" spec
        shift
        for spec in "$@"; do
            printf '{"name":"%s","conclusion":"%s"}\n' "${spec%%:*}" "${spec##*:}"
        done | jq -s '{jobs: .}' >"$dir/jobs.json"
    }
    cadence_fixture() { # <dir> [checked-at] [cron] [runs-json]
        local dir="$1" checked="${2:-2026-09-14T08:00:00Z}" cron="${3:-0 5 * * 1}"
        local runs="${4:-}"
        [ -n "$runs" ] || runs='[{"createdAt":"2026-09-14T06:00:00Z"}]'
        mkdir -p "$dir"
        jq -n --arg checkedAt "$checked" --arg cron "$cron" --argjson runs "$runs" \
            '{checkedAt: $checkedAt, workflows: [{path: ".github/workflows/ci.yml", cron: $cron, declaredAt: ("2026-08-01T00:00:00Z" | fromdateiso8601), runs: $runs}]}' >"$dir/cadence.json"
    }

    workflows="$tmp/workflows"
    mkdir -p "$workflows"
    printf 'on:\n  schedule:\n    - cron: "0 5 * * 1"\njobs: {}\n' >"$workflows/a.yml"
    printf 'on:\n  push:\njobs: {}\n' >"$workflows/b.yml"
    printf 'on:\n  schedule:\n    - cron: "30 6 * * 1" # comment\njobs: {}\n' >"$workflows/c.yaml"
    out="$(list_schedules "$workflows")"
    st "every workflow carrying schedule is enumerated" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
    st "an unscheduled workflow is omitted" "$(printf '%s\n' "$out" | grep -cF 'b.yml')" "0"
    st "cron comments and .yaml workflows are handled" "$(printf '%s\n' "$out" | grep -cF $'c.yaml\t30 6 * * 1')" "1"

    # The GREEN path has to be REACHABLE. A check that can only ever say "incomplete" is as
    # useless as one that only ever says "clean".
    # Eight runs against HISTORY_ROWS=6, so the cap is EXERCISED rather than merely configured. A
    # fixture smaller than the cap can never tell a working limit from an absent one.
    ok="$tmp/ok"
    runs_fixture "$ok" success success success success success success success success
    out="$(render_report "$ok")" && rc=0 || rc=$?
    hist() { printf '%s' "$1" | sed -n '/## Recent scheduled runs/,$p' | grep -c '^| \['; }
    st "a passing newest run exits 0" "$rc" "0"
    st "a passing run says so" "$(printf '%s' "$out" | grep -c 'found nothing it had to report')" "1"
    st "the history table is capped at HISTORY_ROWS" "$(hist "$out")" "$HISTORY_ROWS"
    st "a clean report names no failing job" "$(printf '%s' "$out" | grep -c 'did not pass')" "0"

    # The first run at 04:45 followed four dropped hourly slots; history was still empty at 04:40.
    gap="$tmp/gap"
    cadence_fixture "$gap" "2026-09-04T04:40:00Z" "23 * * * *" '[]'
    out="$(render_cadence "$gap")" && rc=0 || rc=$?
    st "an actual elapsed hourly gap is MISSED" "$(printf '%s' "$out" | grep -cF '**MISSED**')" "1"
    st "a missed run is a report finding, not a broken watcher" "$rc" "0"

    fresh="$tmp/fresh"
    cadence_fixture "$fresh" "2026-09-14T08:00:00Z" "0 5 * * 1" '[]'
    jq '.workflows[0].declaredAt = ("2026-09-11T00:00:00Z" | fromdateiso8601)' "$fresh/cadence.json" >"$fresh/next" && mv "$fresh/next" "$fresh/cadence.json"
    out="$(render_cadence "$fresh")"
    st "a new schedule gets its first full period of grace" "$(printf '%s' "$out" | grep -cF 'within 12h grace')" "1"

    jq '.workflows[0].path = ".github/workflows/scheduled-run-watch.yml"' "$fresh/cadence.json" >"$fresh/next" && mv "$fresh/next" "$fresh/cadence.json"
    out="$(render_cadence "$fresh")"
    st "the scheduled watcher does not claim to observe itself" "$(printf '%s' "$out" | grep -cF 'external stamp only')" "1"

    late="$tmp/late"
    cadence_fixture "$late" "2026-09-14T18:00:00Z" "0 5 * * 1" '[{"createdAt":"2026-09-07T06:00:00Z"}]'
    out="$(render_cadence "$late")" && rc=0 || rc=$?
    st "a run absent twelve hours after its slot is LATE" "$(printf '%s' "$out" | grep -c '| LATE |')" "1"
    st "late is informational" "$rc" "0"

    unknown="$tmp/unknown"
    cadence_fixture "$unknown"
    jq '.workflows[0].runs = null' "$unknown/cadence.json" >"$unknown/next" && mv "$unknown/next" "$unknown/cadence.json"
    out="$(render_cadence "$unknown")" && rc=0 || rc=$?
    st "unreadable history is UNCHECKED" "$(printf '%s' "$out" | grep -cF '**UNCHECKED**')" "1"
    st "unchecked history fails the watcher" "$rc" "1"

    short="$tmp/short"
    runs_fixture "$short" success success
    out="$(render_report "$short")" && rc=0 || rc=$?
    st "a history shorter than the cap prints only the runs it has" "$(hist "$out")" "2"

    # A failed run is REPORTED, not reddened: rc stays 0 because the WATCHER did its job. This is
    # the assertion that separates this watcher from the red tick it exists to replace.
    red="$tmp/red"
    runs_fixture "$red" failure success success
    jobs_fixture "$red" "Build image (dashboard):failure" "Shell tests:success" "Lint:skipped"
    out="$(render_report "$red")" && rc=0 || rc=$?
    st "a FAILED newest run still exits 0 — it is a finding, not a broken watcher" "$rc" "0"
    st "the failing job is named" "$(printf '%s' "$out" | grep -cF 'Build image (dashboard)')" "1"
    st "a passing job is not listed as failing" "$(printf '%s' "$out" | grep -cF '| `Shell tests` |')" "0"
    st "a SKIPPED job is not listed as failing" "$(printf '%s' "$out" | grep -cF '| `Lint` |')" "0"
    # The SAME run renders in both tables, one built in bash and one in jq. Asserting the count is
    # 2 is what pins the two spellings together — it fails if either side drifts.
    st "the failed run is marked in both tables, identically" \
        "$(printf '%s' "$out" | grep -c '| \*\*failure\*\* |')" "2"

    miss="$tmp/missing"
    out="$(render_report "$miss")" && rc=0 || rc=$?
    st "a missing directory fails" "$rc" "1"
    st "a missing directory says both inputs are UNCHECKED" "$(printf '%s' "$out" | grep -c UNCHECKED)" "2"

    empty="$tmp/empty"
    mkdir -p "$empty"
    printf '[]\n' >"$empty/runs.json"
    out="$(render_report "$empty")" && rc=0 || rc=$?
    st "an empty run list fails" "$rc" "1"

    bad="$tmp/bad"
    mkdir -p "$bad"
    printf 'not json at all\n' >"$bad/runs.json"
    out="$(render_report "$bad")" && rc=0 || rc=$?
    st "an unparseable run list fails" "$rc" "1"

    running="$tmp/running"
    mkdir -p "$running"
    printf '[{"databaseId":1,"url":"https://x/1","createdAt":"2026-08-31T05:00:00Z","status":"in_progress","conclusion":null}]\n' >"$running/runs.json"
    out="$(render_report "$running")" && rc=0 || rc=$?
    st "an unfinished newest run fails rather than reading as passing" "$rc" "1"
    st "an unfinished run is not called a success" "$(printf '%s' "$out" | grep -c 'found nothing')" "0"

    # Knowing a run failed but not WHICH job is a half-answer and must not read as a whole one.
    nojobs="$tmp/nojobs"
    runs_fixture "$nojobs" failure success
    out="$(render_report "$nojobs")" && rc=0 || rc=$?
    st "a failed run with no jobs file fails" "$rc" "1"

    badjobs="$tmp/badjobs"
    runs_fixture "$badjobs" failure success
    printf 'nope\n' >"$badjobs/jobs.json"
    out="$(render_report "$badjobs")" && rc=0 || rc=$?
    st "a failed run with an unparseable jobs file fails" "$rc" "1"

    nofail="$tmp/nofail"
    runs_fixture "$nofail" failure success
    jobs_fixture "$nofail" "Shell tests:success"
    out="$(render_report "$nofail")" && rc=0 || rc=$?
    st "a failed run whose jobs all passed fails rather than reporting nothing" "$rc" "1"

    # Every case above calls render_report inside an `&&` list, where bash suppresses `set -e` for
    # the whole dynamic extent of the call — so none of them can see an error-exit that only bites
    # the way CI actually invokes this: bare, in its own process.
    out="$(bash "${BASH_SOURCE[0]}" "$ok")" && rc=0 || rc=$?
    st "the clean path survives a real subprocess invocation" "$rc" "0"
    out="$(bash "${BASH_SOURCE[0]}" "$red")" && rc=0 || rc=$?
    st "a reported failure survives a real subprocess invocation, still 0" "$rc" "0"
    out="$(bash "${BASH_SOURCE[0]}" "$empty")" && rc=0 || rc=$?
    st "a refusal still exits 1 from a real subprocess" "$rc" "1"

    # The title is the upsert key; a change here silently files a second issue for ever.
    st "--title prints the constant and nothing else" \
        "$(bash "${BASH_SOURCE[0]}" --title)" "$WATCH_ISSUE_TITLE"

    [ "$st_fail" = 0 ] && echo "scheduled-run-watch self-test OK"
    exit "$st_fail"
fi

if [ $# -ne 1 ] || [ "${1:0:2}" = "--" ]; then
    usage >&2
    exit 2
fi

render_report "$1"
