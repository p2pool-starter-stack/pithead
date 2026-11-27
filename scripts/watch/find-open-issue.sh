#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] && [ -n "$1" ] || {
    echo "usage: find-open-issue.sh <exact title>" >&2
    exit 2
}

gh api --paginate "repos/{owner}/{repo}/issues?state=open&per_page=100" \
    --jq '.[] | select(has("pull_request") | not) | "\(.number)\t\(.title)"' |
    awk -F'\t' -v t="$1" '$2 == t && !seen++ { print $1 }'
