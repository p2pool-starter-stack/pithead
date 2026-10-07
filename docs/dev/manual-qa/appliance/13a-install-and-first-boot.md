# 13a. Appliance install and first boot

These steps test writing the appliance image to a stick, the first boot, the setup page, the
install, and the first checks on the installed appliance (steps 13.1 to 13.9).

## Before you start

- **Machine.** The appliance box, for every step except 13.6a, which runs on the second appliance
  (the restore PC) on its first install. On a debug release candidate, the appliance box is the
  soak box: read [the appliance README](README.md) first, including
  [Testing a debug RC on the soak box](README.md#testing-a-debug-rc-on-the-soak-box).
- **Earlier steps.** The DIY sessions in the [Run sheet](../README.md#run-sheet). 13.8 repeats
  1.8 and 1.13, sections 4 and 5, 7.1–7.9 and 8.2–8.4, so have those guides at hand.
- **Have ready.** The RC image, a 16 GB USB stick, a second internal disk in the appliance box, a
  Linux machine or a Mac (macOS 14 or later) for 13.1, a monitor, the laptop, the QA wallets (the
  Monero primary address, its subaddress and the Tari address), two miners running XMRig, the
  Telegram test bot, and on the debug image the bench SSH key from the private handoff. See
  [What you need](../what-you-need.md).
- **Rough time.** About 4 hours, plus 30 minutes of provisioning, on the soak appliance (Run sheet
  session 7). 13.6a runs in session 10, on the second appliance.

### 13.1 Verify and flash (M1)

**What you do:**

1. Check the image file against its checksum file. `vX.Y.Z` is the version in the file names you
   downloaded. On Linux:

   ```bash
   sha256sum -c pithead-os-vX.Y.Z.img.xz.sha256
   ```

   On a Mac:

   ```bash
   shasum -a 256 -c pithead-os-vX.Y.Z.img.xz.sha256
   ```

2. Write the image to the USB stick. `/dev/sdX` stands for the USB stick: replace it with the
   stick's device name and check it twice, because `dd` erases whatever you name.

   ```bash
   xz -dc pithead-os-vX.Y.Z.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   On a Mac, write it with easydd as in
   [the appliance guide, step 1](../../../appliance.md#1-write-the-image-to-a-usb-stick).

**What you should see:**

- The checksum line ends in `OK`.
- The write completes.

**Record:** PASS, FAIL or N/A in the results sheet, plus the `.img.xz` size and checksum.

### 13.2 Firmware

**What you do:**

1. Open the appliance box's firmware setup.
2. Disable Secure Boot.
3. Set the power-loss setting to power on.

**What you should see:**

- Both settings exist under one of the names [the appliance guide](../../../appliance.md) lists.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.3 First boot (M1)

**What you do:**

1. Attach a monitor.
2. Boot from the stick.

**What you should see:**

- The console first says it is starting up.
- Within a few minutes it prints the setup address (`https://pithead.local` and an IP).
- It prints a one-time token.
- It prints a certificate fingerprint.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.4 Reach the setup page (M2)

**What you do:**

1. From the laptop, open `https://pithead.local`.
2. Then open the IP the console printed.
3. Enter a wrong token five times.

**What you should see:**

- Both addresses show the token page after one certificate warning.
- The fingerprint in the browser matches the one on the console.
- Five wrong tokens mint a fresh one on the console.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.5 Role and disk (M3, M4)

**What you do:**

1. On the setup page, choose **Pithead + RigForge**.

**What you should see:**

- Each disk is listed with model, size and serial.
- The USB stick is not offered.
- Nothing is preselected.
- A second disk holding unrelated data is listed with `ERASES everything on it`.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.6 Answers (M6)

NOTE: Never choose **Wipe everything** on the soak box: it costs days of resync.

**What you do:**

1. On a disk that already holds an install (the soak box), choose **Fresh start** ("Keep the
   blockchains; wipe settings and wallets.") so the answers form appears. **Keep everything** asks
   nothing, so M6 would be N/A there: run this step on the second appliance.
2. Paste the QA subaddress first.
3. Then paste the QA primary address.
4. Keep every default. Paste the Tari address if the page asks for one.
5. Answer yes to `Enable stratum password?` (its default is no). The
   [stratum](../README.md#glossary) password is what outside miners send to the pool.
6. Press **Validate, then install**.

**What you should see:**

- The subaddress is refused with an explanation before you submit.

Per #3099 and #3092:

- Merge-mining Tari is on by default when the target disk fits both chains, and off when it does
  not.
- The page does not ask about the XvB raffle and leaves it off.
- It generates a dashboard login by default.
- It keeps the first [sync](../README.md#glossary) on [Tor](../README.md#glossary) unless you opt
  in to the faster sync.
- That faster-sync choice covers every chain the stack runs locally, and warns that it exposes
  your IP to the Monero network and, if Tari is on, the Tari network (13.6a).
- After validation the page shows the dashboard login, the address `https://pithead.local`, the
  miner address `stratum+tcp://pithead.local:3333` and, because you answered yes, the stratum
  password. On a box with another machine name, read that name for `pithead`.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.6a Stratum default and fast sync

**What you do:**

1. On the second appliance's setup page, on its first install, keep every default. The stratum
   question stays no.
2. Turn on the faster first sync.
3. Press **Validate, then install**.
4. If that disk is too small for both chains, note that Tari is off.
5. After the install, open Configuration.

**What you should see:**

Per #3099 and #3092:

- The hand-off card says `No stratum password`.
- The faster-sync choice warns as in [13.6](#136-answers-m6).
- Configuration shows `monero.clearnet_initial_sync` on.
- When Tari is on, Configuration shows `tari.clearnet_initial_sync` on too.
- On a disk too small for both chains, the page turns Tari off and says why.

**Record:** PASS, FAIL or N/A in the results sheet, plus whether Tari was off because the disk was too small.

### 13.7 Install (M3)

**What you do:**

1. Save the login the page shows.
2. Type the disk name.
3. Press **I saved these — erase the disk and install.**
4. When the machine has switched itself off, remove the stick.
5. Switch the machine on.

**What you should see:**

- After item 3, progress is shown, then the machine switches itself off.
- After item 5, it boots from the disk and the console narrates provisioning.
- Within 10–30 minutes the dashboard answers with the saved login.
- A second disk, if present, still holds its data.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.7a RigForge is pinned to the 1.18.0 commit (#3116)

**What you do:**

1. Over SSH on the debug image, before `--start`, run:

   ```bash
   cat /opt/rigforge/RIGFORGE_REF
   ```

2. After the RigForge v1.18.0 tag exists (it is cut after the soak), run:

   ```bash
   git ls-remote https://github.com/p2pool-starter-stack/rigforge refs/tags/v1.18.0
   ```

**What you should see:**

- Item 1 prints `ref=<sha> version=1.18.0`, where `<sha>` is the commit the release notes name as
  the one RigForge v1.18.0 is tagged from.
- Once the tag exists, `git ls-remote` prints the same `<sha>`.

**Record:** PASS, FAIL or N/A in the results sheet, plus the `<sha>` that item 1 printed.

### 13.8 The same checks as DIY

**What you do:**

1. Using only the setup page, the dashboard and [the appliance guide](../../../appliance.md), find
   the pool URL and, if one is set, the stratum password an outside miner must send.
2. Look at the dashboard signed in, then signed out.
3. While the appliance's chains sync, check 1.8 (in
   [01-fresh-install.md](../diy/01-fresh-install.md)).
4. When they finish, check 1.13.
5. Repeat sections 4 and 5, 5.12 included ([04-connect-a-miner.md](../diy/04-connect-a-miner.md)
   and [05-dashboard-tour.md](../diy/05-dashboard-tour.md)), pointing XMRig at
   `pithead.local:3333`.
6. Repeat steps 7.1–7.9 ([07-settings-dashboard.md](../diy/07-settings-dashboard.md)). The
   appliance's Configuration view is always on. Skip the second half of 7.1a, which edits
   `config.json`.
7. Set up Telegram in Configuration, then repeat 8.2–8.4
   ([08-alerts-telegram.md](../diy/08-alerts-telegram.md)).
8. Skip anything else that needs a shell (`./pithead`, `docker`, editing `config.json`): the
   appliance has none apart from its console.

**What you should see:**

Per #3092:

- Signed in, the dashboard shows a **Connect a miner** block with the LAN pool URL and the same
  stratum password as the 13.6 hand-off card, or `No stratum password`.
- Signed out, nothing shows it.
- On a box with no dashboard login, the block shows it to anyone on the LAN (owner, 2026-10-04:
  the risk is accepted; an [onion](../README.md#glossary)-published dashboard always has a login).

For items 3 to 7:

- The same results as on the DIY route.
- The built-in miner appears as a worker, and it reports RigForge 1.18.0 (#3116).

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.8a The built-in miner follows its toggle

**What you do:**

1. Wait until the chains are synced and the built-in worker is mining.
2. In Configuration, turn `local_miner.enabled` off.
3. [Preview](../README.md#glossary) the change, then [apply](../README.md#glossary) it: confirm,
   and type `APPLY` if asked.
4. Watch Workers Alive without rebooting.
5. Turn `local_miner.enabled` on the same way.

**What you should see:**

Per #3090:

- The built-in worker leaves Workers Alive within a few minutes of the first apply.
- It returns within a few minutes of the second apply.
- There is no reboot in between, even if an apply reports no configuration changes.

**Record:** PASS, FAIL or N/A in the results sheet.

### 13.9 Boot menu

NOTE: On the soak box, first wait until the dashboard's Tari card shows progress (see
[step 2 of the soak-box rules](README.md#step-2-run-the-hardware-battery-before---start)).

**What you do:**

1. Attach a monitor.
2. Reboot.

**What you should see:**

- A five-second menu that names the version, its [slot](../README.md#glossary) and **current**.
- The menu also offers **Set up again**.
- It boots by itself.

**Record:** PASS, FAIL or N/A in the results sheet.
