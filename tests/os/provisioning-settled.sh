# shellcheck shell=bash
# Sourced by tests/os/run.sh. A live stack is not a finished provisioning: the wizard's `(setup)`
# (and pithead-boot's `./pithead up`) holds the mutation lock through `compose up`'s tor-health
# wait, minutes after `podman ps` shows dashboard and caddy, and a `pithead backup` started then
# either waits it out or, when that `up` dies, backs up the wreck (#1945). Provisioning is
# finished when neither unit is `activating`. A wizard whose setup failed reopens its page and
# stays `activating` for good, so the wait is bounded and the verdict names the spool's reason.
# Both take `_ssh` and `$ip` from run.sh; PROVISIONING_POLL_S is the fixture test's fast poll.

provisioning_units() { # four fields, space-separated: "<firstboot ActiveState> <boot ActiveState> <firstboot ConditionResult> <boot ConditionResult>"
    _ssh "systemctl show -p ActiveState --value pithead-firstboot.service 2>/dev/null
          systemctl show -p ActiveState --value pithead-boot.service 2>/dev/null
          systemctl show -p ConditionResult --value pithead-firstboot.service 2>/dev/null
          systemctl show -p ConditionResult --value pithead-boot.service 2>/dev/null" 2>/dev/null |
        tr -d '\r' | tr '\n' ' '
}

provisioning_terminal_state() { case "$1" in active | inactive | failed | deactivating) return 0 ;; *) return 1 ;; esac }

# $1 = firstboot ActiveState  $2 = boot ActiveState  $3 = firstboot ConditionResult  $4 = boot ConditionResult
# `systemctl is-active` alone cannot tell "skipped by its own condition" from "ran and finished" —
# a oneshot with RemainAfterExit=no (firstboot) reads `inactive` in both cases, and a
# condition-skipped unit never appears in `systemctl --failed` either (#2055 G3, the discrimination
# #1212 needed for hugepages). The two units' conditions are mutually exclusive by design —
# firstboot's ConditionPathExists is `!config.json`/`!machine-role`, boot's is the same paths
# without the `!` — so on a healthy boot exactly one has ConditionResult=yes; "no no" means neither
# entered its normal role (most likely the shared `ConditionPathIsMountPoint=/data` guard failed).
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
provisioning_ran_verdict() {
    local fb_active="$1" boot_active="$2" fb_ran="$3" boot_ran="$4"
    if [ "$fb_ran" != yes ] && [ "$boot_ran" != yes ]; then
        echo "neither provisioning unit ran this boot (firstboot ConditionResult: ${fb_ran:-unreadable}, boot: ${boot_ran:-unreadable}) — is-active alone cannot tell a correctly-skipped unit from one that never got the chance"
        return 1
    fi
    echo "one provisioning unit ran this boot (firstboot: ${fb_active:-unreadable}/ran=${fb_ran:-unreadable}, boot: ${boot_active:-unreadable}/ran=${boot_ran:-unreadable})"
    return 0
}

provisioning_settled() { # $1 seconds -> 0 once no provisioning unit is activating AND one of them ran, 1 at the deadline
    local deadline=$(($(date +%s) + $1)) st
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! st=$(provisioning_units); then
            sleep "${PROVISIONING_POLL_S:-15}"
            continue
        fi
        # shellcheck disable=SC2086  # intentional split: exactly four fields must answer
        set -- $st
        # Word-anchored: `deactivating` contains `activating` and is a unit on its way OUT, not in.
        case " $st " in
        *" activating "*) sleep "${PROVISIONING_POLL_S:-15}" ;;
        *)
            if [ "$#" -eq 4 ] && provisioning_terminal_state "$1" && provisioning_terminal_state "$2" &&
                provisioning_ran_verdict "$1" "$2" "$3" "$4" >/dev/null; then
                return 0
            fi
            sleep "${PROVISIONING_POLL_S:-15}"
            ;;
        esac
    done
    return 1
}

provisioning_state() { # one line for a verdict: unit states + whether one ran, plus the wizard's error if it failed
    local r st
    r=$(_ssh "cat /data/pithead/data/firstboot/error.txt 2>/dev/null" 2>/dev/null | tr -d '[:cntrl:]' | head -c 160)
    st=$(provisioning_units)
    # shellcheck disable=SC2086  # intentional split: four fields on a guest that answered
    set -- $st
    # ARITY IS NOT ASSUMED, and that is the whole point of this line. Every caller is a `bad`
    # reporting that provisioning did not finish, so this runs exactly when the guest is least
    # likely to answer cleanly: unreachable, truncated mid-probe, systemctl absent. Passing a
    # short read straight through would read "$4" unbound under run.sh's `set -u` and kill the
    # verdict — losing the spooled setup error below, which is the one line that says WHY (#2055).
    if [ "$#" -eq 4 ]; then
        printf 'units: %s' "$(provisioning_ran_verdict "$1" "$2" "$3" "$4")"
    else
        printf 'units: the probe answered %s field(s), not the 4 expected: %s' "$#" "${st:-nothing}"
    fi
    [ -z "$r" ] || printf ' — setup error: %s' "$r"
}

# $1 = unit name (no .service suffix needed). Same discrimination as provisioning_ran_verdict
# above, for the "this unit must NOT have run" checks elsewhere in the battery (setup-again-leg.sh,
# phases/rig.sh): `is-active --quiet` reading false is equally true of "correctly skipped" and "ran
# to completion" for a RemainAfterExit=no oneshot like pithead-firstboot, so it cannot by itself
# prove the unit stayed closed (#2055 G3).
unit_ran_this_boot() {
    [ "$(_ssh "systemctl show -p ConditionResult --value $1" 2>/dev/null | tr -d '\r\n')" = yes ]
}
