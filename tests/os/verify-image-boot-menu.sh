# shellcheck shell=bash
#
# The boot menu's rows for tests/os/verify-image.sh (#1838 the titles, #1318 the way back to setup).
# Sourced after the ESP and slot A are mounted, with chk/ok/bad, $ESP and $ROOT in scope. A sibling
# rather than more rows in verify-image.sh, which sits at the 400-line target: one subject, one file.
echo "==> boot menu (titles for a person, #1838; the way back to setup, #1318)"
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
GRUBCFG="$ESP/grub/grub.cfg"
chk "the menu waits 5 s — long enough to choose an entry" 'grep -q "^timeout=5$" "$GRUBCFG"'
chk "entries name their version, slot and current/previous state" 'grep -q "^menuentry \"\$CURRENT_NAME (slot \$CURRENT_SLOT, current)\"" "$GRUBCFG" && grep -q "^menuentry \"\$A_TITLE\"" "$GRUBCFG" && grep -q "^menuentry \"\$B_TITLE\"" "$GRUBCFG"'
chk "legacy-unknown and verified-empty slots stay distinct" 'grep -q "Pithead version unknown" "$GRUBCFG" && grep -q "empty (slot B)" "$GRUBCFG"'
chk "no bootloader counters in any title" '! grep "^menuentry" "$GRUBCFG" | grep -qE "OK=|TRY="'
chk "the menu is visible on the serial console" 'grep -q "^terminal_output console serial$" "$GRUBCFG"'
chk "the slot-version metadata writer ships executable" '[ -x "$ROOT/usr/local/sbin/pithead-boot-version" ]'
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
BVU="$ROOT/etc/systemd/system/pithead-boot-version.service"
# Every boot repairs its own slot's label, including a machine that has never been provisioned —
# the one most likely to have a person at its console. Riding pithead-boot.service put the repair
# behind that unit's provisioned-only conditions, and a slot filled by `rauc install` was offered
# as "empty (slot B, current)" on the real bench (#1956).
chk "the slot-version repair unit ships and is enabled" '[ -s "$BVU" ] && [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-boot-version.service" ]'
chk "it runs on every boot, not only a provisioned one" '! grep -q "^ConditionPathExists=" "$BVU" && grep -q "^ConditionPathIsMountPoint=/boot/efi$" "$BVU" && grep -q "^ExecStart=/usr/local/sbin/pithead-boot-version record-booted$" "$BVU"'
chk "pithead-boot no longer carries the repair (one writer per boot)" '! grep -q "pithead-boot-version" "$ROOT/usr/local/sbin/pithead-boot"'
chk "a Set up again entry, carrying the flag on its kernel line" 'grep -q "^menuentry \"Set up again (opens the setup wizard; keeps the saved settings)\"" "$GRUBCFG" && [ "$(grep -c "^ *linux .*pithead.setup=1" "$GRUBCFG")" -eq 1 ]'
# The entry is the default boot plus one flag: it must follow the slot counting, never pin a slot.
chk "the setup entry boots the slot the counting chose" 'grep -q "rauc.slot=\$SETUP_SLOT pithead.setup=1" "$GRUBCFG" && grep -q "^set SETUP_SLOT=A$" "$GRUBCFG" && grep -q "SETUP_SLOT=B" "$GRUBCFG"'
# grub-reboot's mechanism: the running system names an entry for ONE boot, and grub.cfg consumes it.
chk "next_entry is honoured for one boot and consumed" 'grep -q "set default=\"\$next_entry\"" "$GRUBCFG" && grep -q "^    save_env next_entry$" "$GRUBCFG"'
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
SAU="$ROOT/etc/systemd/system/pithead-setup-again.service"
chk "the setup-again unit ships and is enabled" '[ -s "$SAU" ] && [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-setup-again.service" ]'
chk "it runs only on a boot carrying the flag" 'grep -q "^ConditionKernelCommandLine=pithead.setup=1$" "$SAU"'
chk "…and only on a provisioned machine, either shape" 'grep -q "^ConditionPathExists=|/data/pithead/config.json$" "$SAU" && grep -q "^ConditionPathExists=|/data/pithead/machine-role$" "$SAU"'
chk "it holds the normal boot behind the page" 'grep -q "^Before=pithead-boot.service$" "$SAU"'
chk "it runs the wizard in set-up-again mode, on the console" 'grep -q "^Environment=PITHEAD_SETUP_AGAIN=1$" "$SAU" && grep -q "^ExecStart=/data/pithead/pithead firstboot-wizard$" "$SAU" && grep -q "^StandardOutput=journal+console$" "$SAU"'
# The switch's three readers in the baked CLI: the mode test, the page's signal, the page's keep.
chk "the baked pithead honours the switch (mode, saved-role.json, keep-role)" 'grep -q "setup_again_mode" "$ROOT/opt/pithead/pithead" && grep -q "saved-role.json" "$ROOT/opt/pithead/pithead" && grep -q "keep-role" "$ROOT/opt/pithead/pithead"'
chk "pithead-boot does not read the flag (the unit is its only reader)" '! grep -q "pithead.setup" "$ROOT/usr/local/sbin/pithead-boot"'
