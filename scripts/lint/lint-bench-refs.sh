#!/usr/bin/env bash
set -euo pipefail

TARGETS=(pithead lib build os dashboard install.sh docker-compose.yml pithead-completion.bash README.md config.reference.json config.minimal.json config.core-keys.json)
EXCLUDES=(':(exclude,glob)**/CHANGELOG*.md')
PATTERN='bench[-_]ci|pithead-developer|adversarial-review|rig-e2e|tier4-(e2e|kvm)|CI_JOB_DIR|bench job|bench runner'

enumerate() {
    git ls-files -z -- "${TARGETS[@]}" "${EXCLUDES[@]}"
}

enforce_nonempty_enumeration() {
    if [ -z "$(enumerate | head -c1)" ]; then
        echo "FATAL: git ls-files enumerated zero shipped-surface files. Run from the repo root; a" >&2
        echo "broken enumeration and a clean tree both scan zero hits — refusing to report either as success." >&2
        return 1
    fi
    return 0
}

scan() {
    { grep -HniIE -e "$PATTERN" -- "$@" 2>/dev/null || true; } | cut -c1-200
}

run() {
    local -a files
    mapfile -d '' -t files < <(enumerate)
    local hits
    hits=$(scan "${files[@]}")
    if [ -n "$hits" ]; then
        printf 'bench-refs: a shipped file names the private CI/runner tooling. Name the behaviour, the tier role or the job id instead — the bare word "bench", job ids and SHAs are fine (allow-list rationale: CONTRIBUTING.md, lint-bench-refs):\n'
        printf '%s\n' "$hits"
        return 1
    fi
    echo "bench refs OK — no CI/runner tooling reference among ${#files[@]} shipped files"
    return 0
}

if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    st_fail=0
    expect() {
        if [ "$2" = hit ] && [ -z "$3" ]; then
            echo "  self-test FAIL: $1 (expected a hit, got none)"
            st_fail=1
        elif [ "$2" = hits ] && [ "$(printf '%s\n' "$3" | grep -c .)" -ne "$4" ]; then
            echo "  self-test FAIL: $1 (expected $4 flagged lines, got $(printf '%s\n' "$3" | grep -c .))"
            st_fail=1
        elif [ "$2" = clean ] && [ -n "$3" ]; then
            echo "  self-test FAIL: $1 (expected clean, got: $3)"
            st_fail=1
        else echo "  self-test ok: $1"; fi
    }

    printf 'bench-ci runs this job\nBENCH_CI_APP_ID gates the release\npithead-developer files the runner\nadversarial-review gates the merge\nthe rig-e2e lock serialises rigs\ntier4-e2e targeted builds the branch\ntier4-kvm boots the image\nCI_JOB_DIR names the receipt dir\nBench Job 840 reran the leg\na bench runner queued the job\nbench_ci lower underscore form\n' >"$tmp/hits.txt"
    expect "every refused token and word form, in either case, is flagged" hits "$(scan "$tmp/hits.txt")" 11

    printf 'cp os/build/stage/docker-compose.yml into the image; stage="$(mktemp -d)"; RESTORE_STAGE_DIR="$stage"; STAGE_ONLY=1\nsystemctl restart pithead-control.path pithead-control.service\nheaders["X-Pithead-Control"] = "1"  # CSRF guard\nPITHEAD_OLD_IMAGE=/images/old.img PITHEAD_REGISTRY=ghcr.io\n{"name": "miner-1", "status": "online"}\nthe e2e bench ran job 1115@701013bb1faaea1a9a337cde16dbe79fbca797d1 in targeted mode and the machine benchmarks fine\n' >"$tmp/clean.txt"
    expect "os/build/stage paths and stage variables, pithead-control and X-Pithead-Control, generic PITHEAD_* inputs, miner-N fixtures and the bare words are not flagged" clean "$(scan "$tmp/clean.txt")"

    SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    sfx=".sh"
    legrel="os/overlay/leg$sfx"
    repo="$tmp/shiprepo"
    mkdir -p "$repo/os/overlay" "$repo/tests/integration"
    git -C "$repo" init -q .
    printf 'image built here\n' >"$repo/os/README.md"
    printf 'bench-ci #1 pins this selftest\n' >"$repo/tests/integration/selftest-x$sfx"
    git -C "$repo" add -A
    if (cd "$repo" && bash "$SELF") >"$tmp/scope-out.txt" 2>&1; then
        echo "  self-test ok: a bench-ci reference in tests/ is that file's job, not coupling, and is not flagged"
    else
        echo "  self-test FAIL: a tests/-only tree was flagged or failed: $(cat "$tmp/scope-out.txt")"
        st_fail=1
    fi
    printf '# Bench job 840 reran the leg\ntier4-e2e targeted\n' >"$repo/$legrel"
    git -C "$repo" add -A
    if (cd "$repo" && bash "$SELF") >"$tmp/scope-out.txt" 2>&1 && grep -q "$legrel" "$tmp/scope-out.txt"; then
        echo "  self-test FAIL: a reference inside the shipped surface did not fail the gate"
        st_fail=1
    elif grep -q "$legrel" "$tmp/scope-out.txt"; then
        echo "  self-test ok: a reference inside the shipped surface fails the gate and names the file"
    else
        echo "  self-test FAIL: the gate failed without naming the shipped file: $(cat "$tmp/scope-out.txt")"
        st_fail=1
    fi

    emptyrepo="$tmp/emptyrepo"
    mkdir -p "$emptyrepo"
    git -C "$emptyrepo" init -q .
    printf 'x\n' >"$emptyrepo/Makefile"
    git -C "$emptyrepo" add -A
    if (cd "$emptyrepo" && bash "$SELF") >/dev/null 2>"$tmp/empty-stderr.txt"; then
        echo "  self-test FAIL: an empty shipped-surface enumeration did not fail loudly"
        st_fail=1
    elif grep -q FATAL "$tmp/empty-stderr.txt"; then
        echo "  self-test ok: an empty shipped-surface enumeration fails loudly instead of reading as clean"
    else
        echo "  self-test FAIL: the empty-enumeration run failed, but not with the FATAL guard message"
        st_fail=1
    fi

    [ "$st_fail" -eq 0 ] && {
        echo "lint-bench-refs self-test OK"
        exit 0
    }
    echo "lint-bench-refs self-test FAILED"
    exit 1
fi

enforce_nonempty_enumeration
run
