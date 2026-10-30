import json
import re
import sys
from pathlib import Path

source, dest, monero, tari, subaddress, view_key = sys.argv[1:]
dest = Path(dest)
document = Path(source).read_text()
text = document
replacements = {
    "PASTE_QA_MONERO_PRIMARY_ADDRESS": monero,
    "PASTE_QA_TARI_ADDRESS": tari,
    "PASTE_QA_MONERO_PRIVATE_VIEW_KEY": view_key,
    "PASTE_QA_TARI_PRIVATE_VIEW_KEY": view_key,
    "PASTE_QA_DASHBOARD_PASSPHRASE": "Checklist-Dashboard-42",
    "PASTE_QA_DASHBOARD_PASSWORD": "Checklist-Dashboard-42",
    "PASTE_QA_BOT_TOKEN": "123456:ChecklistBotToken",
    "PASTE_QA_CHAT_ID": "123456",
    "PASTE_FROM_NODE_MACHINE": "checklist-node-42",
}
expected_changes = [
    "Delete one closing `}`",
    "Set `monero.wallet_address` to the QA **subaddress** (starts with `8`)",
    "Swap two different neighbouring characters in the middle of `monero.wallet_address`",
    "Swap two different neighbouring characters in the middle of `tari.wallet_address`",
    'Set `p2pool.pool` to `"large"`',
    'Set `tari.mode` to `"maybe"`',
    'Set `monero.mode` to `"cloud"`',
    'Set `p2pool.stratum_password` to `"has space"`',
    'Add `"proxy": { "donate_level": 150 }`',
    'Set `dashboard.auth.password` to `"short"`',
    'Set `dashboard.onion.enabled` to `true` and the password to `"fifteen-chars-x"` (15 characters)',
    'Set `dashboard.onion.enabled` to `true` and the password to `"changeme-but-longer"`',
    'Add a second top-level `"p2pool"` block below the first, for example `"p2pool": { "pool": "nano" }`',
    'Add a second `"wallet_address"` line inside the `monero` block',
    'Set `dashboard.auth.password` to `"PASTE_QA_DASHBOARD_PASSWORD"`',
    'Set `telegram.bot_token` to `"your_bot_token"` and `telegram.enabled` to `true` (lower case: the check ignores case)',
    "Set `dashboard.onion.enabled` to `true` in a config with no `dashboard.auth` block",
]
table_rows = []
for line in document.split("## Broken configs", 1)[1].splitlines():
    if not line.lstrip().startswith("|"):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if cells == ["Change", "The message contains"]:
        continue
    if all(re.fullmatch(r":?-+:?", cell) for cell in cells):
        continue
    if len(cells) != 2:
        raise ValueError("checklist row needs a change and refusal message")
    table_rows.append(cells)
changes = [cells[0] for cells in table_rows]
if changes != expected_changes:
    raise ValueError("checklist mutations changed; update the matching test cases")
for key, value in replacements.items():
    text = text.replace(key, value)
samples = re.findall(r"```json\n(.*?)\n```", text, re.S)
complete = [sample for sample in samples if sample.startswith("{")]
if len(complete) != 4:
    raise ValueError("expected four complete checklist samples")
for i, sample in enumerate(complete):
    (dest / f"sample-{i}.json").write_text(sample)
base = json.loads(complete[0])
mutations = [
    None,
    ("monero.wallet_address", subaddress),
    ("monero.wallet_address", monero[:20] + monero[21] + monero[20] + monero[22:]),
    ("tari.wallet_address", tari[:20] + tari[21] + tari[20] + tari[22:]),
    ("p2pool.pool", "large"),
    ("tari.mode", "maybe"),
    ("monero.mode", "cloud"),
    ("p2pool.stratum_password", "has space"),
    ("proxy.donate_level", 150),
    ("dashboard.auth.password", "short"),
    ("dashboard.auth.password", "fifteen-chars-x"),
    ("dashboard.auth.password", "changeme-but-longer"),
    None,
    None,
    ("dashboard.auth.password", "PASTE_QA_DASHBOARD_PASSWORD"),
    ("telegram.bot_token", "your_bot_token"),
    ("dashboard.onion.enabled", True),
]
rows = [cells[1] for cells in table_rows]
if len(rows) != len(mutations):
    raise ValueError("checklist refusal rows and mutations differ")
for i, mutation in enumerate(mutations):
    config = json.loads(json.dumps(base))
    if mutation:
        path, value = mutation
        node = config
        *parents, leaf = path.split(".")
        for parent in parents:
            node = node.setdefault(parent, {})
        node[leaf] = value
    if i in (10, 11):
        config["dashboard"]["onion"] = {"enabled": True}
    if i == 15:
        config["telegram"]["enabled"] = True
    raw = json.dumps(config)
    if i == 0:
        raw = raw[:-1]
    elif i == 12:
        raw = raw[:-1] + ', "p2pool": {"pool": "nano"}}'
    elif i == 13:
        raw = raw.replace('"monero": {', '"monero": {"wallet_address": "duplicate",', 1)
    (dest / f"broken-{i}.json").write_text(raw)
    expected = re.search(r"`([^`]+)`", rows[i])
    if expected is None:
        raise ValueError("checklist row needs a quoted refusal")
    (dest / f"broken-{i}.message").write_text(expected[1])
