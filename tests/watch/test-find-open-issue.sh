#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
total=300
case "$1 $2" in
"issue list")
    limit=30
    while [ "$#" -gt 0 ]; do [ "$1" = --limit ] && limit=$2; shift; done
    first=$((total - limit + 1))
    ;;
"api --paginate") first=1 ;;
*) exit 1 ;;
esac
for n in $(seq "$total" -1 "$first"); do
    if [ "$n" = 10 ]; then printf '%s\tWeekly report\n' "$n"; else printf '%s\tOther %s\n' "$n" "$n"; fi
done
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok: $1"; else
        echo "FAIL: $1 (got [$2], want [$3])"
        fail=1
    fi
}

old=$(gh issue list --state open --limit 200 | awk -F'\t' '$2 == "Weekly report" { print $1 }')
check "the fake hides the report from a 200-issue lookup" "$old" ""
check "the shared lookup finds a report past the first 200 issues" \
    "$(bash scripts/watch/find-open-issue.sh "Weekly report")" "10"
check "an absent title yields nothing" "$(bash scripts/watch/find-open-issue.sh "Missing")" ""
check "a prefix of the title does not match" "$(bash scripts/watch/find-open-issue.sh "Weekly")" ""
check "no workflow keeps the capped lookup" \
    "$(grep -l 'issue list --state open' .github/workflows/*.yml | tr '\n' ' ')" ""
for w in pin-watch trivyignore-watch scheduled-run-watch ci os-package-watch; do
    check "$w uses the shared lookup" "$(grep -c 'scripts/watch/find-open-issue.sh' ".github/workflows/$w.yml")" "1"
done
exit "$fail"
