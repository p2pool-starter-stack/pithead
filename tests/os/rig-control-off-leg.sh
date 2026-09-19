# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # ip/jar/SCRIPT_DIR are run.sh's; `token` is local so _setup_again_session's write stays here
#
# #1867: the rig whose pool host does not resolve to an IPv4 address. Sourced by tests/os/run.sh and
# run inside phase_rig on the rig the set-up-again legs leave mining, committed on slot A.
#
# RigForge refuses a writable control path it cannot pin to ONE source, so render_rig_miner_config
# leaves control OFF for such a rig (tier 1 proves that rendering). What only a booted appliance can
# prove is the other half of the same fact: that the wizard writes it into the handoff spool, so the
# card the operator reads says the control path is off and why instead of naming an adopt form the
# rig will never answer.
#
# The pool is the guest's OWN sshd through `ip6-localhost`, which the image's /etc/hosts carries on
# the ::1 line only (os/rauc/populate-slot.sh). That is this case's real shape: a host the wizard's
# pre-commit dial REACHES (so the form is accepted — over IPv6) and `getent ahostsv4` cannot answer
# for (so there is no address to pin control to). A name resolving to nothing at all is refused at
# that dial and never produces a card at all, which is a different path.
#
# The leg restores the rig to 127.0.0.1:22 before it returns — the phase's update and coordinator
# legs run after it — and that restore doubles as the positive control: the field is conditional.

RIG_OFF_REASON="the pool host does not resolve to an IPv4 address to pin it to"

# The note the page would put under the card's rows, rendered through the page's OWN module rather
# than restated here. node is not in tier4-kvm's `needs`, so its absence prints nothing and rc 2 —
# a named skip for the caller, never a red row.
rig_card_note() { # <card json>
    local mod="${RIG_CARD_MODULE:-$SCRIPT_DIR/../../dashboard/mining_dashboard/web/static/workers/rigcardlogic.mjs}"
    command -v node >/dev/null 2>&1 || return 2
    node --input-type=module -e \
        'import(process.argv[1]).then(m => process.stdout.write(m.rigCardNote(JSON.parse(process.argv[2]))))' \
        "file://$(cd "$(dirname "$mod")" && pwd)/$(basename "$mod")" "$1" 2>/dev/null
}

# rc 0 when the card is the one #1867 requires for a pool host with no IPv4: the field, the reason
# the render leg logs verbatim, and — when a note was rendered — text that states it without
# sending the operator to the adopt form or the control port. The whole verdict in one predicate so
# --self-test can drive it against the card the wizard wrote BEFORE this change and see it red.
rig_control_off_card_ok() { # <card json> [note]
    printf '%s' "$1" | jq -e --arg r "$RIG_OFF_REASON" '.control == "off" and .reason == $r' >/dev/null 2>&1 || return 1
    [ -n "${2:-}" ] || return 0
    case "$2" in *"control API is off"*"$RIG_OFF_REASON"*) ;; *) return 1 ;; esac
    case "$2" in *"Adopt form"* | *"control port"*) return 1 ;; esac
    return 0
}

# The other direction: a pool host that DOES resolve carries no control field at all. The absence is
# the assertion — a card that always said "off" would pass the predicate above on every rig.
rig_control_on_card_ok() { # <card json>
    printf '%s' "$1" | jq -e '(has("control") or has("reason")) | not' >/dev/null 2>&1
}

# $1 = the token the rig already enforces. Two set-up-again cycles: off, then back on.
rig_control_off_leg() {
    local tok0="$1" jar="" token="" card="" note="" nrc=0
    info "control-off leg (#1867) — a pool host with no IPv4 leaves control off, and the card says why"
    _setup_again_boot 300 || return
    _setup_again_session || return
    card=$(_setup_again_rig_submit kvm-rig ip6-localhost:22 .) || {
        rm -f "$jar"
        return
    }
    rm -f "$jar"
    note=$(rig_card_note "$card") || nrc=$?
    if rig_control_off_card_ok "$card" "$note"; then
        ok "the card says the control path is off, with the reason the render leg logs (#1867)"
    else
        bad "the control-off card is not what #1867 requires: $(printf '%s' "$card" | jq -c 'del(.token)' 2>/dev/null | cut -c1-140)"
    fi
    if [ "$nrc" = 2 ]; then
        it_skip_leg "the card's rendered text (#1867)" \
            "node is not on this harness host and is not in tier4-kvm's needs — the page's own card module cannot be rendered here" missing
    elif [ -z "$note" ]; then
        bad "the card module rendered no text at all for the control-off card"
    else
        case "$note" in
        *"Adopt form"* | *"control port"*) bad "the rendered card still points at the adopt form: $(printf '%s' "$note" | cut -c1-140)" ;;
        *) ok "the rendered card TEXT states it and names no adopt form: $(printf '%s' "$note" | cut -c1-90)" ;;
        esac
    fi
    _rig_mining_up 36 && ok "the rig mines with control off — the miner and its read-only feed are untouched" ||
        bad "the rig did not come up after the control-off Set up again (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
    _ssh "jq -e '.api == \"enabled\" and (has(\"control\") | not) and (has(\"api_allow_from\") | not)' /data/rigforge/config.json >/dev/null" &&
        ok "the miner's config carries no control path and no pin — RigForge is never asked for what it would refuse" ||
        bad "the rig rendered a control path with nothing to pin it to: $(_ssh "jq -c 'del(.pools, .ACCESS_TOKEN)' /data/rigforge/config.json" 2>/dev/null | cut -c1-120)"
    [ "$(_ssh 'jq -r .ACCESS_TOKEN /data/rigforge/config.json' 2>/dev/null | tr -d '\r')" = "$tok0" ] &&
        ok "the token is kept with control off (the feed still wants it)" ||
        bad "the token changed when control went off — the card showed one the miner does not enforce"

    info "...and back: a pool host that resolves puts the control path back (the field is conditional)"
    _setup_again_boot 300 || return
    _setup_again_session || return
    card=$(_setup_again_rig_submit kvm-rig 127.0.0.1:22 .) || {
        rm -f "$jar"
        return
    }
    rm -f "$jar"
    rig_control_on_card_ok "$card" &&
        ok "a resolvable pool host puts NO control field on the card — it is written only when it is true" ||
        bad "the card still carries control/reason for a pool host that resolves: $(printf '%s' "$card" | jq -c 'del(.token)' 2>/dev/null | cut -c1-140)"
    _rig_mining_up 36 && ok "the rig mines again on the resolvable pool" ||
        bad "the rig did not come back up on the resolvable pool"
    _ssh "jq -e '.control == \"enabled\" and .api_allow_from == \"127.0.0.1\"' /data/rigforge/config.json >/dev/null" &&
        ok "control is back, pinned to the pool host — the phase's later legs get the rig they expect" ||
        bad "control did not come back for a resolvable pool host: $(_ssh "jq -c 'del(.pools, .ACCESS_TOKEN)' /data/rigforge/config.json" 2>/dev/null | cut -c1-120)"
}

# The leg's own mutation kill (#1867), driven at tier 1 by tests/stack/test-harness-tooling.sh: the
# rows above only mean something if they RED on the card the wizard wrote before this change. The
# notes are rendered by the real module, so a reverted card logic reds here too.
_rig_control_off_self_test() {
    local off='{"role":"rig","worker":"kvm-rig","stratum":"stratum+tcp://ip6-localhost:22","token":"00000000000000000000000000000000","address":"10.0.0.9","control":"off","reason":"the pool host does not resolve to an IPv4 address to pin it to"}'
    local pre='{"role":"rig","worker":"kvm-rig","stratum":"stratum+tcp://ip6-localhost:22","token":"00000000000000000000000000000000","address":"10.0.0.9"}'
    local note_off note_pre
    note_off=$(rig_card_note "$off") || return 1
    note_pre=$(rig_card_note "$pre") || return 1
    # Green on the card this change makes the wizard write, note and all.
    rig_control_off_card_ok "$off" "$note_off" || return 1
    # RED on the card the wizard wrote with this change reverted: no field, and a note that sends
    # the operator to the adopt form. This is the revert case, kept where it runs on every push.
    ! rig_control_off_card_ok "$pre" "$note_pre" || return 1
    case "$note_pre" in *"Adopt form"*) ;; *) return 1 ;; esac
    # And red on each half being wrong on its own: the reason paraphrased, the field mis-set.
    ! rig_control_off_card_ok "${off/to pin it to/to pin the control API to}" "$note_off" || return 1
    ! rig_control_off_card_ok "${off/\"off\"/\"enabled\"}" "$note_off" || return 1
    ! rig_control_off_card_ok "$off" "Your Pithead's Workers → Adopt form takes this rig's address." || return 1
    # The conditional half, both ways: the pre-change shape is exactly what a resolvable host writes.
    rig_control_on_card_ok "$pre" || return 1
    ! rig_control_on_card_ok "$off" || return 1
}

if [ "${1:-}" = "--self-test" ]; then
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
    _rig_control_off_self_test
    exit $?
fi
