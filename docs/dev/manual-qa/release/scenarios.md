# Scenarios

This file tests the product through short stories that cross sections: each one is how a real user meets the product.

## Before you start

- **When.** Run them after the walkthrough sections (1–15), on whichever machine fits. In the [Run sheet](../README.md#run-sheet) they are session 13: S1–S8 first (S4 and S7 may wait for the soak), then 11.6 and 11.7 last.
- **Machines.** The fresh box, the upgrade box, and a clean machine for S1. S7 needs the phone with [Tor](../README.md#glossary) Browser (or Orbot) and the Telegram test bot from [What you need](../what-you-need.md). S8 needs a disposable box.
- **During a soak.** S4 and S7 may run on the soak appliance during its 7-day window. S6 and S8 are forbidden there: run them on the second appliance. See [Testing a debug RC on the soak box](../appliance/README.md#testing-a-debug-rc-on-the-soak-box).
- **Time.** About 3 hours, including 11.6 and 11.7.

## Steps

### S1 — New home miner

**What you do:**

1. On a clean box, follow only [Getting Started](../../../getting-started.md), with no other help.
2. Note every place you hesitated.

**What you should see:**

- You reach a mining dashboard without needing anything the guide does not say.

**Record:** PASS, FAIL or N/A in the results sheet, and the list of places you hesitated.

### S2 — Payout address typo

**What you do:**

1. Take a payout address and change one character, as a user who pasted it wrong would.
2. Paste it in the CLI [wizard](../README.md#glossary).
3. Put it in `config.json`.
4. Paste it in the dashboard.
5. Paste it in the appliance setup page.

**What you should see:**

- All four refuse it.
- All four refusals mean the same thing.
- Each refuses it before anything mines.

**Record:** PASS, FAIL or N/A in the results sheet.

### S3 — Power cut overnight

**What you do:**

1. Pull the plug on a DIY box while it is mining.
2. Power it back on.
3. Do not run any command.

**What you should see:**

- The stack comes back without anyone running a command.
- Its firewall comes back without anyone running a command. The firewall check is [9.2](../diy/09-privacy-tor.md#92-survives-a-reboot).
- Miners reconnect.

**Record:** PASS, FAIL or N/A in the results sheet.

### S4 — A rig dies

A [rig](../README.md#glossary) is a machine that only mines.

**What you do:**

1. Unplug a miner's network for 10 minutes.
2. Reconnect it.

**What you should see:**

- One worker-offline message and one back-online message.
- The worker's row goes offline and comes back.
- The chart marks a hashrate drop only when the loss is large enough for the drop alert, so a one-rig loss in a big fleet may leave no marker.

**Record:** PASS, FAIL or N/A in the results sheet.

### S5 — Moving to a new machine

**What you do:**

1. Back up the upgrade box.
2. Stop the upgrade box, so the two machines never mine under the same identity:

   ```bash
   ./pithead down
   ```

3. Restore the archive onto the fresh box with `./pithead restore`.

**What you should see:**

- The fresh box has the same [onion](../README.md#glossary) address, login and settings.
- The chains resync (or are copied across).

**Record:** PASS, FAIL or N/A in the results sheet.

### S6 — Bad change, undo it

**What you do:**

1. Change the pool from the dashboard.
2. Wait 10 minutes.
3. Change it back.

**What you should see:**

- Both changes are in the change history, with the right user and outcome.
- Mining continues throughout.

**Record:** PASS, FAIL or N/A in the results sheet.

### S7 — Remote check-in

**What you do:**

1. Take the phone away from the home network.
2. Reach the dashboard over the onion.
3. Ask the bot `/status`.

**What you should see:**

- The dashboard opens over the onion.
- The bot answers `/status`.
- The two agree.

**Record:** PASS, FAIL or N/A in the results sheet.

### S8 — Disk filling up

Only on a disposable box.

**What you do:**

1. Fill the data disk past 85%.
2. Watch the dashboard's disk badge, and wait for an alert.
3. Free the space afterwards.

**What you should see:**

- The dashboard's disk badge turns amber (red at 95%).
- A disk alert arrives.

**Record:** PASS, FAIL or N/A in the results sheet.
