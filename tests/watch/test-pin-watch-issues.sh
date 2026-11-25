#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

(
    issue_test_dir=$(mktemp -d)
    trap 'rm -f "$issue_test_dir/actions"; rmdir "$issue_test_dir"' EXIT
    actions="$issue_test_dir/actions"
    : >"$actions"
    dry_run=false
    ST_MILESTONES='[[{"title":"maintenance & gates","created_at":"2020","number":1},{"title":"v2.1.0","created_at":"2025","number":3}],[{"title":"v2.0.1","created_at":"2024","number":2}]]'
    ST_ISSUES='[[]]'
    ST_LABELS='[[{"name":"dependencies"},{"name":"tari"}]]'
    ST_RELATION=ahead
    ST_LOOKUP_FAIL=false
    ST_WRITE_FAIL=false
    gh() {
        case "$1 $2" in
        'repo view') echo p2pool-starter-stack/pithead ;;
        api\ repos/*/milestones*)
            "$ST_LOOKUP_FAIL" && return 1
            printf '%s\n' "$ST_MILESTONES"
            ;;
        api\ repos/*/issues*) printf '%s\n' "$ST_ISSUES" ;;
        api\ repos/*/labels*) printf '%s\n' "$ST_LABELS" ;;
        api\ repos/*/commits/*) printf '%s\n' cccccccccccccccccccccccccccccccccccccccc ;;
        api\ repos/*/compare/*) printf '%s\n' "$ST_RELATION" ;;
        'issue create' | 'issue close' | 'label create')
            "$ST_WRITE_FAIL" && return 1
            printf '%s\n' "$*" >>"$actions"
            if [ "$1 $2" = 'issue create' ]; then cat >>"$actions"; fi
            ;;
        *) return 99 ;;
        esac
    }
    init_upgrade_issues
    st "milestone lookup uses the oldest open release across pages" "$release_milestone" v2.0.1
    sync_upgrade_issue tari v6.0.0 v6.0.1 stale tari-project/tari
    st "stale pin creates one issue" "$(grep -c '^issue create ' "$actions")" 1
    st "upgrade gets both labels and the release milestone" "$(grep -c -- '--label dependencies --label tari --milestone v2.0.1' "$actions")" 1
    st "upgrade body has exactly the six required headings" "$(grep '^## ' "$actions")" $'## What\x27s the problem\n## what it impacts\n## How I found it\n## how important is it\n## acceptance criteria\n## possible solutions'
    st "Tari issue requires both runtime proofs" "$(grep -c 'gRPC contract check and the tier4-e2e merge-mining leg' "$actions")" 1
    st "release notes link retains the exact upstream tag" "$(grep -c 'https://github.com/tari-project/tari/releases/tag/v6.0.1' "$actions")" 1
    ST_ISSUES='[[{"number":42,"title":"Upgrade tari to v6.0.1","user":{"login":"github-actions[bot]"}}]]'
    init_upgrade_issues
    : >"$actions"
    sync_upgrade_issue tari v6.0.0 v6.0.1 stale tari-project/tari
    st "existing open upgrade is a no-op" "$(wc -c <"$actions" | tr -d ' ')" 0
    sync_upgrade_issue tari v6.0.1 v6.0.1 current tari-project/tari
    st "current pin closes its upgrade once" "$(grep -c '^issue close 42 ' "$actions")" 1
    : >"$actions"
    sync_upgrade_issue tari v6.0.2-pre.0 v6.0.1 ahead tari-project/tari
    st "ahead pin closes an incorporated stable target" "$(grep -c '^issue close 42 ' "$actions")" 1
    st "ahead prerelease never creates a downgrade issue" "$(grep -c '^issue create ' "$actions" || true)" 0
    : >"$actions"
    sync_upgrade_issue tari v6.0.1-pre.0 v6.0.0 ahead tari-project/tari
    st "future target is not closed when latest stable is older" "$(wc -c <"$actions" | tr -d ' ')" 0
    ST_ISSUES='[[{"number":43,"title":"Upgrade tari to v6.0.1","user":{"login":"outside"}},{"number":44,"title":"Upgrade tari to v6.0.1","pull_request":{},"user":{"login":"VijitSingh97"}}]]'
    init_upgrade_issues
    st "outside issues and pull requests are not changed" "$(jq length <<<"$open_upgrades")" 0
    ST_MILESTONES='[[{"title":"Later (on demand)"},{"title":"Icebox"},{"title":"v2.x - post-GA"},{"title":"v2.0.1-rc.1"}]]'
    init_upgrade_issues
    st "non-release milestones are never selected" "$release_milestone" ""
    sync_upgrade_issue tari v6.0.0 v6.0.1 stale tari-project/tari
    st "missing release milestone is stated in the issue" "$(grep -c 'No open release milestone exists; this issue is unmilestoned.' "$actions")" 1
    st "missing release milestone does not set another milestone" "$(grep -c -- '--milestone' "$actions" || true)" 0
    : >"$actions"
    dry_run=true
    dry_output=$(sync_upgrade_issue tari v6.0.0 v6.0.1 stale tari-project/tari 2>&1)
    st "dry run prints the proposed create" "$(grep -c '^gh issue create ' <<<"$dry_output")" 1
    st "dry run never writes" "$(wc -c <"$actions" | tr -d ' ')" 0
    dry_run=false
    ST_LABELS='[[]]'
    init_upgrade_issues
    sync_upgrade_issue caddy v2.0.0 v2.1.0 stale caddyserver/caddy
    st "a missing component label is created before filing" "$(head -1 "$actions")" 'label create caddy --repo p2pool-starter-stack/pithead --color 0366d6 --description caddy component updates'
    : >"$actions"
    open_upgrades='[{"number":45,"title":"Upgrade rigforge to v1.1.0"}]'
    ST_RELATION=behind
    sync_upgrade_issue rigforge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa v1.2.0 stale p2pool-starter-stack/rigforge
    st "incorporated RigForge target closes while a newer release stays stale" "$(grep -c '^issue close 45 ' "$actions" || true)" 1
    st "newer RigForge target still creates work" "$(grep -c '^issue create ' "$actions")" 1
    open_upgrades='[]'
    ST_WRITE_FAIL=true
    write_rc=0
    sync_upgrade_issue tari v6.0.0 v6.0.1 stale tari-project/tari || write_rc=$?
    st "failed issue writes propagate" "$write_rc" 1
    ST_LOOKUP_FAIL=true
    init_rc=0
    init_upgrade_issues || init_rc=$?
    st "milestone lookup failure does not mean no milestone" "$init_rc" 1
    for relation in ahead behind identical diverged; do
        ST_RELATION=$relation
        case "$relation" in
        ahead) expected=stale ;;
        behind) expected=ahead ;;
        identical) expected=current ;;
        diverged) expected=unchecked ;;
        esac
        got=$(component_status rigforge aaaa bbbb) || got=unchecked
        st "RigForge ancestry $relation is $expected" "$got" "$expected"
    done
    exit "$st_fail"
) || st_fail=1

(
    smoke_root=$(mktemp -d)
    trap 'rm -f "$smoke_root/bin/gh" "$smoke_root/bin/docker" "$smoke_root/scripts/watch/pin-watch.sh" "$smoke_root/scripts/watch/pin-watch-issues.sh" "$smoke_root/scripts/release/release.sh" "$smoke_root/actions"; rmdir "$smoke_root/bin" "$smoke_root/scripts/watch" "$smoke_root/scripts/release" "$smoke_root/scripts" "$smoke_root"' EXIT
    mkdir -p "$smoke_root/bin" "$smoke_root/scripts/watch" "$smoke_root/scripts/release"
    cp "$ROOT/scripts/watch/pin-watch.sh" "$ROOT/scripts/watch/pin-watch-issues.sh" "$smoke_root/scripts/watch/"
    cat >"$smoke_root/scripts/release/release.sh" <<'RELEASE'
pin() {
    if [ "$1" = tari ] && [ "${STUB_PIN_CURRENT:-0}" = 0 ]; then
        echo v6.0.0
    else
        echo v6.0.1
    fi
}
RELEASE
    cat >"$smoke_root/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
'repo view') echo example/pithead ;;
api\ */milestones*) echo '[[]]' ;;
api\ */issues*)
    if [ "${STUB_ISSUE_EXISTS:-0}" = 1 ]; then
        echo '[[{"number":42,"title":"Upgrade tari to v6.0.1","user":{"login":"github-actions[bot]"}}]]'
    else
        echo '[[]]'
    fi
    ;;
api\ */labels*) echo '[[{"name":"dependencies"},{"name":"tari"}]]' ;;
api\ */releases/latest)
    [ "${STUB_LOOKUP_FAIL:-0}" = 0 ] || exit 1
    echo v6.0.1
    ;;
api\ */releases\?*) ;;
'issue create' | 'issue close')
    [ "${STUB_ACTION_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "$*" >>"$STUB_ACTIONS"
    if [ "$1 $2" = 'issue create' ]; then cat >>"$STUB_ACTIONS"; fi
    ;;
*) exit 99 ;;
esac
GH
    printf '#!/usr/bin/env bash\nexit 0\n' >"$smoke_root/bin/docker"
    chmod +x "$smoke_root/bin/gh" "$smoke_root/bin/docker"
    export STUB_ACTIONS="$smoke_root/actions"
    export PATH="$smoke_root/bin:$PATH"
    : >"$STUB_ACTIONS"
    smoke_rc=0
    smoke_output=$(bash "$smoke_root/scripts/watch/pin-watch.sh" 2>&1) || smoke_rc=$?
    st "full watcher runs successful issue reconciliation" "$smoke_rc" 0
    st "full watcher creates exactly the stale Tari issue" "$(grep -c '^issue create ' "$STUB_ACTIONS")" 1
    : >"$STUB_ACTIONS"
    smoke_output=$(bash "$smoke_root/scripts/watch/pin-watch.sh" --dry-run 2>&1)
    st "full watcher dry run prints its create" "$(grep -c '^gh issue create ' <<<"$smoke_output")" 1
    st "full watcher dry run performs no writes" "$(wc -c <"$STUB_ACTIONS" | tr -d ' ')" 0
    smoke_rc=0
    smoke_output=$(STUB_LOOKUP_FAIL=1 bash "$smoke_root/scripts/watch/pin-watch.sh" 2>&1) || smoke_rc=$?
    st "full watcher fails on unchecked upstream rows" "$smoke_rc" 1
    st "unchecked rows never mutate upgrade issues" "$(wc -c <"$STUB_ACTIONS" | tr -d ' ')" 0
    smoke_rc=0
    smoke_output=$(STUB_ACTION_FAIL=1 bash "$smoke_root/scripts/watch/pin-watch.sh" 2>&1) || smoke_rc=$?
    st "full watcher fails on issue action errors" "$smoke_rc" 1
    smoke_output=$(STUB_PIN_CURRENT=1 STUB_ISSUE_EXISTS=1 bash "$smoke_root/scripts/watch/pin-watch.sh" --dry-run 2>&1)
    st "full watcher dry run prints incorporated target close" "$(grep -c '^gh issue close 42 ' <<<"$smoke_output")" 1
    st "full watcher dry run still performs no writes" "$(wc -c <"$STUB_ACTIONS" | tr -d ' ')" 0
    exit "$st_fail"
) || st_fail=1
