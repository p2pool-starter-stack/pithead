#!/usr/bin/env bash

dry_run=false

init_upgrade_issues() {
    issue_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || return 1
    [[ "$issue_repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || return 1
    local milestones
    milestones=$(gh api "repos/$issue_repo/milestones?state=open&sort=created&direction=asc&per_page=100" --paginate --slurp) || return 1
    release_milestone=$(jq -r '[.[][] | select(.title | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))] | sort_by(.created_at, .number) | .[0].title // ""' <<<"$milestones") || return 1
    open_upgrades=$(gh api "repos/$issue_repo/issues?state=open&per_page=100" --paginate --slurp) || return 1
    open_upgrades=$(jq '[.[][] | select(.pull_request == null) | select(.user.login | sub("^app/"; "") | sub("\\[bot\\]$"; "") | test("^(VijitSingh97|github-actions|pithead-(developer|reviewer|architect|devops))$"))]' <<<"$open_upgrades") || return 1
    upgrade_labels=$(gh api "repos/$issue_repo/labels?per_page=100" --paginate --slurp) || return 1
    upgrade_labels=$(jq '[.[][] | .name]' <<<"$upgrade_labels") || return 1
}

upgrade_write() {
    local body=$1
    shift
    if "$dry_run"; then
        printf 'gh' >&2
        printf ' %q' "$@" >&2
        printf '\n%s\n' "$body" >&2
    elif [ -n "$body" ]; then
        printf '%s\n' "$body" | gh "$@" >&2
    else
        gh "$@" >&2
    fi
}

component_status() {
    if [ "$1" != rigforge ]; then
        version_status "$2" "$3"
    elif [ "$2" = "$3" ]; then
        echo current
    else
        local relation
        relation=$(gh api "repos/p2pool-starter-stack/rigforge/compare/$2...$3" --jq .status) || return 1
        case "$relation" in
        ahead) echo stale ;;
        behind) echo ahead ;;
        identical) echo current ;;
        *) return 1 ;;
        esac
    fi
}

sync_upgrade_issue() {
    local component=$1 raw=$2 latest=$3 status=$4 upstream=$5
    local title="Upgrade $1 to $3" issue_number target order body proof milestone_note target_commit target_status
    local -a milestone_args=()
    while IFS=$'\t' read -r issue_number target; do
        [ -n "$issue_number" ] || continue
        target=${target#"Upgrade $component to "}
        if [ "$component" = rigforge ]; then
            version_order "$target" "$target" >/dev/null || continue
            target_commit=$(comparable rigforge "$upstream" "$target") || return 1
            target_status=$(component_status rigforge "$raw" "$target_commit") || return 1
            [ "$target_status" = current ] || [ "$target_status" = ahead ] || continue
        else
            order=$(version_order "$raw" "$target") || continue
            [ "$order" != older ] || continue
        fi
        upgrade_write "" issue close "$issue_number" --repo "$issue_repo" --reason completed || return 1
    done < <(jq -r --arg prefix "Upgrade $component to " '.[] | select(.title | startswith($prefix)) | [.number, .title] | @tsv' <<<"$open_upgrades")
    [ "$status" = stale ] || return 0
    issue_number=$(jq -r --arg title "$title" '[.[] | select(.title == $title)] | .[0].number // ""' <<<"$open_upgrades") || return 1
    [ -z "$issue_number" ] || return 0
    if ! jq -e --arg label "$component" 'index($label) != null' <<<"$upgrade_labels" >/dev/null; then
        upgrade_write "" label create "$component" --repo "$issue_repo" --color 0366d6 --description "$component component updates" || return 1
        upgrade_labels=$(jq --arg label "$component" '. + [$label]' <<<"$upgrade_labels") || return 1
    fi
    proof="Run the affected unit checks and the tier-4 proof required by the runtime paths changed by the upgrade."
    if [ "$component" = tari ]; then
        proof="Run the merge-mining gRPC contract check and the tier4-e2e merge-mining leg required by #1129, on the upgrade PR head."
    fi
    milestone_note="No open release milestone exists; this issue is unmilestoned."
    if [ -n "$release_milestone" ]; then
        milestone_args=(--milestone "$release_milestone")
        milestone_note="Scheduled for $release_milestone, the oldest open release milestone at discovery."
    fi
    body=$(
        cat <<EOF
## What's the problem

The pinned $component version is behind upstream $latest.

## what it impacts

The product continues to run the older $component dependency until a tested upgrade ships.

## How I found it

The weekly pin watch compared pinned \`$(norm "$raw")\` with \`$latest\` and reported stale. Upstream release notes: https://github.com/$upstream/releases/tag/$latest

## how important is it

Dependency maintenance; no security impact is established by version drift alone. $milestone_note

## acceptance criteria

- Upgrade the pin to $latest or a newer usable version without downgrading it.
- $proof
- The weekly pin watch no longer reports this target as stale.

## possible solutions

Review the upstream release notes and migration requirements, update the affected pins together, and verify the resulting runtime. Newer Tari prereleases require a separate usability decision.
EOF
    )
    upgrade_write "$body" issue create --repo "$issue_repo" --title "$title" \
        --label dependencies --label "$component" "${milestone_args[@]}" --body-file -
}
