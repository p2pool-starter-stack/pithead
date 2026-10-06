# 6. Change settings from the command line

This part checks that editing `config.json` and [applying](../README.md#glossary) it with `./pithead apply` shows a correct [preview](../README.md#glossary), asks before disruptive and payout changes, refuses bad values, and keeps the stack healthy.

## Before you start

- Machine: the **upgrade box**, in a terminal in the install directory.
- Earlier steps: sections 2 to 5, ending with the [Dashboard tour](05-dashboard-tour.md).
- Have ready:
  - The second Monero QA wallet: its primary address and its private [view key](../README.md#glossary).
  - A single-key Tari address, for 6.4b.
  - [Config B](../sample-configs.md) from the sample configs, for its `monero.view_key` and its `tari` block (6.4a and 6.4b).
  - The [Broken configs](../sample-configs.md#broken-configs) table, for 6.5.
- Keep a copy of the working `config.json` before you change anything, and restore it at the end (6.8):

  ```bash
  cp config.json config.json.qa
  ```

- Every change here goes through [apply](../README.md#glossary), which first prints a [preview](../README.md#glossary) of what changes. A `•` line is an ordinary change; a `⚠` line is a disruptive one.
- Time: about 1.5 hours. It is part of session 5 in the [Run sheet](../README.md#run-sheet).

## Steps

### 6.1 Preview only

**What you do:**

1. In `config.json`, change `p2pool.pool` (the `pool` key inside the `p2pool` block) to `nano`.
2. Run:

   ```bash
   ./pithead apply --dry-run
   ```

**What you should see:**

- A `•` line `P2Pool sidechain changing ... your PPLNS window resets`.
- Nothing is recreated.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.2 Ordinary change

**What you do:**

1. Run:

   ```bash
   ./pithead apply
   ```

2. Watch the dashboard for a few minutes.
3. Set `p2pool.pool` back to its earlier value and run `./pithead apply` again.

**What you should see:**

- No question is asked: a `•` change is not disruptive.
- p2pool is recreated.
- The dashboard shows the `nano` sidechain within a few minutes.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.3 Disruptive change asks first

**What you do:**

1. Add `"rpc_lan_access": true` inside the `monero` block.
2. Run `./pithead apply`.
3. Answer `n`.
4. Remove the key again.

**What you should see:**

- The change is listed with `⚠`.
- Then `Some of the changes above (⚠) are disruptive.` and a `(y/N)` question.
- Answering `n` prints `Apply cancelled. No changes were made.`

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.4 Payout change asks for the address

**What you do:**

1. Set `monero.wallet_address` to the second QA primary address. If `monero.view_key` is set on this box, change it to the second wallet's key in the same edit, and do [6.4a](#64a-payout-wallet-follows-the-address-and-view-key) together with this step.
2. Run `./pithead apply`. At the prompt, type some wrong characters.
3. Run `./pithead apply` again. At the prompt, type the first 8 characters of the new address.
4. Run `./pithead apply` a third time. At the prompt, type the last 8 characters of the new address (#3097).
5. Put the original address back the same way: edit `config.json`, run `./pithead apply`, and type the last 8 characters of the original address.

**What you should see:**

- The warning `The Monero payout wallet address is changing — ALL future Monero rewards go to the new address.`
- The prompt `Confirm by typing the last 8 characters of the new address (<last 8>).`
- The wrong answer cancels with no change.
- The first 8 characters cancel with no change.
- The last 8 characters apply the change.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.4a Payout wallet follows the address and view key

This step needs `monero.view_key` set to the first QA wallet's key, as in [Config B](../sample-configs.md), and the payout card green on **Earnings**.

**What you do:**

1. Set `monero.wallet_address` to the second QA primary address, leave the first wallet's view key in place, and run `./pithead apply`.
2. Set the second wallet's view key as well, run `./pithead apply`, and type the last 8 characters of the address. Watch the Earnings card.
3. Put both the address and the view key back, run `./pithead apply`, and type the last 8 characters again.

**What you should see:**

Per #3096:

- Item 1 is refused before anything changes, with `monero.view_key does not belong to monero.wallet_address: the public view key differs.`, followed by a pointer to the docs section on getting your view keys.
- In item 2 the preview reads `Payout confirmation view key CHANGED — a new view-only wallet is opened for this address (the previous one is kept).`
- In item 2 the card turns green after the new wallet catches up, within minutes, because a fresh automatic wallet starts 100 blocks behind the local node's tip.
- In item 3 the first wallet reopens, and the card is green again with no rescan.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.4b Tari payout confirmation needs a dual-key address and asks only for the view key

This step needs the `tari` block from [Config B](../sample-configs.md) (the address and `view_key`, no `spend_public_key`) and a green Tari payout card.

**What you do:**

1. Set `tari.spend_public_key` to 64 zeros (the digit `0` typed 64 times) and run `./pithead apply`.
2. Remove the `spend_public_key` key again.
3. Set `tari.wallet_address` to the single-key Tari address, keep `view_key`, and run `./pithead apply`.
4. Put the QA Tari address back, run `./pithead apply`, and type the last 8 characters if it asks.

**What you should see:**

Per #3096 and #2732:

- The `tari` block from Config B is accepted without a spend key, because the public spend key is read from the address.
- Item 1 is refused with `tari.spend_public_key disagrees with tari.wallet_address. Leave it empty to derive the public spend key from the address.`
- Item 3 is refused with `Tari payout confirmation needs a dual-key address, which Tari Universe gives by default. A single-key address carries no public view key to check tari.view_key against. Mining payouts to single-key addresses remain supported.`
- Item 4 applies, and the card is green again with no rescan.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.5 Broken configs

**What you do:**

1. Work through every row of [Broken configs](../sample-configs.md#broken-configs), one row at a time.
2. Run `./pithead status` between rows.

**What you should see:**

- Each refusal matches its row.
- `./pithead status` stays healthy throughout.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.6 Render

**What you do:**

1. Run:

   ```bash
   ./pithead render
   ```

**What you should see:**

- It finishes.
- No container restarts.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.7 Rotate secrets

**What you do:**

1. Run this and confirm when it asks:

   ```bash
   ./pithead rotate-secrets
   ```

2. If `p2pool.stratum_password` is `"auto"`, give each miner the new [stratum](../README.md#glossary) password from `.env` (`grep PROXY_STRATUM_PASSWORD .env` shows it).

**What you should see:**

- It names what changes.
- It keeps `.bak-` copies.
- It recreates the affected containers.
- If `p2pool.stratum_password` is `"auto"`, miners with the old password are now rejected; with the new one from `.env` they mine again.
- With a password you set yourself, the stratum password does not change.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.8 Restore

**What you do:**

1. Run:

   ```bash
   cp config.json.qa config.json && ./pithead apply
   ```

2. Answer `y`.

**What you should see:**

- The preview marks the node RPC login change ⚠ ([6.7](#67-rotate-secrets) rotated it) and asks `(y/N)`.
- After `y`, the original settings are back.

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.9 Mine on the stack machine

**What you do:**

1. Add `"local_miner": { "enabled": true }` to `config.json` as a top-level block.
2. Run `./pithead apply`.
3. Run `./pithead apply` again, with nothing changed.
4. Optional: install RigForge on this machine with the pool URL and stratum password that apply printed (see [Connecting Miners](../../../workers.md)).
5. Afterwards, remove the `local_miner` block and run `./pithead apply` again.

**What you should see:**

Per #3090:

- The first apply changes no rendered setting, yet it still announces the local miner.
- The first apply prints the LAN pool URL and the stratum password (or `none set`) that a RigForge install on this machine needs.
- The second apply reports no configuration changes, and still prints the pool URL and the stratum password (or `none set`).
- If you installed RigForge with those values, the worker appears in Workers Alive.
- Removing the block does not uninstall RigForge. If you installed it, it stays as an extra worker in later sections.

On the appliance the same toggle also starts or stops the built-in miner in the same apply; that is checked in [13.8a](../appliance/13a-install-and-first-boot.md).

**Record:** PASS, FAIL or N/A in the results sheet.

### 6.10 A config newer than the code warns

**What you do:**

1. Run this and write down the value it prints:

   ```bash
   jq -r .config_version config.json
   ```

2. Edit `config.json` and change the `config_version` value to `"9.9.9"`.
3. Run `./pithead render`, then check its exit code:

   ```bash
   ./pithead render
   echo "exit=$?"
   ```

4. Run `jq -r .config_version config.json` again.
5. Put the value you wrote down back by hand.
6. Run `./pithead render` again.

**What you should see:**

Per #3109:

- The first render exits 0 (`exit=0`).
- It warns `config.json was written by pithead 9.9.9; this is <version>. Settings added after <version> are ignored until you update.`
- The stamp still reads `9.9.9`: a stamp is never rewritten downward.
- The second render prints no warning.

Step [7.1a](07-settings-dashboard.md#71a-the-config-version-is-read-only) shows the same condition in the dashboard.

**Record:** PASS, FAIL or N/A in the results sheet.
