# 14. RigForge rig

This file tests a RigForge [rig](../README.md#glossary): installing one, adopting it from the appliance's dashboard, running one from the USB stick, and a rig's power loss and update.

## Before you start

- **Machines.** The two loaner rigs from [What you need](../what-you-need.md): rig-class loaner machines with Secure Boot off, never a production rig and never someone's own PC. The appliance from section 13 is the [coordinator](../README.md#glossary): the Pithead machine the rigs mine to.
- **Warning.** 14.1 erases the first rig's internal disk. 14.3 runs the second rig from the stick.
- **Earlier steps.** Section 13 on the appliance, so the coordinator is installed and mining. If the coordinator has a [stratum](../README.md#glossary) password, you found it in [13.8](13a-install-and-first-boot.md#138-the-same-checks-as-diy).
- **Have ready.** The RC image on a USB stick, the RC update bundle and the two loaner rigs (session 12 of the [Run sheet](../README.md#run-sheet)).
- **During a soak.** Only 14.1, 14.3 and 14.4 may run while the soak appliance's 7-day window is open, and only on the rig side. Adopting a rig (14.2) is forbidden in the window: run it before `--start`, or on the second appliance as the coordinator. See [Testing a debug RC on the soak box](README.md#testing-a-debug-rc-on-the-soak-box).
- **Battery rows.** These are the hands-on rows M11–M13 in [the rig battery](rig-battery.md).
- **Time.** About 2 hours.

## Steps

### 14.1 Install a rig (M11)

**What you do:**

1. Boot the stick on the first rig.
2. Choose **RigForge**.
3. Accept the pool address it fills in (`pithead.local:3333`). It fills one in only when a coordinator named `pithead` answers there. Otherwise the field opens empty: type `<name>.local:3333`, where `<name>` is the coordinator's machine name.
4. Enter the stratum password from 13.8. Leave the field empty if the coordinator has none.
5. Name the worker.
6. Choose the internal disk. This erases it.
7. Copy the control token. You need it in 14.2.

**What you should see:**

- The rig mines.
- The coordinator lists the worker badged `not adopted`.
- `doctor` on the rig reports [MSR](../README.md#glossary) applied and HugePages reserved.
- The coordinator's Worker Inspect shows RigForge 1.18.0 for it (#3116).

**Record:** PASS, FAIL or N/A in the results sheet.

### 14.2 Adopt (M12)

**What you do:**

1. On the coordinator's dashboard, click the worker.
2. Fill the adopt form with the rig's address, port `8082` and the control token from 14.1.
3. Change the donation level.
4. Click **Apply to rig**.

**What you should see:**

- The change reaches `applied`.
- The pool settings are untouched.

**Record:** PASS, FAIL or N/A in the results sheet.

### 14.3 Run from the stick

**What you do:**

1. On the second rig, boot the stick.
2. Choose **RigForge**.
3. Choose **run from this USB stick**.
4. Once it mines, reboot the rig.

**What you should see:**

- It mines without installing anything.
- After the reboot, it returns to mining.

**Record:** PASS, FAIL or N/A in the results sheet.

### 14.4 Rig power loss and update (M13)

**What you do:** as [M13](rig-battery.md#m13--rig-power-loss-and-rig-update) in the rig battery describes. In short:

1. With the rig mining, cut its power at the wall, then leave it alone.
2. Install the release bundle on the rig (on a release candidate, the RC update bundle).

**What you should see:**

- The rig returns to mining by itself.
- After the update, it mines on the new version.

**Record:** PASS, FAIL or N/A in the results sheet.
