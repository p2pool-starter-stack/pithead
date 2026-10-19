# 15. Appliance rename and resets

This file tests renaming the appliance and its two resets: the config reset and the factory reset.

## Before you start

- **Machine.** Run last, on the appliance box. These steps change the machine's identity or erase it.
- **Which appliance.** The [Run sheet](../README.md#run-sheet) runs 15.1 and 15.2 on the second appliance (session 10) and 15.3 on the restore PC (session 11, after 13.13 and 13.14). Where it differs from this page, the Run sheet wins. Renames and resets are forbidden on the soak appliance during its 7-day window; see [Testing a debug RC on the soak box](README.md#testing-a-debug-rc-on-the-soak-box).
- **Earlier steps.** The section 13 steps the Run sheet puts first on the same machine: 13.21–13.25 before 15.1 and 15.2, and 13.14 before 15.3. 15.2 needs the dashboard password you put back at the end of [13.24](13b-updates-restore-and-media.md#1324-change-and-recover-the-dashboard-password).
- **Have ready.** The laptop, the dashboard password, and a monitor and keyboard on the box for the console in 15.2 and 15.3. For 15.1, a note of which [rigs](../README.md#glossary), if any, use the old machine name and which use an IP address.
- **Time.** About 1 hour, plus the reboots.

## Steps

### 15.1 Rename

**What you do:**

1. In Configuration, set the machine name (`dashboard.host`) to `qa-box`.
2. Read the [preview](../README.md#glossary), then confirm.
3. Open `https://qa-box.local` in the browser and accept the new certificate warning.
4. Reboot the box, then open `https://qa-box.local` again.
5. Check each rig that used the old name, and each rig that used an IP address, if there are any.

**What you should see:**

- The preview warns that rigs using the old name stop mining.
- The preview says each such rig needs **Set up again** to point it at the new name (#3100).
- The dashboard answers at `https://qa-box.local` after one new certificate warning.
- The dashboard keeps that name after a reboot.
- A rig that used the old name stops mining until it is set up again.
- A rig that used an IP address keeps mining.

**Record:** PASS, FAIL or N/A in the results sheet.

### 15.2 Config reset

**What you do:**

1. At the console, log in as `root` with the dashboard password.
2. Run:

   ```bash
   cd /data/pithead && ./pithead config-reset
   ```

3. Type the confirmation it asks for.
4. When the machine has rebooted into the setup [wizard](../README.md#glossary), answer it again.

**What you should see:**

- You must type to confirm.
- The machine reboots into the setup wizard.
- After you answer again, the chains are still [synced](../README.md#glossary).

**Record:** PASS, FAIL or N/A in the results sheet.

### 15.3 Factory reset

**What you do:**

1. At the console, logged in as `root`, run:

   ```bash
   cd /data/pithead && ./pithead factory-reset
   ```

2. Type the confirmation it asks for.

**What you should see:**

- You must type to confirm.
- The machine reboots into a blank setup wizard with nothing kept, chains included.

**Record:** PASS, FAIL or N/A in the results sheet.
