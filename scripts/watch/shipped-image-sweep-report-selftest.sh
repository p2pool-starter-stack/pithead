# shellcheck shell=bash
# Self-test for shipped-image-sweep-report.sh, sourced by its --self-test branch (#1313): drives every
# failure mode through fixtures with no docker, no network and no GitHub. SWEEP_REPORT is the script.
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

# <dir> <service> <artifact-ref> <vuln-json-array>
fixture() {
    mkdir -p "$1"
    jq -n --arg a "$3" --argjson v "$4" \
        '{ArtifactName: $a, Results: [{Target: "t", Class: "os-pkgs", Vulnerabilities: $v}]}' \
        >"$1/sweep-$2.json"
    printf 'v1.20.0\n' >"$1/sweep-$2.tag"
}
ref_for() { printf 'ghcr.io/p2pool-starter-stack/pithead-%s@sha256:%064d' "$1" "$2"; }

# A whole clean sweep. The green path has to be REACHABLE — a check that can only ever say
# "incomplete" is as useless as one that only ever says "clean".
clean="$tmp/clean"
i=1
for s in $SWEPT_IMAGES; do
    fixture "$clean" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
out="$(render_report "$clean")" && rc=0 || rc=$?
st "a complete clean sweep passes" "$rc" "0"
st "a clean sweep says so" \
    "$(printf '%s' "$out" | grep -c 'No fixable HIGH/CRITICAL')" "1"
st "every image appears in the summary" \
    "$(printf '%s' "$out" | grep -c '^| `pithead-')" "6"

# Findings are counted, and only the FIXABLE ones.
found="$tmp/found"
i=1
for s in $SWEPT_IMAGES; do
    if [ "$s" = dashboard ]; then
        fixture "$found" "$s" "$(ref_for "$s" "$i")" '[
            {"VulnerabilityID":"CVE-2026-1","Severity":"HIGH","PkgName":"libfoo",
             "InstalledVersion":"1.0","FixedVersion":"1.1"},
            {"VulnerabilityID":"CVE-2026-2","Severity":"CRITICAL","PkgName":"libbar",
             "InstalledVersion":"2.0","FixedVersion":"2.1"},
            {"VulnerabilityID":"CVE-2026-3","Severity":"HIGH","PkgName":"libbaz",
             "InstalledVersion":"3.0"}
        ]'
    else
        fixture "$found" "$s" "$(ref_for "$s" "$i")" '[]'
    fi
    i=$((i + 1))
done
out="$(render_report "$found")" && rc=0 || rc=$?
st "a finding is reported, not failed" "$rc" "0"
st "only the fixable findings are counted" \
    "$(printf '%s' "$out" | grep -c '`pithead-dashboard` — 2 fixable')" "1"
st "the unfixable finding is not in the table" \
    "$(printf '%s' "$out" | grep -c 'CVE-2026-3')" "0"
st "the finding's own digest is named in full" \
    "$(printf '%s' "$out" | grep -c "Scanned \`$(ref_for dashboard 5)\`")" "1"

# Every refusal. Each must exit 1 AND say UNCHECKED — a quiet zero is the bug.
miss="$tmp/miss"
i=1
for s in $SWEPT_IMAGES; do
    [ "$s" = tor ] || fixture "$miss" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
out="$(render_report "$miss")" && rc=0 || rc=$?
st "a leg that did not finish fails the run" "$rc" "1"
st "the missing image reads UNCHECKED, never clean" \
    "$(printf '%s' "$out" | grep -c '`pithead-tor` | — | \*\*UNCHECKED\*\*')" "1"
# On the PROBLEM TEXT, not just the UNCHECKED row. The missing-file guard and the
# unparseable-report guard below it emit an identical summary row and an identical rc, so an
# assertion on either of those passes whichever guard fired — deleting the missing-file check
# outright left this whole block green until it was checked by mutation. Each guard is now
# named by the one sentence only it writes.
st "the missing leg is diagnosed as a leg that did not finish" \
    "$(printf '%s' "$out" | grep -c 'produced no scan report; its matrix leg did not finish')" "1"
st "a missing leg is not misreported as an unparseable one" \
    "$(printf '%s' "$out" | grep -c 'could not be parsed')" "0"

extra="$tmp/extra"
i=1
for s in $SWEPT_IMAGES; do
    fixture "$extra" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
fixture "$extra" newsvc "$(ref_for newsvc 9)" '[]'
out="$(render_report "$extra")" && rc=0 || rc=$?
st "an image the report does not know about fails the run" "$rc" "1"
st "the drift is named" "$(printf '%s' "$out" | grep -c 'drifted apart')" "1"

bad="$tmp/bad"
i=1
for s in $SWEPT_IMAGES; do
    fixture "$bad" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
printf 'not json at all' >"$bad/sweep-monero.json"
out="$(render_report "$bad")" && rc=0 || rc=$?
st "an unparseable report fails the run" "$rc" "1"
st "an unparseable report reads UNCHECKED" \
    "$(printf '%s' "$out" | grep -c 'could not be parsed')" "1"
st "an unparseable report is not misreported as a missing leg" \
    "$(printf '%s' "$out" | grep -c 'its matrix leg did not finish')" "0"

malformed="$tmp/malformed"
cp -R "$clean" "$malformed"
jq 'del(.Results)' "$clean/sweep-monero.json" >"$malformed/sweep-monero.json"
out="$(render_report "$malformed")" && rc=0 || rc=$?
st "a report without a Results array fails the run" "$rc" "1"
st "a structurally incomplete report reads UNCHECKED" \
    "$(printf '%s' "$out" | grep -c 'could not be parsed')" "1"
jq '.Results = [null]' "$clean/sweep-monero.json" >"$malformed/sweep-monero.json"
out="$(render_report "$malformed")" && rc=0 || rc=$?
st "a non-object Results entry is UNCHECKED" "$rc" "1"
jq '.Results = [{Vulnerabilities: [null]}]' "$clean/sweep-monero.json" >"$malformed/sweep-monero.json"
out="$(render_report "$malformed")" && rc=0 || rc=$?
st "a non-object vulnerability entry is UNCHECKED" "$rc" "1"
jq '.Results = []' "$clean/sweep-monero.json" >"$malformed/sweep-monero.json"
out="$(render_report "$malformed")" && rc=0 || rc=$?
st "an empty Results array is UNCHECKED" "$rc" "1"
jq '.Results = [{Target: "language-pkgs", Class: "lang-pkgs", Vulnerabilities: []}]' "$clean/sweep-monero.json" >"$malformed/sweep-monero.json"
out="$(render_report "$malformed")" && rc=0 || rc=$?
st "a report without an OS-package result is UNCHECKED" "$rc" "1"

notag="$tmp/notag"
cp -R "$clean" "$notag"
rm "$notag/sweep-monero.tag"
out="$(render_report "$notag")" && rc=0 || rc=$?
st "missing release-tag metadata fails the run" "$rc" "1"
st "missing release-tag metadata reads UNCHECKED" \
    "$(printf '%s' "$out" | grep -c 'produced no release-tag metadata')" "1"

# The load-bearing one. If the digest resolve fell through and trivy scanned a TAG, the run
# must not claim it swept published bytes — that is #1313's own defect, one level in.
tagref="$tmp/tagref"
i=1
for s in $SWEPT_IMAGES; do
    fixture "$tagref" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
fixture "$tagref" p2pool "ghcr.io/p2pool-starter-stack/pithead-p2pool:v1.20.0" '[]'
out="$(render_report "$tagref")" && rc=0 || rc=$?
st "a tag scan is refused, not reported as a shipped-image result" "$rc" "1"
st "the tag scan reads UNCHECKED" \
    "$(printf '%s' "$out" | grep -c 'not a digest reference')" "1"

swap="$tmp/swap"
i=1
for s in $SWEPT_IMAGES; do
    fixture "$swap" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
fixture "$swap" tor "$(ref_for monero 3)" '[]'
out="$(render_report "$swap")" && rc=0 || rc=$?
st "a leg that scanned the wrong image fails the run" "$rc" "1"

conflict="$tmp/conflict"
i=1
for s in $SWEPT_IMAGES; do
    fixture "$conflict" "$s" "$(ref_for "$s" "$i")" '[]'
    i=$((i + 1))
done
printf 'v1.19.3\n' >"$conflict/sweep-tor.tag"
out="$(render_report "$conflict")" && rc=0 || rc=$?
st "legs that swept different releases fail the run" "$rc" "1"

out="$(render_report "$tmp/nothing-here")" && rc=0 || rc=$?
st "a missing artifact directory fails the run" "$rc" "1"
st "a missing artifact directory does not print a clean table" \
    "$(printf '%s' "$out" | grep -c 'No fixable')" "0"

empty="$tmp/empty"
mkdir -p "$empty"
out="$(render_report "$empty")" && rc=0 || rc=$?
st "an empty artifact directory fails the run" "$rc" "1"

# Every case above calls render_report inside an `&&` list, where bash suppresses `set -e`
# for the whole dynamic extent of the call — so none of them can see an error-exit that only
# bites the way CI actually invokes this: bare, in its own process. Drive the green path
# through a real subprocess once, or the suite is proving the logic and not the script.
out="$(bash "$SWEEP_REPORT" "$clean")" && rc=0 || rc=$?
st "the clean path survives a real subprocess invocation" "$rc" "0"
st "the subprocess renders the same table" \
    "$(printf '%s' "$out" | grep -c '^| `pithead-')" "6"
out="$(bash "$SWEEP_REPORT" "$miss")" && rc=0 || rc=$?
st "an incomplete sweep still exits 1 from a real subprocess" "$rc" "1"

# The title is the upsert key; a change here silently files a second issue for ever.
st "--title prints the constant and nothing else" \
    "$(bash "$SWEEP_REPORT" --title)" "$SWEEP_ISSUE_TITLE"

[ "$st_fail" = 0 ] && echo "shipped-image-sweep-report self-test OK"
exit "$st_fail"
