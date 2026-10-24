wizard_consume_rig_preseed() {
    if [ -f "$PRESEED_DIR/pithead-rig.json" ] && ! installer_mode_available && [ ! -f "$PWD/rig.json" ]; then
        if jq -e 'type == "object" and ((.pool // "") | length > 0) and ((.access_token // "") | test("^[0-9a-f]{32}$"))' "$PRESEED_DIR/pithead-rig.json" >/dev/null 2>&1 &&
            install -m 600 "$PRESEED_DIR/pithead-rig.json" "$PWD/rig.json" 2>/dev/null; then
            record_machine_role rig
            scrub_staged_rig consumed
            _console "This machine is now a RigForge rig ($(jq -r '.worker // "unnamed"' "$PWD/rig.json" 2>/dev/null))."
        else
            warn "The staged rig settings at $PRESEED_DIR/pithead-rig.json are unusable — opening the setup page."
            scrub_staged_rig unusable
        fi
    fi
}
