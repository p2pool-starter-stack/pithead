# Appliance tests

These guides test the Pithead appliance: the image, its setup page, updates, power loss, backups,
[rigs](../README.md#glossary), resets and, on a debug release candidate, the 7-day soak.

## Before you start

- **Machines.** The appliance box (the soak box on a debug release candidate) and the restore PC,
  which is also the second appliance. Both are described in [What you need](../what-you-need.md).
- **Earlier steps.** Run the DIY sessions first, in the order of the
  [Run sheet](../README.md#run-sheet). Section 13 repeats DIY steps from sections 1, 4, 5, 7 and 8,
  and 13.14a and 13.15 use the upgrade box.
- **Have ready.** The release artifacts from [What you need](../what-you-need.md), the bench SSH key
  for debug images from the private handoff, a monitor, a 16 GB USB stick and a second stick, the
  laptop, and the QA wallets.
- **Rough time.** From the Run sheet: about 4 hours, plus 30 minutes of provisioning, to install the
  soak appliance (session 7), 4 hours for updates and power (session 8), 7 hours on the second
  appliance (session 10), 4 hours for backup and restore (session 11), 2 hours for rigs
  (session 12) and 1 hour to start the soak (session 14). The soak then runs for 7 days.

## The files in this folder

Run them in this order. Where the [Run sheet](../README.md#run-sheet) orders steps differently,
the Run sheet wins.

1. This page: how section 13 works and, on a debug release candidate, the soak box.
2. [13a-install-and-first-boot.md](13a-install-and-first-boot.md): steps 13.1 to 13.9, with 13.6a,
   13.7a and 13.8a.
3. [13b-updates-restore-and-media.md](13b-updates-restore-and-media.md): steps 13.10 to 13.25, with
   13.14a.
4. [14-rigforge-rig.md](14-rigforge-rig.md): steps 14.1 to 14.4.
5. [15-rename-and-resets.md](15-rename-and-resets.md): steps 15.1 to 15.3. These run last.
6. [hardware-battery.md](hardware-battery.md): the manual hardware battery (M1–M10) the steps
   serve, and why it cannot be automated.
7. [rig-battery.md](rig-battery.md): the rig-role manual battery (M11–M13).

## How section 13 works

Run section 13 on the **appliance box**. Each step names the battery row it serves (M1–M16,
defined in [appliance-release.md](../../appliance-release.md)); why the hands-on rows cannot be
automated is in [the hardware battery](hardware-battery.md). Follow
[the appliance guide](../../../appliance.md) as a user would, and file anything you had to know
rather than read.

### Which image each step runs on

Steps 13.10–13.12 copy update bundles to the box over SSH, which only the debug image has (see
[Know which image you are holding](../release/before-the-cut.md#know-which-image-you-are-holding)).
On a candidate with a release image:

1. Run 13.1–13.9 on the release image.
2. Before 13.10, write the debug image to the stick with the 13.1 commands. Skip the checksum check
   if the debug image has no `.sha256` file.
3. Boot the box from the stick, choose the same disk, and pick **Keep everything**.
4. Reach the box as `root` over SSH with the bench key from the private handoff.
5. Run 13.10–13.12.
6. After 13.12, write the release image to the stick and reinstall the same way.
7. Run everything else on the release image.

The dashboard's own update path checks for the latest *published* release, so it is tested after
publishing, in 12.3 ([12-upgrade-from-dashboard.md](../diy/12-upgrade-from-dashboard.md)).

On a debug release candidate, [the soak-box section below](#testing-a-debug-rc-on-the-soak-box)
overrides this list: every step already runs on the debug image, so there is no reinstall before
13.10 and none after 13.12.

### The appliance's command line

The appliance's command line runs like this, at the console or over SSH:

```bash
cd /data/pithead && ./pithead <verb>
```

`<verb>` is the command a step names, for example `os-update` or `config-reset`.
`/opt/pithead/pithead` changes into its own read-only directory before it reads anything, so
started from there it does not find this box's `config.json`.

## Testing a debug RC on the soak box

Read this first when the candidate is a debug release candidate and the appliance box then
carries the 7-day soak ([#1652](https://github.com/p2pool-starter-stack/pithead/issues/1652)). The
soak probe scores one boot, flat container restarts, every day-0 container running and healthy,
and exactly one SSH login a day, its own. Rule 6 also requires the egress table to remain
present with the same stateless ruleset hash as day 0. Resources, chain heights/growth and
accepted work are recorded; they do not gate. See the
[soak probe contract](../../../../tests/os/README.md#soak-probe).

Work through steps 1 to 5 in order. The rules after them hold for the whole run.

### Step 1: Use the debug image for every appliance step

No release image exists before GA, so every appliance step runs on the debug image.

1. Skip the instruction in [Which image each step runs on](#which-image-each-step-runs-on) to
   write the release image after 13.12.
2. Record the variant (debug, and its commit) on every M row.
3. Record these as N/A: `verify-image.sh` without `--test`, the release-keyring checks and
   "Signing must be ON" in [Cutting](../release/cutting-and-after.md#cutting). They refuse a debug
   image by design, and they run at GA against the release artifacts.

### Step 2: Run the hardware battery before `--start`

1. Run M1–M10: 13.1–13.12 and 13.19. M5, in 13.18, may run on the second appliance instead.
2. Cut power (M8 in 13.11, M10 in 13.19) only before the window opens.
3. Run M15 (13.13 and 13.14) before `--start` or after day 7, never inside the window.
4. Run the [Tor](../README.md#glossary) drill (9.6a, in
   [09-privacy-tor.md](../diy/09-privacy-tor.md)) on either appliance, before `--start` only.
5. After 13.7, and again after each reboot in 13.10–13.12, wait until the dashboard's Tari card
   shows progress before the next reboot, boot-menu test or power cut. A disk that kept its chains
   may hold a Tari database that migrates on its first start, for hours, and an interrupted
   migration loses it (see 2.3a in [02-upgrade.md](../diy/02-upgrade.md)).
6. Never run M8 or M10 while Tari reads loading.

### Step 3: Record the box before `--start`

Before `soak-probe --start`, over SSH:

1. Copy `/data/pithead/config.json` off the box into the private handoff, never into an issue or
   the release thread. It holds the dashboard password, the [view keys](../README.md#glossary)
   and the bot token.
2. Note what each of these prints:

   ```bash
   cat /opt/pithead/BUILD_COMMIT
   ```

   ```bash
   cat /opt/rigforge/RIGFORGE_REF
   ```

   ```bash
   rauc status
   ```

   The second one is the check in 13.7a.
3. Note the payout addresses, the machine name, its IPv4 address and both chain heights.
4. If the box has a [stratum](../README.md#glossary) password, read it with this command and keep
   it in the private handoff, for 4.x and 14.1 (see 13.8):

   ```bash
   grep PROXY_STRATUM_PASSWORD /data/pithead/.env
   ```

NOTE: The machine name replaces `pithead` in every `pithead.local` address in these guides.

### Step 4: Freeze the soak state before `--start`

1. Put the soak configuration in place for good: payout address, machine name, pool, Telegram (so
   8.2 and S7 can run during the soak) and the [onion](../README.md#glossary), on or off. The
   day-0 container set is fixed at `--start`.
2. Remove every USB stick from the box.
3. Delete `pithead-config.json` and `pithead-token.txt` from the image stick. A stick left in is
   read at the next boot, after any power event.
4. Check that `/data/pithead/.os-migration-pending` is absent.
5. Check that both chains are [synced](../README.md#glossary).
6. Confirm no first-sync clearnet exemption remains. `--start` refuses an exemption or an
   unreadable firewall check without opening a window.

### Step 5: Start the probe

1. Make a fresh probe log directory, never the previous soak's, so the old `soak.log`,
   `day0.env`, `started` and `read<N>.env` files are not mixed into this soak's record.
2. Keep the probe, its three sibling shell scripts and `tests/os/soak-local.py` together
   in the kit; include `dashboard/mining_dashboard/helper/http.py` for the self-test.
   Preserve all six repository-relative paths. On a Linux or macOS workstation with
   Bash 3.2 or newer, Python 3 and jq, run:

   ```bash
   tests/os/soak-probe.sh --self-test
   ```

   ```bash
   tests/os/soak-probe.sh <box IPv4> <logdir> --read
   ```

   Inspect the private readings. `<box IPv4>` is the soak box's IPv4 address from step 3.
   `<logdir>` is the fresh log directory from item 1. This read opens no soak window.
3. Once step 4 is complete, open day 0:

   ```bash
   tests/os/soak-probe.sh <box IPv4> <logdir> --start
   ```

4. Add the daily cron line, with the same IPv4 address and log directory:

   ```bash
   0 6 * * * <checkout>/tests/os/soak-probe.sh <box IPv4> <logdir> >><logdir>/cron.log 2>&1
   ```

   `<checkout>` is the path of the pithead checkout on the build host.

**What you should see:**

- The day-0 line carries a rule-4 FAIL from the setup logins. That is the baseline, not a soak
  day.
- Every UTC date has a probe line. A skipped date makes the next read fail with
  `schedule:missing-days(N)` and leaves both chains' growth and rate as `?`; another read
  on that date cannot clear the gap. The next consecutive successful daily sample resumes
  growth reporting, but the missing day still fails the whole soak window.

### Allowed during the soak (read-only)

- 5.1–5.6 and 5.8–5.12.
- 7.1 and 7.8 as views only; 7.7.
- 13.20.
- 8.2 and 8.3.
- 4.1, 4.2, 4.4, 4.5 and 8.4 with outside miners and no Configuration commit.
- S4 and S7 ([scenarios](../release/scenarios.md)).
- 14.1, 14.3 and 14.4 on the rigs, rig side only.

Anything not listed here is forbidden during the window.

### Forbidden after `--start` until day 7

- Any SSH or `scp` except the probe's own, including agent and operator sessions. Tell them the
  box is held.
- Any reboot or power cut, the boot-menu reboot (13.9) included.
- `down` and `up` (5.7).
- The dashboard upgrade (12.2).
- Any Configuration commit, benign ones included: 7.1a, 7.2–7.6, 7.9, 13.8a, 13.15, 13.21, 13.22,
  13.24, and Telegram setup.
- **Back up now** (13.13).
- OS updates (12.3, 13.10–13.12).
- The Tor drill (9.6a).
- Inserting a USB stick (13.17, 13.18, 13.23).
- Adopting a rig (14.2).
- Renames and resets (15.x).
- S6 and S8.

### On a second appliance

1. Flash the restore PC with the same debug RC and give it a machine name other than `pithead`, so
   rigs and mDNS (the lookup that turns a `.local` machine name into an address on the LAN) never
   land on it by accident.
2. Run these there: 13.8's Sync Mode checks (1.8 and 1.13; the soak box's chains are already
   synced), 13.6a, 7.1a–7.6, 7.9, 9.6a, 13.14a, 13.15–13.18, 13.21–13.25, 15.1–15.3, S6 and S8,
   and 14.2 with it as the [coordinator](../README.md#glossary) if 14.2 was not done before
   `--start`.
3. For M15, only before `--start` or after day 7: run 13.13 on the soak box, power the soak box
   off, and run 13.14 on the restore PC. Then factory-reset the restore PC (15.3) before the soak
   box is powered on again, so the two never run the same identity.
4. Inside the window, skip M15 or run it between two other machines.

### The LAN test registry

A debug image pulls its stack images from the LAN test registry at first start and on every
re-pull.

1. Before 13.7, 13.14, 13.14a, 13.16, 13.18, 15.2 and 15.3, and before flashing the second
   appliance, check that the registry answers and still holds the debug images.
2. A pull or verify error during provisioning points at the registry first: check it before you
   file.

### If the soak box is a laptop

This is not confirmed. Pulling the wall plug cuts nothing while the battery holds.

1. Cut power in 13.11 and 13.19 by holding the power button.
2. Power it on by hand.
3. Record "powers on by itself" (13.2's setting, 13.19) as N/A.
