# The boot menu's "Set up again" entry (#1318). os/rauc/grub.cfg appends pithead.setup=1 to that
# one boot; pithead-setup-again.service runs `pithead firstboot-wizard` with PITHEAD_SETUP_AGAIN
# set, ahead of pithead-boot. What that switch changes is small, and all of it is here or one line
# each in firstboot_wizard: the "this machine already has a role" short-circuits are skipped, the
# page is told what the machine is, and "Keep it" ends the session with nothing on /data touched.
# The role marker, rig.json and config.json are replaced only where a NEW role is accepted — the
# same accept paths a first boot takes, unchanged.
setup_again_mode() { [ -n "${PITHEAD_SETUP_AGAIN:-}" ]; }

# What the page is told the machine already is, secrets left out: the role, and for a rig the pool
# and worker it mines as (no stratum password, no control token). The rig form's pre-fill is
# pointed at the SAME answers, so "Set up again" opens on them rather than on a fresh LAN probe; a
# coordinator's form pre-fills from config.json through the reinstall rule (strip_config_secrets),
# once per session so a failed re-provision's own retry context is never overwritten. Nothing is
# published outside a set-up-again boot: the file's presence IS the page's signal.
publish_saved_role() { # <spool-dir>
    setup_again_mode || return 0
    local spool="$1" role
    role=$(machine_role)
    if [ "$role" = rig ] && [ -f "$PWD/rig.json" ]; then
        wizard_spool_publish "$spool" saved-role.json jq \
            '{role: "rig", pool: (.pool // ""), worker: (.worker // "")}' "$PWD/rig.json" || return 1
        wizard_spool_publish "$spool" rig-defaults.json jq '{pool, worker}' "$PWD/rig.json"
    else
        wizard_spool_publish "$spool" saved-role.json jq -n --arg r "$role" '{role: $r}' || return 1
        if [ ! -e "$spool/last-attempt.json" ] && [ -f "$PWD/config.json" ]; then
            wizard_spool_publish "$spool" last-attempt.json strip_config_secrets "$PWD/config.json"
        fi
    fi
}

# The wizard's credentials card, both roles: the coordinator's login, or (since #1836) the rig's
# control token. The shared spool publisher creates it privately and replaces any stale card.
write_handoff_card() { # <spool-dir>; the card's JSON on stdin
    wizard_spool_publish "$1" handoff.json cat
}

# "Keep it": the page wrote keep-role. Nothing on /data was touched — the marker, rig.json and
# config.json are exactly as this boot found them — so firstboot_wizard returns, the unit ends,
# and pithead-boot runs the boot the machine would have taken from the default entry.
wizard_keep_requested() { # <spool-dir>
    setup_again_mode && wizard_spool_has "$1" keep-role || return 1
    rm -f "$1/keep-role"
    _console "Setup closed: the saved settings are kept. The machine is starting as it was."
}

setup_again_commit_slot() {
    setup_again_mode || return 0
    [ -e config.json ] || [ -e machine-role ] || return 0
    command -v rauc >/dev/null 2>&1 || return 0
    [ ! -e data/os-update/in-flight.json ] || return 0
    local slot state
    slot=$(os_booted_slot) || return 1
    case "$slot" in A | B) ;; *) return 1 ;; esac
    state=$(grub-editenv "${PITHEAD_GRUBENV:-/boot/efi/grub/grubenv}" list) || return 1
    printf '%s\n' "$state" | grep -qx "${slot}_OK=1" || return 1
    [ "$("$1" inspect --format '{{.State.Running}}' pithead-wizard)" = true ] || return 1
    rauc status mark-good
}
