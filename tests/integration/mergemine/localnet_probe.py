"""LocalNet read-back for the merge-mining acceptance phase (#2589, V5 of #1129).

Runs on the isolated LocalNet network beside the real Tari node. `tip <host:port>` prints the node's
tip once it answers. `judge <host:port> <min heights>` reads P2Pool's log on stdin, asks the node for
every block P2Pool says it mined, and prints `ROW PASS|FAIL <text>` and `INFO <text>` lines.

P2Pool logs "Mined Tari block" whenever SubmitBlock returns OK, and Tari also returns OK for an
orphan or a block it already has. The verdicts therefore come from the node's main chain: a block
counts only if GetHeaderByHash finds it at the height P2Pool reported, mined with RandomXM.

Raw bytes over grpcio and a minimal protobuf reader, no generated stubs. Field numbers are Tari's
`base_node.proto` and `block.proto` at the pinned release.
"""

import re
import sys

SERVICE = "/tari.rpc.BaseNode/"
RANDOMXM = 0

CHAIN_ID = re.compile(r"uses chain_id ([0-9a-f]{64})")
TEMPLATE = re.compile(r"Tari aux block template: height = (\d+), diff = (\d+)")
MINED = re.compile(r"Mined Tari block ([0-9a-f]{64}) at height (\d+)")
FAILED = re.compile(r"SubmitBlock failed: (.*)")


def _varint(buf: bytes, i: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7


def fields(buf: bytes) -> dict[int, list]:
    """Every field of one protobuf message, by number: ints for varints, bytes otherwise."""
    out: dict[int, list] = {}
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        wire = key & 7
        if wire == 0:
            value, i = _varint(buf, i)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, i = _varint(buf, i)
            else:
                size = 8 if wire == 1 else 4
            if i + size > len(buf):
                raise ValueError("truncated field")
            value, i = buf[i : i + size], i + size
        else:
            raise ValueError(f"unsupported wire type {wire}")
        out.setdefault(key >> 3, []).append(value)
    return out


def _first(f: dict, num: int, default):
    return f.get(num, [default])[0]


def decode_tip(buf: bytes) -> dict:
    """TipInfoResponse.metadata: best_block_height (1), best_block_hash (2)."""
    meta = fields(_first(fields(buf), 1, b""))
    return {"height": _first(meta, 1, 0), "hash": _first(meta, 2, b"").hex()}


def decode_header(buf: bytes) -> dict:
    """BlockHeaderResponse: header (1: hash 1, height 3, prev_hash 4, pow 12), confirmations (2)."""
    resp = fields(buf)
    header = fields(_first(resp, 1, b""))
    pow_ = fields(_first(header, 12, b""))
    return {
        "hash": _first(header, 1, b"").hex(),
        "height": _first(header, 3, 0),
        "prev": _first(header, 4, b"").hex(),
        "algo": _first(pow_, 1, 0),
        "pow_data": len(_first(pow_, 4, b"")),
        "depth": _first(resp, 2, 0),
    }


def parse_log(text: str) -> dict:
    mined: dict[str, int] = {}
    for m in MINED.finditer(text):
        mined.setdefault(m.group(1), int(m.group(2)))
    return {
        "chain_ids": sorted(set(CHAIN_ID.findall(text))),
        "templates": sorted({int(h) for h, _ in TEMPLATE.findall(text)}),
        "diffs": sorted({int(d) for _, d in TEMPLATE.findall(text)}),
        "mined": mined,
        "failed": [m.group(1).strip() for m in FAILED.finditer(text)],
    }


def judge(log: dict, lookup, min_heights: int) -> list[str]:
    """Verdict lines. `lookup(hash_hex)` returns decode_header's dict or raises LookupError."""
    out = []

    def row(ok: bool, text: str) -> None:
        out.append(f"ROW {'PASS' if ok else 'FAIL'} {text}")

    heights = log["templates"]
    chain = log["chain_ids"][0][:16] + "…" if log["chain_ids"] else "none"
    row(
        len(log["chain_ids"]) == 1 and len(heights) >= 2,
        f"P2Pool took aux templates from the LocalNet node: chain_id {chain}, {len(heights)} heights"
        + (
            f" ({heights[0]}..{heights[-1]}), difficulty {','.join(map(str, log['diffs']))}"
            if heights
            else ""
        ),
    )

    accepted: dict[int, dict] = {}
    missing = 0
    for block, height in log["mined"].items():
        try:
            h = lookup(block)
        except LookupError:
            missing += 1
            continue
        if (
            h["hash"] == block
            and h["height"] == height
            and h["algo"] == RANDOMXM
            and h["pow_data"] > 0
        ):
            accepted.setdefault(height, h)
    mined_heights = sorted(set(log["mined"].values()))
    lost = [h for h in mined_heights if h not in accepted]
    for h in sorted(accepted)[:10]:
        b = accepted[h]
        out.append(
            f"INFO accepted height={h} block={b['hash']} parent={b['prev']} depth={b['depth']} pow_data={b['pow_data']}B"
        )
    out.append(
        f"INFO P2Pool submissions answered OK: {len(log['mined'])}, off the main chain: {missing}"
        f" (competing blocks at difficulty 1); SubmitBlock errors: {len(log['failed'])}"
    )
    for reason in sorted(set(log["failed"]))[:3]:
        out.append(f"INFO SubmitBlock error: {reason}")
    example = ""
    if accepted:
        first = accepted[min(accepted)]
        example = f"; first block {first['hash'][:16]}… at height {first['height']}, depth {first['depth']}"
    row(
        len(accepted) >= min_heights and not lost,
        f"LocalNet node holds a P2Pool-mined RandomXM block on its main chain at {len(accepted)} of"
        f" {len(mined_heights)} submitted heights (need all, and at least {min_heights}){example}",
    )

    links = [h for h in accepted if h - 1 in accepted]
    broken = [h for h in links if accepted[h]["prev"] != accepted[h - 1]["hash"]]
    unfollowed = [h for h in accepted if h != max(accepted) and h + 1 not in heights]
    row(
        len(links) >= min_heights - 1 and not broken and not unfollowed,
        f"each accepted block's parent is the previous accepted block ({len(links) - len(broken)} of {len(links)} links)"
        f" and P2Pool took the next height's template after it ({len(accepted) - len(unfollowed)} of {len(accepted)})",
    )

    return out


def main() -> int:
    import grpc  # the image has it; the unit tests never import it

    cmd, addr = sys.argv[1], sys.argv[2]
    channel = grpc.insecure_channel(addr)

    def call(method: str, request: bytes) -> bytes:
        return channel.unary_unary(SERVICE + method)(request, timeout=15)

    tip = decode_tip(call("GetTipInfo", b""))
    print(f"INFO LocalNet tip height={tip['height']} hash={tip['hash']}", flush=True)
    if cmd == "tip":
        return 0

    def lookup(block: str) -> dict:
        request = b"\x0a" + bytes([32]) + bytes.fromhex(block)
        try:
            return decode_header(call("GetHeaderByHash", request))
        except grpc.RpcError as e:
            raise LookupError(e.details()) from e

    for line in judge(parse_log(sys.stdin.read()), lookup, int(sys.argv[3])):
        print(line, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
