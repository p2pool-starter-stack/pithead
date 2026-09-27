# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Doctor's remedial strings are surface-aware (#1213, #1776, #1777): the dr_*_surface switch, the
# data-dir verdict's wording, and the sweep over the shipped artifact for plain verdicts that name a
# CLI verb. Moved out of tests/stack/run.sh unchanged. Sourced by tests/stack/run.sh after lib.sh.

echo "== unit: doctor's remedial strings are surface-aware (#1213) =="
# Doctor's verdicts reach the dashboard verbatim now that the diagnostics verbs ship them
# (control_diag_doctor runs `doctor --json`; doctor_json emits every message as {status, message}),
# so a remedial string naming a CLI verb is a dead end on an appliance, which has no shell. Two
# instruments, because either alone passes for the wrong reason: the switch has to actually FLIP,
# and no verdict may be left behind it.
#
# 1. The mechanism. Argument one is the DIY/host wording, argument two the appliance's; each side
#    must print its own and NOT the other's -- asserting only that the right text appears would
#    stay green if both were printed.
for _s in fail warn info; do
    out=$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" "dr_${_s}_surface" "DIYSIDE" "APPLIANCESIDE" 2>&1)
    assert_contains "dr_${_s}_surface off the appliance prints the host wording" "$out" "DIYSIDE"
    case "$out" in
    *APPLIANCESIDE*) bad "dr_${_s}_surface off the appliance withholds the appliance wording" "both sides printed: $out" ;;
    *) ok "dr_${_s}_surface off the appliance withholds the appliance wording" ;;
    esac
    out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" "dr_${_s}_surface" "DIYSIDE" "APPLIANCESIDE" 2>&1)
    assert_contains "dr_${_s}_surface on the appliance prints the appliance wording" "$out" "APPLIANCESIDE"
    case "$out" in
    *DIYSIDE*) bad "dr_${_s}_surface on the appliance withholds the host wording" "both sides printed: $out" ;;
    *) ok "dr_${_s}_surface on the appliance withholds the host wording" ;;
    esac
done

# 2. The #1776 site, named because the sweep below could not see it: its verdict prescribed two
#    host-only remedies ("Move the data here" and the verb as the bare quoted word 'apply'), which
#    the sweep's alternation had no token for until #1777 widened it. Read off the SHIPPED
#    artifact, the same instrument the sweep uses, so a lib/ edit that never reaches it cannot pass.
#
#    AND THIS BLOCK IS NOW THE SITE'S ONLY VERB GUARD. Converting it to dr_warn_surface took it
#    OUT of block 3's sweep by construction -- that sweep's site pattern is `dr_warn "`, which a
#    `dr_warn_surface "` call does not match, deliberately, because a host argument is SUPPOSED to
#    keep its verb. The single literal in _dd_pred_verb is all that stands behind the appliance
#    side of this verdict. Widen it here, not there.
#
#    THE CONTROL IS NOT OPTIONAL. Both assertions below are ABSENCE claims over a grep, and one
#    goes green when the needle merely stops matching -- rename the message and this passes forever
#    proving nothing. So the same two predicates run against a synthetic PRE-FIX line and must fire.
_dd_pred_plain() { case "$1" in *dr_warn_surface*) return 1 ;; *) return 0 ;; esac }
_dd_pred_verb() { case "$1" in *"run 'apply'"*) return 0 ;; *) return 1 ;; esac }
_dd_seed="            dr_warn \"Data dir from .env not found: X=Y — a relocated/copied install re-syncs from scratch. Move the data here, or set the data_dir in config.json and run 'apply'.\""
if _dd_pred_plain "$_dd_seed" && _dd_pred_verb "$_dd_seed"; then
    ok "control: the pre-fix data-dir verdict is caught as plain AND as naming a verb (#1776)"
else
    bad "control: the pre-fix data-dir verdict was NOT caught" "instrument cannot fail; the assertions below prove nothing"
fi

_dd_line=$(grep -a -n 'Data dir from .env not found' "$STACK" | head -1)
if [ -z "$_dd_line" ]; then
    bad "the data-dir verdict is present in the shipped artifact (#1776)" "no line matched -- the message was renamed and the assertions below are vacuous"
else
    ok "the data-dir verdict is present in the shipped artifact (#1776)"
    if _dd_pred_plain "$_dd_line"; then
        bad "the data-dir verdict is surface-aware (#1776)" "still a plain dr_warn: $_dd_line"
    else
        ok "the data-dir verdict is surface-aware (#1776)"
    fi
    # The host side KEEPS the verb by design (it is the DIY wording); only the appliance side must
    # not. Take the second quoted argument, the way the helper's own contract orders them.
    _dd_appl=$(printf '%s' "$_dd_line" | awk -F'"' '{print $4}')
    # ...and prove the field EXISTS before reading an absence out of it: on the pre-fix shape (one
    # quoted argument) $4 is empty, _dd_pred_verb "" returns rc 1, and the row below would print ok
    # having examined nothing. Only its sibling reds that case today.
    if [ -z "$_dd_appl" ]; then
        bad "the data-dir verdict's appliance wording names no host verb (#1776)" "no second quoted argument on: $_dd_line"
    elif _dd_pred_verb "$_dd_appl"; then
        bad "the data-dir verdict's appliance wording names no host verb (#1776)" "appliance side still says run 'apply': $_dd_appl"
    else
        ok "the data-dir verdict's appliance wording names no host verb (#1776)"
    fi

    # The appliance wording NAMES which of these dirs the dashboard can repoint, so it is a claim
    # about CONTROL_DASHBOARD_CONFIRM_KEYS -- and its first draft ("no dashboard control relocates a
    # data directory") was false for four of the five keys the check fires on. Derive both sets from
    # the shipped artifact, so an allowlist change reds HERE and names the string to rewrite.
    _dd_in_set() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac }
    _dd_repointable() {
        local _k _out=''
        for _k in $1; do _dd_in_set "$_k" "$2" && _out="${_out:+$_out }$_k"; done
        printf '%s' "$_out"
    }
    _dd_sites=$(sed -n 's/^ *for var in \(.*_DATA_DIR\); do$/\1/p' "$STACK")
    _dd_all=${_dd_sites%%$'\n'*}
    # THE GUARD THAT EARNS ITS PLACE, replacing one that could not: reseeding TOR_DATA_DIR was
    # strictly REDUNDANT, its pass condition being exactly what the CANNOT row asserts, so it could
    # never red alone. A second site above either live extractor would otherwise feed these rows a
    # stale list. Sed drops a `for ...; do` line with a trailing comment, and the existing uniqueness guard reds.
    # Only awk's closing-quote trailing-comment over-read remains unguarded; it does not change today's output.
    assert_eq "the data-dir key list comes from exactly one site (#1776)" "$(printf '%s\n' "$_dd_sites" | grep -c .)" "1"
    assert_eq "the confirm-key allowlist comes from exactly one site (#1816)" "$(grep -c "^CONTROL_DASHBOARD_CONFIRM_KEYS='" "$STACK")" "1"
    _dd_conf=$(awk "/^CONTROL_DASHBOARD_CONFIRM_KEYS='/{f=1} f{print} f && /'[[:space:]]*\$/{exit}" "$STACK" |
        tr -d "\n'" | sed "s/^CONTROL_DASHBOARD_CONFIRM_KEYS=//;s/  */ /g;s/^ //")
    assert_eq "the dirs doctor warns about that the dashboard CAN repoint (#1776)" \
        "$(_dd_repointable "$_dd_all" "$_dd_conf")" \
        "MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR"
    assert_eq "the dirs doctor warns about that it CANNOT (#1776)" \
        "$(_dd_repointable "$_dd_all" "$(printf '%s' "$_dd_all" | tr ' ' '\n' | grep -vxF -f <(printf '%s' "$_dd_conf" | tr ' ' '\n') | tr '\n' ' ')")" \
        "TOR_DATA_DIR"
    # ...and that the wording actually carries both halves. If either row above reds, THIS is the
    # string that has to be rewritten, so name it here rather than only in the assertion text.
    case "$_dd_appl" in
    *"repointed from the config page"*) ok "the appliance wording offers the dashboard route (#1776)" ;;
    *) bad "the appliance wording offers the dashboard route (#1776)" "no config-page route in: $_dd_appl" ;;
    esac
    case "$_dd_appl" in
    *"tor data dir cannot"*) ok "the appliance wording excepts the one dir that cannot (#1776)" ;;
    *) bad "the appliance wording excepts the one dir that cannot (#1776)" "TOR_DATA_DIR is on neither allowlist and the wording does not say so: $_dd_appl" ;;
    esac
fi

# 3. Totality over the SHIPPED artifact. The SITES are enumerated mechanically out of the built
#    `pithead`, not a hand list -- a hand list is blind to the site nobody remembered, and this
#    sweep found nine of those. A PLAIN dr_fail/dr_warn/dr_info literal has no appliance side, so
#    naming a CLI verb there tells an appliance operator to run it; `dr_*_surface` calls do not
#    match, their host argument keeping its verb by design. An exemption states its reason inline.
#
#    #1777 WIDENED THE ALTERNATION TO THE IMPERATIVE, not just the executable form: it carried
#    `\./pithead ` but no token for a verb written as a bare or quoted word, so it returned 0 over
#    #1776's site, which it fully covers. Over the artifact the widened branch adds exactly one
#    site -- the "Run doctor there" info below -- and that one takes the marker, not a conversion.
#
#    WHICH LEAVES THE CONTROL AS THE ONLY THING VALIDATING THE WIDENING: with that marker in place
#    the new branch has NO live target, so its 0 is what a needle matching nothing also prints. The
#    seed is the pre-marker text, run through _dr_leaks -- the helper the sweep itself calls, never
#    a second spelling of it, which would be mutated in lockstep with nothing.
#
#    STILL NOT COVERED: the needle list is hand-kept, so a verdict using a token nobody listed
#    passes clean -- green means "none of the KNOWN forms leaked", never "no verb leaked". And it
#    is LITERAL-ONLY: a message arriving in a VARIABLE is beyond any needle -- read
#    05-doctor-checks.sh:111 and 21-doctor-stack-checks.sh:261 by hand. A THIRD site left this list
#    when #1772 made the stratum-exposure warn a dr_warn_surface; it is test-doctor-exposure.sh's.
_dr_leaks() { grep -nE '(dr_fail|dr_warn|dr_info) "' | grep -E "\./pithead |docker compose |docker pull |docker-compose-v2|Start the Docker daemon|sudo |systemctl|git pull|([Rr]e-?)?[Rr]un '?(\./pithead )?(apply|setup|up|down|restart|doctor|status|logs)'?" | grep -v "appliance-unreachable" || true; }
if [ -z "$(printf '%s\n' '    dr_info "This is not the live install -- X/current points at Y. Run doctor there to check its control channel."' | _dr_leaks)" ]; then
    bad "control: the sweep catches an imperative naming a bare pithead verb (#1777)" "the widened alternation cannot fire; the 0 below is not evidence"
else
    ok "control: the sweep catches an imperative naming a bare pithead verb (#1777)"
fi
dr_verb_leaks=$(_dr_leaks <"$STACK")
assert_eq "no plain doctor verdict still names a CLI verb (#1213)" \
    "$(printf '%s' "$dr_verb_leaks" | grep -c . || true)" "0"
[ -n "$dr_verb_leaks" ] && printf '    leaked: %s\n' "$dr_verb_leaks" | head -12 || true
