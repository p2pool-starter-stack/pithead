# 1. Fresh DIY install

This part tests the path a new user takes, from an empty machine to a stack that is [syncing](../README.md#glossary) its chains.

## Before you start

- **Machine:** the **fresh box**, Ubuntu Server 24.04 with nothing of Pithead on it (full spec in [What you need](../what-you-need.md)). It may be a virtual machine: see [sandbox-vm.md](sandbox-vm.md), and start from its *clean* snapshot.
- **Earlier steps:** none. 1.1–1.11 are session 2 of the [Run sheet](../README.md#run-sheet); 1.12 and 1.13 wait for session 9, once the fresh box has synced.
- **Have ready:** the candidate's full commit SHA; the QA Monero wallet's **primary** address and one **subaddress** of it; the Tari QA address; the laptop on the same network, with a browser.
- **Why from source:** build the candidate from source, so a failure here does not spend the version tag.
- **Time:** about 2 hours hands-on for 1.1–1.11, then hours to days of chain sync before 1.12 and 1.13.

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
   - Tari: the default and, if it asks, the Tari address.
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
  - Tari is on when the disk fits both chains and off when it does not, and the wizard says which. On a fitting disk it asks for the Tari address.
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

Per #3099 and #3092:

- `"xvb": { "enabled": false }`.
- `tari_mode` is `local` on a fitting disk and `off` otherwise.
- `stratum_set` is `false`.
- `dashboard_login` is `true`.
- Both `fast_sync` entries are `false` or `null`.
- `jq -r .config_version config.json` prints the candidate's release number (2.3 explains the stamp).

**Record**: PASS, FAIL or N/A in the results sheet.

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
- This first start prints a short note that the miner is held until both chains sync.
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
- Under `Chain sync in progress — the miner is held until it completes:` each chain shows its percent and blocks remaining.
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
2. Accept the one-time certificate warning.
3. Log in with the dashboard login you saved in 1.4.

**What you should see:**

- A one-time certificate warning, then the login.
- Then the **Sync Mode** screen, with a progress line per chain and a held-miner notice.
- The top bar shows CPU, RAM, HugePages and disk.

**Record**: PASS, FAIL or N/A in the results sheet.

### 1.9 Logs

**What you do:**

1. Follow the Monero node's log, watch it for a minute, then press Ctrl-C to stop:

   ```bash
   ./pithead logs monerod
   ```

2. Do the same for the Tari node:

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
2. Check back every few hours. `./pithead status` shows how far each chain has got, as in 1.6.
3. Do 1.12 if you catch the moment Monero has finished and Tari has not.
4. Do 1.13 when both are synced.

**What you should see:**

- Nothing to check in this step: 1.12 and 1.13 hold the checks.

**Record**: PASS, FAIL or N/A in the results sheet, and write down the time you noted.

### 1.12 Tari not required

**What you do:**

1. Run this step only while Monero has finished its first sync and Tari has not.
2. Add `"tari_required": false` inside the `dashboard` block of `config.json`.
3. Apply the change:

   ```bash
   ./pithead apply
   ```

**What you should see:**

- The miner starts without waiting for Tari.
- The normal dashboard shows a `Tari syncing` indicator instead of the full-screen Sync view.
- Per #3091, a Tari node that is syncing is never treated as down: no worker is rejected for it while it catches up, whatever `tari_required` says.
- No `Tari DOWN` badge shows.
- If the test chat is set up on this box, one message that starts `Tari node is syncing` arrives, once.
- For reference: only an unreachable Tari node (10.5) can reject workers, and then only with `tari_required` true.

**Record**: PASS, FAIL or N/A in the results sheet. Record SKIP if the timing never lines up.

### 1.13 Sync finishes

**What you do:**

1. Wait until both chains are synced, without touching the stack.
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

- Once both chains are synced, the dashboard shows the full operational view by itself (from Sync Mode, or from the `Tari syncing` indicator after 1.12).
- The miner runs without anyone touching it.
- Monero returns to Tor by itself: the status banner is gone.
- `./pithead doctor` reports `all node P2P is Tor-only`.

**Record**: PASS, FAIL or N/A in the results sheet.
