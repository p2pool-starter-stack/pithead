import json
import re
import sys
from pathlib import Path

source, dest, monero, tari, subaddress = sys.argv[1:]
dest = Path(dest)
text = Path(source).read_text()
replacements = {
    "PASTE_QA_MONERO_PRIMARY_ADDRESS": monero,
    "PASTE_QA_TARI_ADDRESS": tari,
    "PASTE_QA_MONERO_PRIVATE_VIEW_KEY": "a" * 64,
    "PASTE_QA_TARI_PRIVATE_VIEW_KEY": "b" * 64,
    "PASTE_QA_DASHBOARD_PASSPHRASE": "Checklist-Dashboard-42",
    "PASTE_QA_DASHBOARD_PASSWORD": "Checklist-Dashboard-42",
    "PASTE_QA_BOT_TOKEN": "123456:ChecklistBotToken",
    "PASTE_QA_CHAT_ID": "123456",
    "PASTE_FROM_NODE_MACHINE": "checklist-node-42",
}
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
rows = [
    line.split("|")[2].strip()
    for line in text.split("## Broken configs", 1)[1].splitlines()
    if line.startswith("| ")
][1:]
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
