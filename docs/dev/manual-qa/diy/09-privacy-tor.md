# 9. Privacy and Tor

This part checks the Tor-only egress firewall, the dashboard as a [Tor](../README.md#glossary) [onion](../README.md#glossary) service, Tor recovery, and the warnings when the firewall is missing or the box has a public IP.

## Before you start

- Machine: the **upgrade box**, in a terminal in the install directory, with the dashboard open on the laptop. The appliance half of 9.6a runs later on an appliance (see that step).
- Earlier steps: sections 2 to 8. The Telegram test chat from [section 8](08-alerts-telegram.md) must be set up: 9.6a and 9.8 send alerts to it.
- Have ready: Tor Browser on the laptop, and a dashboard password of 16 or more characters for 9.4.
- [Privacy](../../../privacy.md) explains what these checks protect.
- Time: about 3 hours. It is part of session 6 in the [Run sheet](../README.md#run-sheet); the appliance half of 9.6a is part of session 10.

## Steps

### 9.1 Egress firewall

**What you do:**

1. Run:

   ```bash
   ./pithead doctor
   ```

**What you should see:**

- `Tor-only egress firewall is installed`
- `Tor clearnet egress works`

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.2 Survives a reboot

**What you do:**

1. Reboot the machine and wait for the stack to come back.
2. Run `./pithead doctor` again.

**What you should see:**

- The same two lines as in 9.1.
- No warning that the firewall will not survive a reboot.

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.3 Topology panel

**What you do:**

1. In the dashboard's Advanced view, look at **Stack Topology & Egress** and at the header.

**What you should see:**

- **Stack Topology & Egress** shows the unselected clearnet routes as blocked.
- The header shows no firewall warning.

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.4 Onion dashboard

**What you do:**

1. Make sure the dashboard password is 16 or more characters.
2. Inside the `dashboard` block, add `"onion": { "enabled": true, "client_auth": true }`.
3. Run `./pithead apply` (see [apply](../README.md#glossary)). The [preview](../README.md#glossary) marks the change ⚠ and asks `(y/N)`. Answer `y`.
4. Copy the `.onion` address from the dashboard header.
5. Get the key:

   ```bash
   ./pithead onion-client-key
   ```

6. In Tor Browser, open `http://<address>.onion`, where `<address>` is the onion address you copied.
7. Accept the certificate prompt, and paste the bare key when asked.
8. Log in with the usual dashboard login.
9. Try the address again without giving the key (for example, cancel the key prompt).

**What you should see:**

- With the key, the dashboard login appears.
- The same login works.
- Without the key, the address does not load at all.

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.5 Rotate the onion

**What you do:**

1. Run:

   ```bash
   ./pithead rotate-dashboard-onion
   ```

2. Try the old address in Tor Browser.
3. Try the new address with the new key.

**What you should see:**

- A new address and key are printed.
- The old address stops working.
- The new address works with the new key.

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.6 Tor recovery check

**What you do:**

1. Run:

   ```bash
   ./pithead tor-recover check
   ```

Do not run `tor-recover apply` on a healthy machine.

**What you should see:**

- On a healthy machine it prints `Tor recovery refused: circuit history is not saturated.` and exits 1.
- It prints no unexpected-abort message or debug advice.
- It changes nothing.

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.6a Tor recovers from a saturated circuit-build state (#3118)

Where to run it:

- The appliance half, with `tor.auto_heal` on (the appliance default): on the second appliance, or on the soak appliance before `--start`, over SSH on the debug image. Never inside the soak window.
- The DIY half, with `tor.auto_heal` off: on the upgrade box.

This step stops Tor and cuts the stack's network for up to an hour. Set up the test chat first ([section 8](08-alerts-telegram.md)), and run nothing else meanwhile.

**What you do:**

1. Open a terminal in the install directory. On the appliance, that is:

   ```bash
   cd /data/pithead
   ```

2. Run this block. It stops Tor first, because a state file moved under a running Tor is written straight back, then seeds the saturated history and cuts Tor's network:

   ```bash
   T=$(grep '^TOR_DATA_DIR=' .env | cut -d= -f2-)
   docker compose stop tor
   sudo cp -p "$T/state" "$T/state.qa-orig"
   sudo sh -c "grep -v -e '^CircuitBuildTimeBin ' -e '^TotalBuildTimes ' -e '^CircuitBuildAbandonedCount ' '$T/state.qa-orig' > '$T/state.qa-new'; printf 'TotalBuildTimes 1000\nCircuitBuildAbandonedCount 1000\n' >> '$T/state.qa-new'; cat '$T/state.qa-new' > '$T/state'; rm '$T/state.qa-new'"
   docker compose start tor
   docker exec tor sh -c 'c=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie | tr -d "\n"); printf "AUTHENTICATE %s\r\nSETCONF DisableNetwork=1\r\n" "$c" | nc -w 3 127.0.0.1 9051'
   ```

3. Wait, watching the test chat, **Stack Topology & Egress** and the Monero card.
4. With `tor.auto_heal` on, after the heal: run the block from item 2 again in the same terminal, without its `cp` line, to check the cooldown.
5. To end the test with `tor.auto_heal` on: stop Tor (`docker compose stop tor`), copy `state.qa-orig` back over `state` with the command below, and start Tor (`docker compose start tor`). Use the same terminal, because the command needs `$T` from the first line of the block:

   ```bash
   sudo sh -c "cat '$T/state.qa-orig' > '$T/state'"
   ```

6. DIY half, with `tor.auto_heal` off: after the long wait, run `./pithead doctor`, then `./pithead tor-recover check`, then `./pithead tor-recover apply`.

**What you should see:**

Per #3118:

- The last command of the block prints `250 OK` twice. The stack loses its circuits, as in the real outage.
- Within about 20 minutes, one alert says Tor's circuit history is saturated.
- The Monero card's advice names `./pithead tor-recover check` as well as restarting monerod.
- With `tor.auto_heal` on (the appliance default), the heal's last step resets Tor through tor-recover within about an hour, and an alert says that it did and why.
- After that reset, `$T/state.backup.<timestamp>` exists and still holds the two `1000` lines, and the new `$T/state` lacks them.
- The P2Pool onion address is unchanged.
- Tor is healthy again; monerod regains outgoing peers and its height catches up.
- A second saturation within 6 hours is refused by the persistent cooldown, and an alert says so. After you repeat the block without its `cp` line (item 4), no new `state.backup.<timestamp>` appears.
- DIY with `tor.auto_heal` off: nothing resets Tor by itself, however long you wait.
- DIY: `./pithead doctor` FAILs the circuit-history check and names `./pithead tor-recover check`.
- DIY: `./pithead tor-recover check`, then `./pithead tor-recover apply`, recovers it, and `state.backup.<timestamp>` exists afterwards.

**Record:** PASS, FAIL or N/A in the results sheet, one result for each half.

### 9.7 Public IP warning

**What you do:**

1. Only if the test network gives the box a public IP address: look at what setup prints, and run `./pithead doctor`. Otherwise this step is N/A.

**What you should see:**

- Setup and doctor warn that [stratum](../README.md#glossary) port 3333 is exposed.

**Record:** PASS, FAIL or N/A in the results sheet.

### 9.8 Missing egress firewall

DESTRUCTIVE: this opens clearnet egress until `up`. Run it only on the upgrade box, never on a production box or the soak box.

**What you do:**

1. Check that Telegram is set up from [section 8](08-alerts-telegram.md), and that no `*_lan_access` key is on yet ([10.3](10-node-and-pool-modes.md#103-remote-monero-node) comes later).
2. Run:

   ```bash
   sudo iptables -F DOCKER-USER
   ```

3. Wait 5 minutes.
4. Look at the dashboard header, **Stack Topology & Egress** and the test chat.
5. Run `./pithead doctor`.
6. Run `./pithead up`, then wait 5 minutes.
7. Look at the dashboard and the test chat again, and run `./pithead doctor` again.

**What you should see:**

- Within about 4 minutes, the dashboard shows `Tor-only egress firewall MISSING on the host`.
- Exactly one alert arrives, starting `Tor-only egress firewall MISSING on the host — clearnet egress is NOT fail-closed.`
- doctor FAILs with `Tor-only egress firewall is MISSING while the stack runs`.
- Nothing reinstalls the rules by itself.
- After `./pithead up`, a second alert says `Tor-only egress firewall restored`.
- The warning clears.
- doctor again prints `Tor-only egress firewall is installed`.

**Record:** PASS, FAIL or N/A in the results sheet.
