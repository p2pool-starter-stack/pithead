# 3. Everyday commands

This part tests the `./pithead` commands an operator runs day to day: version, status, restart, down and up, chaining, tab completion and the support bundle.

## Before you start

- **Machine:** the **upgrade box**, running the candidate since 2.2.
- **Earlier steps:** do not start until 2.3a is done: the Tari migration has ended and Tari reports progress again. This is the start of session 4 of the [Run sheet](../README.md#run-sheet).
- **Have ready:** the dashboard password, the [stratum](../README.md#glossary) password, the Telegram bot token and the Monero payout address, to search for in 3.7.
- **Time:** roughly 1 hour.

## Steps

### 3.1 Version

**What you do:**

1. Print the version three ways:

   ```bash
   ./pithead version
   ./pithead -V
   ./pithead --version
   ```

**What you should see:**

- The same line three times.
- No network wait.

**Record**: PASS, FAIL or N/A in the results sheet.

### 3.2 Status exit code

**What you do:**

1. Show the status and its exit code:

   ```bash
   ./pithead status; echo "exit=$?"
   ```

2. Stop the dashboard container:

   ```bash
   docker stop dashboard
   ```

3. Show the status and its exit code again:

   ```bash
   ./pithead status; echo "exit=$?"
   ```

4. Start everything again:

   ```bash
   ./pithead up
   ```

5. Run `./pithead status` and confirm everything is healthy again.

**What you should see:**

- Item 1 prints `exit=0`.
- Item 3 flags the stopped service, and the exit code is not 0.
- After item 4, everything is healthy again.

**Record**: PASS, FAIL or N/A in the results sheet.

### 3.3 Restart

**What you do:**

1. Restart the whole stack:

   ```bash
   ./pithead restart
   ```

2. Restart [Tor](../README.md#glossary) only:

   ```bash
   ./pithead restart tor
   ```

3. Restart the Monero node only:

   ```bash
   ./pithead restart monerod
   ```

4. Show the status:

   ```bash
   ./pithead status
   ```

**What you should see:**

- Each restart finishes.
- `./pithead status` is healthy afterwards.

**Record**: PASS, FAIL or N/A in the results sheet.

### 3.4 Down and up

**What you do:**

1. Stop the stack:

   ```bash
   ./pithead down
   ```

2. Start it again:

   ```bash
   ./pithead up
   ```

**What you should see:**

- All containers stop, then start.
- Miners reconnect within a few minutes.

**Record**: PASS, FAIL or N/A in the results sheet.

### 3.5 Chaining

**What you do:**

1. Run two commands in one call:

   ```bash
   ./pithead apply status
   ```

**What you should see:**

- [Apply](../README.md#glossary) runs, then status runs.

**Record**: PASS, FAIL or N/A in the results sheet.

### 3.6 Tab completion

**What you do:**

1. Load the completion script:

   ```bash
   source pithead-completion.bash
   ```

2. Type `./pithead doc` and press Tab.
3. Clear the line, type `./pithead logs`, a space, and press Tab twice.

**What you should see:**

- Item 2 completes to `doctor`.
- Item 3 lists the service names.

**Record**: PASS, FAIL or N/A in the results sheet.

### 3.7 Support bundle

**What you do:**

1. Make a support bundle:

   ```bash
   ./pithead support-bundle
   ```

2. Open the archive it names, and check its mode (`ls -l` on it).
3. Search it for the dashboard password, the stratum password and the bot token.
4. Search the files under `logs/` for the Monero payout address and for [onion](../README.md#glossary) (`.onion`) addresses.

**What you should see:**

- The archive is mode 600 (`ls -l` shows `-rw-------`).
- It holds doctor output, a masked config and the last log lines.
- The dashboard password, the stratum password and the bot token do not appear anywhere in it.
- The Monero payout address and `.onion` addresses do not appear in the files under `logs/`: `[redacted-address]` and `[redacted].onion` stand in their place.
- A Tari address in the body of a log line can survive; that gap is known and stated in the code.
- `config.masked.json` keeps the payout addresses in clear by design: they are not secrets there.

**Record**: PASS, FAIL or N/A in the results sheet.
