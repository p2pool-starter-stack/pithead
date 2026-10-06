# Sample configs

Four complete `config.json` files the DIY steps paste in, and the broken configs that
`./pithead apply` must refuse.

## Before you start

- Which machine: any machine with a text editor, during session 1 of the
  [Run sheet](README.md#run-sheet); the steps that use the samples run on the fresh box and the
  upgrade box.
- Have ready: the QA wallets, the Telegram test bot's token and chat id, and a dashboard password
  you make up for QA, all from [What you need](what-you-need.md).
- Rough time: filling in the samples is part of session 1 (1 h in the Run sheet). The broken
  configs run in step 6.5 ([06-settings-command-line.md](diy/06-settings-command-line.md)).

## Fill in a sample

Each sample is a complete `config.json`. Replace every `PASTE_...` value with your QA value
before you use it. [`./pithead apply`](README.md#glossary) refuses a `PASTE_` or `YOUR_` value in
any field and names the key (#3098). Every key is documented in
[Configuration](../../configuration.md).

| Placeholder | What to put there |
|---|---|
| `PASTE_QA_MONERO_PRIMARY_ADDRESS` | The first Monero QA wallet's primary address (starts with `4`, 95 characters) |
| `PASTE_QA_MONERO_PRIVATE_VIEW_KEY` | That wallet's private [view key](README.md#glossary) (*Secret view key* in the Monero GUI) |
| `PASTE_QA_TARI_ADDRESS` | The Tari mainnet QA wallet's dual-key address |
| `PASTE_QA_TARI_PRIVATE_VIEW_KEY` | That Tari wallet's private view key |
| `PASTE_QA_DASHBOARD_PASSPHRASE` | A dashboard password you make up for QA, 16 characters or more (Config B) |
| `PASTE_QA_DASHBOARD_PASSWORD` | A dashboard password you make up for QA (Configs C and D) |
| `PASTE_QA_BOT_TOKEN` | The Telegram test bot's token |
| `PASTE_QA_CHAT_ID` | The chat id of the test chat |
| `PASTE_FROM_NODE_MACHINE` | `node_username` and `node_password`, copied from the node machine's `config.json` (Config D) |

**What you do:**

1. Copy the sample into `config.json` and replace every `PASTE_...` value.
2. Check that no placeholder is left. This command must print nothing:

   ```bash
   grep -n PASTE_ config.json
   ```

**Record:** nothing to write down. If the command prints a line, fix that value before you
go on.

### Edit a block, never paste a second one

When a step says to set or add a key inside a block (for example "add `"rpc_lan_access": true`
inside the `monero` block"), edit that block in the existing `config.json`. Never paste a second
block with the same name: apply refuses a duplicated key at any depth and names it (#3098).

**What you do:**

1. After any hand edit, run this check from the install directory. It finds the same fault
   before apply does:

   ```bash
   python3 -c 'import json; json.load(open("config.json"), object_pairs_hook=lambda kv: exit("duplicate key: " + str([k for k, _ in kv])) if len(kv) != len(dict(kv)) else dict(kv)); print("config.json OK")'
   ```

**What you should see:**

- `config.json OK` when the file is fine.
- The list of keys when a block is duplicated.
- An error when the file has a syntax error.

**Record:** nothing to write down. Fix the file before you run `apply` if the check lists keys
or reports an error.

## Config A — defaults

This is `config.minimal.json` with QA addresses: the file a hand-written install starts from.
The [wizards](README.md#glossary) no longer write its `stratum_password` line: a new install has
no [stratum](README.md#glossary) password unless the user opts in (#3092).

```json
{
    "monero": { "wallet_address": "PASTE_QA_MONERO_PRIMARY_ADDRESS" },
    "tari": { "wallet_address": "PASTE_QA_TARI_ADDRESS" },
    "p2pool": { "stratum_password": "auto" }
}
```

## Config B — everything on

Login, browser configuration, Telegram with commands, stratum TLS, on-chain payout confirmation
for both chains (Tari needs only the view key: the spend key is read from the dual-key
address, #3096), energy prices, and the dashboard as a [Tor](README.md#glossary)
[onion](README.md#glossary) (which needs a dashboard password of 16 characters or more; make one
up for QA).

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

## Config C — small miner, Monero only

No Tari merge-mining, the `nano` sidechain for low hashrate, and no XvB raffle. The Tari address
stays in the file so Tari can be turned back on by changing `mode` alone.

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

## Config D — two machines sharing one Monero node

The node machine (the upgrade box) lets its LAN use its Monero node; the second machine mines
against it. Put the node machine's LAN address in `host` (in place of `192.168.1.10`), and copy
`node_username`/`node_password` from the node machine's `config.json`.

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

## Broken configs

Step 6.5 works through every row of this table; 10.7 and 13.24 point back at it. The last row
is the onion-without-login refusal that 10.7 names.

**What you do:**

1. Start from a working `config.json`.
2. Make the change in one row of the table below, and only that change.
3. Run:

   ```bash
   ./pithead apply
   ```

4. Check the refusal against the second column.
5. Undo the change before the next row.

**What you should see:**

For every row:

- apply stops before anything changes.
- It prints a message that contains the text in the second column.
- The running stack is untouched.

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

**Record:** under step 6.5 in the results sheet: PASS when every row matches, FAIL with the row
that did not.
