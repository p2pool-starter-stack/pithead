# Before the cut

This file covers what to settle before a release is cut: the checks a virtual machine cannot show, reserving the shared hardware, and knowing which image you hold.

## Before you start

- **Who.** Whoever runs the hardware checks or cuts the release.
- **When.** Read it before you touch any shared hardware. Reserving the hardware is part of session 1 (Prepare) of the [Run sheet](../README.md#run-sheet), with filling in the sample configs and checking the LAN test registry.
- **Have ready.** The reservation protocol in [release-server.md](../../release-server.md), and your handoff notes.
- **Time.** About 1 hour for session 1.

## Confirm what the harness cannot see

The KVM battery boots a VM on a virtual NIC, one virtual disk, and no firmware. It can stage an
unrouted documentation-range global IPv6 address, but it is structurally blind to the rows below,
all of which have produced real defects. A green KVM battery says nothing about them: they need a
person and real hardware.

| Check | Why a VM cannot show it |
|---|---|
| Secure Boot, firmware power-on behaviour, real disk topology | No firmware, one virtual disk. |
| Thermals, CPU governor, the hardware watchdog actually resetting a wedged board | A VM has no watchdog device and no heat. |
| First-boot on real media — wall-clock, and what a power cut leaves behind | Writing container storage to a USB stick is nothing like a virtual disk, and the operator experience lives in that gap. An interrupted write to a stick left a store that was present, digest-matched and unrunnable, and it bricked install-from-stick on every later boot (#1029). Fault D covers the interrupted first-boot image-load path on a virtual disk: it must repair and serve the [wizard](../README.md#glossary), or refuse with a legible console message; real-media wear and firmware behaviour remain hardware-only. |

## Reserve the hardware

Bench resources are shared with other sessions and with RigForge's own gates.

**What you do:**

1. Reserve before touching anything, following the reservation protocol in [release-server.md](../../release-server.md).
2. On each loaner [rig](../README.md#glossary), follow the contract at `~/README.md` on that box: back up the config, repoint, and **restore + restart when the job frees it**.
3. For the appliance under test, say in your handoff that you are holding it.
4. Free everything when done, and say in your handoff when you let go of the appliance.

That protocol covers the **rigs**. It does not cover the appliance under test.
[#1022](https://github.com/p2pool-starter-stack/pithead/issues/1022) was closed by
[#1759](https://github.com/p2pool-starter-stack/pithead/pull/1759), which wrote this gap down here
and the rigs' CHECK and FREE rules into [release-server.md](../../release-server.md), and added no
mechanism for the appliance: it has no lock, no holder marker and no contract file of its own, so
nothing stops two sessions working on it at once, and
[the hardware battery](../appliance/hardware-battery.md) reflashes and factory-resets the box. A collision costs whoever else is holding it both their run and the chain on that disk.
Reserving the appliance is an agreement between sessions, and nothing enforces it: say in your
handoff that you are holding it, and say when you let go.

The appliance cannot copy the rig protocol, and #1022 names the reason: a lock stored *on* the
appliance is destroyed by the very tests that take it. Its reservation has to live on a
[coordinator](../README.md#glossary) that the reflash does not touch.

## Know which image you are holding

A **debug** image (sshd on, keys baked) is bench equipment. A **release** image is shell-less
with no keys. `verify-image.sh` without `--test` refuses a debug build, and that refusal is the
last thing standing between a development convenience and a published one.

**What you do:**

1. Before any appliance step, check whether the image you hold is a debug image or a release image.
2. Never publish a debug image.
3. Never hand a debug image to a user.
