# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== egress map: one row per outbound path, committed as a data file (#4194) =="

EGRESS_MAP="$ROOT/data/egress-map.tsv"

if [ -f "$EGRESS_MAP" ]; then
    ok "data/egress-map.tsv exists"
else
    bad "data/egress-map.tsv exists" "the committed egress map is missing"
fi

em_header="$(head -n 1 "$EGRESS_MAP" 2>/dev/null)"
assert_eq "egress map header is role, destination, today, target, route, enforcer, test" \
    "$em_header" "$(printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest')"

em_shape="$(awk -F '\t' '
    NR == 1 { next }
    NF != 7 { print "line " NR " has " NF " fields, expected 7"; next }
    { for (i = 1; i <= 7; i++) if ($i ~ /^[[:space:]]*$/) print "line " NR " has an empty field " i }
    $1 != "appliance" && $1 != "rig" { print "line " NR " role \"" $1 "\" is outside the fixed set" }
' "$EGRESS_MAP" 2>/dev/null)"
assert_eq "every egress map row has seven non-empty fields and a role from the fixed set" \
    "$em_shape" ""

em_dups="$(awk -F '\t' '
    NR > 1 && NF == 7 { seen[$1 SUBSEP $2]++ }
    END { for (k in seen) if (seen[k] > 1) { split(k, p, SUBSEP); print p[1] ": " p[2] } }
' "$EGRESS_MAP" 2>/dev/null | sort)"
assert_eq "no outbound path is listed twice" "$em_dups" ""

em_vocab="$(awk -F '\t' '
    NR == 1 { next }
    NF == 7 {
        if ($3 !~ /^(allow|drop|lan|build|unknown)$/) print "line " NR " today \"" $3 "\" is outside the fixed set"
        if ($4 !~ /^(allow|drop|lan|build|unknown)$/) print "line " NR " target \"" $4 "\" is outside the fixed set"
        if ($5 !~ /^(tor|host|lan|build|unknown)$/) print "line " NR " route \"" $5 "\" is outside the fixed set"
        if ($6 !~ /^(tor-egress-fence|lan-guard|app-config|none)$/) print "line " NR " enforcer \"" $6 "\" is outside the fixed set"
    }
' "$EGRESS_MAP" 2>/dev/null)"
assert_eq "today, target, route and enforcer cells stay in the fixed sets" "$em_vocab" ""

em_missing="$(awk -F '\t' 'NR > 1 && NF == 7 && $7 != "none" { print $7 }' "$EGRESS_MAP" 2>/dev/null | sort -u | while IFS= read -r em_path; do
    [ -n "$em_path" ] && [ ! -e "$ROOT/$em_path" ] && printf '%s\n' "$em_path"
done)"
assert_eq "every test cell names a path that exists in the repo" "$em_missing" ""

em_appliance="$(awk -F '\t' 'NR > 1 && $1 == "appliance" { n++ } END { print n + 0 }' "$EGRESS_MAP" 2>/dev/null)"
if [ "${em_appliance:-0}" -gt 0 ]; then ok "the map carries at least one appliance row ($em_appliance)"; else bad "the map carries at least one appliance row" "found 0"; fi
em_rig="$(awk -F '\t' 'NR > 1 && $1 == "rig" { n++ } END { print n + 0 }' "$EGRESS_MAP" 2>/dev/null)"
if [ "${em_rig:-0}" -gt 0 ]; then ok "the map carries at least one rig row ($em_rig)"; else bad "the map carries at least one rig row" "found 0"; fi

em_enforcer() {
    awk -F '\t' -v want="$1" 'NR > 1 && $6 == want { found = 1; exit } END { print found ? "yes" : "no" }' "$EGRESS_MAP" 2>/dev/null
}
em_destination() {
    awk -F '\t' -v needle="$1" 'NR > 1 && index($2, needle) { found = 1; exit } END { print found ? "yes" : "no" }' "$EGRESS_MAP" 2>/dev/null
}

assert_eq "anchor row exists for tor egress" "$(em_enforcer tor-egress-fence)" "yes"
assert_eq "anchor row exists for the LAN guard" "$(em_enforcer lan-guard)" "yes"
assert_eq "anchor row exists for htpdate time sync" "$(em_destination www.debian.org)" "yes"
assert_eq "anchor row exists for the pool stratum endpoint" "$(em_destination stratum)" "yes"
assert_eq "anchor row exists for registry image pulls" "$(em_destination ghcr.io)" "yes"
