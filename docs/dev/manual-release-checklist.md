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
should get a harness leg.

Contents:

- [How to use this checklist](#how-to-use-this-checklist), [What you need](#what-you-need),
  [Sample configs](#sample-configs)
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
- Run the sections in order. Later sections assume earlier ones passed, and the destructive
  steps (resets, uninstall, factory reset) come last on purpose.
- `./pithead` commands run from the install directory on the stack machine. Commands that start
  with `sudo` ask for the machine's administrator password.
- Plan for about three days. A first chain sync takes hours to days, so start section 1 on day
  one and work through the other sections on the already-synced upgrade machine meanwhile.

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

## What you need

| Item | What it is for |
|---|---|
| **Fresh box** | Ubuntu Server 24.04, AVX2 CPU, 16 GB RAM, 600 GB SSD, nothing of Pithead on it. Section 1. |
| **Upgrade box** | A machine already running the previous release, with both chains synced and the dashboard password set. Sections 2–12. |
| **Appliance box** | An x86-64 UEFI PC with 16 GB RAM, ethernet, firmware settings you can change, and an internal disk you may erase. A second internal disk for the wrong-disk check, and a second PC for the restore test. Section 13. |
| **USB stick** | 8 GB or larger, contents expendable. The image writes 5 GiB. |
| **Miner** | A separate machine running XMRig, or a RigForge loaner rig (never a production rig). Sections 4 and 14. |
| **Laptop** | On the same network, with a normal browser and Tor Browser. |
| **Phone** | For the narrow-screen check and Telegram. |
| **QA wallets** | A Monero wallet used only for QA: its **primary** address (starts with `4`, 95 characters), one **subaddress** from it (starts with `8`), and its private view key. The primary address of a second Monero QA wallet, for the payout-change step. A Tari **mainnet** QA wallet: its address, private view key and public spend key. Payouts go here, so never use a real person's or a donation address. |
| **Telegram test bot** | A bot made with @BotFather, its token, and the chat id of a test chat. See [Telegram](../telegram.md). |
| **Release artifacts** | The candidate's full commit SHA, the previous release tag, and for the appliance: the candidate release `.img.xz` with its `.sha256`, a debug image of the candidate, a debug-variant `.raucb` with a higher version, and the deliberately broken `.raucb` M9 describes ([appliance-release.md](appliance-release.md)). |

Reserve shared machines before you start: see [Reserve the hardware](#reserve-the-hardware).

## Sample configs

Each sample is a complete `config.json`. Replace every `PASTE_...` value with your QA value
before you use it. A wallet placeholder left in is refused, but the others (passwords, the bot
token, node credentials) are accepted as plain text, so after filling a sample,
`grep -n PASTE_ config.json` must print nothing. Every key is
documented in [Configuration](../configuration.md).

When a step says to set or add a key inside a block (for example "add `"rpc_lan_access": true`
inside the `monero` block"), edit that block in the existing `config.json`. Never paste a second
block with the same name: JSON keeps only the last one, so the first block's settings vanish
without a warning. After any hand edit, run this check. It prints `config.json OK`, or lists the
keys when a block is duplicated, or fails on a syntax error:

```bash
python3 -c 'import json; json.load(open("config.json"), object_pairs_hook=lambda kv: exit("duplicate key: " + str([k for k, _ in kv])) if len(kv) != len(dict(kv)) else dict(kv)); print("config.json OK")'
```

**Config A — defaults.** This is `config.minimal.json` with QA addresses: the shape a new user
starts from.

```json
{
    "monero": { "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS" },
    "tari": { "wallet_address": "PASTE_QA_TARI_ADDRESS" },
    "p2pool": { "stratum_password": "auto" }
}
```

**Config B — everything on.** Login, browser configuration, Telegram with commands, stratum TLS,
on-chain payout confirmation for both chains, energy prices, and the dashboard as a Tor onion
(which needs a dashboard password of 16 characters or more; make one up for QA).

```json
{
    "monero": {
        "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS",
        "view_key": "PASTE_QA_MONERO_PRIVATE_VIEW_KEY"
    },
    "tari": {
        "wallet_address": "PASTE_QA_TARI_ADDRESS",
        "view_key": "PASTE_QA_TARI_PRIVATE_VIEW_KEY",
        "spend_public_key": "PASTE_QA_TARI_PUBLIC_SPEND_KEY"
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
    "tari": { "mode": "off" },
    "p2pool": { "stratum_password": "auto" },
    "dashboard": {
        "auth": { "username": "admin", "password": "PASTE_QA_DASHBOARD_PASSWORD" },
        "control": { "enabled": true }
    }
}
```

### Broken configs

Make one change at a time to a working config, run `./pithead apply`, and check the refusal.
Each one must stop before anything changes, print a message that contains the text in the second
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
| With the onion on, set the password to `"fifteen-chars-x"` (15 characters) | `must be at least 16 characters when dashboard.onion.enabled is true` |
| With the onion on, set the password to `"changeme-but-longer"` | `contains a well-known weak pattern` |

---

## 1. Fresh DIY install

Run on the **fresh box**. This tests the path a new user takes, from an empty machine to a
syncing stack. Build the candidate from source so a failure here does not spend the version tag.

- [ ] **1.1 Get the candidate.** Do:

  ```bash
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
  pool `mini`, merge-mine Tari with the bundled node (paste the Tari address), set a dashboard
  password, decline clearnet sync, decline Tor dashboard access, decline Telegram, decline local
  mining, and accept the default at `Enter Hostname`. Answer `y` to
  `Modify GRUB for persistent HugePages now?`. Expect: the subaddress is refused with an
  explanation and you are asked again; setup checks dependencies, warns (but does not stop) if
  disk or RAM is below the documented floor, writes `config.json`, provisions Tor, and ends with
  `System optimization requires a reboot.` and the commands to run next. If setup does not ask
  about GRUB (HugePages are already persistent), it asks `Start Pithead now? (Y/n)` instead:
  answer `y` and skip the reboot in 1.5. Run `ls -l config.json`: it is `-rw-------`.
- [ ] **1.5 HugePages reboot.** Do: `sudo reboot`, then `./pithead up`. Expect: the stack starts,
  and this first start prints a short note that the miner is held until both chains sync. A
  later `./pithead restart` does not print the note again.
- [ ] **1.6 Status while syncing.** Do: `./pithead status`. Expect: the node and support services
  show `✓ running`; `p2pool` and `xmrig-proxy` show `⚠` with
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
- [ ] **1.10 Leave it syncing.** Note the time. Come back to step 1.11 when both chains are
  synced.
- [ ] **1.11 Sync finishes.** Expect: the dashboard switches from Sync Mode to the operational
  view by itself, and the miner is released without anyone touching it.

## 2. Upgrade from the previous release

Run on the **upgrade box**, which runs the previous release with synced chains. Before you start,
write down the payout addresses, the dashboard login, the dashboard's onion address if the onion
is on (`./pithead status` prints it), the worker count, and a screenshot of the hashrate chart.

- [ ] **2.1 Backup first.** Do: `./pithead backup`. Choose a passphrase and keep it. Expect: a
  file `backups/pithead-backup-<date>-<time>.tar.gz.enc` exists; the stack was stopped for the
  copy and is running again.
- [ ] **2.2 Upgrade.** Do, on a source checkout: `git fetch`, `git checkout <full candidate SHA>`,
  `make`, `./pithead upgrade`. On a release-bundle install, use the bundle command in
  [Operations › Updating the stack](../operations.md#updating-the-stack) once the candidate is
  published. Expect: it finishes without errors and recreates only what changed.
- [ ] **2.3 Nothing lost.** Expect: `./pithead version` shows the candidate; the dashboard login,
  payout addresses, onion address, and worker list match your notes; the hashrate chart still
  shows the history from before; both chains are still synced (no Sync Mode); the miners
  reconnected by themselves.
- [ ] **2.4 Health after upgrade.** Do: `./pithead status` and `./pithead doctor`. Expect: all
  healthy, no FAIL.

## 3. Everyday commands

Run on the upgrade box.

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

## 4. Connect a miner

Run on the upgrade box with the miner machine. Get the stratum password with
`grep PROXY_STRATUM_PASSWORD .env`.

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
  primary address and run `./pithead apply`. Type the wrong characters first, then run it again
  and type the first 8 characters of the new address. Expect: the warning says all future rewards
  go to the new address; the wrong answer cancels with no change; the right one applies. Put the
  original address back the same way.
- [ ] **6.5 Broken configs.** Do: work through every row of [Broken configs](#broken-configs).
  Expect: each refusal matches, and `./pithead status` stays healthy throughout.
- [ ] **6.6 Render.** Do: `./pithead render`. Expect: it finishes and no container restarts.
- [ ] **6.7 Rotate secrets.** Do: `./pithead rotate-secrets` and confirm. Expect: it names what
  changes, keeps `.bak-` copies, and recreates the affected containers. If `p2pool.stratum_password`
  is `"auto"`, miners with the old password are now rejected; give each miner the new one from
  `.env` and they mine again. With a password you set yourself, the stratum password does not
  change.
- [ ] **6.8 Restore.** Do: `cp config.json.qa config.json && ./pithead apply`. Expect: the
  original settings are back.

## 7. Change settings from the dashboard

Run on the upgrade box. Inside its `dashboard` block, make sure `auth.password` is set and add
`"control": { "enabled": true }`, then `./pithead apply`.

- [ ] **7.1 Configuration view.** Do: open **Configuration** from the toggle above the chart.
  Expect: a form with grouped sections and an Advanced JSON pane. Secrets show as
  "set — leave blank to keep", never their values.
- [ ] **7.2 Benign change.** Do: set an energy price, click **Save & preview changes**, then
  confirm. Expect: a preview with one row per changed setting; after confirming, the value shows
  on the Energy tab, survives a reload, and appears in **Recent config changes**.
- [ ] **7.3 Ordinary change.** Do: change the P2Pool sidechain to `nano`, preview, and confirm.
  Expect: no typing needed; it applies and the dashboard follows. Change it back.
- [ ] **7.4 Disruptive change.** Do: change the stratum port to `3334`, preview, and try to confirm
  without typing. Expect: the row is marked ⚠ and says every rig must repoint; the commit is
  refused until you type `APPLY`. After it applies, miners on 3333 disconnect. Change it back to
  `3333` the same way and confirm the miners reconnect.
- [ ] **7.5 Payout change.** Do: change the Monero payout address to the second QA primary
  address. Expect: the confirmation asks for the last eight characters of the new address (the
  command line asks for the first eight), and a wrong suffix is refused. After it applies, the **Payout wallet changed** badge appears. Change
  it back.
- [ ] **7.6 Bad value.** Do: paste the QA subaddress into the Monero address field and preview.
  Expect: refused with the same message as the command line; nothing is applied.
- [ ] **7.7 Health check and log.** Do: click **Run health check**, then **Show recent log**.
  Expect: the doctor rows appear grouped with remedies; the log shows recent lines with
  credentials redacted.
- [ ] **7.8 Access log.** Expect: the **Access log** lists your recent requests and counts the
  wrong password from step 5.10.

## 8. Alerts and Telegram

Run on the upgrade box. Add Config B's `telegram` block to its `config.json` as a top-level block
(replace the existing `telegram` block if there is one), fill in the bot token and chat id, and
`./pithead apply`. See [Telegram](../telegram.md).

- [ ] **8.1 Test alert.** Do: `./pithead test-alert`. Expect: one marked test message arrives in
  the test chat, and the command reports each sink's result without printing the token.
- [ ] **8.2 Commands.** Do: send `/help`, `/status`, `/info`, `/hashrate`, `/workers`, `/sync`,
  `/system`, `/pool`, `/xvb`, `/earnings` and `/luck`. Expect: each gets a reply, and the numbers
  agree with the dashboard.
- [ ] **8.3 Other chats are ignored.** Do: message the bot from a chat that is not configured.
  Expect: no reply.
- [ ] **8.4 Worker offline.** Do: stop `qa-rig-02` and wait 6 minutes. Expect: a worker-offline
  message after about 5 minutes, and the row badged offline on the dashboard. Start it again:
  a back-online message about 2 minutes after it reconnects.
- [ ] **8.5 Node down.** Do: `docker stop monerod` and wait 2 minutes. Expect: the dashboard shows the monerod DOWN badge after about 90 seconds and a
  node-down message arrives. xmrig-proxy is stopped, so XMRig logs that it lost the pool (with
  a backup pool in its config it would switch to it). Run `./pithead up`: the badge clears, a
  node-recovered message arrives, and the miners reconnect.
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
  characters) and `./pithead apply`. Copy the `.onion` address from
  the dashboard header and get the key with `./pithead onion-client-key`. In Tor Browser open
  `http://<address>.onion`, accept the certificate prompt, and paste the bare key when asked.
  Expect: the dashboard login appears; the same login works. Without the key, the address does
  not load at all.
- [ ] **9.5 Rotate the onion.** Do: `./pithead rotate-dashboard-onion`. Expect: a new address
  and key are printed; the old address stops working; the new one works with the new key.
- [ ] **9.6 Tor recovery check.** Do: `./pithead tor-recover check`. Expect: on a healthy
  machine it prints `Tor recovery refused: circuit history is not saturated.` and changes nothing.
  Do not run `tor-recover apply` on a healthy machine.
- [ ] **9.7 Clearnet sync warning.** Only on the fresh box before its sync finishes: add
  `"clearnet_initial_sync": true` inside the `monero` block and apply. Expect: apply flags the change ⚠ and
  asks first; `./pithead status` prints a `CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING`
  banner; `./pithead doctor` shows a WARN; the dashboard shows a warning badge. When the sync
  completes the node returns to Tor by itself, and doctor then reports `all node P2P is Tor-only`.
- [ ] **9.8 Public IP warning.** If the test network gives the box a public IP: Expect: setup and
  doctor warn that stratum port 3333 is exposed.

## 10. Node and pool modes

- [ ] **10.1 Monero only.** Do: on the fresh box, replace `config.json` with Config C (same
  dashboard password as before) and `./pithead apply`. Expect: the preview marks
  `Tari merge-mining OFF` with `⚠`, says its chain data is kept, and asks `(y/N)`; answer `y`.
  Afterwards no `tari` container runs,
  mining continues, and the five XvB raffle tiles are gone from the dashboard.
- [ ] **10.2 Back to Tari.** Do: set `tari.mode` back to `local` and apply. Expect: the Tari node
  resumes from the chain it already had instead of starting from zero.
- [ ] **10.3 Remote Monero node.** Do: on the upgrade box (the node machine), add the two Config D
  keys inside its `monero` block and apply; the preview flags them ⚠ and asks first. On the fresh
  box (the second machine), replace `config.json` with Config D's second-machine file and apply.
  Expect: on the second machine no monerod container runs, the dashboard says the node is remote, the topology
  labels it LAN, and mining works.
- [ ] **10.4 Bad remote node.** Do: on the second machine, with the Configuration view on, change
  the Monero node host to a LAN address where nothing listens and click
  **Save & preview changes**. Expect: refused with a reason that names the problem (nothing
  answering), and nothing is applied. Repeat with a public IP address: refused because the
  firewall allows only private addresses. Repeat with a misspelt hostname: reported as a name
  that does not resolve, not as a firewall problem.
- [ ] **10.5 Tari outage.** Do: on the upgrade box, `docker stop tari` and wait 3 minutes.
  Expect: miners keep mining Monero (a Tari outage never rejects workers); the Tari panel and a
  Telegram alert show the outage. Run `./pithead up` afterwards.
- [ ] **10.6 Tari not required.** Only on the fresh box while Monero has finished its first sync
  and Tari has not: add `"tari_required": false` inside the `dashboard` block and apply. Expect:
  the miner starts without waiting for Tari, and the normal dashboard shows a `Tari syncing`
  indicator instead of the full-screen Sync view. Skip it if the timing never lines up.

## 11. Backup, restore and resets

Run on the upgrade box unless stated. The steps are destructive; run them in this order.

- [ ] **11.1 Encrypted backup.** Do: `./pithead backup`. Expect: a `.tar.gz.enc` file under
  `backups/`, mode 600.
- [ ] **11.2 Wrong passphrase.** Do: `./pithead restore backups/<file>` with a wrong passphrase.
  Expect: refused before anything changes.
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
on a DIY box that runs the previous release with `dashboard.control.enabled: true`, 12.3 on an
appliance that runs the previous release.

- [ ] **12.1 Badge.** Expect: the header shows `New release vX.Y.Z available` linking to the
  release, and an **Upgrade to vX.Y.Z** button.
- [ ] **12.2 Upgrade.** Do: click it and type `UPGRADE`. Expect: the page disconnects briefly,
  comes back on the new version, and the badge clears. Config, wallets and chains are unchanged.
- [ ] **12.3 Appliance OS update.** Skip it, recording SKIP, when the previous release shipped no
  appliance image, as for the first appliance release. Do: in the header's **OS updates** control: Check, Download,
  Verify, Install, then Reboot (type `REBOOT`). Expect: Check offers the new release; mining keeps
  running until the reboot; the page reconnects; a banner says it updated; the boot menu shows
  the new version as **current** and the old one as **previous**.

## 13. Appliance

Run on the **appliance box**. Each step names the battery row it serves (M1–M16, defined in
[appliance-release.md](appliance-release.md)); why the hands-on rows cannot be automated is in
[the hardware battery](#the-manual-hardware-battery-m1m10) below. Follow
[the appliance guide](../appliance.md) as a user would, and file anything you had to know rather
than read.

Steps 13.10–13.12 copy update bundles to the box over SSH, which only the debug image has (see
[Know which image you are holding](#know-which-image-you-are-holding)). Before 13.10, reinstall
the box from a debug-image stick and choose **Keep everything**, the same way as 13.18. After
13.12, reinstall from the release-image stick the same way. Everything else runs on the release
image. The dashboard's own update path checks for
the latest *published* release, so it is tested after publishing, in 12.3.

- [ ] **13.1 Verify and flash (M1).** Do:

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
- [ ] **13.6 Answers (M6).** Do: paste the QA subaddress first, then the primary address; keep
  every default except merge-mine Tari = yes (paste the Tari address). Press
  **Validate, then install**. Expect: the subaddress is refused with an explanation before you
  submit; after validation the page shows the dashboard login, the address
  `https://pithead.local`, and the miner address `stratum+tcp://pithead.local:3333`.
- [ ] **13.7 Install (M3).** Do: save the login, type the disk name, and press
  **I saved these — erase the disk and install.** Expect: progress is shown, then the machine
  switches itself off. Remove the stick and switch it on: it boots from the disk, the console
  narrates provisioning, and within 10–30 minutes the dashboard answers with the saved login. A
  second disk, if present, still holds its data.
- [ ] **13.8 The same checks as DIY.** Do: first, using only the setup page, the dashboard and
  [the appliance guide](../appliance.md), find the stratum password an outside miner must send
  (the appliance sets `p2pool.stratum_password` to `"auto"`). If you cannot find it, file it,
  because 4.1 and 14.1 need it. Then repeat sections 4 and 5, pointing XMRig at
  `pithead.local:3333`, and steps 7.1–7.8 (the appliance's Configuration view is always on). Set up Telegram in Configuration, then repeat
  8.2–8.4. Skip anything that needs a shell (`./pithead`, `docker`, editing `config.json`): the
  appliance has none apart from its console. Expect: the same results. The built-in miner
  appears as a worker.
- [ ] **13.9 Boot menu.** Do: reboot with a monitor attached. Expect: a five-second menu that
  names the version, its slot and **current**, plus **Set up again**; it boots by itself.
- [ ] **13.10 Update (M7).** Do: as M7 describes, copy a debug-variant bundle with a higher
  version to the box and run `pithead os-update <bundle>`. Never add `--yes` when the bundle's
  variant differs from the box's (see [Cutting](#cutting), item 3). Expect: it says the update is
  written to the spare slot, that the machine keeps running the current version until it
  reboots, and prints the exact reboot command. Run that command. After the reboot, the boot menu
  shows the new version as **current** and the old one as **previous**.
- [ ] **13.11 Pull the plug during an update (M8).** Do: start `pithead os-update` again with the
  same bundle and pull the plug while it writes. Repeat three times. Expect: the machine boots the old version every
  time.
- [ ] **13.12 Bad release rolls back (M9).** Do: install the deliberately broken bundle M9
  describes with `pithead os-update` and reboot. Expect: the machine returns to the previous
  version without anyone touching it, and the dashboard serves. The spare slot now holds the
  broken release, so do not mark anything bad yet. Do: install the good 13.10 bundle again with
  `pithead os-update`, reboot, and wait until `rauc status` no longer reads the booted slot as
  `bad` (it commits after its health check, about 3 minutes into the boot). Then run
  `rauc status mark-bad booted && reboot`. Expect: the machine comes back on the other slot, on a
  good version, with the dashboard serving.
- [ ] **13.13 Backup (M15, first half).** Do: write down the payout address, the onion address and
  the time. In **Backup**, click **Back up now** and save both downloads: the archive and its
  emergency kit. Expect: the dashboard disconnects briefly and comes back.
- [ ] **13.14 Restore (M15, second half).** Do: power off the appliance box, so two machines
  never run the same identity at once. Boot the stick on the second PC (not this box: later steps
  need its chain), and on the setup page choose **Restoring an existing Pithead? Upload its backup
  instead.** Enter a wrong passphrase first, then the right one. Expect: the wrong passphrase is
  rejected with the reason and the form stays open; with the right one the machine provisions
  itself, and its payout address and onion address match your notes. Then power the second PC
  off and the appliance box back on.
- [ ] **13.15 Settings after setup (M16).** Do: follow M16: a benign energy change, then a node
  endpoint change that needs `APPLY`. Expect: as M16 describes, and the page reconnects by itself
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
- [ ] **13.19 Power loss while mining (M10).** Do: pull the plug at the wall while mining, wait
  30 seconds, plug it back in, and do not touch the machine. Expect: it powers on by itself and
  returns to mining; the dashboard answers.

## 14. RigForge rig

Run on a loaner rig, with the appliance from section 13 as the coordinator. These are the
hands-on rows M11–M13 in [the rig battery](#the-rig-role-manual-battery-m11m13).

- [ ] **14.1 Install a rig (M11).** Do: boot the stick on the rig, choose **RigForge**, accept the
  pool address it fills in (`pithead.local:3333`), enter the stratum password from 13.8, name
  the worker, choose the internal disk, and copy the control token. Expect: the rig mines; the coordinator lists the worker badged
  `not adopted`; `doctor` on the rig reports MSR applied and HugePages reserved.
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
  confirm. Expect: the dashboard answers at `https://qa-box.local` after one new certificate
  warning, and keeps that name after a reboot.
- [ ] **15.2 Config reset.** Do: at the console, log in as `root` with the dashboard password and
  run `pithead config-reset`. Expect: you must type to confirm; the machine reboots into the setup
  wizard, and after you answer again the chains are still synced.
- [ ] **15.3 Factory reset.** Do: `pithead factory-reset`. Expect: you must type to confirm; the
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
- [ ] **S4 — A rig dies.** Unplug a miner's network for 10 minutes, then reconnect it. Expect:
  offline and recovered messages arrive once each, and the dashboard history marks both events.
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

That protocol covers the **rigs**. It does not cover the appliance under test, which
[#1022](https://github.com/p2pool-starter-stack/pithead/issues/1022) records as having no lock, no
holder marker and no contract file of its own — so nothing stops two sessions working on it at
once, and the battery below reflashes and factory-resets the box. A collision costs whoever else
is holding it both their run and the chain on that disk. Until #1022 lands a mechanism, reserving
the appliance is an agreement between sessions and nothing enforces it: say in your handoff that
you are holding it, and say when you let go.

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
checks remain hands-on until #1022 can collect the scripted and attested results together.

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
- Configuring **by paste** for both addresses (M6, which now needs a yes to merge-mining first —
  a new machine is asked for the Monero address only): a wallet address typed by hand is a support
  ticket waiting to happen.

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
