#!/usr/bin/env bash
# install-test-tools.sh — build and verify the test-harness images a bench needs (#2059 follow-up).
#
#   scripts/install-test-tools.sh          build anything missing, then verify everything
#   scripts/install-test-tools.sh --check  verify only; build nothing. rc 1 if something is missing
#   scripts/install-test-tools.sh --self-test
#
# These are IMAGES, not apt packages, and that is the whole point. An apt install on a bench is
# invisible to every piece of supply-chain tooling this repo owns: Dependabot has no apt ecosystem,
# and Trivy scans images, not hosts. As pinned images they get weekly base-digest PRs
# (.github/dependabot.yml) and a CVE gate on every PR (.github/workflows/test-images.yml), same as
# the shipped surfaces.
#
# Nothing here reaches a user. The release bundle (scripts/release/bundle.sh make_bundle) and the
# appliance image (os/rootfs/Dockerfile) are both strict ALLOWLISTS of named paths — no tests/ path
# can enter either, and tests/stack/release asserts it rather than trusting it.
#
# VERIFY, don't assume. `docker build` succeeding proves the Dockerfile parsed, not that the tool
# inside answers. Every image here is RUN once and its tool asked for its version, because "the
# image exists" and "the image works" are different claims and only the second one is useful at
# 2am on a bench.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ENGINE="${NETWATCH_ENGINE:-docker}"
MODE=install
case "${1:-}" in
--check) MODE=check ;;
--self-test) MODE=selftest ;;
"") ;;
*)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

# image-tag <TAB> build-context <TAB> smoke command run INSIDE the image
# The smoke command is the point of the row: it is what turns "built" into "works".
test_tool_images() {
    printf '%s\t%s\t%s\n' \
        'pithead-netwatch:test' 'tests/netwatch' '--version' \
        'pithead-tor-client:test' 'tests/integration/tor-client' '--version'
}

PASS=0 FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n' "$1"
}

if [ "$MODE" = selftest ]; then
    # No engine, no network: prove the table is well-formed and the smoke step cannot be skipped.
    f=0
    n=$(test_tool_images | grep -c .)
    [ "$n" -ge 2 ] || {
        printf 'expected at least 2 image rows, got %s\n' "$n" >&2
        f=1
    }
    while IFS=$'\t' read -r tag ctx smoke; do
        [ -n "$tag" ] && [ -n "$ctx" ] && [ -n "$smoke" ] || {
            printf 'row without a tag, context or SMOKE command: [%s][%s][%s]\n' "$tag" "$ctx" "$smoke" >&2
            f=1
        }
        [ -f "$ROOT/$ctx/Dockerfile" ] || {
            printf 'row names %s but %s/Dockerfile does not exist\n' "$ctx" "$ctx" >&2
            f=1
        }
    done < <(test_tool_images)
    # Every context here must also be covered by dependabot and by the CI CVE scan, or the point of
    # shipping these as images is lost. Checked against the real files, not asserted in prose.
    while IFS=$'\t' read -r _ ctx _; do
        grep -qF "\"/$ctx\"" "$ROOT/.github/dependabot.yml" || {
            printf '%s is not tracked in .github/dependabot.yml\n' "$ctx" >&2
            f=1
        }
        grep -qF "context: $ctx" "$ROOT/.github/workflows/test-images.yml" || {
            printf '%s is not built+scanned in .github/workflows/test-images.yml\n' "$ctx" >&2
            f=1
        }
    done < <(test_tool_images)
    [ "$f" -eq 0 ] || {
        printf 'install-test-tools self-test FAILED\n'
        exit 1
    }
    printf 'install-test-tools self-test passed\n'
    exit 0
fi

command -v "$ENGINE" >/dev/null 2>&1 || {
    printf 'install-test-tools: %s not found. The bench needs a container engine (set NETWATCH_ENGINE to override).\n' "$ENGINE" >&2
    exit 2
}

printf '\033[1;34m==>\033[0m test-harness images (%s)\n' "$ENGINE"
while IFS=$'\t' read -r tag ctx smoke; do
    [ -n "$tag" ] || continue
    have=0
    "$ENGINE" image inspect "$tag" >/dev/null 2>&1 && have=1
    if [ "$MODE" = check ]; then
        [ "$have" = 1 ] && ok "$tag present" || bad "$tag MISSING — run scripts/install-test-tools.sh"
        continue
    fi
    if [ "$have" = 0 ]; then
        printf '  building %s from %s …\n' "$tag" "$ctx"
        if ! "$ENGINE" build -q -t "$tag" "$ROOT/$ctx" >/dev/null 2>"/tmp/netwatch-build.$$"; then
            bad "$tag FAILED to build: $(head -c 200 "/tmp/netwatch-build.$$" 2>/dev/null)"
            rm -f "/tmp/netwatch-build.$$"
            continue
        fi
        rm -f "/tmp/netwatch-build.$$"
    fi
    # The smoke run. A build that parsed is not a tool that answers. Every row declares one, so
    # there is no "built, unverified" state to report — that state is what this exists to remove.
    # shellcheck disable=SC2086 # $smoke is a deliberate word-split argv, not a path
    if out=$("$ENGINE" run --rm "$tag" $smoke 2>&1 | head -n1); then
        ok "$tag works — $out"
    else
        bad "$tag built but its tool does not answer: $(printf '%s' "$out" | head -c 160)"
    fi
done < <(test_tool_images)

printf '\ninstall-test-tools: \033[1;32m%d ok\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
