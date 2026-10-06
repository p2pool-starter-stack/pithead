# 7. Change settings from the dashboard

This part checks the dashboard's **Configuration** view: the form, the read-only config version, ordinary, disruptive and payout changes, refusals, the health check, the logs, and finding the view keys from the docs alone.

## Before you start

- Machine: the **upgrade box**, with the dashboard open on the laptop.
- Earlier steps: [section 6](06-settings-command-line.md), with `config.json` restored in 6.8. Step 7.8 counts the wrong password from [5.10](05-dashboard-tour.md#510-login).
- Have ready:
  - The second Monero QA wallet: its primary address and its private [view key](../README.md#glossary).
  - The QA subaddress (starts with `8`).
  - For 7.9: the two QA wallets open in the official Monero GUI wallet and in Tari Universe.
- Every change here is made in the form, then checked in a [preview](../README.md#glossary) before you confirm it, as `./pithead` [apply](../README.md#glossary) does on the command line.
- Time: about 1.5 hours. It is part of session 5 in the [Run sheet](../README.md#run-sheet).

## Turn on the Configuration view

1. Open `config.json` on the upgrade box.
2. Inside its `dashboard` block, make sure `auth.password` is set.
3. Inside the same block, add `"control": { "enabled": true }`.
4. Run `./pithead apply`.
5. If the Configuration view was off, the preview marks turning it on with ⚠ and asks `(y/N)`. Answer `y`.

## Steps

### 7.1 Configuration view

**What you do:**

1. Open **Configuration** from the toggle above the chart.

**What you should see:**

- A form with grouped sections and an Advanced JSON pane.
- Secrets show as "set — leave blank to keep", never their values.
- The config file version (`config_version`) shows as plain text, not as a field (#3109).

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.1a The config version is read-only

**What you do:**

1. On the upgrade box, run `jq -r .config_version config.json` and write down the value.
2. Look for `config_version` in the Advanced JSON pane.
3. Add `"config_version": "1.0.0"` at the top level of the pane.
4. Change an energy price in the form.
5. Click **Save & preview changes**, then confirm.
6. Run `jq -r .config_version config.json` again.
7. DIY only: edit `config.json` by hand and set the stamp to `"9.9.9"`, as in [6.10](06-settings-command-line.md#610-a-config-newer-than-the-code-warns), then reload the Configuration view.
8. Put the stamp back by hand to the value you wrote down.

**What you should see:**

Per #3109:

- The pane never shows `config_version`.
- The pasted value is ignored, so the preview has no row for it.
- The stamp on disk is unchanged.
- **Recent config changes** has no `config_version` row.
- With the stamp at 9.9.9, the view warns `This configuration was written by a newer Pithead version.` and says saving is blocked while it holds settings this version does not know.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.2 Benign change

**What you do:**

1. Set an energy price.
2. Click **Save & preview changes**.
3. Confirm.
4. Reload the page.

**What you should see:**

- A preview with one row per changed setting.
- After confirming, the value shows on the Energy tab.
- The value survives the reload.
- The change appears in **Recent config changes**.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.3 Ordinary change

**What you do:**

1. Change the P2Pool sidechain to `nano`.
2. Click **Save & preview changes**, then confirm.
3. Change it back the same way.

**What you should see:**

- No typing is needed to confirm.
- The change applies, and the dashboard follows it.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.3a Turn the XvB raffle on and off

**What you do:**

1. In Configuration, flip `xvb.enabled`.
2. Preview and confirm. Type `APPLY` if it asks.
3. Wait a few minutes and look at the dashboard.
4. Flip `xvb.enabled` back the same way, and look again.

**What you should see:**

- The preview names the change.
- With XvB on, the five XvB raffle tiles show within a few minutes.
- With XvB off, they are gone ([10.1](10-node-and-pool-modes.md#101-monero-only) checks the same).

A new install leaves XvB off and never asks (#3099), so this panel is where a user turns it on.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.4 Disruptive change

**What you do:**

1. Change the [stratum](../README.md#glossary) port to `3334` and preview.
2. Try to confirm without typing anything.
3. Type `APPLY` and confirm.
4. Change the port back to `3333` the same way.

**What you should see:**

- The row is marked ⚠ and says every [rig](../README.md#glossary) must repoint.
- The commit is refused until you type `APPLY`.
- After it applies, miners on 3333 disconnect.
- After you change it back to `3333`, the miners reconnect.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.5 Payout change

**What you do:**

1. Change the Monero payout address to the second QA primary address. If `monero.view_key` is set, change its view key to the second wallet's key too.
2. Preview.
3. At the confirmation, type `APPLY` and a wrong last-eight suffix.
4. Type `APPLY` and the last eight characters of the new address, and confirm.
5. Change the address (and view key) back the same way.
6. If `monero.view_key` is set: enter the new address with a view key that does not belong to it, and preview.

**What you should see:**

- The change is marked ⚠.
- The confirmation asks you to type `APPLY` and the last eight characters of the new address. The command line asks for the same ([6.4](06-settings-command-line.md#64-payout-change-asks-for-the-address), #3097).
- A wrong suffix is refused.
- After it applies, the **Payout wallet changed** badge appears.
- With a view key set, the preview refuses a key that does not belong to the new address, with the same message as [6.4a](06-settings-command-line.md#64a-payout-wallet-follows-the-address-and-view-key) (#3096).

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.6 Bad value

**What you do:**

1. Paste the QA subaddress into the Monero address field and preview. Put the field back afterwards.
2. In the Advanced pane, add a second top-level `"p2pool"` block and preview. Remove it afterwards.
3. Type `PASTE_QA_X` into the dashboard password field and preview.

**What you should see:**

- The subaddress is refused with the same message as the command line.
- The duplicated block is refused, and the message names the key (#3098).
- The placeholder is refused, and the message names the key (#3098).
- Nothing is applied.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.7 Health check and log

**What you do:**

1. Click **Run health check**.
2. Click **Show recent log**.

**What you should see:**

- The doctor rows appear, grouped, with remedies.
- The log shows recent lines, with credentials redacted.

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.8 Access log

**What you do:**

1. Open the **Access log**.

**What you should see:**

- It lists your recent requests.
- It counts the wrong password from step [5.10](05-dashboard-tour.md#510-login).

**Record:** PASS, FAIL or N/A in the results sheet.

### 7.9 Get the view keys from the docs alone

**What you do:**

1. Have only the two QA wallets open, in the official Monero GUI wallet and in Tari Universe, and the payout-confirmation instructions in [The Dashboard](../../../dashboard.md) (the section [Getting your view keys](../../../dashboard.md#getting-your-view-keys)).
2. With no other help, find the Monero secret view key and restore height, and the Tari view key and wallet birthday.
3. Enter them in Configuration's payout settings, preview and confirm.
4. Paste the Monero *public* view key into the Monero view key field and preview.

**What you should see:**

Per #3112:

- The docs name every menu or file you needed.
- You never needed the spend key, the seed words or a wallet password.
- The matching values are accepted.
- The public key is refused with a message that points at the docs section, not at a label either wallet lacks.

**Record:** PASS, FAIL or N/A in the results sheet. Write down every place you hesitated.
