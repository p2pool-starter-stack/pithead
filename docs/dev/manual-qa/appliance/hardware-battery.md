# The manual hardware battery (M1–M10)

This file lists the appliance checks that still need hands on a physical box, the record of earlier hardware runs, and the install-path cases worth walking on purpose.

## Before you start

- **Machine.** A physical appliance box (see [What you need](../what-you-need.md)), never a virtual machine.
- **Where the rows run.** The battery is defined in [appliance-release.md](../../appliance-release.md). The walkthrough steps in section 13 carry its rows: M1 in 13.1 and 13.3, M2 in 13.4, M3 in 13.5 and 13.7, M4 in 13.5, M6 in 13.6, M5 in 13.18, M7 in 13.10, M8 in 13.11, M9 in 13.12, and M10 in 13.19. See [Install and first boot](13a-install-and-first-boot.md) and [Updates, restore and media](13b-updates-restore-and-media.md).
- **Have ready.** The release issue, where you record the results.
- **Time.** The hands-on time is in sessions 7, 8 and 10 of the [Run sheet](../README.md#run-sheet).

Run the battery's remaining hardware-only checks on a physical box and record the results in the
release issue. The KVM battery covers the scriptable parts noted below; the physical checks remain
hands-on, and #1022 closed without a way to collect the scripted and attested results together.

## Needs hands, every time

### M1 — flash and boot

**What you do:**

1. Disable Secure Boot in the box's firmware.
2. Verify the published `.img.xz` checksum.
3. Flash its decompressed bytes to a real stick, using the appliance guide's command (the [13.1](13a-install-and-first-boot.md#131-verify-and-flash-m1) commands).
4. Boot the box from the stick.

**What you should see:**

- As [13.1](13a-install-and-first-boot.md#131-verify-and-flash-m1) and [13.3](13a-install-and-first-boot.md#133-first-boot-m1) describe.

**Record:** PASS, FAIL or N/A in the results sheet, and the compressed image's byte size and checksum.

### M4 — wrong-disk guard

M4's mechanics (the wrong-disk guard) now have a KVM analog — see
[appliance-release.md](../../appliance-release.md) — so only the real-hardware disk-controller
cases still need a physical second disk.

**What you do:**

1. With a physical second disk in the box, walk [13.5](13a-install-and-first-boot.md#135-role-and-disk-m3-m4) and [13.7](13a-install-and-first-boot.md#137-install-m3).

**What you should see:**

- As 13.5 and 13.7 describe for the second disk.

**Record:** PASS, FAIL or N/A in the results sheet.

## The power-cut items

The power-cut items are the ones that justify the whole appliance design (A/B
[slots](../README.md#glossary), the health-gated commit, the migration hold). Two are now in the
KVM battery. A virtual disk cannot show USB-stick media damage or the firmware's
Restore-on-AC-Power-Loss setting, so the box coming back **by itself** after the plug is pulled
still needs hands on real hardware.

### M8 — power cut during the update's write phase

*Covered by: `fault` phase Fault A (destroy mid-write, `tests/os/phases/fault.sh`) — pull the
plug at the wall on real hardware to confirm Restore on AC Power Loss, not the write itself.*

**What you do:**

1. On real hardware, during the update's write phase, pull the plug at the wall. [13.11](13b-updates-restore-and-media.md#1311-pull-the-plug-during-an-update-m8) has the steps.
2. Do not touch the box.

**What you should see:**

- The box comes back by itself (Restore on AC Power Loss).

**Record:** PASS, FAIL or N/A in the results sheet.

### M10 — power cut during normal mining

*Covered by: `provision` phase's power-cut leg (M10, #2067, `tests/os/phases/provision-power-cut.sh`),
which checks the complete recovery after every one of its three cuts — same caveat.*

**What you do:**

1. On real hardware, while the box is mining, pull the plug at the wall. [13.19](13b-updates-restore-and-media.md#1319-power-loss-while-mining-m10) has the steps.
2. Do not touch the box.

**What you should see:**

- The box comes back by itself (Restore on AC Power Loss).

**Record:** PASS, FAIL or N/A in the results sheet.

## Recorded runs

For reference only: you do not run anything in this section.

The operator's own record is the evidence; each run is reported in full on
[#2044](https://github.com/p2pool-starter-stack/pithead/issues/2044). The runs below are a dev
image, not a shipping image: they do not prove the final release SHA, and the final shipping
image's evidence stays with the GA gates (the soak,
[#1652](https://github.com/p2pool-starter-stack/pithead/issues/1652), and pre-publication
verification, [#1653](https://github.com/p2pool-starter-stack/pithead/issues/1653)).

**2026-09-18 and 2026-09-19, one physical x86-64 UEFI laptop with an NVMe and no second disk.**
Source: `develop` at `1b0da07016`, the debug variant (SSH, dev certificate, LAN registry) built by
bench job 482, flashed to a USB stick. Image checksum: UNKNOWN, not recorded at the run. The M7,
M8 and M9 bundles were dev bundles built on the bench from that head with a raised VERSION
(2.0.1, and the deliberately broken 2.0.2 and 2.0.3).

| Step | Result | Observed |
|---|---|---|
| M1 flash and boot | PASS | Booted from the stick with Secure Boot off and reached the [wizard](../README.md#glossary). |
| M2 discovery | PASS, partial | `http://pithead.local` reached from another machine: token gate, the expected certificate warning. Not run: the monitor-unplug half (the target is a laptop). |
| M3 install to disk | PASS | Pithead and RigForge installed with "Keep everything" on the NVMe; stick pulled; the box booted from the internal disk and served the setup page. |
| M4 wrong-disk guard | NOT RUN | No second disk in the machine. |
| M5 reinstall keeps the chain | PASS | After the M6 reinstall, monerod kept its chain and caught up only the blocks missed during the test. |
| M6 configure by paste | PASS, with findings | A pasted subaddress was refused with an explanation; a node name that does not resolve was refused; the stack provisioned and the dashboard came up. Findings: #2350, #2351, #2352. |
| M7 real update | PASS | 2.0.1 installed with `pithead os-update`; after a manual reboot the box came up on slot B and `pithead-boot` committed it. Finding: #2382 (no "reboot next" message). |
| M8 pull the plug, three times | PASS | Forced power-off at 61%, 87% and 99% of the slot copy; each time the box booted slot A with the dashboard serving. RAUC marked the target slot bad before each write and active only after a complete copy. |
| M9 bad release rollback | PASS, with finding | 2.0.3 (Caddy started against a missing config): the gate waited, left the slot uncommitted and rebooted; the box fell back to slot A and committed it with nobody present. The operator rollback from a committed 2.0.1 with `rauc status mark-bad booted && reboot` returned to A. Findings: 2.0.2 (dashboard healthcheck always failing) was committed because the gate did not read container health, #2383; the console is silent for the whole gate wait, #2436. |
| M10 power loss while mining | PASS | Forced off by holding the power button and powered on again: stack healthy, RigForge mining, dashboard reachable. Not shown: the box powering on by itself after a cut at the wall (Restore on AC Power Loss). |
| M15 backup and restore | FAIL | "Backup did not complete", no archive: `compose down` failed on a podman overlay unmount of the Caddy container (#2364). Not run: the restore half. |
| M16 settings after provisioning | PARTIAL | The energy value [previewed](../README.md#glossary), [applied](../README.md#glossary) and persisted, and the change history was accurate. Findings: #2365, #2366, #2367. Not run: the node-endpoint `APPLY` step. |
| RC1 addendum | NOT RUN | |

Hardware-only observation: a freshly booted slot reads `bad` in `rauc status` until its gate
commits it, about two and a half minutes into the boot; rebooting inside that window leaves both
slots reading `bad` until the gate runs again. The KVM install phase checks the Fresh Start
reinstall sequence behind #2352; the physical result above remains the September 2026 observation.

Still open from these runs, as of 2026-10-03: #2351 and #2436. Closed since, and not re-run on
hardware: #2367 and the Fresh Start KVM gap, #2447. Fixed on `develop` since, and not re-run on
hardware: #2350, #2352, #2364, #2365, #2366, #2382 and #2383.

## Install-path cases worth walking deliberately

Walk each of these on purpose at least once:

- A **fresh** disk.
- A disk that **already holds an installation**: choose *keep* and confirm the chain survives.
  This is M5, and it is where the corrupt-container-store blocker was found: a partially written
  image store left every `podman run` failing, so the wizard never served.
- Reaching the wizard **by mDNS name** and **by IP**, since the appliance serves both.
- Confirming once that the dashboard refuses the real box's ISP-assigned IPv6 address. The
  provision battery proves the listener boundary with an unrouted RFC 3849 address; this check
  confirms that the physical network presents the same address shape.
- Configuring **by paste** for both addresses (M6: a new machine on a disk that fits both chains
  is asked for both, and on a smaller disk for the Monero address only, #3099): a wallet address
  typed by hand is a support ticket waiting to happen.
