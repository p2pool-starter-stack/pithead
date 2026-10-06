# The rig-role manual battery (M11–M13)

This file lists the [rig](../README.md#glossary) checks that still need hands on real rig hardware: install and mine, setup from the [coordinator](../README.md#glossary)'s dashboard, and power loss and update.

## Before you start

- **When.** Required for any release that touches the rig role.
- **Machines.** A rig-class loaner (never a production-only rig), the image stick, and a real coordinator: the Pithead machine the rig mines to. See [What you need](../what-you-need.md).
- **Where the rows run.** The walkthrough carries them in [section 14](14-rigforge-rig.md): M11 in 14.1, M12 in 14.2 and M13 in 14.4.
- **Have ready.** The release bundle for M13, and the release issue for the results.
- **Time.** About 2 hours, the Rigs session of the [Run sheet](../README.md#run-sheet).

The battery is defined in [appliance-release.md](../../appliance-release.md). The `rig` KVM phase
only proves the [wizard](../README.md#glossary)'s rig card, role select, a submit toward a faked pool listener, volatile
journald, a plain reboot, a power cut, and the A/B update leg — so these three stay hands-on
until #1886's first gap converts what it can and names a bench e2e for the rest. Each row below names the
check that replaces it once that lands. M14 (run-from-USB) no longer needs a hand-run: the
`rigmedia` KVM phase (`tests/os/phases/rigmedia.sh`, #2069) covers it — see its row below for what
it proves and what it still leaves out.

## Steps

### M11 — rig install and mine

**What you do:**

1. Flash the same stick.
2. Boot a rig-class loaner from it (never a production-only rig).
3. Choose RigForge.
4. Point it at a real coordinator.

**What you should see:**

- The rig card shows worker + pool with no login.
- The coordinator's dashboard shows the worker with accepted shares within minutes.
- `doctor` on the rig reports MSR applied and hugepages reserved.
- Hashrate sits within the box's recorded baseline band.

*Replaced by: the accepted-share and `doctor` MSR/hugepages checks #1886's gap 1 still has to add
— the KVM phase fakes the pool listener and never accepts a share, and asserts nothing about MSR or
hugepages.*

**Record:** PASS, FAIL or N/A in the results sheet.

### M12 — rig from the coordinator's dashboard

**What you do:**

1. From the coordinator's Worker Inspect, adopt the rig.
2. Apply one writable change (for example the donation level).
3. Watch the change.

**What you should see:**

- The change reaches `applied`.
- No pool credential was touched.

*Replaced by: a dashboard-driven adopt/config push check, not yet written — a rig serves no
dashboard of its own, so nothing in the KVM `rig` phase exercises this today.*

**Record:** PASS, FAIL or N/A in the results sheet.

### M13 — rig power loss and rig update

**What you do:**

1. With the rig mining, cut power at the wall.
2. Leave the rig alone.
3. Install the release bundle on the rig.

**What you should see:**

- After the power cut, the rig returns to mining unaided (Restore on AC power loss).
- After the update, the rig comes back mining on the new [slot](../README.md#glossary) and self-commits.

*Covered by: the `rig` phase's power-cut leg (#2067, `tests/os/phases/rig.sh`) proves the
return-mining-unaided fact off a real `virsh destroy`, and the phase's existing update leg proves
the install/self-commit half. What stays manual is Restore on AC Power Loss itself — a firmware
setting a virtual disk cannot show.*

**Record:** PASS, FAIL or N/A in the results sheet.

### M14 — run-from-USB rig. AUTOMATED (#2069)

**What you do:** nothing by hand for this row. For reference, the check it automates:

1. Boot the stick.
2. Choose RigForge.
3. Do **not** install to disk.

**What you should see:**

- It mines from the stick.
- A reboot returns it to mining.
- Reaching the wizard again needs the bootloader path (#1318).

*Replaced by: the `rigmedia` KVM phase (`tests/os/phases/rigmedia.sh`), which boots the image as
removable media beside a blank internal disk, answers RigForge with no install offered, and
asserts the stick-run rig mines the baked binary with no containers, volatile journald, an unaided
reboot returns it mining, and the blank disk stays byte-for-byte untouched. Still manual: reaching
the wizard again via the bootloader path (#1318) on a stick-run rig, and stick wear / wall-clock
on real USB media.*

**Record:** N/A as a hand-run row: the `rigmedia` KVM phase covers it.
