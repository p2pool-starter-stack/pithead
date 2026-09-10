# shellcheck shell=bash
# Sourced by tests/os/run.sh. A live stack is not a finished provisioning: the wizard's `(setup)`
# (and pithead-boot's `./pithead up`) holds the mutation lock through `compose up`'s tor-health
# wait, minutes after `podman ps` shows dashboard and caddy, and a `pithead backup` started then
# either waits it out or, when that `up` dies, backs up the wreck (#1945). Provisioning is
# finished when neither unit is `activating`. A wizard whose setup failed reopens its page and
# stays `activating` for good, so the wait is bounded and the verdict names the spool's reason.
# Both take `_ssh` and `$ip` from run.sh; PROVISIONING_POLL_S is the fixture test's fast poll.

provisioning_units() { # the two units' states, one line, space-separated: "<firstboot> <boot>"
    _ssh "systemctl is-active pithead-firstboot.service pithead-boot.service 2>/dev/null; :" 2>/dev/null |
        tr -d '\r' | tr '\n' ' '
}

provisioning_terminal_state() { case "$1" in active | inactive | failed | deactivating) return 0 ;; *) return 1 ;; esac }

provisioning_settled() { # $1 seconds -> 0 once no provisioning unit is activating, 1 at the deadline
    local deadline=$(($(date +%s) + $1)) st
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! st=$(provisioning_units); then
            sleep "${PROVISIONING_POLL_S:-15}"
            continue
        fi
        # shellcheck disable=SC2086  # intentional split: exactly two unit states must answer
        set -- $st
        # Word-anchored: `deactivating` contains `activating` and is a unit on its way OUT, not in.
        case " $st " in
        *" activating "*) sleep "${PROVISIONING_POLL_S:-15}" ;;
        *)
            [ "$#" -eq 2 ] && provisioning_terminal_state "$1" && provisioning_terminal_state "$2" && return 0
            sleep "${PROVISIONING_POLL_S:-15}"
            ;;
        esac
    done
    return 1
}

provisioning_state() { # one line for a verdict: unit states, plus the wizard's error if it failed
    local r
    r=$(_ssh "cat /data/pithead/data/firstboot/error.txt 2>/dev/null" 2>/dev/null | tr -d '[:cntrl:]' | head -c 160)
    printf 'units: %s' "$(provisioning_units)"
    [ -z "$r" ] || printf ' — setup error: %s' "$r"
}
