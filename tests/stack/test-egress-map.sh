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
assert_eq "egress map header is role, destination, today, target, route, enforcer, test, audit" \
    "$em_header" "$(printf 'role\tdestination\ttoday\ttarget\troute\tenforcer\ttest\taudit')"

em_shape="$(awk -F '\t' '
    NR == 1 { next }
    NF != 8 { print "line " NR " has " NF " fields, expected 8"; next }
    { for (i = 1; i <= 8; i++) if ($i ~ /^[[:space:]]*$/) print "line " NR " has an empty field " i }
    $1 != "appliance" && $1 != "rig" { print "line " NR " role \"" $1 "\" is outside the fixed set" }
' "$EGRESS_MAP" 2>/dev/null)"
assert_eq "every egress map row has eight non-empty fields and a role from the fixed set" \
    "$em_shape" ""

em_dups="$(awk -F '\t' '
    NR > 1 && NF == 8 { seen[$1 SUBSEP $2]++ }
    END { for (k in seen) if (seen[k] > 1) { split(k, p, SUBSEP); print p[1] ": " p[2] } }
' "$EGRESS_MAP" 2>/dev/null | sort)"
assert_eq "no outbound path is listed twice" "$em_dups" ""

em_vocab="$(awk -F '\t' '
    NR == 1 { next }
    NF == 8 {
        if ($3 !~ /^(allow|drop|lan|build|unknown)$/) print "line " NR " today \"" $3 "\" is outside the fixed set"
        if ($4 !~ /^(allow|drop|lan|build|unknown)$/) print "line " NR " target \"" $4 "\" is outside the fixed set"
        if ($5 !~ /^(tor|host|lan|build|unknown)$/) print "line " NR " route \"" $5 "\" is outside the fixed set"
        if ($6 !~ /^(tor-egress-fence|lan-guard|app-config|none)$/) print "line " NR " enforcer \"" $6 "\" is outside the fixed set"
    }
' "$EGRESS_MAP" 2>/dev/null)"
assert_eq "today, target, route and enforcer cells stay in the fixed sets" "$em_vocab" ""

em_audit="$(awk -F '\t' '
    NR == 1 || NF != 8 || $8 == "-" { next }
    {
        n = split($8, a, " ")
        if (n != 3 || a[2] != "tcp" || a[1] !~ /^(allowlisted|choice:(monero|tari|p2pool|xvb|donation))$/ || a[3] !~ /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) print "line " NR " audit \"" $8 "\" is outside the fixed form"
        if ($5 != "host") print "line " NR " has an audit match but route " $5 ": only host-route rows are counted by the host table"
    }
' "$EGRESS_MAP" 2>/dev/null)"
assert_eq "audit cells are '-' or '<allowlisted|choice:KEY> tcp PORTS' on host-route rows" "$em_audit" ""

em_overlap="$(awk -F '\t' '
    NR == 1 || NF != 8 || $8 == "-" { next }
    {
        split($8, a, " "); cls = a[1] ~ /^choice:/ ? "choice" : "allowlisted"
        m = split(a[3], ps, ",")
        for (i = 1; i <= m; i++) { if (ps[i] in owner && owner[ps[i]] != cls) print "port " ps[i] " is both " owner[ps[i]] " and " cls; owner[ps[i]] = cls }
    }
' "$EGRESS_MAP" 2>/dev/null)"
assert_eq "no port is both allowlisted and an operator choice, so the host counters never double-subtract" "$em_overlap" ""

em_keys="$(awk -F '\t' 'NR > 1 && NF == 8 && $8 ~ /choice:/ { split($8, a, " "); sub(/^choice:/, "", a[1]); print a[1] }' "$EGRESS_MAP" | sort -u)"
em_holes="$(
    awk '/^tor_egress_choice_active\(\)/ { arm = 1 }
        arm && /^    [a-z0-9]+\)/ { s = $1; sub(/\)/, "", s); print s }
        arm && /^    esac/ { arm = 0 }' "$ROOT/lib/pithead/02b-tor-egress-apply.sh"
    awk '/^host_egress_audit_choices\(\)/ { on = 1 }
        on && /c="/ { n = split($0, q, "\""); m = split(q[n - 1], t, " "); if (m >= 1 && t[m] ~ /^[a-z0-9]+$/) print t[m] }
        on && /^}/ { on = 0 }' "$ROOT/lib/pithead/02f-host-egress-audit.sh"
)"
em_holes="$(printf '%s\n' "$em_holes" | grep . | sort -u)"
assert_eq "every clearnet hole the firewall can open has a choice row, so a chosen path can never read as a leak" \
    "$(comm -23 <(printf '%s\n' "$em_holes") <(printf '%s\n' "$em_keys"))" ""
assert_eq "every choice row names a hole the firewall can open, so no row hides a class nothing counts" \
    "$(comm -23 <(printf '%s\n' "$em_keys") <(printf '%s\n' "$em_holes"))" ""

em_missing="$(awk -F '\t' 'NR > 1 && NF == 8 && $7 != "none" { print $7 }' "$EGRESS_MAP" 2>/dev/null | sort -u | while IFS= read -r em_path; do
    [ -n "$em_path" ] && [ ! -e "$ROOT/$em_path" ] && printf '%s\n' "$em_path"
done)"
assert_eq "every test cell names a path that exists in the repo" "$em_missing" ""

em_appliance="$(awk -F '\t' 'NR > 1 && $1 == "appliance" { n++ } END { print n + 0 }' "$EGRESS_MAP" 2>/dev/null)"
if [ "${em_appliance:-0}" -gt 0 ]; then ok "the map carries at least one appliance row"; else bad "the map carries at least one appliance row" "found 0"; fi
em_rig="$(awk -F '\t' 'NR > 1 && $1 == "rig" { n++ } END { print n + 0 }' "$EGRESS_MAP" 2>/dev/null)"
if [ "${em_rig:-0}" -gt 0 ]; then ok "the map carries at least one rig row"; else bad "the map carries at least one rig row" "found 0"; fi

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
