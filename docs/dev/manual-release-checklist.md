# The manual release checklist

The hands-on test plan a person runs before every release: one pass through every feature, in
plain steps, followed by the hardware-only checks and the release-cut traps that no harness can
do for you. The automated gates are described in [releasing.md](releasing.md) (DIY channel) and
[appliance-release.md](appliance-release.md) (appliance channel).

Most of what the walkthrough touches is also covered by automated tests. It is here anyway: a
green suite proves each piece works on its own, and only a person using the product end to end
notices a confusing message, a missing button, or two screens that disagree. The hardware
sections further down keep their original rule: each item says **why it cannot be automated**,
an item that becomes automatable should move off that list, and anything that keeps biting
should get a harness leg. Walkthrough steps that could be automated but are not yet are tracked
under [#3068](https://github.com/p2pool-starter-stack/pithead/issues/3068).

Contents:

- [How to use this checklist](#how-to-use-this-checklist),
  [Known on the re-cut RC](#known-on-the-re-cut-rc), [Run sheet](#run-sheet): the order to run
  it in, [What you need](#what-you-need), [Sample configs](#sample-configs)
- [Route coverage](#route-coverage): where each feature is checked on the self-hosted (DIY) route
  and on the appliance route; [Re-cut coverage](#re-cut-coverage): which steps prove each issue
  the 2.0.0 re-cut fixed
- The walkthrough: sections [1](#1-fresh-diy-install) to [15](#15-appliance-rename-and-resets)
- [Scenarios](#scenarios): short end-to-end stories that cross sections
- Hardware and release-cut checks: [Before the cut](#before-the-cut),
  [the hardware battery](#the-manual-hardware-battery-m1m10),
  [the rig battery](#the-rig-role-manual-battery-m11m13), [Cutting](#cutting),
  [After publishing](#after-publishing)

---

## How to use this checklist

- You do not need to read code. You need a terminal on the test machine, a web browser, and a
  way to write down what you see.
- Every step has a **Do** part and an **Expect** part. A step passes only when what you see
  matches **Expect**. If it differs in any way — a different message, a missing button, a wait
  far longer than stated — mark it FAIL, even if the product seems to work.
- Give every step one result: **PASS**, **FAIL** (link the issue you filed), **SKIP** (say why),
  or **BLOCKED** (name the earlier failure that stopped you).
- Copy the sections you run into the release issue and tick the boxes there. At the top, record
  the full commit SHA you tested and, for the appliance, the image checksum.
- Follow the [Run sheet](#run-sheet) for the order of sessions, and run the steps within a session
  in order. Later steps assume earlier ones passed, and the destructive steps (resets, uninstall,
  factory reset) come last on purpose.
- `./pithead` commands run from the install directory on the stack machine. Commands that start
  with `sudo` ask for the machine's administrator password.
- Plan for about six working days of hands-on time, then the 7-day soak. A first chain sync takes
  hours to days, so start session 2 of the Run sheet on day one and work through the other
  sessions on the already-synced upgrade machine meanwhile.

### When a step fails

1. Take a screenshot, or a photo of the console. A photo of the screen is a good bug report.
2. On the stack machine, run `./pithead support-bundle`. It writes a chmod-600 archive with the
   config masked and secrets redacted; nothing leaves the machine. Open it and check it before you
   attach it anywhere.
3. Search the open issues first, and for the appliance also
   [os/KNOWN-ISSUES.md](../../os/KNOWN-ISSUES.md). Then file: the step number, what **Expect**
   said, and what you saw.
4. Keep machine names, IP addresses, passwords and raw logs out of public issues. They go in a
   private handoff.
5. Carry on with the next step that does not depend on the failed one.

### Known on the re-cut RC

A step that fails for a reason listed here is linked to the issue listed, not filed again. Every
**Expect** line now quotes merged code. If the behaviour matches and only the wording differs,
record PASS and write down the text you saw.

- [#3165](https://github.com/p2pool-starter-stack/pithead/issues/3165): the appliance first-boot
  wizard's JSON pane collapses a duplicate key silently (last one wins) instead of refusing it;
  `apply` and the dashboard's Configuration editor refuse it as 7.6 expects.
- [#3166](https://github.com/p2pool-starter-stack/pithead/issues/3166): `tor.auto_heal` only probes
  and logs warnings on a box without `dashboard.control.enabled`, which includes an appliance set up with
  **No login**; it refreshes or recovers Tor only when control is on.

## Run sheet

The order for one tester with the soak appliance, a fresh DIY box, an upgrade DIY box (sections 1
and 2–11 need one machine each; either may be a virtual machine, see
[Running the DIY boxes as virtual machines](#running-the-diy-boxes-as-virtual-machines)) and the rest of [What you need](#what-you-need). The restore PC is
the second appliance. Where this order differs from the section order below, this order wins.
Sessions 1–13 run before the soak; session 14 starts it. Times are hands-on time plus the waits you
cannot shorten. Test files are named by role: the RC image, the RC update bundle, the good
higher-version test bundle and the broken (health-gate fault) test bundle.

| # | Session | About | Steps | Needs |
|---|---|---|---|---|
| 1 | Prepare | 1 h | [Reserve the hardware](#reserve-the-hardware); fill in the sample configs; check the LAN test registry | Every release artifact, the QA wallets, the test bot |
| 2 | Fresh install | 2 h, then days of sync | 1.1–1.11 | Fresh box, laptop |
| 3 | Upgrade | 1 h and a 3 h wait | 2.1–2.4 | Upgrade box, a USB disk for the backup |
| 4 | Use it | 3 h | 3.1–3.7, 4.1–4.5, 5.1–5.12 | Upgrade box, two miners, laptop, phone |
| 5 | Change it | 3 h | 6.1–6.10, 7.1–7.9 | Upgrade box, the second Monero QA wallet, a single-key Tari address, the Monero GUI wallet and Tari Universe |
| 6 | Alerts and Tor | 4 h | 8.1–8.7, 9.1–9.8, and 9.6a's DIY half | Upgrade box, test bot, Tor Browser |
| 7 | Soak appliance: install | 4 h and 30 min of provisioning | 13.1–13.9 (not 13.6a), 13.7a, 13.8a, 13.20 | The RC image, 16 GB stick, soak appliance, a second disk, laptop |
| 8 | Soak appliance: updates and power | 4 h | 13.10–13.12, 13.19 | The good higher-version test bundle (the RC update bundle if you have none), the broken test bundle, the debug SSH key |
| 9 | DIY node modes and backups | 4 h, once the fresh box has synced | 1.12, 1.13, 10.1–10.7, 11.1–11.5 | Fresh box, upgrade box, a miner |
| 10 | Second appliance | 7 h | 13.1–13.8 with 13.6a, then 9.6a, 13.15–13.18, 13.21–13.25, 15.1, 15.2 | The RC image, restore PC, second stick, laptop |
| 11 | Backup and restore (M15) | 4 h | 13.13, 13.14, 15.3 on the restore PC, then 13.14a | Soak appliance, restore PC, upgrade box (down for 13.14a), the plain 1.x backup |
| 12 | Rigs | 2 h | 14.1–14.4 | The RC image, the RC update bundle, two loaner rigs |
| 13 | Scenarios, then the fresh box's end | 3 h | S1–S8 (S4 and S7 may wait for the soak), then 11.6 and 11.7 last | Fresh box, upgrade box, a clean machine for S1 |
| 14 | Start the soak | 1 h | [The soak preface](#testing-a-debug-rc-on-the-soak-box): record the box, freeze its state, remove every stick, run `--start` | Build host, a new log directory |

The 7-day clock starts when `tests/os/soak-probe.sh <box IPv4> <logdir> --start` writes
`<logdir>/started`; day 7 is seven days after that time. After it, nothing touches the soak
appliance but the daily probe. After publishing: 12.1–12.3 and [After publishing](#after-publishing).

## What you need

| Item | What it is for |
|---|---|
| **Fresh box** | Ubuntu Server 24.04, AVX2 CPU, 16 GB RAM, 600 GB SSD, nothing of Pithead on it. Section 1. A virtual machine is fine: see [Running the DIY boxes as virtual machines](#running-the-diy-boxes-as-virtual-machines). |
| **Upgrade box** | A machine already running the previous release, with both chains synced and the dashboard password set. A virtual machine is fine: see [Running the DIY boxes as virtual machines](#running-the-diy-boxes-as-virtual-machines). Sections 2–11; it runs the candidate from 2.2 on. Its Monero node also serves as the test node for 13.15 (M16), opened to the LAN as in Config D. 9.5 replaces its dashboard onion address and 11.5 clears its dashboard history, so do not use a box whose onion or history you need to keep. |
| **Appliance box** | An x86-64 UEFI PC with 16 GB RAM, ethernet, firmware settings you can change (Secure Boot off), and an internal SSD or NVMe of **600 GB or more** that may be erased; a smaller disk cannot hold both chains ([the appliance guide](../appliance.md)). A second internal disk for the wrong-disk check. Section 13. |
| **Restore PC** | A second x86-64 UEFI PC with 16 GB RAM, wired ethernet, Secure Boot off and a disk that may be erased, for the restore tests in 13.14 and 13.14a. While a soak runs it is also the second appliance (see [Testing a debug RC on the soak box](#testing-a-debug-rc-on-the-soak-box)). |
| **USB sticks** | One of **16 GB or larger** for the image (a smaller stick stops the first boot at an emergency console), contents expendable. A second stick of any size for the settings files in 13.23 and 13.24, so writing them does not erase the image; 13.23 erases this second stick when it partitions it. The appliance reads settings only from a stick the kernel reports as removable: on a Linux machine, `lsblk -o NAME,RM` must show `1` under `RM` for it. |
| **Miners** | Two machines running XMRig, for section 4 (4.4 needs a second worker). Your own PCs are fine: nothing in section 4 changes them. |
| **Rigs** | Two rig-class loaner machines (never a production rig, never someone's own PC), with Secure Boot off, for section 14. 14.1 **erases** the first one's internal disk; 14.3 runs the second from the stick. |
| **Laptop** | On the same network, with a normal browser and Tor Browser. A Linux machine (this laptop or another) for writing the image in 13.1. |
| **Phone** | For the narrow-screen check and Telegram, with Tor Browser (or Orbot) for S7. |
| **QA wallets** | A Monero wallet used only for QA: its **primary** address (starts with `4`, 95 characters), one **subaddress** from it (starts with `8`), and its private view key (the Monero GUI calls it *Secret view key*). A second Monero QA wallet: its primary address and private view key, for the payout-change steps (6.4, 6.4a, 7.5). A Tari **mainnet** QA wallet with a dual-key address, which is what Tari Universe creates: its address and private view key. The public spend key is read from the address, so no spend key is needed (#3096). A single-key Tari address (about 46 characters, never funded) for the refusal in 6.4b. The two QA wallets should open in the official Monero GUI wallet and Tari Universe, for the view-key docs walk in 7.9. Payouts go here, so never use a real person's or a donation address. |
| **Telegram test bot** | A bot made with @BotFather, its token, and the chat id of a test chat. See [Telegram](../telegram.md). |
| **Release artifacts** | The candidate's full commit SHA, the previous release tag, and for the appliance: the RC image (the candidate's debug image; the release `.img.xz` with its `.sha256` joins it at GA), the RC update bundle (the candidate's own `.raucb`), the good higher-version test bundle (a debug-variant `.raucb` with a higher version), the broken (health-gate fault) test bundle M9 describes (also debug-variant, with a version above the good one), and the bench SSH key for debug images, kept in the private handoff ([appliance-release.md](appliance-release.md)). |

Reserve shared machines before you start: see [Reserve the hardware](#reserve-the-hardware).

### Running the DIY boxes as virtual machines

The fresh box and the upgrade box can be virtual machines on a Linux host with KVM (libvirt or
similar). The appliance, the restore PC and the rigs cannot: sections 13–15 need real hardware.

| Setting | Value | Why |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS, nothing of Pithead on it | The fresh-box baseline in 1.1 |
| CPU | Host passthrough (libvirt `host-passthrough`), 6 or more vCPUs | The guest must see AVX2 and AES; the RandomX miner and the build need them |
| Memory | 16 GB for a box that runs both chains | The documented minimum. Less tests an undersized box, not the release |
| Disk | 700 GB, thin-provisioned | 600 GB for both chains, plus headroom |
| Network | Its own address on your LAN (bridged or macvtap) | The laptop, the miners and the phone must reach its dashboard and stratum port; a NAT network hides it |

- **Snapshots.** Take one right after the OS install (*clean*) and one once the previous release
  has synced (*previous release synced*). Section 1 starts from *clean*, and section 2 from
  *previous release synced*. Reverting repeats a route without reinstalling.
- **Sync time.** A box syncing both chains from zero over Tor takes days. For the upgrade box,
  install the previous release with `clearnet_initial_sync` set to `true` under both `monero` and
  `tari`. That exposes the box's IP while it syncs, which is acceptable on a sandbox. Otherwise,
  start it a few days ahead. 1.1–1.11 do not need the chains synced; 1.12 and 1.13 do.
- **Two boxes at once.** Session 9 needs both: in 10.3 and 10.4 the upgrade box serves its node
  and the second machine uses it as a remote node. That second machine runs no chain of its own,
  so a small VM (about 6 GB of memory) is enough while the fresh box is paused or stopped. On a
  host that cannot hold both full boxes, run session 2 first, then pause or stop the fresh box
  for sessions 3–9.
- **What a VM cannot prove.** HugePages and MSR tuning for the built-in miner, USB sticks, power
  cuts, physical disks and real network cards. Record those steps as N/A for a VM run, never as
  PASS, and walk them on hardware.
- **Host load.** Give the VM its own cores where you can. A busy host slows the guest enough to
  turn timing-sensitive steps (sync waits, alert debounces) into false failures.

## Sample configs

Each sample is a complete `config.json`. Replace every `PASTE_...` value with your QA value
before you use it. `./pithead apply` refuses a `PASTE_` or `YOUR_` value in any field and names
the key (#3098); after filling a sample, `grep -n PASTE_ config.json` should still print nothing.
Every key is documented in [Configuration](../configuration.md).

When a step says to set or add a key inside a block (for example "add `"rpc_lan_access": true`
inside the `monero` block"), edit that block in the existing `config.json`. Never paste a second
block with the same name: apply refuses a duplicated key at any depth and names it (#3098). After
any hand edit, run this check, which finds the same fault before apply does. It prints
`config.json OK`, or lists the keys when a block is duplicated, or fails on a syntax error:

```bash
python3 -c 'import json; json.load(open("config.json"), object_pairs_hook=lambda kv: exit("duplicate key: " + str([k for k, _ in kv])) if len(kv) != len(dict(kv)) else dict(kv)); print("config.json OK")'
```

**Config A — defaults.** This is `config.minimal.json` with QA addresses: the file a hand-written
install starts from. The wizards no longer write its `stratum_password` line: a new install has no
stratum password unless the user opts in (#3092).

```json
{
    "monero": { "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS" },
    "tari": { "wallet_address": "PASTE_QA_TARI_ADDRESS" },
    "p2pool": { "stratum_password": "auto" }
}
```

**Config B — everything on.** Login, browser configuration, Telegram with commands, stratum TLS,
on-chain payout confirmation for both chains (Tari needs only the view key: the spend key is read
from the dual-key address, #3096), energy prices, and the dashboard as a Tor onion (which needs a
dashboard password of 16 characters or more; make one up for QA).

```json
{
    "monero": {
        "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS",
        "view_key": "PASTE_QA_MONERO_PRIVATE_VIEW_KEY"
    },
    "tari": {
        "wallet_address": "PASTE_QA_TARI_ADDRESS",
        "view_key": "PASTE_QA_TARI_PRIVATE_VIEW_KEY"
    },
    "p2pool": { "pool": "mini", "stratum_password": "auto", "stratum_tls": true },
    "dashboard": {
        "auth": { "username": "admin", "password": "PASTE_QA_DASHBOARD_PASSPHRASE" },
        "control": { "enabled": true },
        "onion": { "enabled": true, "client_auth": true },
        "energy": { "cost_per_kwh": 0.25, "currency": "USD" }
    },
    "telegram": {
        "enabled": true,
        "bot_token": "PASTE_QA_BOT_TOKEN",
        "chat_id": "PASTE_QA_CHAT_ID",
        "commands": { "enabled": true }
    }
}
```

**Config C — small miner, Monero only.** No Tari merge-mining, the `nano` sidechain for low
hashrate, and no XvB raffle. The Tari address stays in the file so Tari can be turned back on by
changing `mode` alone.

```json
{
    "monero": { "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS" },
    "tari": { "mode": "off", "wallet_address": "PASTE_QA_TARI_ADDRESS" },
    "p2pool": { "pool": "nano", "stratum_password": "auto" },
    "xvb": { "enabled": false },
    "dashboard": {
        "auth": { "username": "admin", "password": "PASTE_QA_DASHBOARD_PASSWORD" },
        "control": { "enabled": true }
    }
}
```

**Config D — two machines sharing one Monero node.** The node machine (the upgrade box) lets its
LAN use its Monero node; the second machine mines against it. Put the node machine's LAN address
in `host`, and copy `node_username`/`node_password` from the node machine's `config.json`.

On the node machine, add these two keys inside the existing `monero` block:

```json
"rpc_lan_access": true,
"zmq_lan_access": true
```

On the second machine, use this complete file:

```json
{
    "monero": {
        "mode": "remote",
        "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS",
        "node_username": "PASTE_FROM_NODE_MACHINE",
        "node_password": "PASTE_FROM_NODE_MACHINE",
        "remote": { "host": "192.168.1.10", "rpc_port": 18081, "zmq_port": 18083 }
    },
    "tari": { "mode": "off", "wallet_address": "PASTE_QA_TARI_ADDRESS" },
    "p2pool": { "stratum_password": "auto" },
    "dashboard": {
        "auth": { "username": "admin", "password": "PASTE_QA_DASHBOARD_PASSWORD" },
        "control": { "enabled": true }
    }
}
```

### Broken configs

Make one change at a time to a working config, run `./pithead apply`, check the refusal, and undo
the change before the next row. Each one must stop before anything changes, print a message that contains the text in the second
column, and leave the running stack untouched.

| Change | The message contains |
|---|---|
| Delete one closing `}` | `is not valid JSON` |
| Set `monero.wallet_address` to the QA **subaddress** (starts with `8`) | `is a SUBADDRESS (starts with 8)` |
| Swap two different neighbouring characters in the middle of `monero.wallet_address` | `fails its checksum` |
| Swap two different neighbouring characters in the middle of `tari.wallet_address` | `tari.wallet_address fails its checksum` |
| Set `p2pool.pool` to `"large"` | `p2pool.pool must be "main", "mini", or "nano"` |
| Set `tari.mode` to `"maybe"` | `tari.mode must be "local", "remote" or "off"` |
| Set `monero.mode` to `"cloud"` | `monero.mode must be "local" or "remote"` |
| Set `p2pool.stratum_password` to `"has space"` | `p2pool.stratum_password must be "auto", empty, or 1–128 chars` |
| Add `"proxy": { "donate_level": 150 }` | `proxy.donate_level must be an integer 0–99` |
| Set `dashboard.auth.password` to `"short"` | `dashboard.auth.password must be 8–128 printable characters` |
| Set `dashboard.onion.enabled` to `true` and the password to `"fifteen-chars-x"` (15 characters) | `must be at least 16 characters when dashboard.onion.enabled is true` |
| Set `dashboard.onion.enabled` to `true` and the password to `"changeme-but-longer"` | `contains a well-known weak pattern` |
| Add a second top-level `"p2pool"` block below the first, for example `"p2pool": { "pool": "nano" }` | A refusal that names the duplicated key and says where it is, for example `duplicate key "p2pool" at the top level` |
| Add a second `"wallet_address"` line inside the `monero` block | A refusal that names `monero.wallet_address` as a duplicated key |
| Set `dashboard.auth.password` to `"PASTE_QA_DASHBOARD_PASSWORD"` | A refusal that names `dashboard.auth.password` as a placeholder and does not print the value |
| Set `telegram.bot_token` to `"your_bot_token"` and `telegram.enabled` to `true` (lower case: the check ignores case) | A refusal that names `telegram.bot_token` as a placeholder |
| Set `dashboard.onion.enabled` to `true` in a config with no `dashboard.auth` block | `dashboard.onion.enabled is true but dashboard.auth.password is empty` |

---

## Route coverage

Pithead ships two ways: the self-hosted (DIY) Compose stack, driven by `./pithead` and
`config.json`, and the appliance, driven by its setup page, dashboard, boot menu and USB stick.
Every feature is checked on both routes, or the table says why one route has nothing to check.
Sections 1–12 are written for the DIY route; section 13 runs the appliance route and repeats the
DIY steps that apply there.

| Feature | Self-hosted (DIY) | Appliance |
|---|---|---|
| Install | 1.1–1.9, 1.4a | 13.1–13.7, 13.6a, 13.7a |
| First sync and Sync Mode | 1.6–1.13 | 13.8 (repeats 1.8 and 1.13) |
| Upgrade from the previous release | 2.1–2.4, 12.1–12.2 | 12.3, 13.10 |
| Everyday commands | 3.1–3.7 | No shell. The health check and recent log (7.7, through 13.8) and the boot menu (13.9) stand in. |
| Miners | 4.1–4.5 | 13.8 (repeats section 4), 14.1–14.4 |
| Mining on the stack machine itself | 6.9 | 13.8 (the built-in miner), 13.8a |
| Dashboard | 5.1–5.12 | 13.8 (repeats section 5) |
| Settings | 6.1–6.10, 7.1–7.9 | 13.8 (repeats 7.1–7.9), 13.15, 13.23, 13.24 |
| Alerts and Telegram | 8.1–8.7 | 13.8 (repeats 8.2–8.4) |
| Privacy and Tor | 1.10, 9.1–9.8 | 9.6a, 13.20, 13.21 |
| Node and pool modes | 10.1–10.7 | 13.15, 13.22 |
| Backup and restore | 11.1–11.4, S5 | 13.13, 13.14, 13.14a |
| Resets and removal | 11.5–11.7 | 15.2, 15.3 |
| Power loss | S3 | 13.19 |
| Machine name | 1.4 (the hostname prompt) | 15.1 |
| Headless setup and recovery | Not applicable: a DIY host has its own shell. | 13.16, 13.17, 13.23 |
| Rigs | Not applicable: a DIY rig is a RigForge install, tested in that project. | 14.1–14.4 |

## Re-cut coverage

Which steps prove each issue the 2.0.0 re-cut fixed or added. **Shipped** means the **Expect**
lines quote merged code; every row is shipped.

| Issue | What it requires | Steps | Wording |
|---|---|---|---|
| [#3090](https://github.com/p2pool-starter-stack/pithead/issues/3090) | `setup`, `up` and `apply` always print the pool URL and the stratum password (`none set` when there is none); a toggle-only `apply` still converges the local miner | 1.4, 1.5, 6.9, 13.8a | Shipped (#3101) |
| [#3091](https://github.com/p2pool-starter-stack/pithead/issues/3091) | A required Tari rejects workers only after its RPC has been unreachable 10–15 minutes (15 shipped); migrating, starting and syncing only alert; Tari alerts ignore `tari_required`; an unreachable Monero node, local or remote, always rejects | 1.12, 2.3a, 8.5, 10.5, 10.6 | Shipped (#3093) |
| [#3092](https://github.com/p2pool-starter-stack/pithead/issues/3092) | The stratum password is opt-in (default off) in both wizards and shows on the hand-off card, in **Connect a miner** and in CLI output, also on a LAN dashboard with no login; an onion dashboard always has a login | 1.4, 1.4a, 5.12, 10.7, 13.6, 13.6a, 13.8, last row of [Broken configs](#broken-configs) | Shipped (#3107) |
| [#3094](https://github.com/p2pool-starter-stack/pithead/issues/3094) | Enabling Tari on a box that is already mining keeps Monero mining while Tari syncs | 10.2, 13.22 | Shipped (#3102) |
| [#3096](https://github.com/p2pool-starter-stack/pithead/issues/3096) and [#2732](https://github.com/p2pool-starter-stack/pithead/issues/2732) | One view-only wallet per (address, view key), adopted on upgrade; a fresh wallet starts near the tip; a key that does not match the address is refused; Tari confirmation needs a dual-key address and asks for the view key only | 2.3, 6.4a, 6.4b, 7.5 | Shipped (#3113) |
| [#3097](https://github.com/p2pool-starter-stack/pithead/issues/3097) | A payout-address change is confirmed by typing its last 8 characters, everywhere | 6.4, 7.5, 13.8 | Shipped (#3105) |
| [#3098](https://github.com/p2pool-starter-stack/pithead/issues/3098) | `apply` and the dashboard refuse duplicate JSON keys and `PASTE_` or `YOUR_` values | [Broken configs](#broken-configs), 6.5, 7.6 | Shipped (#3106) |
| [#3099](https://github.com/p2pool-starter-stack/pithead/issues/3099) | New-install defaults in both wizards: Tari by disk, XvB off and not asked, a generated dashboard login, Tor first sync with an opt-in fast sync that warns; upgrades keep their config | 1.4, 1.4a, 2.3, 7.3a, 13.6, 13.6a | Shipped (#3110) |
| [#3109](https://github.com/p2pool-starter-stack/pithead/issues/3109) | A read-only `config_version` stamp, shown but not editable; a newer config warns; a restore of a newer config is refused; the 1.x release-notes line | 1.4a, 2.3, 6.10, 7.1, 7.1a, 11.2a, and the 1.x note in section 2 | Shipped (#3114) |
| [#3112](https://github.com/p2pool-starter-stack/pithead/issues/3112) | Docs for getting the view keys from the Monero GUI wallet and Tari Universe | 7.9 | Shipped (#3168) |
| [#3100](https://github.com/p2pool-starter-stack/pithead/issues/3100) | Appliance docs corrections | 12.3, 13.10, 13.21, 13.25, 15.1 | Shipped (#3104) |
| [#3116](https://github.com/p2pool-starter-stack/pithead/issues/3116) | The image pins RigForge at the develop tip that becomes v1.18.0 | 13.7a, 13.8, 14.1 | Shipped (#3117) |
| [#3118](https://github.com/p2pool-starter-stack/pithead/issues/3118) | Tor recovers from a saturated circuit-build state: early alert, self-heal under `tor.auto_heal`, advice and doctor name `tor-recover` | 9.6a | Shipped (#3120) |

No step re-points Tari at another node (#3094) or changes a Tari payout address (#3097): both need
equipment that [What you need](#what-you-need) does not list, a second Tari node and a second Tari
QA wallet.

## 1. Fresh DIY install

Run on the **fresh box**. This tests the path a new user takes, from an empty machine to a
syncing stack. Build the candidate from source so a failure here does not spend the version tag.

- [ ] **1.1 Get the candidate.** Do: on a fresh Ubuntu, install the build tools first:

  ```bash
  sudo apt update && sudo apt install -y git make
  git clone https://github.com/p2pool-starter-stack/pithead.git
  cd pithead
  git checkout <full candidate SHA>
  make
  ```

  Expect: `make` finishes without errors, and `./pithead version` prints
  `pithead dev (... @ <short SHA>, VERSION <the version being released>)`.
- [ ] **1.2 Help and typos.** Do: run `./pithead help`, then `./pithead bogus`, then
  `./pithead up down`. Expect: help lists every command with a one-line description;
  `bogus` prints `Unknown command: bogus. Run './pithead help'.`; `up down` is refused with
  `Invalid chain` and `Nothing was run.`
- [ ] **1.3 Before setup.** Do: `./pithead status`. Expect: `No .env found. Run './pithead setup' first.`
- [ ] **1.4 Setup wizard.** Do: `./pithead setup` with no `config.json` present. At the payout
  prompt paste the QA **subaddress** first, then the primary address. Answer: local Monero node,
  pool `mini`, the Tari default and, if it asks, the Tari address, the default (off) at
  `Enable stratum password?`, decline the faster first sync, decline Tor dashboard access, decline
  Telegram, decline local mining, and accept the default at `Enter Hostname`. Answer `y` to
  `Modify GRUB for persistent HugePages now?`. Expect: the subaddress is refused with an
  explanation and you are asked again. Per #3099, #3092 and #3090:

  - Tari is on when the disk fits both chains and off when it does not, and the wizard says
    which; on a fitting disk it asks for the Tari address.
  - The wizard does not ask about the XvB raffle and leaves it off.
  - It generates a dashboard login and shows it once (save it for 1.8).
  - It keeps the first sync on Tor unless you opt in. The fast-sync offer covers each chain the
    stack runs locally and warns that it exposes your IP to the Monero network and, if Tari is
    on, the Tari network.
  - At the end it prints the LAN pool URL and says `none set` for the stratum password.

  Setup also checks dependencies, warns (but does not stop) if
  disk or RAM is below the documented floor, writes `config.json`, provisions Tor, and ends with
  `System optimization requires a reboot.` and the commands to run next. If setup does not ask
  about GRUB (HugePages are already persistent), it asks `Start Pithead now? (Y/n)` instead:
  answer `y` and skip the reboot in 1.5. Run `ls -l config.json`: it is `-rw-------`. On a
  machine where setup has just installed Docker, it may stop first with
  `Docker daemon is not reachable` and tell you to join the `docker` group: run
  `sudo usermod -aG docker $USER`, log out and back in, and run `./pithead setup` again.
- [ ] **1.4a The wizard wrote the new-install defaults.** Do: run
  `jq '{xvb, tari_mode: .tari.mode, stratum_set: ((.p2pool.stratum_password // "") != ""), dashboard_login: (.dashboard.auth.password // "" | length > 0), fast_sync: [.monero.clearnet_initial_sync, .tari.clearnet_initial_sync]}' config.json`.
  It prints booleans and modes only, never a secret. Expect, per #3099 and #3092: `"xvb": { "enabled": false }`, `tari_mode` `local` on a fitting disk and `off`
  otherwise, `stratum_set` `false`, `dashboard_login` `true`, and both `fast_sync` entries `false`
  or `null`. `jq -r .config_version config.json` prints the candidate's release number (2.3
  explains the stamp).
- [ ] **1.5 HugePages reboot.** Do: `sudo reboot`, then `./pithead up`. Expect: the stack starts,
  and this first start prints a short note that the miner is held until both chains sync. A
  later `./pithead restart` does not print the note again. Per #3090, `up` also prints the LAN pool
  URL and `none set` for the stratum password, every time.
- [ ] **1.6 Status while syncing.** Do: `./pithead status`. Expect: each node and support service
  shows a `✓` line ending in `running`; `p2pool` and `xmrig-proxy` show `⚠` with
  `held until the required chains finish syncing`; under
  `Chain sync in progress — the miner is held until it completes:` each chain shows its percent
  and blocks remaining. No `✗` line.
- [ ] **1.7 Doctor.** Do: `./pithead doctor`. Expect: a readable report with no FAIL line. It
  includes `Tor-only egress firewall is installed`. Any WARN line names a fix you can follow.
  Then `./pithead doctor --json | python3 -m json.tool`: valid JSON with the same checks.
- [ ] **1.8 Sync Mode in the browser.** Do: on the laptop open the URL setup printed
  (`https://<hostname>`). Expect: a one-time certificate warning (accept it), then the login,
  then the **Sync Mode** screen with a progress line per chain and a held-miner notice. The
  top bar shows CPU, RAM, HugePages and disk.
- [ ] **1.9 Logs.** Do: `./pithead logs monerod` and `./pithead logs tari`, Ctrl-C to stop.
  Expect: the logs follow live and show the node syncing; no repeating error.
- [ ] **1.10 Faster first sync over clearnet.** Do: add `"clearnet_initial_sync": true` inside
  the `monero` block and `./pithead apply`. Expect: apply marks the change ⚠ and asks first;
  `./pithead status` then prints a `CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING` banner,
  `./pithead doctor` shows a WARN, and the dashboard shows a warning badge.
- [ ] **1.11 Leave it syncing.** Note the time. Check back every few hours; do 1.12 if you catch
  the moment Monero has finished and Tari has not, then 1.13 when both are synced.
- [ ] **1.12 Tari not required.** Only while Monero has finished its first sync and Tari has not:
  add `"tari_required": false` inside the `dashboard` block and apply. Expect: the miner starts
  without waiting for Tari, and the normal dashboard shows a `Tari syncing` indicator instead of
  the full-screen Sync view. Per #3091, a Tari node that is syncing is never treated as down: no
  worker is rejected for it while it catches up, whatever `tari_required` says, and no `Tari DOWN`
  badge shows. If the test chat is set up on this box, one message that starts
  `Tari node is syncing` arrives, once. Only an unreachable Tari node (10.5) can reject workers,
  and then only with `tari_required` true. Record SKIP if the timing never lines up.
- [ ] **1.13 Sync finishes.** Expect: once both chains are synced the dashboard shows the full
  operational view by itself (from Sync Mode, or from the `Tari syncing` indicator after 1.12)
  and the miner runs without anyone touching it. Monero returns to Tor by itself: the status
  banner is gone, and `./pithead doctor` reports `all node P2P is Tor-only`.

## 2. Upgrade from the previous release

Run on the **upgrade box**, which runs the previous release with synced chains. Before you start,
write down the payout addresses, the dashboard login, the dashboard's onion address if the onion
is on (`./pithead status` prints it), the worker count, whether XvB is on, Tari's mode, whether a
stratum password is set (`grep PROXY_STRATUM_PASSWORD .env` shows an empty value when none is),
whether payout confirmation is on (`monero.view_key` set), and a screenshot of the hashrate chart.

An upgrade from 1.x.x keeps `config.json` as faithfully as it can: a key the old file lacked
(`xvb.enabled`, `tari.mode`, `p2pool.stratum_password`, a dashboard login) behaves as it did on
1.x, because the new-install defaults of #3099 come only from the wizards. Config versioning
starts with 2.0.0 and has no 1.x migration (#3109). If the upgrade refuses or misreads a 1.x
config, the 2.0.0 release notes say so: a fresh setup may be required when upgrading from 1.x.x.
Record what broke, take a backup, run setup again, and carry on from 2.3 on the fresh config.

- [ ] **2.1 Backup first.** Do: `./pithead backup --with-chains`, as the 2.0.0 upgrading notes
  ask, because the Tari migration in 2.2 is one-way. Choose a passphrase and keep it in the private
  handoff, and answer `y` to `Stop the stack, back up, then start it again?`. Then move the archive
  off the box (a USB disk or a NAS) before 2.2: left in `backups/` on the data disk, it can take the
  free space the Tari migration needs, and 2.2 then refuses (2.2a). Keep a plain `./pithead backup`
  for 13.14a too; 2.1b says when to take it. Expect: a
  file `backups/pithead-backup-<date>-<time>.tar.gz.enc` exists; the stack was stopped for the
  copy and is running again.
- [ ] **2.1b 1.x config keys are migrated.** Do, on the previous release, after you took the notes
  above: if `dashboard.workers` already exists, record this upgrade session BLOCKED and keep the
  config unchanged; it already carries legacy workers this fixture must not overwrite. Otherwise note
  whether `workers.list` exists. If it does, save the output of
  `jq -c '.workers.list' config.json` with your private notes, including an empty `[]`.
  This output can contain rig addresses and tokens: never attach it publicly. Without applying, edit
  `config.json` and add a top-level `"xmrig_proxy": { "enabled": false }` (first delete `enabled`
  from the `xvb` block, if there is one). If there is no `workers.list`, add
  `"workers": [ { "name": "qa-1x-migration" } ]` inside the `dashboard` block. If there is a `telegram`
  block, add `"control": { "enabled": true }` inside it. Run the duplicate-key check from
  [Sample configs](#sample-configs). Now take a plain `./pithead backup`, copy it to the laptop
  (`scp`), and keep it, with its passphrase, for 13.14a. After the upgrade (2.2), run
  `jq '{xvb, workers, tc: .telegram.control}' config.json` and `ls config.json.bak-1x`.
  Expect: the first `./pithead upgrade` that runs (2.2a or 2.2) prints
  `[pithead] Migrated the 1.x config keys (dashboard.workers[] to workers.list[], xmrig_proxy.* to xvb.*) — the old copy is at config.json.bak-1x.`
  in all three cases (absent, empty or populated `workers.list`), and, with the `telegram` block, the warning
  `telegram.control was removed: the Telegram bot is read-only now.` The `jq` output shows
  `"enabled": false` under `xvb` and `"tc": null`. `qa-1x-migration` appears under `workers.list`
  only if this step added it. Otherwise `jq -c '.workers.list' config.json` matches the saved line
  byte for byte, whether the list was empty or populated;
  `config.json.bak-1x` exists. A later dashboard save (7.2) is not refused for a leftover key.
- [ ] **2.2a The upgrade refuses a Tari volume without room.** Upgrade box only, before 2.2, with
  the stack running (the `tari` container must exist). Do: run the first 2.2 commands, `git fetch`,
  `git checkout <full candidate SHA>` and `make`, but not `./pithead upgrade` yet. Find the node
  database: the `data.mdb` under `…/base_node/db/` inside the directory `tari.data_dir` names
  (`data/tari` when it is unset), with
  `sudo find <that directory> -path '*/base_node/db/data.mdb' -exec ls -l {} +`, and the free
  space on its volume with `df -BG <that directory>`. On that same volume, create a filler so that
  the free space drops below the size of `data.mdb` plus 5 GiB, for example
  `sudo fallocate -l <free − data.mdb size − 2>G <a directory on that volume>/qa-filler`, and run
  `df -BG` again to check. Run `./pithead upgrade` at once, then remove the filler at once. If the
  stack reports disk or write errors meanwhile, remove the filler first. If `./pithead upgrade`
  did not refuse, remove the filler immediately, touch nothing else, and go on with 2.3a: the
  migration has started. Expect: `./pithead upgrade` stops
  with `Refusing the upgrade: Tari 5 → 6 migrates the node database by writing a compacted copy beside the old one, which needs`,
  the GiB needed and free on the volume, and ends with `No container was changed.`; `docker ps`
  still shows the previous release's containers running. After the filler is gone, 2.2 goes ahead.
- [ ] **2.2 Upgrade.** Do, on a source checkout: `git fetch`, `git checkout <full candidate SHA>`,
  `make`, `./pithead upgrade`. On a release-bundle install, use the bundle command in
  [Operations › Updating the stack](../operations.md#updating-the-stack) once the candidate is
  published. Expect: it finishes without errors and recreates only what changed.
- [ ] **2.3 Nothing lost.** Do: compare the box with your notes, then run
  `jq -r .config_version config.json` and `ls -l config.json`. Expect: `./pithead version` shows
  the candidate; the dashboard login, payout addresses, onion address, and worker list match your
  notes, with `qa-1x-migration` as the one expected extra `workers.list` entry only if 2.1b inserted
  it. Otherwise the worker list matches your notes exactly. When 2.1b ran, XvB is
  off, because 2.1b deliberately set `xmrig_proxy.enabled` to `false`, which migrates to
  `xvb.enabled: false`; if that fixture was BLOCKED, XvB matches your original notes.
  Tari's mode and the stratum password setting are as you noted, because an
  upgrade keeps what it had (#3099); the hashrate chart still shows the history from before;
  Monero is still synced and the miners reconnected by themselves. Per #3109 the first `jq` line prints the candidate's
  release number without any `-pre` or build suffix, and `config.json` is still `-rw-------` with
  its owner unchanged. If payout confirmation was on before the
  upgrade, the payout card is green again with no rescan: #3096 adopts the old wallet as the one
  for your current address and view key. Tari reads loading, with
  no progress, until its one-way database migration ends (2.3a): that is expected for hours, not a
  failure.
- [ ] **2.3a Wait out the Tari migration and the fork rewind.** Do: right after 2.2, run
  `docker logs -f tari` and leave the box alone. Do not run any command that stops or recreates a
  container (`restart`, `down`, `up`, `apply`, `upgrade`, `backup`, a reboot): a stopped Tari
  container is killed one minute after the stop, and an interrupted migration loses the Tari
  database with no way back. `./pithead status`, `./pithead doctor` and `docker logs` only read,
  so they are safe. Note the times of
  `[MIGRATIONS] Blockchain database is at v6`, `v6: Starting JMT v1 → v2 rebuild`,
  `JMT rebuild complete`, `Compacting LMDB env`, and then the `[pithead fork-check]` lines. Look at
  the dashboard's Tari card and `./pithead status` every 30 minutes. Expect: for about two and a
  half hours the Tari card reads loading with no progress, and the log shows the phases in that
  order. When the migration ends, the fork check prints either
  `[pithead fork-check] header 350000 is canonical (…); nothing to rewind`, or `… dead 5.3.1 branch`
  followed by `stopping the node to rewind to 349900`, `rewound to …` and
  `starting the node normally`. No `[pithead fork-check] ERROR:` line appears. Tari then catches up
  to the tip, and the Tari card shows its progress again. Per #3091, a migrating or starting node
  is never down: `docker ps` shows `xmrig-proxy` running throughout, no `Tari DOWN` or
  `Workers rejected` badge shows, and if the box already has Telegram set up, a message that
  starts `Tari node is migrating` or `Tari node is starting` arrives instead.
- [ ] **2.4 Health after upgrade.** Run this only once 2.3a has ended and Tari is at the tip.
  Do: `./pithead status` and `./pithead doctor`. Expect: all healthy, no FAIL.

## 3. Everyday commands

Run on the upgrade box. Do not start this section until 2.3a is done: the Tari migration has
ended and Tari reports progress again.

- [ ] **3.1 Version.** Do: `./pithead version`, `./pithead -V`, `./pithead --version`. Expect: the
  same line three times, with no network wait.
- [ ] **3.2 Status exit code.** Do: `./pithead status; echo "exit=$?"`. Expect: `exit=0`. Then
  `docker stop dashboard` and run `./pithead status; echo "exit=$?"` again. Expect: the stopped service is flagged and the exit
  code is not 0. Run `./pithead up` and confirm everything is healthy again.
- [ ] **3.3 Restart.** Do: `./pithead restart`, then `./pithead restart tor`, then
  `./pithead restart monerod`. Expect: each finishes, and `./pithead status` is healthy afterwards.
- [ ] **3.4 Down and up.** Do: `./pithead down`, then `./pithead up`. Expect: all containers stop,
  then start; miners reconnect within a few minutes.
- [ ] **3.5 Chaining.** Do: `./pithead apply status`. Expect: apply runs, then status runs.
- [ ] **3.6 Tab completion.** Do: `source pithead-completion.bash`, type `./pithead doc` and press
  Tab. Expect: it completes to `doctor`. Type `./pithead logs`, a space, and press Tab twice: it lists the
  service names.
- [ ] **3.7 Support bundle.** Do: `./pithead support-bundle`, then open the archive it names.
  Expect: the archive is mode 600; it holds doctor output, a masked config and the last log lines.
  Search it for the dashboard password, the stratum password, and the bot token: none appear.
  Search the files under `logs/` for the Monero payout address and for `.onion` addresses: none
  appear, and `[redacted-address]` and `[redacted].onion` stand in their place. A Tari address in
  the body of a log line can survive; that gap is known and stated in the code.
  `config.masked.json` keeps the payout addresses in clear by design: they are not secrets there.

## 4. Connect a miner

Run on the upgrade box with the miner machine. Get the stratum password with
`grep PROXY_STRATUM_PASSWORD .env`. 4.2 needs one: if the value is empty (a box that never had
one; a new install has none unless its wizard was told to), add `"stratum_password": "auto"` inside
the `p2pool` block and `./pithead apply` first.

- [ ] **4.1 Plain stratum.** Do: point XMRig at the stack, using
  [Connecting Miners](../workers.md):

  ```json
  { "pools": [ { "url": "<stack IP>:3333", "user": "qa-rig-01", "pass": "<stratum password>" } ] }
  ```

  Expect: XMRig logs `accepted` shares within a few minutes, and `qa-rig-01` appears in the
  dashboard's **Workers Alive** table within a minute (the page refreshes every 30 seconds).
- [ ] **4.2 Wrong password.** Do: change `pass` to something wrong and restart XMRig. Expect: the
  stack rejects the miner; it does not appear in Workers Alive. Put the right password back.
- [ ] **4.3 TLS.** Do: set `"stratum_tls": true` inside the `p2pool` block, run `./pithead apply`, and copy the
  fingerprint it prints (also in `./pithead status`). Add `"tls": true` and
  `"tls-fingerprint": "<fingerprint>"` to the miner's pool entry. Expect: the miner connects over
  TLS and mines; a miner without `tls` keeps mining in cleartext on the same port.
- [ ] **4.4 Second worker.** Do: start a second miner with `"user": "qa-rig-02"`. Expect: two rows,
  and the total hashrate is about the sum of the two.
- [ ] **4.5 Worker drill-down.** Expect: each row shows IP, uptime, hashrate and accepted/rejected
  shares; a RigForge rig also shows its chips (thermals, governor) and version.

## 5. Dashboard tour

Run on the upgrade box, logged in from the laptop. See [The Dashboard](../dashboard.md) for what
each panel means.

- [ ] **5.1 Header.** Expect: hostname and IP, the version badge (the release version on release
  images; `dev · <branch> @ <commit>` on a source build), last-update time, and 1h/24h averages.
  No warning badge appears that the machine does not deserve.
- [ ] **5.2 Simple view.** Expect: the mine-cart strip, the KPI band (Total Hashrate, Shares in
  Window, Raffle Eligible, Blocks Found, XvB Tier, Mining Mode), the hashrate chart, Overview,
  Earnings, and Workers Alive. Every number is plausible: no `NaN`, no negative values, no
  forever-spinning placeholders.
- [ ] **5.3 Chart.** Do: click each range (1h, 24h, 1w, 1mo, all), change the averaging window,
  and toggle each legend item off and on. Expect: the chart redraws each time; nothing is blank.
- [ ] **5.4 Advanced view.** Do: switch to **Advanced**. Expect: the extra cards appear (P2Pool
  node and global stats, XvB, XMR Network, Tari Merge-Mining, Pool Cadence & Luck,
  **Stack Topology & Egress**, earnings calculator). Topology shows every route the config uses.
- [ ] **5.5 Preferences stick.** Do: change the theme, the view, the chart window and the worker
  sort, then reload the page. Expect: all of them are kept.
- [ ] **5.6 Live refresh.** Do: leave the page open for two minutes without touching it. Expect:
  the panels refresh in place about every 30 seconds; scroll position stays put.
- [ ] **5.7 Disconnected banner.** Do: with the page open, run `./pithead down`, wait 60 seconds,
  then `./pithead up`. Expect: a red `Disconnected — showing data from …` banner appears while the
  stack is down, then clears by itself once it is back, with no manual reload.
- [ ] **5.8 Phone.** Do: open the dashboard on the phone. Expect: one column, a stacked header,
  and a worker table that scrolls sideways. Nothing is cut off and nothing overlaps.
- [ ] **5.9 Light and dark.** Do: switch the laptop's system theme between light and dark.
  Expect: both are readable, including the chart and the images.
- [ ] **5.10 Login.** Do: open the dashboard in a private window and enter a wrong password,
  then the right one. Expect: the wrong one is refused, the right one lets you in.
- [ ] **5.11 Metrics.** Do: from the laptop, `curl -k -u admin:<dashboard password> https://<host>/metrics`.
  Expect: Prometheus text with `pithead_` lines, including `pithead_shares_accepted_total`.
  Without `-u`, the request is refused.
- [ ] **5.12 Connect a miner.** Do: signed in, find the **Connect a miner** block in the Simple
  view. Then open the dashboard in a private window and do not sign in. Expect, per #3092: signed in, the block shows the LAN pool URL (`<host>:3333`),
  the stratum password or the words `No stratum password`, and the TLS fingerprint when stratum
  TLS is on (4.3). The password matches `grep PROXY_STRATUM_PASSWORD .env`. Signed out, the
  private window shows the login and none of those values. A dashboard with no login shows the
  block to anyone on the LAN (10.7).

## 6. Change settings from the command line

Run on the upgrade box. Keep a copy of the working `config.json` (`cp config.json config.json.qa`)
and restore it at the end.

- [ ] **6.1 Preview only.** Do: change `p2pool.pool` to `nano` and run `./pithead apply --dry-run`.
  Expect: a `•` line `P2Pool sidechain changing ... your PPLNS window resets`, and nothing is
  recreated.
- [ ] **6.2 Ordinary change.** Do: `./pithead apply`. Expect: no question asked (a `•` change is
  not disruptive); p2pool is recreated and the dashboard shows the `nano` sidechain within a few
  minutes. Set the pool back and apply again.
- [ ] **6.3 Disruptive change asks first.** Do: add `"rpc_lan_access": true` to the `monero` block
  and run `./pithead apply`; answer `n`. Expect: the change is listed with `⚠`, then
  `Some of the changes above (⚠) are disruptive.` and a `(y/N)` question; `n` prints
  `Apply cancelled. No changes were made.` Remove the key again.
- [ ] **6.4 Payout change asks for the address.** Do: set `monero.wallet_address` to the second QA
  primary address and run `./pithead apply`. Run it three times, answering the prompt differently
  each time: wrong characters, then the first 8 characters of the new address, then its last 8
  (#3097). If `monero.view_key` is set on this box, change it to the second wallet's key in the
  same edit and do 6.4a with this step. Expect: the warning
  `The Monero payout wallet address is changing — ALL future Monero rewards go to the new address.`
  and the prompt `Confirm by typing the last 8 characters of the new address (<last 8>).` The
  wrong answer and the first 8 characters each cancel with no change; the last 8 apply. Put the
  original address back the same way.
- [ ] **6.4a Payout wallet follows the address and view key.** Needs `monero.view_key` set to the
  first QA wallet's key, as in Config B, and the payout card green on **Earnings**. Do: (1) set
  `monero.wallet_address` to the second QA primary address and leave the first wallet's view key,
  then run `./pithead apply`. (2) Set the second wallet's view key as well, apply, and type the
  last 8 characters. Watch the Earnings card. (3) Put both the address and the view key back,
  apply, and type the last 8 characters again. Expect, per #3096: (1) is refused before anything changes with
  `monero.view_key does not belong to monero.wallet_address: the public view key differs.`, followed
  by a pointer to the docs section on getting your view keys. (2) The preview reads `Payout
  confirmation view key CHANGED — a new view-only wallet is opened for this address (the previous
  one is kept).`; the card turns green after the new wallet catches up within minutes, because a
  fresh automatic wallet starts 100 blocks behind the local node's tip. (3) The first wallet
  reopens, and the card is green again with no rescan.
- [ ] **6.4b Tari payout confirmation needs a dual-key address and asks only for the view key.**
  Needs Config B's `tari` block (the address and `view_key`, no `spend_public_key`) and a green Tari
  payout card. Do: (1) set `tari.spend_public_key` to 64 zeros and run `./pithead apply`, then
  remove the key. (2) Set `tari.wallet_address` to the single-key Tari address, keep `view_key`,
  and apply. (3) Put the QA address back, apply, and type the last 8 characters if asked. Expect,
  per #3096 and #2732: the block in Config B is accepted without a spend key, because the public
  spend key is read from the address. (1) is refused with `tari.spend_public_key disagrees with
  tari.wallet_address. Leave it empty to derive the public spend key from the address.` (2) is
  refused with `Tari payout confirmation needs a dual-key address, which Tari Universe gives by
  default. A single-key address carries no public view key to check tari.view_key against. Mining
  payouts to single-key addresses remain supported.` (3) applies, and the card is green again with
  no rescan.
- [ ] **6.5 Broken configs.** Do: work through every row of [Broken configs](#broken-configs).
  Expect: each refusal matches, and `./pithead status` stays healthy throughout.
- [ ] **6.6 Render.** Do: `./pithead render`. Expect: it finishes and no container restarts.
- [ ] **6.7 Rotate secrets.** Do: `./pithead rotate-secrets` and confirm. Expect: it names what
  changes, keeps `.bak-` copies, and recreates the affected containers. If `p2pool.stratum_password`
  is `"auto"`, miners with the old password are now rejected; give each miner the new one from
  `.env` and they mine again. With a password you set yourself, the stratum password does not
  change.
- [ ] **6.8 Restore.** Do: `cp config.json.qa config.json && ./pithead apply`. Expect: the
  preview marks the node RPC login change ⚠ (6.7 rotated it) and asks `(y/N)`; answer `y`, and the
  original settings are back.
- [ ] **6.9 Mine on the stack machine.** Do: add `"local_miner": { "enabled": true }` as a
  top-level block and `./pithead apply`. Then run `./pithead apply` again with nothing changed.
  Expect, per #3090: the first apply changes no rendered setting,
  yet it still announces the local miner, and it prints the LAN pool URL and the stratum password
  (or `none set`) that a RigForge install on this machine needs (see
  [Connecting Miners](../workers.md)). The second apply reports no configuration changes and
  still prints the pool URL and the stratum password (or `none set`). On the appliance the toggle
  also starts or stops the built-in miner in the same apply (13.8a). If you install RigForge with
  those values, the worker appears in Workers Alive. Remove the block and apply again afterwards.
  Removing it does not uninstall RigForge; if you installed it, it stays as an extra worker in
  later sections.
- [ ] **6.10 A config newer than the code warns.** Do: note `jq -r .config_version config.json`,
  then edit `config.json` and change the `config_version` value to `"9.9.9"`. Run
  `./pithead render`, then `jq -r .config_version config.json`. Then put the noted value back by
  hand and run `./pithead render` again. Expect, per #3109: the
  first render exits 0 and warns `config.json was written by pithead 9.9.9; this is <version>.
  Settings added after <version> are ignored until you update.`; the stamp still
  reads `9.9.9` (a stamp is never rewritten downward); the second render prints no warning.
  7.1a shows the same condition in the dashboard.

## 7. Change settings from the dashboard

Run on the upgrade box. Inside its `dashboard` block, make sure `auth.password` is set and add
`"control": { "enabled": true }`, then `./pithead apply`. If the Configuration view was off, the
preview marks turning it on with ⚠ and asks `(y/N)`; answer `y`.

- [ ] **7.1 Configuration view.** Do: open **Configuration** from the toggle above the chart.
  Expect: a form with grouped sections and an Advanced JSON pane. Secrets show as
  "set — leave blank to keep", never their values. The config file version (`config_version`)
  shows as plain text, not as a field (#3109).
- [ ] **7.1a The config version is read-only.** Do: look for `config_version` in the Advanced JSON
  pane. Add `"config_version": "1.0.0"` at the top level of the pane, change an energy price in the
  form, click **Save & preview changes**, confirm, then run `jq -r .config_version config.json`.
  Next, DIY only: edit `config.json` by hand to `"9.9.9"` as in 6.10 and reload the Configuration
  view, then put the stamp back by hand. Expect, per #3109: the
  pane never shows `config_version`; the pasted value is ignored, so the preview has no row for
  it, the stamp on disk is unchanged and **Recent config changes** has no `config_version` row.
  With the stamp at 9.9.9 the view warns `This configuration was written by a newer Pithead
  version.` and says saving is blocked while it holds settings this version does not know.
- [ ] **7.2 Benign change.** Do: set an energy price, click **Save & preview changes**, then
  confirm. Expect: a preview with one row per changed setting; after confirming, the value shows
  on the Energy tab, survives a reload, and appears in **Recent config changes**.
- [ ] **7.3 Ordinary change.** Do: change the P2Pool sidechain to `nano`, preview, and confirm.
  Expect: no typing needed; it applies and the dashboard follows. Change it back.
- [ ] **7.3a Turn the XvB raffle on and off.** Do: in Configuration flip `xvb.enabled`, preview
  and confirm (type `APPLY` if asked), then flip it back the same way. Expect: the preview names
  the change; with XvB on, the five XvB raffle tiles show within a few minutes, and with it off
  they are gone (10.1). A new install leaves XvB off and never asks (#3099), so this panel is
  where a user turns it on.
- [ ] **7.4 Disruptive change.** Do: change the stratum port to `3334`, preview, and try to confirm
  without typing. Expect: the row is marked ⚠ and says every rig must repoint; the commit is
  refused until you type `APPLY`. After it applies, miners on 3333 disconnect. Change it back to
  `3333` the same way and confirm the miners reconnect.
- [ ] **7.5 Payout change.** Do: change the Monero payout address to the second QA primary
  address, and its view key too if `monero.view_key` is set. Expect: the change is marked ⚠; the
  confirmation asks you to type `APPLY` and the last eight characters of the new address (the
  command line asks for the same, 6.4, #3097), and a wrong suffix is refused. After it applies,
  the **Payout wallet changed** badge appears. Change it back. With a view key set, the preview
  refuses a key that does not belong to the new address with the same message as 6.4a (#3096).
- [ ] **7.6 Bad value.** Do: paste the QA subaddress into the Monero address field and preview.
  Then add a second top-level `"p2pool"` block in the Advanced pane and preview, and type
  `PASTE_QA_X` into the dashboard password field and preview. Expect: the subaddress is refused
  with the same message as the command line; the duplicated block and the placeholder are refused
  too, each naming the key, per #3098; nothing is applied.
- [ ] **7.7 Health check and log.** Do: click **Run health check**, then **Show recent log**.
  Expect: the doctor rows appear grouped with remedies; the log shows recent lines with
  credentials redacted.
- [ ] **7.8 Access log.** Expect: the **Access log** lists your recent requests and counts the
  wrong password from step 5.10.
- [ ] **7.9 Get the view keys from the docs alone.** Do: with only the two QA wallets open in the
  official Monero GUI wallet and in Tari Universe, and the payout-confirmation instructions in
  [The Dashboard](../dashboard.md) (the section on getting your view keys), find the Monero secret
  view key and restore height and the Tari view key and wallet birthday, with no other help. Enter
  them in Configuration's payout settings, preview and confirm. Then paste the Monero *public*
  view key into the Monero view key field and preview. Expect, per #3112: the docs name every menu
  or file you needed, and you never needed the spend key, the
  seed words or a wallet password; the matching values are accepted; the public key is refused
  with a message that points at the docs section, not at a label either wallet lacks. Write down
  every place you hesitated.

## 8. Alerts and Telegram

Run on the upgrade box. Add Config B's `telegram` block to its `config.json` as a top-level block
(replace the existing `telegram` block if there is one), fill in the bot token and chat id, and
`./pithead apply`. See [Telegram](../telegram.md).

- [ ] **8.1 Test alert.** Do: `./pithead test-alert`. Expect: one marked test message arrives in
  the test chat, and the command reports each sink's result without printing the token.
- [ ] **8.2 Commands.** Do: send `/help`, `/status`, `/info`, `/hashrate`, `/workers`, `/sync`,
  `/system`, `/pool`, `/xvb`, `/earnings` and `/luck`. Expect: each gets a reply, and the numbers
  agree with the dashboard. Then send `/restart` and `/apply`, which 2.0.0 removed. Expect: each
  gets `Unknown command.` and the help text; nothing restarts or applies (`docker ps` uptimes are
  unchanged, and **Recent config changes** has no new row).
- [ ] **8.3 Other chats are ignored.** Do: message the bot from a chat that is not configured.
  Expect: no reply.
- [ ] **8.4 Worker offline.** Do: stop `qa-rig-02` and wait 6 minutes. Expect: a worker-offline
  message after about 5 minutes, and the row badged offline on the dashboard. Start it again:
  a back-online message about 2 minutes after it reconnects.
- [ ] **8.5 Node down.** Do: `docker stop monerod` and wait 2 minutes. Expect: the dashboard shows
  the `monerod DOWN` badge after about 90 seconds, then a `Workers rejected` badge, and a node-down
  message arrives (`Monero node is DOWN — workers failing over to backup pools.`). xmrig-proxy is
  stopped, so XMRig logs that it lost the pool (with a backup pool in its config it would switch
  to it). Run `./pithead up`: the badges clear, a node-recovered message arrives
  (`Monero node recovered — workers readmitted.`), and the miners reconnect. Monero always alerts
  and always rejects, local or remote (10.6). The Tari outage alert, which does not depend on
  `tari_required` (#3091), is checked in 10.5.
- [ ] **8.6 Daily summary.** Do: set `telegram.daily_summary_time` a few minutes ahead and apply.
  Expect: the summary arrives at that time with 24h hashrate and earnings.
- [ ] **8.7 Stack online.** Do: `./pithead restart`. Expect: one "Pithead online" message when the
  dashboard is back.

## 9. Privacy and Tor

Run on the upgrade box. See [Privacy](../privacy.md).

- [ ] **9.1 Egress firewall.** Do: `./pithead doctor`. Expect:
  `Tor-only egress firewall is installed` and `Tor clearnet egress works`.
- [ ] **9.2 Survives a reboot.** Do: reboot the machine and wait for the stack. Run
  `./pithead doctor` again. Expect: the same two lines, with no warning that the firewall will
  not survive a reboot.
- [ ] **9.3 Topology panel.** Expect: **Stack Topology & Egress** shows unselected clearnet routes
  as blocked, and the header shows no firewall warning.
- [ ] **9.4 Onion dashboard.** Do: inside the `dashboard` block add
  `"onion": { "enabled": true, "client_auth": true }` (the dashboard password must be 16 or more
  characters) and `./pithead apply`; the preview marks it ⚠ and asks `(y/N)`, so answer `y`. Copy
  the `.onion` address from
  the dashboard header and get the key with `./pithead onion-client-key`. In Tor Browser open
  `http://<address>.onion`, accept the certificate prompt, and paste the bare key when asked.
  Expect: the dashboard login appears; the same login works. Without the key, the address does
  not load at all.
- [ ] **9.5 Rotate the onion.** Do: `./pithead rotate-dashboard-onion`. Expect: a new address
  and key are printed; the old address stops working; the new one works with the new key.
- [ ] **9.6 Tor recovery check.** Do: `./pithead tor-recover check`. Expect: on a healthy
  machine it prints `Tor recovery refused: circuit history is not saturated.` and changes nothing.
  Do not run `tor-recover apply` on a healthy machine.
- [ ] **9.6a Tor recovers from a saturated circuit-build state (#3118).** Where: on the second
  appliance, or on the soak appliance before `--start`, over SSH on the debug image; never inside
  the soak window. The DIY half, with `tor.auto_heal` off, runs on the upgrade box. This step
  stops Tor and cuts the stack's network for up to an hour, so set up the test chat first
  (section 8) and run nothing else meanwhile. Do: from the install directory (`cd /data/pithead`
  on the appliance), stop Tor first, because a state file moved under a running Tor is written
  straight back, then seed the saturated history and cut Tor's network:

  ```bash
  T=$(grep '^TOR_DATA_DIR=' .env | cut -d= -f2-)
  docker compose stop tor
  sudo cp -p "$T/state" "$T/state.qa-orig"
  sudo sh -c "grep -v -e '^CircuitBuildTimeBin ' -e '^TotalBuildTimes ' -e '^CircuitBuildAbandonedCount ' '$T/state.qa-orig' > '$T/state.qa-new'; printf 'TotalBuildTimes 1000\nCircuitBuildAbandonedCount 1000\n' >> '$T/state.qa-new'; cat '$T/state.qa-new' > '$T/state'; rm '$T/state.qa-new'"
  docker compose start tor
  docker exec tor sh -c 'c=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie | tr -d "\n"); printf "AUTHENTICATE %s\r\nSETCONF DisableNetwork=1\r\n" "$c" | nc -w 3 127.0.0.1 9051'
  ```

  Then wait, watching the test chat, **Stack Topology & Egress** and the Monero card. Expect, per
  #3118:

  - The last command prints `250 OK` twice. The stack loses its circuits, as in the real outage.
  - Within about 20 minutes one alert says Tor's circuit history is saturated. The Monero card's
    advice names `./pithead tor-recover check` as well as restarting monerod.
  - With `tor.auto_heal` on (the appliance default), the heal's last step resets Tor through
    tor-recover, within about an hour, and an alert says that it did and why.
    `$T/state.backup.<timestamp>` exists and still holds the two `1000` lines; the new `$T/state`
    lacks them; the P2Pool onion address is unchanged; Tor is healthy again; monerod regains
    outgoing peers and its height catches up.
  - A second saturation within 6 hours is refused by the persistent cooldown, and an alert says
    so. Repeat the block above without its `cp` line: no new `state.backup.<timestamp>` appears.
    To end the test, stop Tor, copy `state.qa-orig` back over `state` with
    `sudo sh -c "cat '$T/state.qa-orig' > '$T/state'"`, and start Tor.
  - DIY with `tor.auto_heal` off: nothing resets Tor by itself, however long you wait.
    `./pithead doctor` FAILs the circuit-history check and names `./pithead tor-recover check`.
    `./pithead tor-recover check`, then `./pithead tor-recover apply`, recovers it, and
    `state.backup.<timestamp>` exists afterwards.
- [ ] **9.7 Public IP warning.** If the test network gives the box a public IP: Expect: setup and
  doctor warn that stratum port 3333 is exposed.
- [ ] **9.8 Missing egress firewall.** DESTRUCTIVE: it opens clearnet egress until `up`. Run it
  only on the upgrade box, never on a production box or the soak box. Do: with Telegram set up
  from section 8 and no `*_lan_access` key on yet (10.3 comes later), run
  `sudo iptables -F DOCKER-USER`. Wait 5 minutes, then look at the dashboard header, **Stack
  Topology & Egress** and the test chat, and run `./pithead doctor`. Then run `./pithead up` and
  wait 5 minutes. Expect: within about 4 minutes the dashboard shows
  `Tor-only egress firewall MISSING on the host`, and exactly one alert arrives that starts
  `Tor-only egress firewall MISSING on the host — clearnet egress is NOT fail-closed.` doctor FAILs
  with `Tor-only egress firewall is MISSING while the stack runs`. Nothing reinstalls the rules by
  itself. After `./pithead up`, a second alert says `Tor-only egress firewall restored`, the
  warning clears, and doctor again prints `Tor-only egress firewall is installed`.

## 10. Node and pool modes

- [ ] **10.1 Monero only.** Do: on the fresh box, replace `config.json` with Config C (same
  dashboard password as before) and `./pithead apply`. Expect: the preview marks
  `Tari merge-mining OFF` with `⚠`, says its chain data is kept, and asks `(y/N)`; answer `y`.
  Afterwards no `tari` container runs,
  mining continues, and the five XvB raffle tiles are gone from the dashboard.
- [ ] **10.2 Back to Tari.** Do: set `tari.mode` back to `local` and apply, then watch `docker ps`
  and a miner's log while Tari catches up. Expect: the preview marks `Tari merge-mining ON` with
  `⚠` and asks `(y/N)`; answer `y`. Per #3094 its row says that Monero mining continues and that
  merge-mining starts when Tari has synced (on an already-mining machine). The Tari node resumes
  from the chain it already had instead of starting from zero. `xmrig-proxy` and p2pool stay up,
  the miners keep hashing, no `Workers rejected` badge shows, and the Tari card reads syncing until
  Tari is at the tip. Only a first install waits for both chains.
- [ ] **10.3 Remote Monero node.** Do: on the upgrade box (the node machine), add the two Config D
  keys inside its `monero` block and apply; the preview flags them ⚠ and asks first. On the fresh
  box (the second machine), replace `config.json` with Config D's second-machine file and apply;
  the node endpoint change is also marked ⚠ and asks `(y/N)`. Expect: on the second machine no monerod container runs, the dashboard says the node is remote, the topology
  labels it LAN, and mining works.
- [ ] **10.3a The LAN-published node survives a reboot.** Do: on the node machine (with the 10.3
  keys on), run
  `systemctl is-enabled pithead-lan-guard.service pithead-lan-hold.service pithead-egress.service`
  and `docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' monerod`. Then `sudo reboot` and
  touch nothing. When it is back, look at the second machine's dashboard. Then, on the node
  machine, run `docker kill monerod`, wait 5 minutes, run `./pithead doctor`, and finally
  `./pithead up`. Expect: all three units are `enabled`, and the restart policy is `no`. After the
  reboot monerod starts by itself, without `./pithead up`, and the second machine reconnects and
  mines within minutes. After `docker kill`, Docker does not restart monerod; doctor and the
  dashboard say that it is down, and the node-down alert arrives. `./pithead up` brings it back,
  and the second machine mines again.
- [ ] **10.4 Bad remote node.** Do: on the second machine, with the Configuration view on, change
  the Monero node host to a LAN address where nothing listens and click
  **Save & preview changes**. Expect: refused with a reason that names the problem (nothing
  answering), and nothing is applied. Repeat with a public IP address: refused because the
  firewall allows only private addresses. Repeat with a misspelt hostname: reported as a name
  that does not resolve, not as a firewall problem.
- [ ] **10.5 Tari outage.** Do: on the upgrade box, with `dashboard.tari_required` at its default
  (`true`), `docker stop tari` and wait 20 minutes, watching the dashboard, the test chat and a
  miner's log. Run `./pithead up`. Then add `"tari_required": false` inside the `dashboard` block,
  apply, and repeat. Expect, per #3091: with `tari_required` true, the Tari panel reports the node
  unreachable within minutes and the miners keep mining at the 10-minute mark. After 15 minutes of
  unreachable Tari RPC the `Tari DOWN` and `Workers rejected` badges show, a node-down alert
  arrives, and the workers are rejected (xmrig-proxy is stopped, so XMRig logs that it lost the
  pool). After `./pithead up` and 60 seconds of confirmed reachability the workers are readmitted
  and mine again, and a node-recovered alert arrives. With `tari_required` false the `Tari DOWN`
  badge and the alert arrive at the same 15 minutes, but no worker is rejected: the miners keep
  mining Monero throughout and xmrig-proxy stays up. If the alert text says that workers are
  failing over to backup pools while `tari_required` is false, file it: they are not. Remove the
  key afterwards.
- [ ] **10.6 Remote Monero node outage.** Do: with the second machine on Config D (10.3) and a
  miner pointed at it, run `docker stop monerod` on the node machine and wait 5 minutes. Look at
  the second machine's dashboard and the miner's log. Then run `./pithead up` on the node machine.
  Expect, per #3091: an unreachable Monero node, local or remote, always rejects workers, so the
  second machine shows the `monerod DOWN` and `Workers rejected` badges, stops its xmrig-proxy,
  and XMRig logs that it lost the pool. After `./pithead up` on the node machine, the workers are
  readmitted and mine again.
- [ ] **10.7 A dashboard with no login.** Do: on the fresh box, keep a copy of `config.json`,
  remove its `dashboard.auth` and `dashboard.control` blocks, and `./pithead apply`; answer `y` to
  what it asks. Open the dashboard in a private window, then put the copy back and apply. Expect,
  per #3092: no login prompt appears, and the **Connect a miner**
  block shows the LAN pool URL and the stratum password, or `No stratum password`, to anyone on
  the LAN (the owner accepts that risk). A dashboard published as an onion always has a login: the
  last row of [Broken configs](#broken-configs) is that refusal.

## 11. Backup, restore and resets

Run on the upgrade box unless stated. The steps are destructive; run them in this order.

- [ ] **11.1 Encrypted backup.** Do: `./pithead backup`. Expect: a `.tar.gz.enc` file under
  `backups/`, mode 600.
- [ ] **11.2 Wrong passphrase.** Do: `./pithead restore backups/<file>` with a wrong passphrase.
  Expect: refused before anything changes.
- [ ] **11.2a A backup from a newer version is refused.** Do: edit `config.json` and set
  `config_version` to `"9.9.9"` as in 6.10, run `./pithead backup`, and put the stamp back by hand.
  Then run `./pithead restore backups/<that newest file>` with the right passphrase. Do not use
  that archive in 11.3. Expect, per #3109: the restore is refused
  before anything is promoted, with `This backup's configuration was written by pithead <stamp>;
  this machine runs <version>. Update to <stamp> or later, then restore.`; `config.json`, the data
  and the running stack are unchanged.
- [ ] **11.3 Restore.** Do: change the energy price in the dashboard, then restore the backup with
  the right passphrase. Expect: the energy price is back to its earlier value, the onion address
  and login are unchanged, and the hashrate history is there.
- [ ] **11.4 Dashboard backup.** Do: in the dashboard open **Backup** and make a backup. Expect:
  the archive downloads and the passphrase is shown once. Save both.
- [ ] **11.5 Reset dashboard data.** Do: `./pithead reset-dashboard` and confirm. Expect: the
  dashboard history starts from zero; chains, wallets and config are untouched; mining continues.
- [ ] **11.6 Config reset.** Do on the **fresh box**: `./pithead config-reset`. Expect: you must
  type to confirm; `config.json` is removed; running `./pithead setup` asks the setup questions
  again and the chains are reused, with no resync.
- [ ] **11.7 Uninstall.** Do on the **fresh box**, last: `./pithead uninstall`. Expect: you must
  type to confirm; it prints what it removed, what it kept (`config.json`, `backups/`, the data
  directories), and the exact command to delete the rest. `docker ps` shows no Pithead
  containers. Running `./pithead setup` again brings the stack back on the kept data.

## 12. Upgrade from the dashboard

Needs the published release, so do it during [After publishing](#after-publishing): 12.1 and 12.2
on a DIY box that still runs the previous release with `dashboard.control.enabled: true` (the
upgrade box no longer does after 2.2; after 11.7, install the previous release's bundle on the
fresh box), 12.3 on an appliance that runs the previous release.

- [ ] **12.1 Badge.** Expect: the header shows `New release vX.Y.Z available` linking to the
  release, and an **Upgrade to vX.Y.Z** button.
- [ ] **12.2 Upgrade.** Do: click it and type `UPGRADE`. Expect: the page disconnects briefly,
  comes back on the new version, and the badge clears. Config, wallets and chains are unchanged.
- [ ] **12.3 Appliance OS update.** Skip it, recording SKIP, when the previous release shipped no
  appliance image, as for the first appliance release. Never on the soak box while it carries a
  soak. Do: in the header's **OS updates** control: Check, Download,
  Verify, Install, then Reboot (type `REBOOT`). Expect: Check offers the new release; mining keeps
  running until the reboot, but Install arms the spare slot, so any reboot boots the update (#3100)
  and the **Reboot** button expires 24 hours after Install; the page reconnects; a banner says it
  updated; the boot menu shows the new version as **current** and the old one as **previous**.

## 13. Appliance

Run on the **appliance box**. Each step names the battery row it serves (M1–M16, defined in
[appliance-release.md](appliance-release.md)); why the hands-on rows cannot be automated is in
[the hardware battery](#the-manual-hardware-battery-m1m10) below. Follow
[the appliance guide](../appliance.md) as a user would, and file anything you had to know rather
than read.

Steps 13.10–13.12 copy update bundles to the box over SSH, which only the debug image has (see
[Know which image you are holding](#know-which-image-you-are-holding)). Before 13.10, write the
debug image to the stick with the 13.1 commands (skip the `sha256sum` line if the debug image has
no `.sha256` file), boot the box from it, choose the same disk, and pick **Keep everything**. Reach it as `root` over SSH with the bench key from
the private handoff. After 13.12, write the release image to the stick and reinstall the same
way. Everything else runs on the release
image. The dashboard's own update path checks for
the latest *published* release, so it is tested after publishing, in 12.3. On a debug release
candidate, [the preface below](#testing-a-debug-rc-on-the-soak-box) overrides this paragraph:
every step already runs on the debug image, so there is no reinstall before 13.10 and none after
13.12.

The appliance's command line runs as `cd /data/pithead && ./pithead <verb>`, at the console or
over SSH. `/opt/pithead/pithead` changes into its own read-only directory before it reads
anything, so started from there it does not find this box's `config.json`.

### Testing a debug RC on the soak box

Read this first when the candidate is a debug release candidate and the appliance box then
carries the 7-day soak ([#1652](https://github.com/p2pool-starter-stack/pithead/issues/1652)). The
soak probe scores one boot, flat container restarts, every day-0 container running and healthy,
and exactly one SSH login a day, its own. Anything else spends a soak day.

- **The image.** No release image exists before GA, so every appliance step runs on the debug
  image. Skip the instruction above to write the release image after 13.12, and record the variant
  (debug, and its commit) on every M row. `verify-image.sh` without `--test`, the release-keyring
  checks and "Signing must be ON" in [Cutting](#cutting) refuse a debug image by design: record
  them N/A here. They run at GA against the release artifacts.
- **Before `soak-probe --start`: record the box.** Over SSH, copy `/data/pithead/config.json`
  off the box into the private handoff, never into an issue or the release thread (it holds the
  dashboard password, the view keys and the bot token), and note `cat /opt/pithead/BUILD_COMMIT`,
  `cat /opt/rigforge/RIGFORGE_REF` (13.7a), `rauc status`, the payout addresses, the machine name,
  its IPv4 address and both chain heights. If the box has a stratum password, keep it from
  `grep PROXY_STRATUM_PASSWORD /data/pithead/.env` in the private handoff, for 4.x and 14.1 (see
  13.8). The machine name replaces `pithead` in every `pithead.local` address below.
- **Before `--start`: the hardware battery.** Run M1–M10 (13.1–13.12 and 13.19; M5, in 13.18,
  may run on the second appliance instead). Cut power (M8 in 13.11, M10 in 13.19) only before the
  window opens. M15 (13.13 and 13.14) runs before `--start`
  or after day 7, never inside the window. The Tor drill (9.6a) runs on either appliance, before
  `--start` only. After 13.7, and again after each reboot in
  13.10–13.12, wait until the dashboard's Tari card shows progress before the next reboot,
  boot-menu test or power cut: a disk that kept its chains may hold a Tari database that migrates
  on its first start, for hours, and an interrupted migration loses it (see 2.3a). M8 and M10
  never run while Tari reads loading.
- **Before `--start`: freeze the soak state.** Put the soak configuration in place for good:
  payout address, machine name, pool, Telegram (so 8.2 and S7 can run during the soak) and the
  onion, on or off; the day-0 container set is fixed at `--start`. Remove every USB stick from the
  box, and delete `pithead-config.json` and `pithead-token.txt` from the image stick: a stick left
  in is read at the next boot, after any power event. Check that
  `/data/pithead/.os-migration-pending` is absent and that both chains are synced.
- **Starting the probe.** Use a fresh probe log directory, never the previous soak's, so the old
  `soak.log`, `day0.env`, `started` and `read<N>.env` files are not mixed into this soak's record. On the build host, run
  `tests/os/soak-probe.sh <box IPv4> <logdir> --start`, then add the daily cron line with the same
  IPv4 and log directory:
  `0 6 * * * <checkout>/tests/os/soak-probe.sh <box IPv4> <logdir> >><logdir>/cron.log 2>&1`.
  The day-0 line carries a rule-4 FAIL from the setup logins; that is the baseline, not a soak day.
- **Allowed during the soak (read-only).** 5.1–5.6 and 5.8–5.12; 7.1 and 7.8 as views only; 7.7;
  13.20; 8.2 and 8.3; 4.1, 4.2, 4.4, 4.5 and 8.4 with outside miners and no Configuration commit;
  S4; S7; and 14.1, 14.3 and 14.4 on the rigs, rig side only. Anything not listed here is
  forbidden during the window.
- **Forbidden after `--start` until day 7.** Any SSH or `scp` except the probe's own, including
  agent and operator sessions (tell them the box is held); any reboot or power cut, the boot-menu
  reboot (13.9) included; `down` and `up` (5.7); the dashboard upgrade (12.2); any
  Configuration commit, benign ones included (7.1a, 7.2–7.6, 7.9, 13.8a, 13.15, 13.21, 13.22,
  13.24, Telegram setup); **Back up now** (13.13); OS updates (12.3, 13.10–13.12); the Tor drill
  (9.6a); inserting a USB stick (13.17, 13.18, 13.23); adopting a rig (14.2); renames and resets
  (15.x); S6 and S8.
- **On a second appliance.** Flash the restore PC with the same debug RC and give it a machine
  name other than `pithead`, so rigs and mDNS never land on it by accident. Run there: 13.8's
  Sync Mode checks (1.8 and 1.13; the soak box's chains are already synced), 13.6a, 7.1a–7.6,
  7.9, 9.6a, 13.14a, 13.15–13.18, 13.21–13.25, 15.1–15.3, S6 and S8, and 14.2 with it as the
  coordinator if 14.2 was not done before `--start`. For M15, only before `--start` or after
  day 7, run 13.13 on the soak box, power the soak box off, and run 13.14 on the restore PC; then factory-reset the restore PC
  (15.3) before the soak box is powered on again, so the two never run the same identity. Inside
  the window, skip M15 or run it between two other machines.
- **The LAN test registry.** A debug image pulls its stack images from the LAN test registry at
  first start and on every re-pull. Before 13.7, 13.14, 13.14a, 13.16, 13.18, 15.2 and 15.3, and
  before flashing the second appliance, check that the registry answers and still holds the debug
  images. A pull or verify error during provisioning points at the registry first: check it before
  you file.
- **If the soak box is a laptop** (not confirmed): pulling the wall plug cuts nothing while the
  battery holds. Cut power in 13.11 and 13.19 by holding the power button, power it on by hand,
  and record "powers on by itself" (13.2's setting, 13.19) as N/A.

### The appliance steps

- [ ] **13.1 Verify and flash (M1).** Do, on a Linux machine:

  ```bash
  sha256sum -c pithead-os-vX.Y.Z.img.xz.sha256
  xz -dc pithead-os-vX.Y.Z.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
  ```

  `/dev/sdX` is the USB stick; check it twice, because `dd` erases whatever you name. Expect:
  the checksum line ends in `OK`, and the write completes. Record the `.img.xz` size and checksum.
- [ ] **13.2 Firmware.** Do: in the firmware setup, disable Secure Boot and set the power-loss
  setting to power on. Expect: both settings exist under one of the names the guide lists.
- [ ] **13.3 First boot (M1).** Do: boot from the stick with a monitor attached. Expect: the
  console first says it is starting up; within a few minutes it prints the setup address
  (`https://pithead.local` and an IP), a one-time token, and a certificate fingerprint.
- [ ] **13.4 Reach the setup page (M2).** Do: from the laptop open `https://pithead.local`, then
  the printed IP. Expect: both show the token page after one certificate warning, and the
  fingerprint in the browser matches the console. Five wrong tokens mint a fresh one on the
  console.
- [ ] **13.5 Role and disk (M3, M4).** Do: choose **Pithead + RigForge**. Expect: each disk is
  listed with model, size and serial; the USB stick is not offered; nothing is preselected. A
  second disk holding unrelated data is listed with `ERASES everything on it`.
- [ ] **13.6 Answers (M6).** Do: on a disk that already holds an install (the soak box), choose
  **Fresh start** ("Keep the blockchains; wipe settings and wallets.") so the answers form appears;
  never **Wipe everything** on the soak box, which costs days of resync. **Keep everything** asks
  nothing, so M6 would be N/A there: run it on the second appliance. Paste the QA subaddress
  first, then the primary address; keep every default, paste the Tari address if the page asks
  for one, and answer yes to `Enable stratum password?` (its default is no). Press
  **Validate, then install**. Expect: the subaddress is refused with an explanation before you
  submit. Per #3099 and #3092:

  - Merge-mining Tari is on by default when the target disk fits both chains and off when it does
    not.
  - The page does not ask about the XvB raffle and leaves it off.
  - It generates a dashboard login by default.
  - It keeps the first sync on Tor unless you opt in to the faster sync. That choice covers every
    chain the stack runs locally and warns that it exposes your IP to the Monero network and, if
    Tari is on, the Tari network (13.6a).
  - After validation the page shows the dashboard login, the address `https://pithead.local`, the
    miner address `stratum+tcp://pithead.local:3333` and, because you answered yes, the stratum
    password. On a box with another machine name, read that name for `pithead`.
- [ ] **13.6a Stratum default and fast sync.** Do: on the second appliance's setup page, on its
  first install, keep every default (the stratum question stays no), turn on the faster first
  sync, and press **Validate, then install**. If that disk is too small for both chains, note
  that Tari is off. After the install open Configuration. Expect, per #3099 and #3092: the hand-off card says `No stratum password`; the faster-sync choice
  warns as in 13.6; Configuration shows `monero.clearnet_initial_sync` on and, when Tari is on,
  `tari.clearnet_initial_sync` on too; on a disk too small for both chains the page turns Tari
  off and says why.
- [ ] **13.7 Install (M3).** Do: save the login, type the disk name, and press
  **I saved these — erase the disk and install.** Expect: progress is shown, then the machine
  switches itself off. Remove the stick and switch it on: it boots from the disk, the console
  narrates provisioning, and within 10–30 minutes the dashboard answers with the saved login. A
  second disk, if present, still holds its data.
- [ ] **13.7a RigForge is pinned to the 1.18.0 commit (#3116).** Do: over SSH on the debug image,
  before `--start`, run `cat /opt/rigforge/RIGFORGE_REF`. After the RigForge v1.18.0 tag exists
  (it is cut after the soak), run
  `git ls-remote https://github.com/p2pool-starter-stack/rigforge refs/tags/v1.18.0`. Expect:
  `ref=<sha> version=1.18.0`, where `<sha>` is the commit the release notes name as the one
  RigForge v1.18.0 is tagged from; once the tag exists, `git ls-remote` prints the same `<sha>`.
- [ ] **13.8 The same checks as DIY.** Do: first, using only the setup page, the dashboard and
  [the appliance guide](../appliance.md), find the pool URL and, if one is set, the stratum
  password an outside miner must send. Expect, per #3092: signed
  in, the dashboard shows a **Connect a miner** block with the LAN pool URL and the same stratum
  password as the 13.6 hand-off card, or `No stratum password`; signed out, nothing shows it. On a
  box with no dashboard login, the block shows it to anyone on the LAN (owner, 2026-10-04: the
  risk is accepted; an onion-published dashboard always has a login). Then, while the appliance's
  chains sync, check 1.8; when they finish, check 1.13. Then repeat sections 4 and 5 (5.12
  included), pointing XMRig at `pithead.local:3333`, and steps 7.1–7.9 (the appliance's
  Configuration view is always on; skip the second half of 7.1a, which edits `config.json`). Set
  up Telegram in Configuration, then repeat 8.2–8.4. Skip anything else that needs a shell
  (`./pithead`, `docker`, editing `config.json`): the appliance has none apart from its console.
  Expect: the same results. The built-in miner appears as a worker, and it reports RigForge
  1.18.0 (#3116).
- [ ] **13.8a The built-in miner follows its toggle.** Do: with the chains synced and the built-in
  worker mining, turn `local_miner.enabled` off in Configuration, preview and confirm (type
  `APPLY` if asked), and watch Workers Alive without rebooting; then turn it on the same way.
  Expect, per #3090: the built-in worker leaves Workers Alive
  within a few minutes of the first apply and returns within a few minutes of the second, with no
  reboot in between, even if an apply reports no configuration changes.
- [ ] **13.9 Boot menu.** Do: reboot with a monitor attached. Expect: a five-second menu that
  names the version, its slot and **current**, plus **Set up again**; it boots by itself.
- [ ] **13.10 Update (M7).** Do: as M7 describes, copy the good higher-version test bundle (a
  debug-variant bundle with a higher version) to the box and run
  `cd /data/pithead && ./pithead os-update <bundle>`. Never add `--yes` when the bundle's variant
  differs from the box's (see [Cutting](#cutting), item 3). Expect: it says the update is written
  to the spare slot, that the machine keeps running the current version until it reboots, and
  prints the exact reboot command. The spare slot is now armed: any reboot boots the update, a
  power cut included (#3100). Run that command. After the reboot, the boot menu shows the new
  version as **current** and the old one as **previous**.
  With no higher-version bundle, install the RC update bundle (the RC's own `.raucb`) over the RC:
  the same version is accepted, but if the bundle's version is not a plain `X.Y.Z`, os-update
  refuses with `Refusing a possible downgrade`, so add `--allow-downgrade` and record that. Score
  M7 by the booted slot letter in `rauc status` and by `cat /opt/pithead/BUILD_COMMIT`, before and
  after the reboot, not by the version label, since both menu entries read the same version. Two
  things are expected, not defects: the bundle declares a data migration, so a Tari volume
  without room is refused with `Refusing: this update declares a chain data migration` (free space
  and retry), and after the reboot the chain services wait until the new slot commits.
- [ ] **13.11 Pull the plug during an update (M8).** Do: start
  `cd /data/pithead && ./pithead os-update <bundle>` again with the same bundle and pull the plug
  while it writes. Repeat three times. If the box is a laptop, hold the power button instead, at
  about 30%, 60% and 90% of the write. Expect: every time, the
  machine boots the 13.10 version on its slot, marked **current**, and the dashboard serves. Do
  not pick the other slot from the boot menu: it holds a half-written copy and may still show
  its old label.
- [ ] **13.12 Bad release rolls back (M9).** Do: install the broken (health-gate fault) test
  bundle M9 describes with `cd /data/pithead && ./pithead os-update <bundle>` and reboot. Build that bundle
  from the candidate's own commit. The rollback is decided by the gate inside the new slot, so
  never use an older broken bundle whose gate code predates #2383: it tests the old gate, not the
  candidate's. Expect: without anyone touching it, the machine
  falls back to the 13.10 version on the slot it ran before, and the dashboard serves. The spare slot now holds the
  broken release, so do not mark anything bad yet. Do: install the good 13.10 bundle again with
  `cd /data/pithead && ./pithead os-update <bundle>`, reboot, and wait until `rauc status` no longer reads the booted slot as
  `bad` (it commits after its health check, about 3 minutes into the boot). Then run
  `rauc status mark-bad booted && reboot`. Expect: the machine comes back on the other slot, on a
  good version, with the dashboard serving.
  The `/data` floor fallback after a migrating update fails its gate (#1393) is not hand-run:
  the KVM battery's floor-fallback leg (`tests/os/data-floor-fallback-leg.sh`) proves it on the
  candidate's commit at every gate.
- [ ] **13.13 Backup (M15, first half).** Do: write down the payout address, the onion address and
  the time. In **Backup**, click **Back up now** and save both downloads: the archive and its
  emergency kit. Expect: the dashboard disconnects briefly and comes back.
- [ ] **13.14 Restore (M15, second half).** Do: power off the appliance box, so two machines
  never run the same identity at once. Boot the stick on the restore PC (not this box: later steps
  need its chain), and on the setup page choose **Restoring an existing Pithead? Upload its backup
  instead.** Choose the restore PC's disk (it is erased) and type its name as the page asks. Enter
  a wrong passphrase first, then the right one, and follow the page to the end. Expect: the wrong
  passphrase is rejected with the reason and the form stays open; with the right one the machine
  provisions itself, and its payout address and onion address match your notes. Then power the restore PC
  off and the appliance box back on.
- [ ] **13.14a Restore a 1.20 DIY backup.** Do: run `./pithead down` on the upgrade box for the
  whole step, the safe default because the archive carries its node onion keys, which 9.5 does not
  replace. Boot the stick on the restore PC, choose
  **Restoring an existing Pithead? Upload its backup instead.**, upload the plain 1.20 archive you
  copied to the laptop in 2.1b, choose the restore PC's disk, enter its passphrase, and follow the page to the end. Then
  open Configuration's Advanced pane. Expect: the 1.20 archive is accepted, not refused for its
  layout, and the machine provisions itself; its payout address matches your 2.1 notes. The
  Advanced pane shows `xvb` and `workers.list`, and no `xmrig_proxy`, `dashboard.workers` or
  `telegram.control`. Afterwards power the restore PC off, and run `./pithead up` on the upgrade
  box. Do not power the restore PC on next to the upgrade box again until it is reinstalled.
- [ ] **13.15 Settings after setup (M16).** Do: follow M16: a benign energy change, then a node
  endpoint change that needs `APPLY`. For the test node, use the upgrade box's Monero node opened
  to the LAN as in Config D, with the RPC login from that box's `config.json`. Expect: as M16 describes, and the page reconnects by itself
  after the containers restart.
- [ ] **13.16 Set up again.** Do: choose **Set up again** in the boot menu. Expect: the setup page
  opens with the saved answers filled in, secrets left blank; finishing it keeps the chains.
- [ ] **13.17 Headless setup.** Do: on the laptop, put `pithead-token.txt` with a token you choose
  on the stick's `PITHEAD` volume, and boot the stick without a monitor. Expect: your token opens
  the setup page. Then add `pithead-config.json` holding Config A: the setup page opens with
  every answer filled in, and only the disk choice is left to you.
- [ ] **13.18 Reinstall keeps the chain (M5).** Do: continue from 13.17, choose the same disk, and
  pick **Keep everything**. Expect: the disk is listed with `holds a previous install`, and
  **Keep everything** is the default choice; after the install the chain is intact and only the blocks missed during the test download.
  Afterwards delete `pithead-config.json` and `pithead-token.txt` from the stick, and take every
  stick out of the box: the appliance reads a settings file from any stick left in at its next
  boot.
- [ ] **13.19 Power loss while mining (M10).** Do: pull the plug at the wall while mining, wait
  30 seconds, plug it back in, and do not touch the machine. Expect: it powers on by itself and
  returns to mining; the dashboard answers. If the box is a laptop, a wall-plug cut changes
  nothing while the battery holds: hold the power button instead, power it on by hand, and
  record "powers on by itself" as N/A.
- [ ] **13.20 Tor egress on the appliance.** Do: in Configuration click **Run health check**, then
  open **Stack Topology & Egress** in the Advanced view. Expect: the health check reports
  `Tor-only egress firewall is installed` and `Tor clearnet egress works`; the topology shows
  unselected clearnet routes as blocked; the header shows no firewall warning.
- [ ] **13.21 Onion dashboard on the appliance.** Do: in Configuration turn on
  `dashboard.onion.enabled`, leaving `dashboard.onion.client_auth` on, preview, type `APPLY`
  and confirm. Expect: the `.onion` address appears under the machine name with a
  **Copy address** button. **Show client key** reveals the key, pressing it again reveals the same
  key (**Set up again** keeps it too, #3100), and each reveal appears in the change history. With
  that key, Tor Browser opens the dashboard as in 9.4. Turning `client_auth` off while the onion
  is on is refused.
- [ ] **13.22 Node modes on the appliance.** Do: in Configuration set Tari's mode to `off`,
  preview, type `APPLY` and confirm; then set it back to `local` the same way. Expect: the preview
  marks each change ⚠; with Tari off, mining continues; switching back resumes the Tari chain it
  already had, and Monero mining carries on while Tari catches up (#3094): the `Tari merge-mining ON` row says so, Workers Alive keeps its workers (the built-in
  miner included), no `Workers rejected` badge shows, and the Tari card reads syncing. (The remote
  Monero node change is 13.15.)
- [ ] **13.23 Settings by USB stick.** Do: on the laptop, give the second stick one partition
  formatted FAT32 (not exFAT, and not FAT written across the whole device without a partition:
  the appliance reads neither) and write to it only a
  `pithead-config.json` with `{"p2pool": {"pool": "nano"}}`. Insert it into the running
  appliance. Expect: nothing happens until a reboot. Reboot with a monitor attached. Expect: the
  console prints the pool change, old and new value (the old one may read `(unset)` while the
  pool is still at its default), and counts down 60 seconds. Pull the stick
  during the countdown: the console says the change was cancelled, and nothing changes. Write the
  file again, reboot, and let the countdown run out. Expect: the change applies; the file is gone
  from the stick; the dashboard shows the `nano` sidechain. Put `mini` back the same way.
- [ ] **13.24 Change and recover the dashboard password.** Do: in Configuration set a new
  dashboard password, preview it, type `APPLY` and confirm. Log in with the new password. Reboot
  with a monitor attached and log in at the console as `root`, first with the old password, then
  with the new one. Next, on the second stick from 13.23, write only a `pithead-config.json` with
  `{"dashboard": {"auth": {"password": "<a third QA password>"}}}`, insert it, reboot, and let the
  countdown run out. Finally put the original password back the same way, because 15.2 needs it.
  While the onion from 13.21 is on, every password in this step must be at least 16 characters and
  free of well-known weak patterns, or it is refused (see [Broken configs](#broken-configs)).
  Expect: the preview warns that a mistyped password locks this session out and that on the
  appliance it is also the console root login. After the apply, the old password is refused and
  the new one works, in the browser and at the console. With the stick, the console shows
  `dashboard.auth.password: changed (value hidden)`, never the value, counts down, and applies;
  the third password then works in both places.
- [ ] **13.25 Walk the appliance guide against the device (#3100).** Do: on the second appliance,
  read [the appliance guide](../appliance.md) from top to bottom beside the box. For every
  instruction that names a button, a label, a command or an outcome, check that the device matches.
  Do not repeat the destructive ones: they have their own steps. Expect: every label and command
  is real. In particular: console commands read `cd /data/pithead && ./pithead <verb>` (13.24, 15.2
  and 15.3 use them); the wizard labels are `ERASES everything on it` and `holds a previous
  install`; the onion button is **Copy address**; **Show client key** shows the same key twice
  (13.21); an installed OS update boots at any reboot and the dashboard's Reboot button expires
  after 24 hours (12.3); **Config reset** keeps the machine's identity, and **Fresh start, keep the
  blockchains** is the way to hand a machine over (15.2); a restore says to switch the old machine
  off first (13.14); a rename warns that rigs using the old name stop mining (15.1). File every
  sentence the device contradicts, and every place you had to know something the guide does not
  say.

## 14. RigForge rig

Run on the two loaner rigs from "What you need", with the appliance from section 13 as the
coordinator. 14.1 erases the first rig's internal disk. These are the
hands-on rows M11–M13 in [the rig battery](#the-rig-role-manual-battery-m11m13).

- [ ] **14.1 Install a rig (M11).** Do: boot the stick on the rig, choose **RigForge**, accept the
  pool address it fills in (`pithead.local:3333`). It fills one in only when a coordinator named
  `pithead` answers there; otherwise the field opens empty, so type `<name>.local:3333` with the
  coordinator's machine name. Enter the stratum password from 13.8 (leave it empty if the
  coordinator has none), name the worker, choose the internal disk, and copy the control token.
  Expect: the rig mines; the coordinator lists the worker badged `not adopted`; `doctor` on the rig
  reports MSR applied and HugePages reserved; the coordinator's Worker Inspect shows RigForge
  1.18.0 for it (#3116).
- [ ] **14.2 Adopt (M12).** Do: on the coordinator's dashboard, click the worker and fill the adopt
  form with the rig's address, port `8082` and the token. Then change the donation level and
  click **Apply to rig**. Expect: the change reaches `applied`; the pool settings are untouched.
- [ ] **14.3 Run from the stick.** Do: on a second rig, boot the stick, choose **RigForge**, and
  choose **run from this USB stick**. Expect: it mines without installing anything, and a reboot
  returns it to mining.
- [ ] **14.4 Rig power loss and update (M13).** Do: as M13 describes. Expect: the rig returns to
  mining by itself, and after the update it mines on the new version.

## 15. Appliance rename and resets

Run last, on the appliance box. These change the machine's identity or erase it.

- [ ] **15.1 Rename.** Do: in Configuration set the machine name (`dashboard.host`) to `qa-box` and
  confirm. Expect: the preview warns that rigs using the old name stop mining and that each needs
  **Set up again** to point it at the new name (#3100); the dashboard answers at
  `https://qa-box.local` after one new certificate warning, and keeps that name after a reboot. A
  rig that used the old name stops mining until it is set up again; a rig that used an IP address
  keeps mining.
- [ ] **15.2 Config reset.** Do: at the console, log in as `root` with the dashboard password and
  run `cd /data/pithead && ./pithead config-reset`. Expect: you must type to confirm; the machine reboots into the setup
  wizard, and after you answer again the chains are still synced.
- [ ] **15.3 Factory reset.** Do: `cd /data/pithead && ./pithead factory-reset`. Expect: you must type to confirm; the
  machine reboots into a blank setup wizard with nothing kept, chains included.

---

## Scenarios

Short stories that cross sections. Each one is how a real user meets the product; run them after
the sections above, on whichever machine fits.

- [ ] **S1 — New home miner.** On a clean box, follow only
  [Getting Started](../getting-started.md), with no other help. Expect: you reach a mining
  dashboard without needing anything the guide does not say. Note every place you hesitated.
- [ ] **S2 — Payout address typo.** A user pastes an address with one wrong character, in the
  CLI wizard, `config.json`, the dashboard, and the appliance setup page. Expect: all four refuse
  it, with the same meaning, before anything mines.
- [ ] **S3 — Power cut overnight.** Pull the plug on a DIY box mid-mining. Power it back on.
  Expect: the stack and its firewall come back without anyone running a command (the firewall
  check is 9.2), and miners reconnect.
- [ ] **S4 — A rig dies.** Unplug a miner's network for 10 minutes, then reconnect it. Expect: one
  worker-offline and one back-online message, and the worker's row goes offline and comes back.
  The chart marks a hashrate drop only when the loss is large enough for the drop alert, so a
  one-rig loss in a big fleet may leave no marker.
- [ ] **S5 — Moving to a new machine.** Back up the upgrade box, then stop it with
  `./pithead down` so the two machines never mine under the same identity. Restore the archive
  onto the fresh box with `./pithead restore`. Expect: the same onion address, login and
  settings; the chains resync (or are copied across).
- [ ] **S6 — Bad change, undo it.** Change the pool from the dashboard, then change it back
  10 minutes later. Expect: both changes are in the change history with the right user and
  outcome, and mining continues throughout.
- [ ] **S7 — Remote check-in.** From the phone, away from the home network, reach the dashboard
  over the onion and ask the bot `/status`. Expect: both work and agree.
- [ ] **S8 — Disk filling up.** Only on a disposable box: fill the data disk past 85%. Expect: the
  dashboard's disk badge turns amber (red at 95%) and a disk alert arrives. Free the space
  afterwards.

---

## Before the cut

### Confirm what the harness cannot see

The KVM battery boots a VM on a virtual NIC, one virtual disk, and no firmware. It can stage an
unrouted documentation-range global IPv6 address, but it is structurally blind to the following,
all of which have produced real defects:

| Check | Why a VM cannot show it |
|---|---|
| Secure Boot, firmware power-on behaviour, real disk topology | No firmware, one virtual disk. |
| Thermals, CPU governor, the hardware watchdog actually resetting a wedged board | A VM has no watchdog device and no heat. |
| First-boot on real media — wall-clock, and what a power cut leaves behind | Writing container storage to a USB stick is nothing like a virtual disk, and the operator experience lives in that gap. An interrupted write to a stick left a store that was present, digest-matched and unrunnable, and it bricked install-from-stick on every later boot (#1029). Fault D covers the interrupted first-boot image-load path on a virtual disk: it must repair and serve the wizard, or refuse with a legible console message; real-media wear and firmware behaviour remain hardware-only. |

### Reserve the hardware

Bench resources are shared with other sessions and with RigForge's own gates. Reserve before
touching anything, free when done — see the reservation protocol in
[release-server.md](release-server.md). The loaner rigs carry their own contract at `~/README.md`
on each box: back up the config, repoint, and **restore + restart when the job frees it**.

That protocol covers the **rigs**. It does not cover the appliance under test.
[#1022](https://github.com/p2pool-starter-stack/pithead/issues/1022) was closed by
[#1759](https://github.com/p2pool-starter-stack/pithead/pull/1759), which wrote this gap down here
and the rigs' CHECK and FREE rules into [release-server.md](release-server.md), and added no
mechanism for the appliance: it has no lock,
no holder marker and no contract file of its own, so nothing stops two sessions working on it at
once, and the battery below reflashes and factory-resets the box. A collision costs whoever else
is holding it both their run and the chain on that disk. Reserving the appliance is an agreement
between sessions, and nothing enforces it: say in your handoff that you are holding it, and say
when you let go.

The appliance cannot copy the rig protocol, and #1022 names the reason: a lock stored *on*
the appliance is destroyed by the very tests that take it. Its reservation has to live on a
coordinator that the reflash does not touch.

### Know which image you are holding

A **debug** image (sshd on, keys baked) is bench equipment. A **release** image is shell-less
with no keys. `verify-image.sh` without `--test` refuses a debug build, and that refusal is the
last thing standing between a development convenience and a published one. Never publish a debug
image; never hand one to a user.

---

## The manual hardware battery (M1–M10)

Defined in [appliance-release.md](appliance-release.md). Run its remaining hardware-only checks on a physical box and record the
results in the release issue. The KVM battery covers the scriptable parts noted below; the physical
checks remain hands-on, and #1022 closed without a way to collect the scripted and attested
results together.

Needs hands, every time:

- **M1 — flash and boot** from a real stick with Secure Boot disabled in firmware. Verify
  the published `.img.xz` checksum, then flash its decompressed bytes using the appliance
  guide's command. Record the compressed image's byte size and checksum.

M4's mechanics (the wrong-disk guard) now have a KVM analog — see
[appliance-release.md](appliance-release.md) — so only the real-hardware disk-controller
cases still need a physical second disk.

The power-cut items are the ones that justify the whole appliance design (A/B slots, the
health-gated commit, the migration hold). Two are now in the KVM battery — a virtual disk cannot
show USB-stick media damage or the firmware's Restore-on-AC-Power-Loss setting, so the box coming
back **by itself** after the plug is pulled still needs hands on real hardware:

- **M8 — power cut during the update's write phase.** *Covered by: `fault` phase Fault A
  (destroy mid-write, `tests/os/phases/fault.sh`) — pull the plug at the wall on real hardware to
  confirm Restore on AC Power Loss, not the write itself.*
- **M10 — power cut during normal mining.** *Covered by: `provision` phase's power-cut leg
  (M10, #2067, `tests/os/phases/provision-power-cut.sh`), which checks the complete recovery after
  every one of its three cuts — same caveat.*

### Recorded runs

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
| M1 flash and boot | PASS | Booted from the stick with Secure Boot off and reached the wizard. |
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
| M16 settings after provisioning | PARTIAL | The energy value previewed, applied and persisted, and the change history was accurate. Findings: #2365, #2366, #2367. Not run: the node-endpoint `APPLY` step. |
| RC1 addendum | NOT RUN | |

Hardware-only observation: a freshly booted slot reads `bad` in `rauc status` until its gate
commits it, about two and a half minutes into the boot; rebooting inside that window leaves both
slots reading `bad` until the gate runs again. The KVM install phase checks the Fresh Start
reinstall sequence behind #2352; the physical result above remains the September 2026 observation.

Still open from these runs, as of 2026-10-03: #2351 and #2436. Closed since, and not re-run on
hardware: #2367 and the Fresh Start KVM gap, #2447. Fixed on `develop` since, and not re-run on
hardware: #2350, #2352, #2364, #2365, #2366, #2382 and #2383.

### Install-path cases worth walking deliberately

- A **fresh** disk.
- A disk that **already holds an installation** — choose *keep* and confirm the chain survives
  (this is M5, and it is where the corrupt-container-store blocker was found: a partially written
  image store left every `podman run` failing, so the wizard never served).
- Reaching the wizard **by mDNS name** and **by IP**, since the appliance serves both.
- Confirming once that the dashboard refuses the real box's ISP-assigned IPv6 address. The
  provision battery proves the listener boundary with an unrouted RFC 3849 address; this check
  confirms that the physical network presents the same address shape.
- Configuring **by paste** for both addresses (M6: a new machine on a disk that fits both chains
  is asked for both, and on a smaller disk for the Monero address only, #3099): a wallet address
  typed by hand is a support ticket waiting to happen.

---

## The rig-role manual battery (M11–M13)

Defined in [appliance-release.md](appliance-release.md). Required for any release that touches
the rig role. The `rig` KVM phase only proves the wizard's
rig card, role select, a submit toward a faked pool listener, volatile journald, a plain reboot,
a power cut, and the A/B update leg — so these three stay hands-on until #1886's first gap
converts what it can and names a bench e2e for the rest. Each row below names the check that
replaces it once that lands. M14 (run-from-USB) no longer needs a hand-run: the `rigmedia` KVM
phase (`tests/os/phases/rigmedia.sh`, #2069) covers it — see the row below for what it proves and
what it still leaves out.

- **M11 — rig install and mine.** Flash the same stick; boot a rig-class loaner (never a
  production-only rig); choose RigForge; point it at a real coordinator. Expected: the rig card
  shows worker + pool with no login, the coordinator's dashboard shows the worker with accepted
  shares within minutes, `doctor` on the rig reports MSR applied and hugepages reserved, and
  hashrate sits within the box's recorded baseline band. *Replaced by: the accepted-share and
  `doctor` MSR/hugepages checks #1886's gap 1 still has to add — the KVM phase fakes the pool
  listener and never accepts a share, and asserts nothing about MSR or hugepages.*
- **M12 — rig from the coordinator's dashboard.** From the coordinator's Worker Inspect, adopt
  the rig, apply one writable change (for example the donation level), and watch it reach
  `applied`; confirm no pool credential was touched. *Replaced by: a dashboard-driven adopt/config
  push check, not yet written — a rig serves no dashboard of its own, so nothing in the KVM `rig`
  phase exercises this today.*
- **M13 — rig power loss and rig update.** Cut power at the wall with the rig mining; it must
  return mining unaided (Restore on AC power loss). Then install the release bundle on the rig and
  confirm it comes back mining on the new slot and self-commits. *Covered by: the `rig` phase's
  power-cut leg (#2067, `tests/os/phases/rig.sh`) proves the return-mining-unaided fact off a real
  `virsh destroy`, and the phase's existing update leg proves the install/self-commit half. What
  stays manual is Restore on AC Power Loss itself — a firmware setting a virtual disk cannot show.*
- **M14 — run-from-USB rig. AUTOMATED (#2069).** Boot the stick, choose RigForge, do **not**
  install to disk. Expected: it mines from the stick; a reboot returns it mining; reaching the
  wizard again needs the bootloader path (#1318). *Replaced by: the `rigmedia` KVM phase
  (`tests/os/phases/rigmedia.sh`), which boots the image as removable media beside a blank
  internal disk, answers RigForge with no install offered, and asserts the stick-run rig mines
  the baked binary with no containers, volatile journald, an unaided reboot returns it mining,
  and the blank disk stays byte-for-byte untouched. Still manual: reaching the wizard again via
  the bootloader path (#1318) on a stick-run rig, and stick wear / wall-clock on real USB media.*

---

## Cutting

Before publication, the owner confirms that the release root certificate and signing leaf
exist, and that the root private key has an offline backup. Run the baked-keyring fingerprint
comparison and both `rauc info --keyring` bundle checks in
[appliance-release.md](appliance-release.md#cutting-a-release), step 3. Package the verified
image and bundle with step 4 there; record both published sizes, checksums, and the fingerprint
and bundle verification results in the release issue. Flash that `.img.xz` for the hardware
battery and soak. Stop the cut if either asset is at or above 2 GiB or
any check fails: the first published image establishes the trust anchor on every fielded box.

1. **Signing must be ON.** Confirm the preflight says so *before* answering the confirmation
   prompt. A release once shipped unsigned because the environment was absent and the script
   only warned; the fix made it refuse, and the check still belongs on this list.
2. **Two-channel versions publish as a draft.** Published release assets are immutable — a
   version was burned exactly this way. Cut with `--draft`, attach the `.img.xz`, `.raucb`, and
   both `.sha256` files alongside the DIY artifacts, then publish once. Note the git tag is spent
   at the cut even under `--draft`, so do not start the
   DIY stage until the appliance tree is believed final.
3. **Never pass `--yes` to `os-update` across a variant flip.** Installing a release bundle onto
   a debug box removes the SSH channel driving the install. The prompt exists for exactly that;
   overriding it costs the box's management channel until someone reflashes or rolls back.
4. Record the **hardware battery results** and the **live e2e** evidence in the release issue.

## After publishing

- Post-publish smoke against the published tag, including the upgrade path from the previous
  release on a box that actually runs it.
- Confirm `main` fast-forwarded to the tag — `release.sh` does this at publish. If the push was
  refused, run the command it printed by hand.
- Sync `develop` → the integration branch, so the next cut does not diverge.
- Record the per-rig performance baselines you actually re-tagged (see
  [RELEASING.md in RigForge](https://github.com/p2pool-starter-stack/rigforge/blob/main/RELEASING.md)),
  and reset the rigs' checkouts afterwards — a dirty checkout aborts the next tag deploy.

---

## Watch the operator experience, not just the asserts

A green battery says the machine works. It does not say the product is pleasant. During any
manual run, notice and file:

- Any step that goes silent for more than a minute or two without saying what it is doing or
  roughly how long it will take. A first boot that loads container images from a USB stick is
  the current worst case, and it reads as a hang.
- Any failure that leaves the console showing a stale progress message. A failed first-boot
  service once looked identical to a slow one, forever, which turned a three-minute failure into
  an hour of waiting; that one is fixed, and the shape of it is worth watching for elsewhere.
- Any message that promises a duration the machine cannot keep ("this takes a minute or two").
- Anything you had to know rather than read.

These are release-quality defects for a product whose whole promise is that a non-expert can run
it. File them with what you saw on screen; a photograph of the console is a perfectly good bug
report and has already produced two.
