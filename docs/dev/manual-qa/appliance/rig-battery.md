# The rig-role manual battery (M11–M13)

This file lists the [rig](../README.md#glossary) checks that still need hands on real rig hardware: install and mine, setup from the [coordinator](../README.md#glossary)'s dashboard, and power loss and update.

## Before you start

- **When.** Required for any release that touches the rig role.
- **Machines.** A rig-class loaner (never a production-only rig), the image stick, and a real coordinator: the Pithead machine the rig mines to. See [What you need](../what-you-need.md).
- **Where the rows run.** The walkthrough carries them in [section 14](14-rigforge-rig.md): M11 in 14.1, M12 in 14.2 and M13 in 14.4.
- **Have ready.** The release bundle for M13, and the release issue for the results.
- **Time.** About 2 hours, the Rigs session of the [Run sheet](../README.md#run-sheet).

The battery is defined in [appliance-release.md](../../appliance-release.md). The `rig` KVM phase
proves the [wizard](../README.md#glossary)'s rig card, role select, a submit toward a faked pool listener, volatile
journald, a plain reboot, a power cut, and the A/B update leg; its share leg (#2063,
`tests/os/rig-share-leg.sh`) boots a second guest as a remote-node coordinator and proves an
accepted share on the appliance channel both ways, and since #3996 asserts a nonzero hashrate floor
on the rig's own feed and fails a release job whose promised input went missing
(`--require-complete`), while #3994 added the dashboard adoption and config push. Each row below
says what is automated and what a hand must still do. M14 (run-from-USB) no longer needs a hand-run: the
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

*Automated (partially, #2063 + #3996): the `rig` phase's share leg (`tests/os/rig-share-leg.sh`)
re-points the already-proven rig guest at a coordinator guest the battery itself boots, asserts a
nonzero hashrate on the rig's own RigForge feed (the M11 floor), and fails unless the rig's worker
AND the coordinator's built-in miner both show an accepted share — the release rig/rigmedia/media
split is submitted with `--require-complete` (`docs/dev/releasing.md`), so that leg can no longer
pass as a skip there. Stays manual: the physical half (flash the
stick, firmware-boot the loaner and read its rig card, real `pithead.local` discovery), the
`doctor` MSR check — a KVM guest's `/dev/cpu/*/msr` is the guest's virtual MSRs, so a write there
proves the path works but moves nothing a virtual CPU can measure, and the RandomX MSR hashrate
effect is a physical-CPU fact — and the baseline-band reading itself. Hugepages: the boot sizer
(`os/overlay/pithead-hugepages`) sizes the reservation off the guest's RAM (full 3072 pages on the
16 GiB guest) and the xmrig unit is fenced from re-growing it
(`os/overlay/pithead-xmrig-hugepages.conf`), but a guest-side reservation cannot show the pool is
physically backed, so the `doctor` line here stays hardware-only too.*

**Record:** PASS, FAIL or N/A in the results sheet.

### M12 — rig from the coordinator's dashboard

**What you do:**

1. From the coordinator's Worker Inspect, adopt the rig.
2. Apply one writable change (for example the donation level).
3. Watch the change.

**What you should see:**

- The change reaches `applied`.
- No pool credential was touched.

*Automated by `rig_adopt_leg` in `tests/os/rig-adopt-leg.sh` — #3717's leg, merged only to
`develop-v2.1.0` and backported to this branch by #3994 — called at the end of `rig_share_leg`
after the accepted-share rows. It uses the existing two guests, enables the coordinator control
channel, previews and commits an adoption with typed `APPLY`, and polls for an adopted worker with
a reachable API. Worker descriptors reload on each poll; adoption does not require a separate
dashboard restart. The leg changes `DONATION`, waits for the matching `change_id` in worker history
to reach `applied`, checks the rig's own config and unchanged pools, restores the original effective
value (read from the rig's reported config when the raw key is absent), and checks that the unpinned
bench host still cannot reach the control port. It prints elapsed seconds without the card token.
The form and inspector clicks remain manual.*

**Record:** PASS, FAIL or N/A in the results sheet.

### M13 — rig power loss and rig update

**What you do:**

1. With the rig mining, cut power at the wall.
2. Leave the rig alone.
3. Install the release bundle on the rig.
4. Update the rig the way its owner does: boot it from a newer USB stick and choose
   **Keep everything**.

**What you should see:**

- After the power cut, the rig returns to mining unaided (Restore on AC power loss).
- After the update, the rig comes back mining on the new [slot](../README.md#glossary) and self-commits.
- The Keep-everything reinstall keeps the rig's data: same `machine-role`, same `rig.json`,
  same access token. The rig mines on the new image, and a coordinator that had adopted the
  rig reads it again with no adopting to redo.

*Covered by: the `rig` phase's power-cut leg (#2067, `tests/os/phases/rig.sh`) proves the
return-mining-unaided fact off a real `virsh destroy`, and the phase's existing update leg proves
the install/self-commit half. What stays manual is Restore on AC Power Loss itself — a firmware
setting a virtual disk cannot show — and the Keep-everything pass itself: no automated leg
reinstalls a rig over its own `/data` yet (#3995).*

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
