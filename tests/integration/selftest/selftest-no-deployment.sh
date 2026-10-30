#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT
echo "== invocation-bound early refusal proof =="
candidate=$(git -C "$HERE/../.." rev-parse HEAD) || exit 1
main_src=$(sed -n '/^main() {$/,/^}$/p' "$HERE/e2e.sh")
for fixture in newer canonical-newer invalid-config invalid-version unreadable transport compatible older unstamped prerelease missing-binding invalid-job invalid-invocation wrong-local-sha wrong-remote-sha stale reused cancelled preflight-failure build-failure build-cancel backup-failure wallet-failure borrow-failure deploy-failure harness-failure backup-cancel deploy-cancel after-boundary-refusal publication-failure legacy; do
    case_dir="$sandbox/$fixture"
    mkdir -p "$case_dir/candidate" "$case_dir/canonical" "$case_dir/proof"
    printf '2.0.0\n' >"$case_dir/candidate/VERSION"
    printf '{"config_version":"2.0.0"}\n' >"$case_dir/candidate/config.json"
    cp "$case_dir/candidate/config.json" "$case_dir/canonical/config.json"
    case "$fixture" in
    newer | legacy | stale | reused | publication-failure) printf '{"config_version":"2.0.1"}\n' >"$case_dir/candidate/config.json" ;;
    canonical-newer) printf '{"config_version":"2.0.1"}\n' >"$case_dir/canonical/config.json" ;;
    older) printf '2.0.1\n' >"$case_dir/candidate/VERSION" ;;
    unstamped) printf '{}\n' >"$case_dir/candidate/config.json" ;;
    prerelease) printf '2.0.0-pre.1+build\n' >"$case_dir/candidate/VERSION" ;;
    invalid-version) printf 'invalid\n' >"$case_dir/candidate/VERSION" ;;
    unreadable) rm "$case_dir/candidate/config.json" ;;
    invalid-config) printf '{"private":"must-not-appear"' >"$case_dir/candidate/config.json" ;;
    esac
    [ "$fixture" != stale ] || printf 'stale\n' >"$case_dir/proof/no-deployment.json"
    [ "$fixture" != reused ] || mkdir "$case_dir/proof/.no-deployment-claim"
    : >"$case_dir/events"
    out=$(
        (
            source "$HERE/lib/e2e-no-deployment.sh"
            E2E_NO_DEPLOY_DIR="$case_dir/proof" E2E_JOB_ID=3177 E2E_INVOCATION_ID=0123456789abcdef0123456789abcdef E2E_CANDIDATE_SHA="$candidate"
            case "$fixture" in
            missing-binding) unset E2E_INVOCATION_ID ;;
            invalid-job) E2E_JOB_ID='3177/private' ;;
            invalid-invocation) E2E_INVOCATION_ID='bad' ;;
            wrong-local-sha) E2E_CANDIDATE_SHA=0000000000000000000000000000000000000000 ;;
            legacy) unset E2E_NO_DEPLOY_DIR E2E_JOB_ID E2E_INVOCATION_ID E2E_CANDIDATE_SHA ;;
            esac
            die() {
                printf '%s\n' "$*"
                exit 1
            }
            no_deployment_init || die 'invalid binding'
            BRANCH=fixture BENCH_HOST=fixture MODE=targeted KEEP=0 RESTORED=0 E2E_DIR="$case_dir/candidate" CANONICAL_DIR="$case_dir/canonical"
            log() { :; }
            ok() { :; }
            restore_all() {
                [ "$RESTORED" = 1 ] && return 0
                no_deployment_invalidate
                echo restore >>"$case_dir/events"
            }
            rig_lock_remote_release() { :; }
            source "$HERE/lib/parent-lock.sh"
            rig_lock_remote_release() { :; }
            trap e2e_exit EXIT
            trap 'exit 143' TERM
            operation() {
                echo "$1" >>"$case_dir/events"
                [ "$fixture" != "$1-failure" ] || exit 7
                [ "$fixture" != "$1-cancel" ] || kill -TERM "$BASHPID"
            }
            preflight() {
                [ "$fixture" != cancelled ] || kill -TERM "$BASHPID"
                [ "$fixture" != preflight-failure ] || exit 7
            }
            provision() { :; }
            backup_stack() {
                operation backup
                [ "$fixture" != after-boundary-refusal ] || no_deployment_refuse
            }
            wallet_fixture_capture() { operation wallet; }
            borrow_miner() { operation borrow; }
            deploy_branch() { operation deploy; }
            run_harness() { operation harness; }
            on_bench() {
                case "$1" in
                *scripts/build-pithead.sh*) operation build ;;
                'git -C '*)
                    [ "$fixture" != wrong-remote-sha ] || {
                        echo mismatch
                        return
                    }
                    echo "$candidate"
                    ;;
                *) [ "$fixture" != transport ] && bash -c "$1" ;;
                esac
            }
            if [ "$fixture" = publication-failure ]; then
                mv() { return 1; }
            fi
            eval "$main_src"
            main
        ) 2>&1
    )
    rc=$?
    case "$fixture" in
    newer | canonical-newer | invalid-config | invalid-version | unreadable | transport)
        assert_rc "$fixture remains a refusal" "$rc" 1
        assert_eq "$fixture never mutates or restores" "$(cat "$case_dir/events")" ''
        proof_rc=0
        python3 - "$case_dir/proof/no-deployment.json" "$candidate" <<'CHECK' || proof_rc=$?
import json
import sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes()
assert len(raw) <= 1024
assert json.loads(raw) == {
    "schema_version": 1,
    "job_id": "3177",
    "invocation_id": "0123456789abcdef0123456789abcdef",
    "candidate_sha": sys.argv[2],
    "status": "refused",
    "reason_code": "restore_compatibility_unverified",
    "baseline_mutated": False,
}
CHECK
        assert_rc "$fixture emits the exact bounded contract" "$proof_rc" 0
        assert_eq "$fixture atomically consumes the temporary file" "$(find "$case_dir/proof" -name receipt.tmp -print)" ''
        ;;
    compatible | older | unstamped | prerelease)
        assert_rc 'compatible candidate continues' "$rc" 0
        assert_eq 'compatible run executes every mutation and restore' "$(paste -sd, "$case_dir/events")" 'build,backup,wallet,borrow,deploy,harness,restore'
        ;;
    legacy)
        assert_rc 'older caller retains compatibility refusal' "$rc" 1
        assert_eq 'older caller refuses without baseline mutation' "$(cat "$case_dir/events")" ''
        ;;
    stale)
        assert_rc 'stale receipt refuses invocation' "$rc" 1
        assert_eq 'stale receipt is never refreshed' "$(cat "$case_dir/proof/no-deployment.json")" stale
        assert_eq 'stale receipt triggers no operation' "$(cat "$case_dir/events")" ''
        ;;
    *)
        [ "$rc" -ne 0 ] && it_pass "$fixture fails" || it_fail "$fixture fails" 'unexpected success'
        ;;
    esac
    case "$fixture" in
    newer | canonical-newer | invalid-config | invalid-version | unreadable | transport | stale) ;;
    *)
        [ ! -e "$case_dir/proof/no-deployment.json" ] && it_pass "$fixture grants no proof" || it_fail "$fixture grants no proof" 'receipt present'
        ;;
    esac
    case "$fixture" in
    missing-binding | invalid-job | invalid-invocation | wrong-local-sha | wrong-remote-sha | reused)
        assert_eq "$fixture causes no baseline operation" "$(cat "$case_dir/events")" ''
        ;;
    publication-failure)
        assert_eq 'publication failure never changes the baseline' "$(cat "$case_dir/events")" ''
        ;;
    *-failure | *-cancel | after-boundary-refusal)
        assert_contains "$fixture preserves restoration" "$(cat "$case_dir/events")" restore
        ;;
    esac
    case "$out" in
    *must-not-appear*) it_fail "$fixture hides private contents" leaked ;;
    *) it_pass "$fixture hides private contents" ;;
    esac
done
echo "== real wrapper rejects invalid binding before transport =="
: >"$sandbox/contact"
out=$(
    (
        ssh() {
            printf contacted >>"$E2E_TEST_CONTACT"
            return 1
        }
        export -f ssh
        E2E_TEST_CONTACT="$sandbox/contact" E2E_NO_DEPLOY_DIR="$sandbox" E2E_JOB_ID=invalid \
            E2E_INVOCATION_ID=0123456789abcdef0123456789abcdef E2E_CANDIDATE_SHA="$candidate" \
            bash "$HERE/e2e.sh" fixture --no-miner --bench fixture
    ) 2>&1
)
assert_rc 'real wrapper refuses invalid binding' "$?" 1
assert_contains 'real wrapper initializes proof before transport' "$out" 'Invalid or reused no-deployment binding'
assert_eq 'real wrapper performs no transport' "$(cat "$sandbox/contact")" ''
printf 'no deployment: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
