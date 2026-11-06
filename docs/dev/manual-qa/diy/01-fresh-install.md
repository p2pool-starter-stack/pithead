# 1. Fresh DIY install

This part tests the path a new user takes, from an empty machine to a stack that is [syncing](../README.md#glossary) its Monero chain.

## Before you start

- **Machine:** the **fresh box**, Ubuntu Server 24.04 with nothing of Pithead on it (full spec in [What you need](../what-you-need.md)). It may be a virtual machine: see [sandbox-vm.md](sandbox-vm.md), and start from its *clean* snapshot.
- **Earlier steps:** none. 1.1–1.11 are session 2 of the [Run sheet](../README.md#run-sheet). 1.12 applies only to the separate Tari opt-in run from 1.4b, while Monero has synced and Tari has not. 1.13 waits for session 9, once Monero has synced; also check Tari there if opted in.
- **Have ready:** the candidate's full commit SHA; the QA Monero wallet's **primary** address and one **subaddress** of it; the Tari QA address; the laptop on the same network, with a browser.
- **Why from source:** build the candidate from source, so a failure here does not spend the version tag.
- **Time:** about 2 hours hands-on for 1.1–1.11, then hours to days of chain sync: 1.12 runs partway through it, 1.13 after it.

## Steps

### 1.1 Get the candidate

**What you do:**

1. On the fresh Ubuntu machine, install the build tools first:

   ```bash
   sudo apt update && sudo apt install -y git make
   ```

2. Download the source and go into it:

   ```bash
   git clone https://github.com/p2pool-starter-stack/pithead.git
   cd pithead
   ```

3. Switch to the candidate. Replace `<full candidate SHA>` with the full commit SHA of the release candidate (all 40 characters, not the short form):

   ```bash
   git checkout <full candidate SHA>
   ```

4. Build it:

   ```bash
   make
   ```

5. Print the version:

   ```bash
   ./pithead version
   ```

**What you should see:**

- `make` finishes without errors.
- `./pithead version` prints `pithead dev (... @ <short SHA>, VERSION <the version being released>)`. Here `<short SHA>` is the first few characters of the candidate SHA, and `<the version being released>` is the release number.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.2 Help and typos

**What you do:**

1. Show the help:

   ```bash
   ./pithead help
   ```

2. Run a command that does not exist:

   ```bash
   ./pithead bogus
   ```

3. Run two commands that cannot be chained:

   ```bash
   ./pithead up down
   ```

**What you should see:**

- `help` lists every command with a one-line description.
- `bogus` prints `Unknown command: bogus. Run './pithead help'.`
- `up down` is refused with `Invalid chain` and `Nothing was run.`

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.3 Before setup

**What you do:**

1. Ask for the status before anything is set up:

   ```bash
   ./pithead status
   ```

**What you should see:**

- `No .env found. Run './pithead setup' first.`

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.4 Setup wizard

**What you do:**

1. Make sure no `config.json` is present in the install directory.
2. Start the setup [wizard](../README.md#glossary):

   ```bash
   ./pithead setup
   ```

3. On a machine where setup has just installed Docker, it may stop first with `Docker daemon is not reachable` and tell you to join the `docker` group. If it does, run this, log out and back in, and run `./pithead setup` again:

   ```bash
   sudo usermod -aG docker $USER
   ```

4. At the payout prompt, paste the QA **subaddress** first.
5. When it asks again, paste the QA **primary** address.
6. Answer the remaining questions like this:
   - Monero node: local.
   - Pool: `mini`.
   - Tari: press Enter for the default (No). Keep this Monero-only run separate from 1.4b and 1.4c.
   - The [stratum](../README.md#glossary) password question, `Enable stratum password?`: the default (off).
   - The faster first sync: decline.
   - [Tor](../README.md#glossary) dashboard access: decline.
   - Telegram: decline.
   - Local mining: decline.
   - `Enter Hostname`: accept the default.
   - `Modify GRUB for persistent HugePages now?`: answer `y`.
7. If setup does not ask about GRUB (HugePages are already persistent), it asks `Start Pithead now? (Y/n)` instead: answer `y`, and skip the reboot in 1.5.
8. Write down the dashboard login the wizard shows. It is shown once, and you need it in 1.8.
9. Check the permissions of the file setup wrote:

   ```bash
   ls -l config.json
   ```

**What you should see:**

- The subaddress is refused with an explanation, and you are asked again.
- Per #3099, #3092 and #3090:
  - The Tari question is labelled beta and says a yes syncs a Tari chain over Tor. Enter means No on any disk; the wizard says declining is the default. A Yes asks for the Tari address and writes `dashboard.tari_required: false`.
  - The wizard does not ask about the XvB raffle and leaves it off.
  - It generates a dashboard login and shows it once.
  - It keeps the first sync on Tor unless you opt in. The fast-sync offer covers each chain the stack runs locally, and warns that it exposes your IP to the Monero network and, if Tari is on, the Tari network.
  - At the end it prints the LAN pool URL and says `none set` for the stratum password.
- Setup also checks dependencies.
- It warns, but does not stop, if disk or RAM is below the documented floor.
- It writes `config.json` and provisions Tor.
- It ends with `System optimization requires a reboot.` and the commands to run next (or with the `Start Pithead now? (Y/n)` question from item 7).
- `ls -l config.json` shows `-rw-------`.

**Record**: PASS, FAIL or N/A in the results sheet. Keep the dashboard login for 1.8.

### 1.4a The wizard wrote the new-install defaults

**What you do:**

1. Print what the wizard chose. This prints booleans and modes only, never a secret:

   ```bash
   jq '{xvb, tari_mode: .tari.mode, stratum_set: ((.p2pool.stratum_password // "") != ""), dashboard_login: (.dashboard.auth.password // "" | length > 0), fast_sync: [.monero.clearnet_initial_sync, .tari.clearnet_initial_sync]}' config.json
   ```

2. Print the config version stamp:

   ```bash
   jq -r .config_version config.json
   ```

**What you should see:**

Per #3333, #3099 and #3092:

- `"xvb": { "enabled": false }`.
- Fresh Enter-through expectation: `tari_mode=off`, regardless of free disk.
- No Tari payout address is needed, and no Tari node starts.
- `stratum_set` is `false`.
- `dashboard_login` is `true`.
- Both `fast_sync` entries are `false` or `null`.
- `jq -r .config_version config.json` prints the candidate's release number (2.3 explains the stamp).

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.4b Explicit Tari beta opt-in

**What you do:**

1. Use a separate fresh box or VM cloned from the clean snapshot, with no `config.json` or retained chain data. Keep the default run from 1.4–1.4a intact.
2. Repeat 1.1–1.4, but explicitly choose Yes (beta) for Tari and provide the QA Tari address. Decline faster first sync.
3. Run the mode query from 1.4a, then print the mining requirement:

   ```bash
   jq '.dashboard.tari_required' config.json
   ```

4. Continue 1.5–1.13 on this separate run, recording it as the opt-in case.

**What you should see:**

- `tari_mode` is `local`, and `dashboard.tari_required` is `false`.
- The local Tari node downloads and syncs its chain over Tor.
- Monero mining starts once Monero is synced, without waiting for Tari.

**Record**: PASS, FAIL or N/A separately from the default run.

### 1.4c Reinstall with a retained Tari chain

**What you do:**

1. On a disposable reinstall fixture, keep an existing `data/tari` chain occupying at least half the Tari disk budget (100 GiB). Keep this separate from the fresh-box runs.
2. With the old stack stopped and its config backed up outside the install directory, remove `config.json` and repeat 1.4. Press Enter at the Tari question and provide the QA Tari address when asked.
3. Run the mode query from 1.4a.

**What you should see:**

- The wizard says keeping merge-mining on is the default, and `tari_mode` is `local`.
- This exception follows retained chain data, not free disk. An existing config or an upgrade keeps its configured mode; it is not a new wizard run.

**Record**: PASS, FAIL or N/A separately from the fresh-box runs. Record N/A if no retained-chain fixture is available.

### 1.5 HugePages reboot

**What you do:**

1. Reboot the machine:

   ```bash
   sudo reboot
   ```

2. When it is back, start the stack from the install directory:

   ```bash
   ./pithead up
   ```

**What you should see:**

- The stack starts.
- This first start prints `The miner is held until the initial sync finishes for Monero, then starts automatically.`
  The wizard leaves Tari off by default and makes it non-required when opted in. A config with
  Tari enabled and `dashboard.tari_required` true names `Monero and Tari` instead.
- A later `./pithead restart` does not print the note again.
- Per #3090, `up` also prints the LAN pool URL and `none set` for the stratum password, every time.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.6 Status while syncing

**What you do:**

1. Show the status:

   ```bash
   ./pithead status
   ```

**What you should see:**

- Each node and support service shows a `✓` line ending in `running`.
- `p2pool` and `xmrig-proxy` show `⚠` with `held until the required chains finish syncing`.
- Under `Chain sync in progress — the miner is held until it completes:`, Monero shows its percent and blocks remaining.
- Sync-hold rows: `monero` in both fresh runs (default and beta opt-in). Tari is not listed there in either run: it is off by default and non-required after the opt-in.
- No `✗` line.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.7 Doctor

**What you do:**

1. Run the health check:

   ```bash
   ./pithead doctor
   ```

2. Run it again as JSON:

   ```bash
   ./pithead doctor --json | python3 -m json.tool
   ```

**What you should see:**

- A readable report with no FAIL line.
- It includes `Tor-only egress firewall is installed`.
- Any WARN line names a fix you can follow.
- The second command prints valid JSON with the same checks.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.8 Sync Mode in the browser

**What you do:**

1. On the laptop, open the URL that setup printed, of the form `https://<hostname>`. `<hostname>` stands for the box's name.
2. [Verify and trust the installation's root CA](../../../configuration.md#exposing-the-dashboard-safely), then reload the dashboard.
3. Log in with the dashboard login you saved in 1.4.

**What you should see:**

- A valid HTTPS connection, then the login.
- Then the **Sync Mode** screen, with Monero progress and a held-miner notice. Tari is absent in the default run; in the opt-in run, it does not delay Monero mining.
- The top bar shows CPU, RAM, HugePages and disk.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.9 Logs

**What you do:**

1. Follow the Monero node's log, watch it for a minute, then press Ctrl-C to stop:

   ```bash
   ./pithead logs monerod
   ```

2. Only in the opt-in run from 1.4b, do the same for the Tari node:

   ```bash
   ./pithead logs tari
   ```

**What you should see:**

- The logs follow live and show the node syncing.
- No repeating error.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.10 Faster first sync over clearnet

**What you do:**

1. Edit `config.json`: add `"clearnet_initial_sync": true` inside the `monero` block. [Sample configs](../sample-configs.md#sample-configs) explains how to add a key inside a block.
2. [Apply](../README.md#glossary) the change, and answer yes when it asks:

   ```bash
   ./pithead apply
   ```

3. Show the status:

   ```bash
   ./pithead status
   ```

4. Run the health check:

   ```bash
   ./pithead doctor
   ```

5. Look at the dashboard on the laptop.

**What you should see:**

- Apply marks the change ⚠ and asks first.
- `./pithead status` then prints a `CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING` banner.
- `./pithead doctor` shows a WARN.
- The dashboard shows a warning badge.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.11 Leave it syncing

**What you do:**

1. Note the time.
2. Check back every few hours. `./pithead status` shows required Monero progress while mining is held, as in 1.6. In the opt-in run, follow passive Tari progress on the dashboard or with `./pithead logs tari`.
3. In the opt-in run only, do 1.12 when Monero has finished and Tari has not.
4. Do 1.13 when Monero is synced; in the opt-in run, also check the later Tari sync completion.

**What you should see:**

- Nothing to check in this step: 1.12 and 1.13 hold the checks.

**Record**: PASS, FAIL or N/A in the results sheet, and write down the time you noted.

### 1.12 Tari not required

**What you do:**

1. On the default Monero-only run, record N/A: Tari is off.
2. On the separate opt-in run from 1.4b, run this step while Monero has finished its first sync and Tari has not.
3. Confirm `dashboard.tari_required` is already `false`, then check the dashboard and `./pithead status`. No config edit or apply is needed.

**What you should see:**

- The miner starts without waiting for Tari.
- The normal dashboard shows a `Tari syncing` indicator instead of the full-screen Sync view.
- Per #3091, a Tari node that is syncing is never treated as down: no worker is rejected for it while it catches up, whatever `tari_required` says.
- No `Tari DOWN` badge shows.
- If the test chat is set up on this box, one message that starts `Tari node is syncing` arrives, once.
- For reference: only an unreachable Tari node (10.5) can reject workers, and then only with `tari_required` true.

**Record**: PASS, FAIL or N/A in the results sheet. Record SKIP only if Tari finished its first sync before Monero did, so the window never happened, and say so. A window you missed is not a SKIP: 1.12 is not covered yet. Note it as missed and repeat the step: on a VM, revert to the *clean* snapshot as [Two boxes at once](sandbox-vm.md#two-boxes-at-once) describes; on a real machine, reinstall from an empty disk. Then repeat the opt-in case from 1.4b through 1.11 and check the dashboard more often during the sync.

### 1.13 Sync finishes

**What you do:**

1. Wait until Monero is synced, without touching the stack. For the separate opt-in run, also observe Tari finishing its sync later.
2. Look at the dashboard on the laptop.
3. Show the status:

   ```bash
   ./pithead status
   ```

4. Run the health check:

   ```bash
   ./pithead doctor
   ```

**What you should see:**

- Once Monero is synced, the dashboard shows the full operational view by itself and mining begins. In the opt-in run, the `Tari syncing` indicator from 1.12 clears once Tari also syncs.
- The miner runs without anyone touching it.
- Monero returns to Tor by itself: the status banner is gone.
- `./pithead doctor` reports `all node P2P is Tor-only`.

**Record**: PASS, FAIL or N/A in the results sheet.
