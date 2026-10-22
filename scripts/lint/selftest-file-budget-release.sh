#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
unset FILE_BUDGET_BASE_REF
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GATE_SCRIPT="$ROOT/scripts/lint/lint-file-budget.sh"
export RELEASE_SCRIPT="$ROOT/scripts/release/release.sh"
export FIXTURE_MAKEFILE="$scratch/Makefile"
printf 'test:\n\tbash "$(GATE_SCRIPT)" --self-test\n\tbash "$(GATE_SCRIPT)"\n' >"$FIXTURE_MAKEFILE"
mkdir -p "$scratch/repo/docs/dev"
cd "$scratch/repo"
git init -q -b develop
git config user.email test@example.invalid
git config user.name test
seq 1 500 >budgeted.sh
printf 'budgeted.sh\t500\n' >docs/dev/file-budget.tsv
git add .
git commit -qm frozen
export FROZEN_COMMIT
FROZEN_COMMIT=$(git rev-parse HEAD)
seq 1 450 >budgeted.sh
printf 'budgeted.sh\t450\n' >docs/dev/file-budget.tsv
git add .
git commit -qm lowered
git update-ref refs/remotes/origin/develop HEAD
git checkout -q --detach "$FROZEN_COMMIT"

expect() {
    local expected="$1" description="$2" actual=0
    shift 2
    "$@" >"$scratch/output" 2>&1 || actual=$?
    if [ "$actual" -ne "$expected" ]; then
        cat "$scratch/output"
        printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

expect 1 'PR mode rejects a ceiling above newer develop' bash "$GATE_SCRIPT"
grep -q "raises budgeted.sh's ceiling from 450 to" "$scratch/output"
expect 0 'release mode accepts its frozen budget' env FILE_BUDGET_BASE_REF="$FROZEN_COMMIT" bash "$GATE_SCRIPT"
expect 1 'an invalid override fails instead of falling back' env FILE_BUDGET_BASE_REF=missing-release-ref bash "$GATE_SCRIPT"
grep -q 'invalid FILE_BUDGET_BASE_REF' "$scratch/output"

expect 0 'real release test gate uses the frozen commit despite inherited override' \
    env FILE_BUDGET_BASE_REF=missing-release-ref bash -c '
    set --
    source "$RELEASE_SCRIPT"
    GIT_COMMIT="$FROZEN_COMMIT"
    SKIP_INTEGRATION=1
    make() { command make -f "$FIXTURE_MAKEFILE" "$@"; }
    test_gate
    [ "$FILE_BUDGET_BASE_REF" = missing-release-ref ]
'
expect 0 'dry run prints the frozen base without executing the test gate' bash -c '
    set --
    source "$RELEASE_SCRIPT"
    GIT_COMMIT="$FROZEN_COMMIT"
    SKIP_INTEGRATION=1
    DRY_RUN=1
    make() { exit 99; }
    test_gate
'
grep -q "make test FILE_BUDGET_BASE_REF=$FROZEN_COMMIT" "$scratch/output"

seq 1 501 >budgeted.sh
expect 1 'release mode still rejects files over their recorded ceilings' env FILE_BUDGET_BASE_REF="$FROZEN_COMMIT" bash "$GATE_SCRIPT"
grep -q 'budgeted.sh is 501 lines, over its recorded ceiling of 500' "$scratch/output"
seq 1 500 >budgeted.sh
seq 1 801 >new.sh
expect 1 'release mode still enforces the hard ceiling' env FILE_BUDGET_BASE_REF="$FROZEN_COMMIT" bash "$GATE_SCRIPT"
grep -q 'new.sh is 801 lines, over the hard ceiling of 800' "$scratch/output"
seq 1 450 >new.sh
printf 'new.sh\t500\n' >>docs/dev/file-budget.tsv
expect 1 'release mode still rejects headroom on first appearances' env FILE_BUDGET_BASE_REF="$FROZEN_COMMIT" bash "$GATE_SCRIPT"
grep -q 'adds new.sh as a new row at ceiling' "$scratch/output"
printf 'file-budget release self-test OK\n'
