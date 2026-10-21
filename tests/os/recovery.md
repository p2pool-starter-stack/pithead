# Destructive recovery matrix

The `recovery` phase exercises recovery after destructive operations on a real two-slot appliance.

Run it as a separate `tier4-kvm` job with `phases: ["recovery"]` and
`old_image_commit` set to the full source SHA of the previous release. The runner must supply
an attested image for that exact source; the phase fails if it is missing. It boots and provisions
that image, waits for its health commit, installs the candidate with `pithead os-update`, and
waits for the candidate to commit without marking either slot good itself. The previous image
may lack a test marker; its exact source SHA remains mandatory. Fixture preparation reports the
failed boot, SSH, provisioning, health or identity stage without printing wizard credentials.

## Applicable cells

| Platform and operation | Recovery routes |
|---|---|
| Appliance `config-reset` | Wizard setup; wizard backup upload; CLI `down`, encrypted `restore`, then `up` |
| Appliance `factory-reset` | Wizard setup; wizard backup upload; CLI `down`, encrypted `restore`, then `up` |
| Appliance **Set up again**, starting with saved settings | **Keep it**; submit the setup form; wizard backup upload |
| DIY `config-reset` | CLI encrypted restore and `up`, in the lifecycle reset-restore leg |
| DIY `uninstall` | Setup from kept configuration, in the existing uninstall round trip; encrypted CLI restore and `up` |

**Set up again** is a separate operation, following
[the saved-settings flow](../../docs/appliance.md#set-up-again).
The reset cells do not use it: resets erase the saved settings that distinguish that operation
from fresh wizard setup. Each reset records that combination as a `by-design` skip.
DIY has no appliance setup page or boot-menu operation, and the appliance uses its two resets
instead of DIY uninstall. Those combinations are also recorded `by-design`, with pointers to
[the two resets](../../docs/appliance.md#starting-over-the-two-resets) and
[DIY uninstall](../../docs/operations.md#what-uninstall-removes).

## Assertions

Before each destructive cell, take an encrypted backup off the guest, capture every project
container ID, and plant sentinels in both configured Monero and Tari chain directories.
After reset, require the actual setup page and a readable all-state container census containing
none of the old IDs. Config reset preserves the sentinels; factory reset erases both before any
recovery route runs. Factory reset cannot erase the external backup used by the restore cells.

After recovery, require settled successful provisioning, a rendered environment, passing status
and doctor, no wizard container, healthy Caddy, and a dashboard HTTP response rather than the
setup page. Require the old container IDs to remain absent. Reboot through the provisioned health
gate, wait for its current-boot commit message, then reboot once more. Both observations must
retain the candidate's exact source and marker, good primary slot B, both good slots with zero
TRY counters, and `ORDER=B A`. Mount the inactive slot read-only to verify that its exact previous
release source still exists. A failed cell remains red and stops the matrix rather than repairing
bootloader state to continue.

The saved-settings cells require a saved coordinator role. **Keep it** must preserve the exact
configuration hash. All three cells run the same commit and extra-reboot checks.
The DIY lifecycle cells require healthy web ownership, original configuration and secret
fingerprints after restore, and no surviving pre-operation project containers.

`selftest-recovery.sh` checks slot/source/TRY/fallback parsing, census rejection and both reboot
boundaries. The integration selftests drive restore failures and census failures without Docker.
They are tier-1 helper checks, not appliance or DIY runtime proof. The RC gate runs this phase
separately from the reset/stack group; the full matrix must not share that group's timeout.
