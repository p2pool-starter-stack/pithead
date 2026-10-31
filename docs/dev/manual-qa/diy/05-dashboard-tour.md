# 5. Dashboard tour

This part checks every panel of the dashboard on a DIY box: the header, both views, the chart, live refresh, the phone and theme layouts, the login, the metrics endpoint and the **Connect a miner** block.

## Before you start

- Machine: the **upgrade box**, with the dashboard open on the laptop and signed in.
- Earlier steps: [Upgrade](02-upgrade.md) (including the Tari migration in 2.3a), [Everyday commands](03-everyday-commands.md) and [Connect a miner](04-connect-a-miner.md) are done. 5.12 uses the [stratum](../README.md#glossary) TLS setting from [4.3](04-connect-a-miner.md).
- Have ready: the laptop, the phone, the dashboard password, and a terminal on the upgrade box in the install directory.
- [The Dashboard](../../../dashboard.md) explains what each panel means.
- Time: about 1 hour. It is part of session 4 in the [Run sheet](../README.md#run-sheet).

## Steps

### 5.1 Header

**What you do:**

1. Look at the header at the top of the dashboard.

**What you should see:**

- The hostname and the IP address.
- The version badge: the release version on release images, or `dev · <branch> @ <commit>` on a source build.
- The last-update time.
- The 1h and 24h averages.
- No warning badge that the machine does not deserve.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.2 Simple view

**What you do:**

1. Make sure the dashboard shows the **Simple** view.
2. Look at every panel on the page.

**What you should see:**

- The mine-cart strip.
- The KPI band (the row of headline numbers): Total Hashrate, Shares in Window, Raffle Eligible, Blocks Found, XvB Tier and Mining Mode.
- The hashrate chart, Overview, Earnings and Workers Alive.
- Every number is plausible: no `NaN`, no negative values, and no placeholders that spin forever.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.3 Chart

**What you do:**

1. Click each range on the hashrate chart in turn: 1h, 24h, 1w, 1mo and all.
2. Change the averaging window.
3. Turn each legend item off, then on again.

**What you should see:**

- The chart redraws each time.
- Nothing is blank.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.4 Advanced view

**What you do:**

1. Switch to **Advanced**.

**What you should see:**

- The extra cards appear: P2Pool node and global stats, XvB, XMR Network, Tari Merge-Mining, Pool Cadence & Luck, **Stack Topology & Egress**, and the earnings calculator.
- **Stack Topology & Egress** shows every route the config uses.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.5 Preferences stick

**What you do:**

1. Change the theme.
2. Change the view.
3. Change the chart window.
4. Change the worker sort.
5. Reload the page.

**What you should see:**

- All four changes are kept after the reload.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.6 Live refresh

**What you do:**

1. Leave the page open for two minutes without touching it.

**What you should see:**

- The panels refresh in place about every 30 seconds.
- The scroll position stays where it was.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.7 Disconnected banner

**What you do:**

1. Keep the dashboard open on the laptop.
2. On the upgrade box, run:

   ```bash
   ./pithead down
   ```

3. Wait 60 seconds.
4. Run:

   ```bash
   ./pithead up
   ```

**What you should see:**

- While the stack is down, a red `Disconnected — showing data from …` banner appears.
- Once the stack is back, the banner clears by itself, with no manual reload.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.8 Phone

**What you do:**

1. Open the dashboard on the phone.

**What you should see:**

- One column.
- A stacked header.
- A worker table that scrolls sideways.
- Nothing is cut off and nothing overlaps.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.9 Light and dark

**What you do:**

1. Switch the laptop's system theme to light and look at the dashboard.
2. Switch it to dark and look again.

**What you should see:**

- Both themes are readable, including the chart and the images.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.10 Login

**What you do:**

1. Open the dashboard in a private browser window.
2. Enter a wrong password.
3. Enter the right password.

**What you should see:**

- The wrong password is refused.
- The right password lets you in.

**Record:** PASS, FAIL or N/A in the results sheet. Step 7.8 later counts this wrong password.

### 5.11 Metrics

**What you do:**

1. On the laptop, run this command. Replace `<dashboard password>` with the dashboard password, and `<host>` with the box's hostname or address, the same one you use to open the dashboard:

   ```bash
   curl -k -u admin:<dashboard password> https://<host>/metrics
   ```

2. Run it again without `-u admin:<dashboard password>`:

   ```bash
   curl -k https://<host>/metrics
   ```

**What you should see:**

- The first command prints Prometheus text with `pithead_` lines, including `pithead_shares_accepted_total`.
- Without `-u`, the request is refused.

**Record:** PASS, FAIL or N/A in the results sheet.

### 5.12 Connect a miner

**What you do:**

1. Signed in, find the **Connect a miner** block in the Simple view.
2. On the upgrade box, run this and compare the value with the password the block shows:

   ```bash
   grep PROXY_STRATUM_PASSWORD .env
   ```

3. Open the dashboard in a private window and do not sign in.

**What you should see:**

Per #3092:

- Signed in, the block shows the LAN pool URL (`<host>:3333`).
- Signed in, it shows the stratum password, or the words `No stratum password`.
- Signed in, it shows the TLS fingerprint when stratum TLS is on ([4.3](04-connect-a-miner.md)).
- The password matches the output of `grep PROXY_STRATUM_PASSWORD .env`.
- Signed out, the private window shows the login and none of those values.
- A dashboard with no login shows the block to anyone on the LAN. Step [10.7](10-node-and-pool-modes.md#107-a-dashboard-with-no-login) checks that.

**Record:** PASS, FAIL or N/A in the results sheet.
