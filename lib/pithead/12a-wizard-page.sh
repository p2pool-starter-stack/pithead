wizard_start_page() {
    local engine="$1" image="$2" spool="$3" restore_spool="$4" card_mount="$5" installer="$6" token="$7" cert_fp="$8"
    local host_addresses
    "$engine" rm -f pithead-wizard >/dev/null 2>&1 || true
    host_addresses=$(wizard_host_addresses) || host_addresses=""
    "$engine" run -d --name pithead-wizard --entrypoint python3 \
        -p 80:8000 -p 443:8443 -e WIZARD_TOKEN="$token" \
        -e WIZARD_TLS_CERT="${cert_fp:+/wizard-spool/wizard.crt}" \
        -e WIZARD_TLS_KEY="${cert_fp:+/wizard-spool/wizard.key}" \
        -e WIZARD_HOST_ADDRESSES="$host_addresses" \
        -e WIZARD_RESTORE=/wizard-restore \
        -e TMPDIR=/wizard-restore \
        -e WIZARD_HANDOFF="$card_mount" \
        -v "$spool":/wizard-spool -v "$restore_spool":/wizard-restore \
        "$image" -m mining_dashboard.wizard >/dev/null || {
        # `error` writes to stderr = /dev/console, ONE device (whichever the cmdline named
        # LAST); on a box whose monitor is the other one the failure is invisible and a STOPPED
        # box reads as a slow one — a three-minute failure was once taken for an hour of
        # progress. _console reaches every physical console, which is the whole point here.
        _console "" "Setup has STOPPED — this box is no longer preparing a page." \
            "The container engine could not start the setup page." \
            "Diagnose with: journalctl -u pithead-firstboot -b"
        error "Could not start the wizard container ($engine, $image). Pre-seed config.json or run '$0 firstboot-wizard --cli'."
    }
    [ "$installer" -eq 1 ] || reset_slot_restore_good "$engine" || warn "Could not restore the reset slot's good state; reboot may fall back."
    wizard_announce_setup "$host_addresses" "$token" "$cert_fp"
}
