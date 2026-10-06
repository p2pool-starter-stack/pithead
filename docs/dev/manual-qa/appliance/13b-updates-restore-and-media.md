# 13b. Appliance updates, restore and media

These steps test OS updates, power loss, rollback, backup and restore, settings after setup, the
boot menu's **Set up again**, setup and settings by USB stick, [Tor](../README.md#glossary), the
[onion](../README.md#glossary) dashboard, node modes, the dashboard password, and the appliance
guide itself (steps 13.10 to 13.25).

## Before you start

- **Machines.** The appliance box for 13.10–13.13, 13.19 and 13.20; the restore PC for 13.14 and
  13.14a; the upgrade box for 13.14a and 13.15. On a debug release candidate, 13.15–13.18 and
  13.21–13.25 run on the second appliance, and the soak-box rules in
  [the appliance README](README.md#testing-a-debug-rc-on-the-soak-box) decide what may touch the
  soak box.
- **Earlier steps.** 13.1–13.9 in [13a-install-and-first-boot.md](13a-install-and-first-boot.md).
  13.14a needs the plain 1.20 archive from 2.1b and your notes from 2.1
  ([02-upgrade.md](../diy/02-upgrade.md)). 13.21 uses 9.4 ([09-privacy-tor.md](../diy/09-privacy-tor.md)).
  13.24 uses the onion from 13.21 and the second stick from 13.23.
- **Have ready.** The good higher-version test bundle (the RC update bundle if you have none), the
  broken (health-gate fault) test bundle built from the candidate's own commit, the bench SSH key
  for debug images from the private handoff, a monitor, the second USB stick, the laptop with Tor
  Browser, and Config A from [Sample configs](../sample-configs.md) filled in with your QA values.
  See [What you need](../what-you-need.md).
- **Rough time.** From the [Run sheet](../README.md#run-sheet): about 4 hours for updates and power
  (session 8: 13.10–13.12 and 13.19), about 4 hours for backup and restore (session 11: 13.13,
  13.14, 15.3 on the restore PC, then 13.14a), and the second-appliance steps in session 10. Where
  the Run sheet orders these steps differently, the Run sheet wins.

### 13.10 Update (M7)

**What you do:**

1. As M7 describes (in [appliance-release.md](../../appliance-release.md#manual-battery--required-before-every-appliance-release)),
   copy the good higher-version test bundle (a debug-variant bundle with a higher version) to the
   box. If you have no higher-version bundle, follow "With no higher-version bundle" below
   instead.
2. Run the update. `<bundle>` is the path of the bundle file on the box. Never add `--yes` when
   the bundle's variant differs from the box's (see [Cutting](../release/cutting-and-after.md#cutting),
   item 3).

   ```bash
   cd /data/pithead && ./pithead os-update <bundle>
   ```

3. Run the reboot command it prints.

NOTE: After item 2 the spare [slot](../README.md#glossary) is armed: any reboot boots the update,
a power cut included (#3100).

With no higher-version bundle:

1. Before the update, note the booted slot letter in `rauc status` and the output of
   `cat /opt/pithead/BUILD_COMMIT`.
2. Install the RC update bundle (the RC's own `.raucb`) over the RC with the same `os-update`
   command. The same version is accepted, but if the bundle's version is not a plain `X.Y.Z`,
   os-update refuses with `Refusing a possible downgrade`: run it again with `--allow-downgrade`
   added, and record that.
3. Run the reboot command it prints.
4. After the reboot, note the booted slot letter in `rauc status` and the output of
   `cat /opt/pithead/BUILD_COMMIT` again.

**What you should see:**

- After item 2, it says the update is written to the spare slot, that the machine keeps running
  the current version until it reboots, and it prints the exact reboot command.
- After the reboot, the boot menu shows the new version as **current** and the old one as
  **previous**.
- With no higher-version bundle, score M7 by the booted slot letter in `rauc status` and by
  `cat /opt/pithead/BUILD_COMMIT`, before and after the reboot, not by the version label, since
  both menu entries read the same version.

Two things are expected, not defects:

- The bundle declares a data migration, so a Tari volume without room is refused with
  `Refusing: this update declares a chain data migration`. Free space and retry.
- After the reboot, the chain services wait until the new slot commits.

**Record:** PASS, FAIL or N/A in the results sheet, plus whether you used `--allow-downgrade`, and the slot
letters and `BUILD_COMMIT` before and after when you scored by them.

### 13.11 Pull the plug during an update (M8)

NOTE: On the soak box, wait until the dashboard's Tari card shows progress before each power cut,
and never cut power while Tari reads loading (see
[the soak-box rules](README.md#step-2-run-the-hardware-battery-before---start)).

**What you do:**

1. Start the update again with the same bundle:

   ```bash
   cd /data/pithead && ./pithead os-update <bundle>
   ```

2. Pull the plug while it writes. If the box is a laptop, hold the power button instead, at about
   30%, 60% and 90% of the write.
3. Repeat items 1 and 2 three times.

NOTE: Do not pick the other slot from the boot menu: it holds a half-written copy and may still
show its old label.

**What you should see:**

- Every time, the machine boots the 13.10 version on its slot, marked **current**.
- Every time, the dashboard serves.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.12 Bad release rolls back (M9)

**What you do:**

1. Build the broken (health-gate fault) test bundle M9 describes from the candidate's own commit.
   The rollback is decided by the gate inside the new slot, so never use an older broken bundle
   whose gate code predates #2383: it tests the old gate, not the candidate's.
2. Install it:

   ```bash
   cd /data/pithead && ./pithead os-update <bundle>
   ```

3. Reboot, and do not touch the machine.
4. The spare slot now holds the broken release, so do not mark anything bad yet. Install the good
   13.10 bundle again with the same command:

   ```bash
   cd /data/pithead && ./pithead os-update <bundle>
   ```

5. Reboot.
6. Wait until `rauc status` no longer reads the booted slot as `bad`. It commits after its health
   check, about 3 minutes into the boot.
7. Run:

   ```bash
   rauc status mark-bad booted && reboot
   ```

**What you should see:**

- After item 3, without anyone touching it, the machine falls back to the 13.10 version on the
  slot it ran before, and the dashboard serves.
- After item 7, the machine comes back on the other slot, on a good version, with the dashboard
  serving.

NOTE: The `/data` floor fallback after a migrating update fails its gate (#1393) is not hand-run:
the KVM battery's floor-fallback leg (`tests/os/data-floor-fallback-leg.sh`) proves it on the
candidate's commit at every gate.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.13 Backup (M15, first half)

NOTE: On the soak box, run M15 only before `--start` or after day 7 (see
[the soak-box rules](README.md#on-a-second-appliance)).

**What you do:**

1. Write down the payout address, the [onion](../README.md#glossary) address and the time.
2. In **Backup**, click **Back up now**.
3. Save both downloads: the archive and its emergency kit.

**What you should see:**

- The dashboard disconnects briefly and comes back.

**Record:** PASS, FAIL or N/A in the results sheet, plus the payout address, the onion address and the time
from item 1.

### 13.14 Restore (M15, second half)

**What you do:**

1. Power off the appliance box, so two machines never run the same identity at once.
2. Boot the stick on the restore PC, not on the appliance box: later steps need its chain.
3. On the setup page, choose **Restoring an existing Pithead? Upload its backup instead.** and
   upload the archive you saved in 13.13.
4. Choose the restore PC's disk (it is erased) and type its name as the page asks.
5. Enter a wrong passphrase first.
6. Then enter the right one, and follow the page to the end.
7. Power the restore PC off and the appliance box back on.

**What you should see:**

- The wrong passphrase is rejected with the reason, and the form stays open.
- With the right one, the machine provisions itself.
- Its payout address and onion address match your notes from 13.13.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.14a Restore a 1.20 DIY backup

**What you do:**

1. On the upgrade box, in its install directory, run the command below and leave the stack down
   for the whole step. This is the safe default, because the archive carries the upgrade box's
   node onion keys, which 9.5 does not replace.

   ```bash
   ./pithead down
   ```

2. Boot the stick on the restore PC.
3. Choose **Restoring an existing Pithead? Upload its backup instead.**
4. Upload the plain 1.20 archive you copied to the laptop in 2.1b.
5. Choose the restore PC's disk, enter the archive's passphrase, and follow the page to the end.
6. Open Configuration's Advanced pane.
7. Power the restore PC off.
8. On the upgrade box, run:

   ```bash
   ./pithead up
   ```

NOTE: Do not power the restore PC on next to the upgrade box again until it is reinstalled.

**What you should see:**

- The 1.20 archive is accepted, not refused for its layout.
- The machine provisions itself.
- Its payout address matches your 2.1 notes.
- The Advanced pane shows `xvb` and `workers.list`.
- The Advanced pane shows no `xmrig_proxy`, `dashboard.workers` or `telegram.control`.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.15 Settings after setup (M16)

**What you do:**

1. Follow M16 (in [appliance-release.md](../../appliance-release.md#manual-battery--required-before-every-appliance-release)):
   make a benign energy change.
2. Then make a node endpoint change that needs `APPLY`. For the test node, use the upgrade box's
   Monero node opened to the LAN as in Config D ([Sample configs](../sample-configs.md)), with the
   RPC login from that box's `config.json`.

**What you should see:**

- The results M16 describes.
- The page reconnects by itself after the containers restart.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.16 Set up again

**What you do:**

1. In the boot menu, choose **Set up again**.
2. Finish the setup page.

**What you should see:**

- The setup page opens with the saved answers filled in and the secrets left blank.
- Finishing it keeps the chains.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.17 Headless setup

**What you do:**

1. On the laptop, put `pithead-token.txt`, holding a token you choose, on the stick's `PITHEAD`
   volume.
2. Boot the stick without a monitor.
3. Open the setup page with your token.
4. On the laptop, add `pithead-config.json` holding Config A
   ([Sample configs](../sample-configs.md)) to the same volume, and boot the stick again without a
   monitor.

**What you should see:**

- After item 3, your token opens the setup page.
- After item 4, the setup page opens with every answer filled in, and only the disk choice is left
  to you.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.18 Reinstall keeps the chain (M5)

**What you do:**

1. Continue from 13.17: choose the same disk.
2. Pick **Keep everything** and install.
3. Afterwards, delete `pithead-config.json` and `pithead-token.txt` from the stick.
4. Take every stick out of the box. The appliance reads a settings file from any stick left in at
   its next boot.

**What you should see:**

- The disk is listed with `holds a previous install`.
- **Keep everything** is the default choice.
- After the install, the chain is intact and only the blocks missed during the test download.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.19 Power loss while mining (M10)

NOTE: On the soak box, never cut power while Tari reads loading (see
[the soak-box rules](README.md#step-2-run-the-hardware-battery-before---start)).

**What you do:**

1. While the box is mining, pull the plug at the wall.
2. Wait 30 seconds.
3. Plug it back in, and do not touch the machine.

If the box is a laptop, a wall-plug cut changes nothing while the battery holds: hold the power
button instead, and power it on by hand.

**What you should see:**

- It powers on by itself.
- It returns to mining.
- The dashboard answers.

**Record:** PASS, FAIL or N/A in the results sheet. On a laptop, record "powers on by itself" as N/A.

### 13.20 Tor egress on the appliance

**What you do:**

1. In Configuration, click **Run health check**.
2. Open **Stack Topology & Egress** in the Advanced view.

**What you should see:**

- The health check reports `Tor-only egress firewall is installed`.
- The health check reports `Tor clearnet egress works`.
- The topology shows unselected clearnet routes as blocked.
- The header shows no firewall warning.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.21 Onion dashboard on the appliance

**What you do:**

1. In Configuration, turn on `dashboard.onion.enabled`, leaving `dashboard.onion.client_auth` on.
2. [Preview](../README.md#glossary) the change, then [apply](../README.md#glossary) it: type
   `APPLY` and confirm.
3. Press **Show client key**.
4. Press **Show client key** again.
5. Open the change history.
6. With that key, open the dashboard in Tor Browser as in 9.4
   ([09-privacy-tor.md](../diy/09-privacy-tor.md)).
7. Try to turn `client_auth` off while the onion is on.

**What you should see:**

- The `.onion` address appears under the machine name with a **Copy address** button.
- **Show client key** reveals the key.
- Pressing it again reveals the same key. **Set up again** keeps it too (#3100).
- Each reveal appears in the change history.
- With that key, Tor Browser opens the dashboard as in 9.4.
- Turning `client_auth` off while the onion is on is refused.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.22 Node modes on the appliance

**What you do:**

1. In Configuration, set Tari's mode to `off`.
2. Preview, type `APPLY` and confirm.
3. Set Tari's mode back to `local` the same way.

**What you should see:**

- The preview marks each change ⚠.
- With Tari off, mining continues.
- Switching back resumes the Tari chain it already had.
- Monero mining carries on while Tari catches up (#3094): the `Tari merge-mining ON` row says so.
- Workers Alive keeps its workers, the built-in miner included.
- No `Workers rejected` badge shows.
- The Tari card reads syncing.

The remote Monero node change is 13.15.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.23 Settings by USB stick

**What you do:**

1. On the laptop, give the second stick one partition formatted FAT32. Not exFAT, and not FAT
   written across the whole device without a partition: the appliance reads neither.
2. Write to it only a `pithead-config.json` with this content:

   ```json
   {"p2pool": {"pool": "nano"}}
   ```

3. Insert the stick into the running appliance.
4. Attach a monitor and reboot.
5. Pull the stick during the countdown.
6. Write the file again, insert the stick, reboot, and let the countdown run out.
7. Put `mini` back the same way: the same file with `mini` in place of `nano`.

**What you should see:**

- After item 3, nothing happens until a reboot.
- After item 4, the console prints the pool change, old and new value, and counts down 60 seconds.
  The old value may read `(unset)` while the pool is still at its default.
- After item 5, the console says the change was cancelled, and nothing changes.
- After item 6, the change applies, the file is gone from the stick, and the dashboard shows the
  `nano` sidechain.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.24 Change and recover the dashboard password

NOTE: While the onion from 13.21 is on, every password in this step must be at least 16
characters and free of well-known weak patterns, or it is refused (see
[Broken configs](../sample-configs.md#broken-configs)).

**What you do:**

1. In Configuration, set a new dashboard password.
2. Preview it, type `APPLY` and confirm.
3. Log in with the new password.
4. Attach a monitor and reboot.
5. At the console, log in as `root`, first with the old password, then with the new one.
6. On the second stick from 13.23, write only a `pithead-config.json` with the content below.
   `<a third QA password>` is a third password you make up for QA.

   ```json
   {"dashboard": {"auth": {"password": "<a third QA password>"}}}
   ```

7. Insert the stick, reboot, and let the countdown run out.
8. Log in with the third password in the browser and at the console.
9. Finally, put the original password back the same way, because 15.2 needs it.

**What you should see:**

- The preview warns that a mistyped password locks this session out, and that on the appliance it
  is also the console root login.
- After the apply, the old password is refused and the new one works, in the browser and at the
  console.
- With the stick, the console shows `dashboard.auth.password: changed (value hidden)`, never the
  value, counts down, and applies.
- The third password then works in both places.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.25 Walk the appliance guide against the device (#3100)

**What you do:**

1. On the second appliance, read [the appliance guide](../../../appliance.md) from top to bottom
   beside the box.
2. For every instruction that names a button, a label, a command or an outcome, check that the
   device matches.
3. Do not repeat the destructive ones: they have their own steps.
4. File every sentence the device contradicts, and every place you had to know something the guide
   does not say.

**What you should see:**

Every label and command is real. In particular:

- Console commands read `cd /data/pithead && ./pithead <verb>` (13.24, 15.2 and 15.3 use them).
- The [wizard](../README.md#glossary) labels are `ERASES everything on it` and `holds a previous
  install`.
- The onion button is **Copy address**.
- **Show client key** shows the same key twice (13.21).
- An installed OS update boots at any reboot, and the dashboard's Reboot button expires after 24
  hours (12.3, in [12-upgrade-from-dashboard.md](../diy/12-upgrade-from-dashboard.md)).
- **Config reset** keeps the machine's identity, and **Fresh start, keep the blockchains** is the
  way to hand a machine over (15.2, in [15-rename-and-resets.md](15-rename-and-resets.md)).
- A restore says to switch the old machine off first (13.14).
- A rename warns that [rigs](../README.md#glossary) using the old name stop mining (15.1).

**Record:** PASS, FAIL or N/A in the results sheet, plus the issues you filed.
