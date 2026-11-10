# Manual release QA

The hands-on test plan a person runs before every Pithead release: one pass through every
feature, in plain steps, followed by the hardware-only checks and the release-cut traps that no
harness can do for you. The automated gates are described in [releasing.md](../releasing.md) (DIY
channel) and [appliance-release.md](../appliance-release.md) (appliance channel).

It is written for the tester. You do not need to read code: every step says what to do, what you
should see, and what to write down. Words in the [Glossary](#glossary) are explained there.

Most of what the walkthrough touches is also covered by automated tests. It is here anyway: a
green suite proves each piece works on its own, and only a person using the product end to end
notices a confusing message, a missing button, or two screens that disagree. The hardware
battery files keep their original rule: each item says **why it cannot be automated**, an item
that becomes automatable should move off that list, and anything that keeps biting should get a
harness leg. Walkthrough steps that could be automated but are not yet are tracked under
[#3068](https://github.com/p2pool-starter-stack/pithead/issues/3068).

Contents:

- [How to use this checklist](#how-to-use-this-checklist): what you need on hand, how to read a
  step, how to record results
- [Run sheet](#run-sheet): the order to run everything in, session by session
- [Files in this guide](#files-in-this-guide): where each section and step lives
- [When a step fails](#when-a-step-fails) and [Known on the re-cut RC](#known-on-the-re-cut-rc)
- [Glossary](#glossary)

## How to use this checklist

### Before you start

- Read [What you need](what-you-need.md) and gather everything on it. Reserve the shared
  machines first: see [Reserve the hardware](release/before-the-cut.md#reserve-the-hardware).
- Fill in the [Sample configs](sample-configs.md) with your QA values.
- Rough time: about six working days of hands-on time, then the 7-day [soak](#glossary). A first
  chain [sync](#glossary) takes hours to days, so start session 2 of the [Run sheet](#run-sheet)
  on day one and work through the other sessions on the already-synced upgrade machine meanwhile.

### How to read a step

- You do not need to read code. You need a terminal on the test machine, a web browser, and a
  way to write down what you see.
- Every step has a **What you do** part and a **What you should see** part. A step passes only
  when what you see matches **What you should see**:
  - Text in `code style` must match exactly. A different message there is a FAIL; write down the
    text you saw.
  - Expectations written in plain words describe what must happen, not the exact words on screen.
  - Any other difference (a missing button, a wait far longer than stated, a different outcome) is
    a FAIL, even if the product seems to work.
- Text in `code style` is exactly what you type, or exactly what the product prints. Words in
  angle brackets, such as `<full candidate SHA>`, are placeholders: the step says what to put
  there.
- `./pithead` commands run from the [install directory](#glossary) on the stack machine.
  Commands that start with `sudo` ask for the machine's administrator password.

### How to record results

- Your results sheet is the release issue. Copy the sections you run into it and tick the boxes
  there. At the top, record the full commit SHA you tested and, for the appliance, the image
  checksum.
- Give every step one result:
  - **PASS**: what you saw matches **What you should see**.
  - **FAIL**: link the issue you filed (see [When a step fails](#when-a-step-fails)).
  - **SKIP**: say why.
  - **BLOCKED**: name the earlier failure that stopped you.
  - **N/A**: only where a step or guide tells you to, for example a check a virtual machine
    cannot prove.
- Follow the [Run sheet](#run-sheet) for the order of sessions, and run the steps within a
  session in order. Later steps assume earlier ones passed, and the destructive steps (resets,
  uninstall, factory reset) come last on purpose.

## Run sheet

The order for one tester with the soak appliance, a fresh DIY box, an upgrade DIY box (sections 1
and 2–11 need one machine each; either may be a virtual machine, see
[Running the DIY boxes as virtual machines](diy/sandbox-vm.md)) and the rest of
[What you need](what-you-need.md). The restore PC is the second appliance. Where this order
differs from the section order of the guides, this order wins. Sessions 1–13 run before the soak;
session 14 starts it. Times are hands-on time plus the waits you cannot shorten. Test files are
named by role: the RC image, the RC update bundle, the good higher-version test bundle and the
broken (health-gate fault) test bundle.

| # | Session | About | Steps | Needs |
|---|---|---|---|---|
| 1 | Prepare | 1 h | [Reserve the hardware](release/before-the-cut.md#reserve-the-hardware); fill in the [sample configs](sample-configs.md); check the LAN test registry | Every release artifact, the QA wallets, the test bot |
| 2 | Fresh install | 2 h, then days of sync | [1.1–1.11](diy/01-fresh-install.md) | Fresh box, laptop |
| 3 | Upgrade | 1 h and a 3 h wait | [2.1–2.4](diy/02-upgrade.md) | Upgrade box, a USB disk for the backup |
| 4 | Use it | 3 h | [3.1–3.7](diy/03-everyday-commands.md), [4.1–4.5](diy/04-connect-a-miner.md), [5.1–5.12](diy/05-dashboard-tour.md) | Upgrade box, two miners, laptop, phone |
| 5 | Change it | 3 h | [6.1–6.10](diy/06-settings-command-line.md), [7.1–7.9](diy/07-settings-dashboard.md) | Upgrade box, the second Monero QA wallet, a single-key Tari address, the Monero GUI wallet and Tari Universe |
| 6 | Alerts and Tor | 4 h | [8.1–8.7](diy/08-alerts-telegram.md), [9.1–9.8](diy/09-privacy-tor.md), and [9.6a](diy/09-privacy-tor.md)'s DIY half | Upgrade box, test bot, Tor Browser |
| 7 | Soak appliance: install | 4 h and 30 min of provisioning | [13.1–13.9](appliance/13a-install-and-first-boot.md) (not 13.6a), 13.7a, 13.8a, [13.20](appliance/13b-updates-restore-and-media.md) | The RC image, 16 GB stick, soak appliance, a second disk, laptop |
| 8 | Soak appliance: updates and power | 4 h | [13.10–13.12, 13.19](appliance/13b-updates-restore-and-media.md) | The good higher-version test bundle (the RC update bundle if you have none), the broken test bundle, the debug SSH key |
| 9 | DIY node modes and backups | 4 h, once the fresh box has synced (1.12 runs earlier, in the window when Monero has synced and Tari has not) | [1.12, 1.13](diy/01-fresh-install.md), [10.1–10.7](diy/10-node-and-pool-modes.md), [11.1–11.5](diy/11-backup-restore-resets.md) | Fresh box, upgrade box, a miner |
| 10 | Second appliance | 7 h | [13.1–13.8](appliance/13a-install-and-first-boot.md) with 13.6a, then [9.6a](diy/09-privacy-tor.md), [13.15–13.18, 13.21–13.25](appliance/13b-updates-restore-and-media.md), [15.1, 15.2](appliance/15-rename-and-resets.md) | The RC image, restore PC, second stick, laptop |
| 11 | Backup and restore (M15) | 4 h | [13.13, 13.14](appliance/13b-updates-restore-and-media.md), [15.3](appliance/15-rename-and-resets.md) on the restore PC, then [13.14a](appliance/13b-updates-restore-and-media.md) | Soak appliance, restore PC, upgrade box (down for 13.14a), the plain 1.x backup |
| 12 | Rigs | 2 h | [14.1–14.4](appliance/14-rigforge-rig.md) | The RC image, the RC update bundle, two loaner rigs |
| 13 | Scenarios, then the fresh box's end | 3 h | [S1–S8](release/scenarios.md) (S4 and S7 may wait for the soak), then [11.6 and 11.7](diy/11-backup-restore-resets.md) last | Fresh box, upgrade box, a clean machine for S1 |
| 14 | Start the soak | 1 h | [The soak preface](appliance/README.md#testing-a-debug-rc-on-the-soak-box): record the box, freeze its state, remove every stick, run `--start` | Build host, a new log directory |

The 7-day clock starts when `tests/os/soak-probe.sh <box IPv4> <logdir> --start` writes
`<logdir>/started`. Here `<box IPv4>` is the soak appliance's IPv4 address and `<logdir>` is the
new log directory on the build host. Day 7 is seven days after that time. After it, nothing
touches the soak appliance but the daily probe. After publishing: run
[12.1–12.3](diy/12-upgrade-from-dashboard.md) and
[After publishing](release/cutting-and-after.md#after-publishing).

On a virtual-machine host with room for only one full DIY box, use the box order in
[Two boxes at once](diy/sandbox-vm.md#two-boxes-at-once). The steps are the same; only the order
of the sessions on the fresh and upgrade boxes changes.

## Files in this guide

Start here:

| File | What it covers |
|---|---|
| [README.md](README.md) | This page: how to test and record results, the run sheet, known issues, the glossary |
| [what-you-need.md](what-you-need.md) | The machines, USB sticks, wallets, test bot and release files to gather first |
| [sample-configs.md](sample-configs.md) | Configs A–D to paste, and the broken configs that `apply` must refuse |
| [coverage.md](coverage.md) | Which steps check each feature on each route, and which steps prove each fix in the 2.0.0 re-cut |

The self-hosted (DIY) route, sections 1–12:

| File | What it covers | Steps |
|---|---|---|
| [diy/README.md](diy/README.md) | Overview: the two DIY machines and the order of the DIY files | |
| [diy/sandbox-vm.md](diy/sandbox-vm.md) | Running the fresh box and the upgrade box as virtual machines | |
| [diy/01-fresh-install.md](diy/01-fresh-install.md) | 1. Fresh DIY install | 1.1–1.13, 1.4a |
| [diy/02-upgrade.md](diy/02-upgrade.md) | 2. Upgrade from the previous release | 2.1–2.4, 2.1b, 2.2a, 2.3a |
| [diy/03-everyday-commands.md](diy/03-everyday-commands.md) | 3. Everyday commands | 3.1–3.7 |
| [diy/04-connect-a-miner.md](diy/04-connect-a-miner.md) | 4. Connect a miner | 4.1–4.5 |
| [diy/05-dashboard-tour.md](diy/05-dashboard-tour.md) | 5. Dashboard tour | 5.1–5.12 |
| [diy/06-settings-command-line.md](diy/06-settings-command-line.md) | 6. Change settings from the command line | 6.1–6.10, 6.4a, 6.4b |
| [diy/07-settings-dashboard.md](diy/07-settings-dashboard.md) | 7. Change settings from the dashboard | 7.1–7.9, 7.1a, 7.3a |
| [diy/08-alerts-telegram.md](diy/08-alerts-telegram.md) | 8. Alerts and Telegram | 8.1–8.7 |
| [diy/09-privacy-tor.md](diy/09-privacy-tor.md) | 9. Privacy and Tor | 9.1–9.8, 9.6a |
| [diy/10-node-and-pool-modes.md](diy/10-node-and-pool-modes.md) | 10. Node and pool modes | 10.1–10.7, 10.3a |
| [diy/11-backup-restore-resets.md](diy/11-backup-restore-resets.md) | 11. Backup, restore and resets | 11.1–11.7, 11.2a |
| [diy/12-upgrade-from-dashboard.md](diy/12-upgrade-from-dashboard.md) | 12. Upgrade from the dashboard (after publishing) | 12.1–12.3 |

The appliance route, sections 13–15, and the hardware batteries:

| File | What it covers | Steps |
|---|---|---|
| [appliance/README.md](appliance/README.md) | Section 13's introduction, and testing a debug RC on the soak box | |
| [appliance/13a-install-and-first-boot.md](appliance/13a-install-and-first-boot.md) | 13. Flash, install, first boot and the DIY checks repeated | 13.1–13.9, 13.6a, 13.7a, 13.8a |
| [appliance/13b-updates-restore-and-media.md](appliance/13b-updates-restore-and-media.md) | 13. Updates, rollback, backup and restore, settings by stick, power loss | 13.10–13.25, 13.14a |
| [appliance/14-rigforge-rig.md](appliance/14-rigforge-rig.md) | 14. RigForge rig | 14.1–14.4 |
| [appliance/15-rename-and-resets.md](appliance/15-rename-and-resets.md) | 15. Appliance rename and resets | 15.1–15.3 |
| [appliance/hardware-battery.md](appliance/hardware-battery.md) | The manual hardware battery, its recorded runs, and install-path cases worth walking | M1–M10 |
| [appliance/rig-battery.md](appliance/rig-battery.md) | The rig-role manual battery | M11–M13 (M14 is automated) |

Release:

| File | What it covers | Steps |
|---|---|---|
| [release/scenarios.md](release/scenarios.md) | Short end-to-end stories that cross sections | S1–S8 |
| [release/before-the-cut.md](release/before-the-cut.md) | What the harness cannot see, reserving the hardware, knowing which image you hold | |
| [release/cutting-and-after.md](release/cutting-and-after.md) | Cutting the release, after publishing, and watching the operator experience | |

## When a step fails

1. Take a screenshot, or a photo of the console. A photo of the screen is a good bug report.
2. On the stack machine, run:

   ```bash
   ./pithead support-bundle
   ```

   It writes a chmod-600 archive with the config masked and secrets redacted; nothing leaves the
   machine. Open it and check it before you attach it anywhere.
3. Search the open issues first, and for the appliance also
   [os/KNOWN-ISSUES.md](../../../os/KNOWN-ISSUES.md). Then file: the step number, what
   **What you should see** said, and what you saw.
4. Keep machine names, IP addresses, passwords and raw logs out of public issues. They go in a
   private handoff.
5. Carry on with the next step that does not depend on the failed one.

## Known on the re-cut RC

A step that fails for a reason listed here is linked to the issue listed, not filed again. Every
**What you should see** line quotes merged code, so judge each step by the rule in
[How to read a step](#how-to-read-a-step).

- [#3165](https://github.com/p2pool-starter-stack/pithead/issues/3165): the appliance first-boot
  wizard's JSON pane collapses a duplicate key silently (last one wins) instead of refusing it;
  `apply` and the dashboard's Configuration editor refuse it as
  [7.6](diy/07-settings-dashboard.md) expects.
- [#3166](https://github.com/p2pool-starter-stack/pithead/issues/3166): `tor.auto_heal` only
  probes and logs warnings on a box without `dashboard.control.enabled`, which includes an
  appliance set up with **No login**; it refreshes or recovers Tor only when control is on.

## Glossary

The words the guides use, in alphabetical order.

- **Appliance**: Pithead installed as its own operating system on a dedicated PC, from a USB
  stick. You set it up from a setup page in the browser; it has no shell for the user apart from
  its console.
- **Apply**: `./pithead apply` reads `config.json` and changes the running stack to match it,
  after showing a preview. On the dashboard, confirming a preview does the same.
- **Boot menu**: the five-second menu the appliance shows when it starts. It names the version
  in each slot, marks one **current**, and offers **Set up again (setup wizard; keeps saved
  settings)**. Each title begins with **USB drive:** or **Internal disk:**; an installation
  made from an earlier image shows neither prefix.
- **Built-in miner**: the miner the appliance runs on its own CPU (role **Pithead + RigForge**).
  It shows as a worker, and `local_miner.enabled` turns it on and off.
- **Clearnet**: the ordinary internet, not through Tor. Pithead keeps node traffic on Tor unless
  you choose a clearnet option, such as the faster first sync (`clearnet_initial_sync`).
- **Commit SHA**: the 40-character id of one version of the source code. `<full candidate SHA>`
  means all 40 characters of the candidate's id; `<short SHA>` is its first few characters.
- **Configuration view**: the dashboard page, opened from the toggle above the chart, where you
  change settings in a form or in the Advanced JSON pane.
- **Coordinator**: a Pithead machine that runs the pool, the nodes, Tor and the dashboard. Rigs
  mine to it and are managed from it; in section 14 the appliance is the coordinator.
- **Debug image, release image**: a debug image has SSH on with the bench key baked in, for
  testing only. A release image has no shell and no keys; never publish a debug image or hand
  one to a user.
- **DIY route**: Pithead as a self-hosted Docker Compose stack on your own Ubuntu machine, driven
  by `./pithead` and `config.json`. Sections 1–12 test it.
- **Doctor**: `./pithead doctor`, the stack's health report; problems show as WARN or FAIL lines.
  The dashboard's **Run health check** shows the same rows.
- **Egress firewall**: firewall rules on the stack machine that let the stack reach the internet
  only through Tor. Doctor reports it as `Tor-only egress firewall is installed`.
- **Fresh box, upgrade box**: the two DIY test machines: one with nothing of Pithead on it, one
  already running the previous release. See [What you need](what-you-need.md).
- **GA**: general availability, the published release that follows a passing RC.
- **Harness, KVM battery**: the automated tests. The KVM battery boots the appliance image in
  virtual machines, so it cannot see real firmware, disks, USB sticks or power cuts; the hardware
  batteries (M1–M13) cover those by hand.
- **Health gate**: the check an appliance runs after it boots an update. It keeps the new slot
  only when the stack comes up healthy, and otherwise boots the other slot again.
- **HugePages, MSR**: memory and CPU settings that speed up the RandomX miner. A virtual machine
  cannot prove them.
- **Install directory**: the folder that holds `./pithead` and `config.json`: the cloned
  `pithead` folder on a DIY box, `/data/pithead` on the appliance.
- **LAN test registry**: the local image store a debug image pulls its container images from.
  A pull error during provisioning points at it first.
- **Merge-mining**: mining Tari with the same work as Monero. Tari is optional (`tari.mode`).
- **Miner, worker**: a miner is a machine running mining software (XMRig or RigForge) pointed at
  the stack. Each one shows as a named worker in the dashboard's **Workers Alive** table.
- **Onion address**: a `.onion` address that only Tor can reach. The dashboard can be published
  as one; with client authorization on, Tor Browser also needs the key from
  `./pithead onion-client-key`.
- **P2Pool, sidechain**: P2Pool is the decentralised mining pool the stack runs. Its sidechain is
  `main`, `mini` or `nano`; `nano` suits a low hashrate.
- **Payout confirmation**: with a wallet's private view key set, Pithead watches the chain and
  shows arriving payouts on the dashboard's **Earnings** card.
- **Preview**: the list of changes Pithead shows before it applies them. A `•` change applies
  without a question; a `⚠` change is disruptive and asks first: `(y/N)` on the command line,
  typing `APPLY` on the dashboard. `./pithead apply --dry-run` shows the preview only.
- **Primary address, subaddress**: a Monero wallet's primary address starts with `4` and is 95
  characters long; a subaddress starts with `8`. Pithead refuses a subaddress as the payout
  address.
- **Private handoff**: notes kept out of public view, for passwords, keys, machine names, IP
  addresses and raw logs. Never paste them into a public issue.
- **RC (release candidate)**: the build under test, run through this checklist before it is
  published.
- **Results sheet**: the release issue. Copy the steps you run into it and record each result
  there.
- **Rig**: a machine that only mines. Here, a rig-class loaner machine running RigForge, pointed
  at a coordinator.
- **RigForge**: the project's miner setup for rigs. The appliance image includes it, both as the
  built-in miner and as the **RigForge** role.
- **Slot**: the appliance keeps two copies of its operating system, slot A and slot B. An update
  is written to the spare slot and runs from the next reboot; the boot menu marks the running one
  **current** and the other **previous**.
- **Soak**: the 7-day run of the RC on the soak appliance. Once it starts, nothing touches that
  box but the daily probe.
- **Stack, stack machine**: the stack is the set of containers Pithead runs (nodes, pool, Tor,
  dashboard); the stack machine is the computer it runs on.
- **Stratum**: the protocol miners use to talk to the pool, on port 3333. A stratum password is
  optional; stratum TLS encrypts the connection.
- **Support bundle**: the archive `./pithead support-bundle` writes for a bug report, with the
  config masked and secrets redacted.
- **Sync, Sync Mode**: a node syncs by downloading and checking its whole blockchain; a first
  sync takes hours to days. Meanwhile the dashboard shows **Sync Mode** and the miner is held.
- **Tor, Tor Browser**: Tor is the network Pithead uses to hide where its traffic comes from.
  Tor Browser is the browser that opens `.onion` addresses.
- **Update bundle**: a `.raucb` file that carries an appliance OS update.
  `./pithead os-update <bundle>`, or the dashboard's **OS updates**, writes it to the spare slot.
- **View key**: the private key that lets a wallet see incoming payments but not spend them.
  Pithead uses it for payout confirmation and never needs the spend key or the seed words.
- **Wizard**: the setup questions: `./pithead setup` on a DIY box, the setup page in the browser
  on the appliance.
- **XMRig**: the mining program the test miners run.
- **XvB raffle**: the XMRvsBeast raffle. With `xvb.enabled` on, the stack donates part of its
  hashrate to hold a raffle tier; a new install leaves it off.
