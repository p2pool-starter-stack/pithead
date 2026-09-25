# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
#
# The lock for the #2348 CLI verb ledger (docs/dev/testing-strategy.md § G, "CLI verb ledger").
# That table answers, per verb in PITHEAD_COMMANDS, whether a real tier-4 run exercises it —
# `covered`, `missing` (with the issue that owns it) or `by-design` (with the reason). Nothing
# ties the table to the dispatcher, so a verb can be added to PITHEAD_COMMANDS and the ledger goes
# stale silently — which is exactly how five destructive verbs went unexercised unnoticed before
# anyone thought to grep for it. This is the totality check, same shape as the ROV lock in
# test-readonly-verbs-lock.sh: every verb the dispatcher knows falls in exactly one of the three
# sets below, so a verb neither this file nor a human declared reds here rather than passing
# unseen.
#
# The three sets are a second, test-owned copy of the ledger table's verb→state column, not a
# parse of the markdown: the doc is for a human deciding whether a verb's tier-4 answer is
# acceptable, this is for a machine deciding whether every verb has an answer at all. Keeping the
# doc row and this set in sync when a verb's state changes is a review-time discipline; this check
# only enforces that no verb has NO answer.

echo "== domain: the CLI verb ledger accounts for every dispatched verb (#2348) =="

CVL_COVERED="setup apply render up down restart upgrade status doctor backup restore load-images firstboot-wizard local-miner os-update factory-reset control-run-pending egress-status onion-client-key uninstall"
CVL_MISSING="rotate-secrets rotate-dashboard-onion reset-dashboard config-reset support-bundle render-quadlet"
CVL_BYDESIGN="test-alert logs version help"

cvl_cmds="$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    printf '%s' "${PITHEAD_COMMANDS:-}"
)"

# A size comparison is the one shape here that cannot pass on an empty read (an empty $cvl_cmds
# would make the per-verb loop below iterate zero times and PASS having checked nothing); the
# control at the foot of this block shows the same comparison coming apart on an empty read.
cvl_n_read="$(printf '%s' "$cvl_cmds" | wc -w)"
cvl_n_sets="$(printf '%s' "$CVL_COVERED $CVL_MISSING $CVL_BYDESIGN" | wc -w)"
assert_eq "totality: the dispatch verb list was read from the script, and holds as many verbs as the ledger's three sets" "$cvl_n_read" "$cvl_n_sets"

cvl_unclaimed=""
for c in $cvl_cmds; do
    case " $CVL_COVERED $CVL_MISSING $CVL_BYDESIGN " in *" $c "*) ;; *) cvl_unclaimed="$cvl_unclaimed $c" ;; esac
done
assert_eq "totality: every dispatch verb has a ledger row" "${cvl_unclaimed# }" ""

cvl_phantom=""
for c in $CVL_COVERED $CVL_MISSING $CVL_BYDESIGN; do
    case " $cvl_cmds " in *" $c "*) ;; *) cvl_phantom="$cvl_phantom $c" ;; esac
done
assert_eq "totality: no ledger row names a verb the dispatcher does not have" "${cvl_phantom# }" ""

cvl_both=""
for c in $CVL_COVERED $CVL_MISSING; do
    case " $CVL_BYDESIGN " in *" $c "*) cvl_both="$cvl_both $c" ;; esac
done
for c in $CVL_COVERED; do
    case " $CVL_MISSING " in *" $c "*) cvl_both="$cvl_both $c" ;; esac
done
assert_eq "totality: a verb is never in two of the three sets at once" "${cvl_both# }" ""

# The proof this check can go red: drop a real verb from all three sets and confirm the totality
# check catches it, the same way removing its row from the doc table would leave it with no
# answer. This is the change that must fail before the fix above makes it pass again.
cvl_dropped=""
for c in $CVL_COVERED; do [ "$c" = "apply" ] || cvl_dropped="$cvl_dropped $c"; done
cvl_missing_dropped=""
for c in $cvl_cmds; do
    case " $cvl_dropped $CVL_MISSING $CVL_BYDESIGN " in *" $c "*) ;; *) cvl_missing_dropped="$cvl_missing_dropped $c" ;; esac
done
assert_eq "control: dropping a verb's row from the ledger reds the totality check" "${cvl_missing_dropped# }" "apply"

# The control the size comparison above needs: on an empty read the same comparison must come
# apart, or the headline totality row would be evidence of nothing.
cvl_n_empty="$(printf '%s' "" | wc -w)"
if [ "$cvl_n_empty" = "$cvl_n_sets" ]; then cvl_empty_verdict="SAME"; else cvl_empty_verdict="DIFFERS"; fi
assert_eq "control: on an empty read the totality size comparison comes apart, so that row can fail" "$cvl_empty_verdict" "DIFFERS"
