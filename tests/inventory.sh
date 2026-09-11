#!/usr/bin/env bash
#
# Generate a coverage inventory across every test suite in the repo and print it as Markdown.
# Answers "what is covered" (issue #54). `make test-inventory` runs this and writes
# docs/dev/test-inventory.md — a generated, git-ignored file you read on demand (#414).
#
# Static (grep-based): no test run, no dependencies, deterministic — so it never drifts from
# whether a daemon/server happens to be available.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Test functions (def test_… / async def test_…) in a python file, in source order.
py_tests() {
    grep -E '^[[:space:]]*(async[[:space:]]+)?def test_' "$1" 2>/dev/null |
        sed -E 's/^[[:space:]]*(async[[:space:]]+)?def (test_[A-Za-z0-9_]+).*/\2/'
}
# test('name' | test("name") cases in a node test file.
node_tests() { grep -oE "test\((['\"])[^'\"]+\1" "$1" 2>/dev/null | sed -E "s/^test\(['\"]//; s/['\"]$//"; }
# `== section ==` headers in a shell suite: the whole line that prints one, `echo "== ` through a
# closing ` =="` at end of line. Both anchors are load-bearing, for opposite reasons.
# Without the leading one, a bare `== [^=]+ ==` matches anywhere in the file and harvests jq
# equality expressions — `(.read_only == true) and (.x ==` — which counted 15 phantom sections
# with unreadable names in test_compose.sh and one more in run.sh.
# Without `[^"]+` between them, a header whose own text contains an `=` is dropped: the older
# `[^=]+` silently lost run.sh's `role=rig machine` section. Excluding only the quote, rather than
# using `.+`, keeps `=` legal while stopping a greedy match from swallowing two headers that share
# a line into one garbled name. No header carries code after its closing quotes, so ending the
# match at end-of-line is safe.
sh_sections() {
    grep -oE '^[[:space:]]*echo "== [^"]+ =="$' "$1" 2>/dev/null |
        sed -E 's/^[[:space:]]*echo "== //; s/ =="$//'
}
count() { grep -c . 2>/dev/null || true; }

# Print "- name" bullets for each line on stdin.
bullets() { sed 's/^/- /'; }

# --- gather ---------------------------------------------------------------
PY_DASH_FILES=$(find dashboard/tests -name 'test_*.py' | sort)
NODE_FILES=$(find dashboard/tests/frontend -name '*.test.mjs' 2>/dev/null | sort)

n_py_dash=0
for f in $PY_DASH_FILES; do n_py_dash=$((n_py_dash + $(py_tests "$f" | count))); done
n_py_fake=0
for f in tests/integration/fakes/test_*.py; do n_py_fake=$((n_py_fake + $(py_tests "$f" | count))); done
n_node=0
for f in $NODE_FILES; do n_node=$((n_node + $(node_tests "$f" | count))); done
# Every tests/stack suite, not just run.sh — #1105 moves sections out of run.sh into per-domain
# files, and counting the one file made each split shrink the inventory in silence. See the
# per-file drift gate below for why the aggregate zero-check never noticed. The glob is iterated
# directly, never via a word-split string, so a filename containing a space stays one path
# instead of splitting into two nonexistent ones and reporting phantom drift.
n_stack=0
while IFS= read -r f; do n_stack=$((n_stack + $(sh_sections "$f" | count))); done < <(find tests/stack -type f -name '*.sh' ! -path '*/fixtures/*' | sort)
# Every tests/integration/selftest/*.sh, not just selftest.sh. The Makefile globs these and CI
# runs the target that does (shell.yml since #2048),
# so all of them are run and linted, while counting the one filename published a third of the
# sections and hid the rest (#1388). The self-tests grew from one file to five and the singular
# name never followed. Same enumerate-vs-glob shape the stack aggregate above was fixed for; the
# tell is a gate line naming paths one by one beside a sibling line that globs. The glob is
# iterated directly rather than through a word-split string, for the reason given above it.
n_selftest=0
for f in tests/integration/selftest/*.sh; do n_selftest=$((n_selftest + $(sh_sections "$f" | count))); done
n_scen=$(awk -F'\t' 'NF>1{print $1}' <(sed -n '/scenario_matrix() {/,/^EOF/p' tests/integration/scenarios.sh | grep -E '\t') | count)
n_axes=$(grep -cE '=' <(sed -n '/axis_coverage() {/,/^EOF/p' tests/integration/scenarios.sh | grep -E '^[a-z].*='))
n_mini=$(grep -cE 'log "scenario [0-9]' tests/integration/mini-stack/run-mini-stack.sh)

total=$((n_py_dash + n_py_fake + n_node + n_stack + n_selftest + n_scen + n_mini))

# --- drift gate -----------------------------------------------------------
# The gathering above is grep-based, so a suite that moves, renames or changes shape enumerates
# as zero — or, just as quietly, as a handful — without erroring. CI runs this on every PR (#981).
# These are FLOORS, not emptiness tests (#1420): a counter falling from hundreds to one passes a
# zero check, the very defect min_expected fixes further down this same file. Each floor is about
# half of today's count, so ordinary churn never reaches it; never lower one to pass a real drop.
for pair in n_py_dash:1200 n_py_fake:12 n_node:250 n_stack:180 n_selftest:80 n_scen:8 n_axes:10 n_mini:6; do
    c=${pair%%:*} f=${pair##*:} # :-0 — grep -c on a deleted file emits nothing, not 0
    if [ "${!c:-0}" -lt "$f" ]; then
        echo "inventory drift: $c counted ${!c:-0}, floor $f — at 0 its pattern stopped matching;" \
            "above 0 a suite moved or shrank. Fix it, or lower this floor in tests/inventory.sh" >&2
        exit 1
    fi
done

# Per-FILE zero check for the stack suites. The aggregate above cannot see a single suite go
# dark: 22 files summing to 281 sections stay comfortably non-zero when any one of them drops to
# nothing, which is exactly the drift a #1105 split causes. Counting only run.sh had already hidden
# 162 sections before this was caught, and the aggregate never complained once.
# What this does NOT catch: a file that shrinks without reaching zero. A suite going from 11
# sections to 1 still passes here.
# It also cannot catch a file that VANISHES — the glob simply stops matching it — and nothing else
# catches that either, which is why the source-target check below exists. run.sh runs under
# `set -uo pipefail` with NO `-e`, so `source` of a missing file prints to stderr and execution
# CONTINUES with $FAIL still 0; run.sh's tail exits on the $FAIL counter alone, so the suite goes
# green having silently skipped every assertion in the missing file. Verified, not assumed.
# Three files carry no section header by design, each for its own reason:
#   lib.sh                        — a library of fixtures and helpers; it holds no assertions
#   test_compose.sh               — its cases are jq filters over docker-compose.yml, not sections
#   test-control-add-only-ssrf.sh — split out of a run.sh section whose header stayed behind
SECTIONLESS="standalone/test_compose.sh control/test-control-add-only-ssrf.sh test-lifecycle.sh"
while IFS= read -r f; do
    case " $SECTIONLESS " in *" ${f#tests/stack/} "*) continue ;; esac
    if [ "$(sh_sections "$f" | count)" -eq 0 ]; then
        echo "inventory drift: $f has no '== section ==' header — it moved, was renamed, or" \
            "changed shape; fix the file, or add it to SECTIONLESS with a reason" >&2
        exit 1
    fi
done < <(find tests/stack -type f -name 'test*.sh' | sort)

# The same per-FILE check for the harness self-tests, and it is the half the aggregate above cannot
# do. Now that n_selftest globs, one self-test dropping to zero sections hides inside a comfortably
# non-zero sum exactly as a stack suite did — the aggregate can see a whole tier go dark and never a
# single file. Every self-test carries headers today, so there is no SECTIONLESS counterpart here;
# if one ever legitimately has none, give it one rather than adding an exception, since these files
# exist to be enumerated.
for f in tests/integration/selftest/*.sh; do
    if [ "$(sh_sections "$f" | count)" -eq 0 ]; then
        echo "inventory drift: $f has no '== section ==' header — it moved, was renamed, or" \
            "changed shape; fix the file, or fold it into a sibling self-test" >&2
        exit 1
    fi
done

# A sourcer's `source` line and the file it names have to agree, and they can disagree in EITHER
# direction. Both ways end identically: `source` of a missing file does not stop the sourcer —
# neither tests/stack/run.sh nor tests/integration/run.sh sets `-e` — so the suite goes green
# having skipped every assertion in that domain, and neither the aggregate nor the per-file gate
# can see it. The hyphen-named domain files have no standalone CI invocation of their own — the
# underscore-named test_*.sh suites do, and fail their own step — so for them these two checks are
# the whole safety net. Both directions read one SOURCED list, so the pattern cannot drift between
# them, and a pattern that stops matching cannot quietly satisfy both loops at once: direction 2
# compares the list against the files on disk and reports how many are missing.
#
# The pattern is anchored to the start of the line and admits no `#` ahead of the `source`, and
# that is the load-bearing half: without it a commented-out `# source "$HERE/x.sh"` reads here as
# a live one, so the file counts as sourced while the sourcer never runs it — the same silent skip
# by another route, and the likeliest thing for a conflict resolution to leave behind. It does not
# require `source` to open the line, deliberately: #1400 put a guard prefix on every domain
# stanza, and a pattern that only matched a bare `source` stopped seeing 24 of the 25. What stays
# out of reach is a line that is live text but dead code: a `source` inside a branch that never
# runs, or inside a function nothing calls, still reads as present. Telling those apart needs
# control flow rather than grep, and is not claimed.
#
# Taken over a (sourcer, directory) PAIR rather than copied once per directory (#1595): a second
# copy of a gate this dense drifts, and the drifted copy is the one nobody is reading at the
# moment it goes quiet. Arguments: the sourcer, its directory, a space-separated list of GLOB
# PATTERNS for files in it the sourcer is not expected to source, and the floor checked below.
check_source_set() { # <sourcer> <expected-list> <minimum>
    local sourcer="$1" expected="$2" minimum="$3" base actual missing path
    base=${sourcer%/*}
    actual=$(grep -oE '^[^#]*source "\$HERE/[A-Za-z0-9_./-]+\.sh"' "$sourcer" |
        sed -E 's|^.*source "\$HERE/||; s|"$||' | sort -u)
    if [ "$(printf '%s\n' "$expected" | grep -c .)" -lt "$minimum" ]; then
        echo "inventory drift: expected source set for $sourcer fell below $minimum" >&2
        exit 1
    fi
    missing=""
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        [ -f "$base/$path" ] || missing="${missing}${base}/${path}"$'\n'
    done <<<"$actual"
    [ -z "$missing" ] || {
        printf 'inventory drift: %s sources missing files:\n%s' "$sourcer" "$missing" >&2
        exit 1
    }
    if [ "$actual" != "$expected" ]; then
        echo "inventory drift: source set disagrees for $sourcer" >&2
        diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
        exit 1
    fi
}

stack_expected=$(
    printf '%s\n' lib.sh
    find tests/stack -type f -name 'test-*.sh' -print | sed 's|^tests/stack/||'
)
stack_expected=$(printf '%s\n' "$stack_expected" | sort)
check_source_set tests/stack/run.sh "$stack_expected" 50

# live-*-support.sh are excluded for the skip-accounting.sh reason: run.sh sources live-gates.sh,
# which sources them, so run.sh reaches them transitively and never names them itself.
integration_expected=$(
    printf '%s\n' lib.sh scenarios.sh
    find tests/integration/lib -maxdepth 1 -type f -name '*.sh' \
        ! -name rig-supply.sh ! -name restore-proof.sh ! -name skip-accounting.sh \
        ! -name borrow-fixture.sh ! -name detached-harness.sh ! -name parent-lock.sh \
        ! -name live-upgrade-support.sh ! -name live-state-support.sh ! -name live-xvb-support.sh -print |
        sed 's|^tests/integration/||'
)
integration_expected=$(printf '%s\n' "$integration_expected" | sort)
check_source_set tests/integration/run.sh "$integration_expected" 15

# --- emit -----------------------------------------------------------------
cat <<EOF
# Test Inventory

_Generated by \`make test-inventory\` ([\`tests/inventory.sh\`](../../tests/inventory.sh)). **Do not
edit by hand** — re-run the target to refresh. See [Testing Strategy](testing-strategy.md) for
how the tiers fit together._

**Totals:** ${n_py_dash} dashboard unit tests · ${n_py_fake} contract tests · ${n_node} frontend
tests · ${n_stack} \`pithead\` shell sections · ${n_selftest} harness self-test sections ·
${n_scen} live config scenarios (${n_axes} axis values) · ${n_mini} mini-stack scenarios.

> Counts are **test functions / named cases** (parametrized pytest cases expand to more at
> run time — e.g. the dashboard suite collects ~381). Generated statically by grep, so it's
> stable regardless of what's installed.

| Tier | Suite | Cases |
|---|---|---|
| 1 — Unit | dashboard pytest | ${n_py_dash} |
| 1 — Unit | frontend (node --test) | ${n_node} |
| 1 — Unit | \`pithead\` shell suite | ${n_stack} sections |
| 1 — Unit | compose interpolation + hardening (#90) | 1 |
| 2 — Contract | fake-daemon clients | ${n_py_fake} |
| 3 — Mini-stack | docker control-plane scenarios | ${n_mini} |
| 4 — Live matrix | config scenarios | ${n_scen} (${n_axes} axis values) |
| 4 — Live matrix | harness self-test | ${n_selftest} sections |

---

## Tier 1 — Unit & component

### Dashboard (pytest) — ${n_py_dash} tests
EOF

for f in $PY_DASH_FILES; do
    n=$(py_tests "$f" | count)
    printf '\n#### %s — %s\n' "${f#dashboard/}" "$n"
    py_tests "$f" | bullets
done

cat <<EOF

### Frontend logic (node --test) — ${n_node} tests
EOF
for f in $NODE_FILES; do node_tests "$f" | bullets; done

cat <<EOF

### \`pithead\` shell suite (tests/stack/) — ${n_stack} sections
EOF
while IFS= read -r f; do
    n=$(sh_sections "$f" | count)
    if [ "$n" -eq 0 ]; then continue; fi
    printf '\n#### %s — %s\n' "${f#tests/stack/}" "$n"
    sh_sections "$f" | bullets
done < <(find tests/stack -type f -name '*.sh' ! -path '*/fixtures/*' | sort)

cat <<EOF

### Compose validation + hardening (tests/stack/standalone/test_compose.sh)
- docker-compose.yml \`\${VAR}\` interpolation resolves against a representative .env
- #90 hardening invariants: no-new-privileges / cap_drop / read-only roots, credential-free
  healthchecks, least-privilege Docker socket proxies, and the pinned \`pithead\` project name

### Real-image data-reset repair (tests/stack/standalone/test_data_reset.sh)
- #1062 on a REAL ext4 image with the system's own e2fsprogs: the superblock-magic damage the
  battery injects is repaired with its payload intact — never reformatted — and a destroyed
  image still reaches the reformat escape
- only \`mount\` is stubbed, and its verdict is \`e2fsck -fn\` on the image itself, never a counter

## Tier 2 — Contract (real clients vs controllable fakes)

### tests/integration/fakes/test_*.py — ${n_py_fake} tests
EOF
for f in tests/integration/fakes/test_*.py; do py_tests "$f"; done | bullets

cat <<EOF

## Tier 3 — Fake-daemon mini-stack (docker)

### tests/integration/mini-stack/run-mini-stack.sh — ${n_mini} scenarios
EOF
grep -oE 'log "scenario [0-9]+: [^"]+"' tests/integration/mini-stack/run-mini-stack.sh |
    sed -E 's/^log "//; s/"$//' | bullets

cat <<EOF

## Tier 4 — Live config matrix (real synced server)

### Config scenarios (tests/integration/scenarios.sh) — ${n_scen}
EOF
sed -n '/scenario_matrix() {/,/^EOF/p' tests/integration/scenarios.sh |
    grep -E $'\t' | awk -F'\t' '{print $1}' | bullets

cat <<EOF

### Axis coverage (every value exercised at least once) — ${n_axes}
EOF
sed -n '/axis_coverage() {/,/^EOF/p' tests/integration/scenarios.sh | grep -E '^[a-z].*=' | bullets

cat <<EOF

### Per-scenario assertions (tests/integration/run.sh)
EOF
grep -hoE '(assert_[a-z_]+|it_pass) "[^"]+"' tests/integration/run.sh tests/integration/lib/run-*.sh |
    sed -E 's/^(assert_[a-z_]+|it_pass) "//; s/"$//' |
    grep -vE '^\$[A-Za-z_]+$' | sort -u | bullets

cat <<EOF

### Harness self-test (tests/integration/selftest/*.sh) — ${n_selftest} sections
EOF
for f in tests/integration/selftest/*.sh; do sh_sections "$f"; done | bullets

cat <<EOF

---

_Grand total: **${total}** enumerated cases/sections across the four tiers (plus the live
lifecycle and fault-injection phases, which are exercised on a real server)._
EOF
