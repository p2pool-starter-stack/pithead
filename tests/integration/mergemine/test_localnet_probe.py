"""Unit tests for localnet_probe.py (#2589): protobuf reading and verdicts, no node and no grpc.

Run by tests/integration/selftest/selftest-mergemine-localnet.sh.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from localnet_probe import decode_header, decode_tip, fields, judge, parse_log  # noqa: E402


def varint(n: int) -> bytes:
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def field(num: int, value) -> bytes:
    if isinstance(value, int):
        return varint(num << 3) + varint(value)
    return varint(num << 3 | 2) + varint(len(value)) + value


def h(n: int) -> str:
    return f"{n:064x}"


def header_response(
    block: str,
    height: int,
    prev: str,
    algo: int = 0,
    pow_data: bytes = b"\x01" * 90,
    depth: int = 0,
) -> bytes:
    pow_ = field(1, algo) + field(4, pow_data)
    header = (
        field(1, bytes.fromhex(block))
        + field(3, height)
        + field(4, bytes.fromhex(prev))
        + field(12, pow_)
    )
    return field(1, header) + field(2, depth)


def p2pool_log(heights, extra: str = "") -> str:
    lines = [f"NOTICE  MergeMiningClientTari tari://10.0.0.2:18142 uses chain_id {'ab' * 32}"]
    for n in heights:
        lines.append(
            f"NOTICE  MergeMiningClientTari Tari aux block template: height = {n}, diff = 1, reward = 5, fees = 0, hash = {'cd' * 32}"
        )
        lines.append(f"NOTICE  MergeMiningClientTari Mined Tari block {h(n)} at height {n}")
    lines.append(
        f"NOTICE  MergeMiningClientTari Tari aux block template: height = {heights[-1] + 1}, diff = 1, reward = 5, fees = 0, hash = {'cd' * 32}"
    )
    return "\n".join(lines) + "\n" + extra


def chain(heights, **overrides):
    """A node whose main chain is h(1)..h(max), each block the child of the previous."""
    blocks = {
        h(n): {"hash": h(n), "height": n, "prev": h(n - 1), "algo": 0, "pow_data": 90, "depth": 0}
        for n in heights
    }
    for block, change in overrides.items():
        blocks[block] = None if change is None else {**blocks[block], **change}

    def lookup(block: str) -> dict:
        if block not in blocks or blocks[block] is None:
            raise LookupError("Header not found")
        return blocks[block]

    return lookup


def verdicts(lines):
    return [line.split(" ", 2)[1] for line in lines if line.startswith("ROW ")]


class Protobuf(unittest.TestCase):
    def test_header_fields_decode(self):
        got = decode_header(header_response(h(7), 7, h(6), pow_data=b"\x02" * 100, depth=3))
        self.assertEqual(
            got, {"hash": h(7), "height": 7, "prev": h(6), "algo": 0, "pow_data": 100, "depth": 3}
        )

    def test_tip_decodes(self):
        meta = field(1, 42) + field(2, bytes.fromhex(h(42))) + field(5, b"\x09")
        self.assertEqual(decode_tip(field(1, meta) + field(2, 1)), {"height": 42, "hash": h(42)})

    def test_truncated_input_raises(self):
        with self.assertRaises(ValueError):
            fields(field(1, b"abcdef")[:-2])


class Judge(unittest.TestCase):
    def test_accepted_linked_chain_passes(self):
        lines = judge(parse_log(p2pool_log([1, 2, 3, 4])), chain([1, 2, 3, 4]), 3)
        self.assertEqual(verdicts(lines), ["PASS"] * 3, lines)

    def test_ok_answers_for_blocks_off_the_main_chain_fail(self):
        # SubmitBlock said OK at height 3, but the node holds no P2Pool block there: an orphan, not an acceptance.
        lines = judge(
            parse_log(p2pool_log([1, 2, 3])),
            chain([1, 2, 3], **{h(3): None}),
            2,
        )
        self.assertEqual(verdicts(lines)[1], "FAIL", lines)

    def test_competing_block_at_an_accepted_height_is_only_information(self):
        extra = f"NOTICE  MergeMiningClientTari Mined Tari block {'ee' * 32} at height 2\n"
        lines = judge(
            parse_log(p2pool_log([1, 2, 3], extra)),
            chain([1, 2, 3]),
            3,
        )
        self.assertEqual(verdicts(lines), ["PASS"] * 3, lines)
        self.assertTrue(any("off the main chain: 1" in line for line in lines), lines)

    def test_too_few_heights_fail(self):
        lines = judge(parse_log(p2pool_log([1, 2])), chain([1, 2]), 3)
        self.assertEqual(verdicts(lines)[1:3], ["FAIL", "FAIL"], lines)

    def test_a_block_mined_with_another_algo_is_not_acceptance(self):
        lookup = chain([1, 2, 3], **{h(2): {"algo": 1}})
        lines = judge(parse_log(p2pool_log([1, 2, 3])), lookup, 1)
        self.assertEqual(verdicts(lines)[1], "FAIL", lines)

    def test_a_block_without_pow_data_is_not_acceptance(self):
        lookup = chain([1, 2, 3], **{h(3): {"pow_data": 0}})
        lines = judge(parse_log(p2pool_log([1, 2, 3])), lookup, 1)
        self.assertEqual(verdicts(lines)[1], "FAIL", lines)

    def test_a_header_at_another_height_is_not_acceptance(self):
        lookup = chain([1, 2, 3], **{h(3): {"height": 30}})
        lines = judge(parse_log(p2pool_log([1, 2, 3])), lookup, 1)
        self.assertEqual(verdicts(lines)[1], "FAIL", lines)

    def test_templates_from_two_chains_fail(self):
        extra = f"NOTICE  MergeMiningClientTari tari://10.0.0.3:18142 uses chain_id {'ef' * 32}\n"
        lines = judge(parse_log(p2pool_log([1, 2, 3], extra)), chain([1, 2, 3]), 3)
        self.assertEqual(verdicts(lines)[0], "FAIL", lines)

    def test_a_single_template_height_is_not_a_fresh_template(self):
        log = f"uses chain_id {'ab' * 32}\nTari aux block template: height = 1, diff = 1, reward = 5\n"
        lines = judge(parse_log(log), chain([]), 3)
        self.assertEqual(verdicts(lines)[0], "FAIL", lines)

    def test_broken_parent_link_fails(self):
        lines = judge(
            parse_log(p2pool_log([1, 2, 3])),
            chain([1, 2, 3], **{h(3): {"prev": h(9)}}),
            3,
        )
        self.assertEqual(verdicts(lines)[2], "FAIL", lines)

    def test_no_fresh_template_after_an_accepted_block_fails(self):
        log = p2pool_log([1, 2, 3]).replace("height = 2,", "height = 20,")
        lines = judge(parse_log(log), chain([1, 2, 3]), 3)
        self.assertEqual(verdicts(lines)[2], "FAIL", lines)

    def test_no_templates_and_no_blocks_fail_every_row(self):
        lines = judge(parse_log("nothing from Tari\n"), chain([]), 3)
        self.assertEqual(verdicts(lines), ["FAIL"] * 3, lines)

    def test_submit_errors_are_reported(self):
        extra = (
            "WARNING MergeMiningClientTari SubmitBlock failed: Invalid block provided: bad pow\n"
        )
        lines = judge(
            parse_log(p2pool_log([1, 2, 3], extra)),
            chain([1, 2, 3]),
            3,
        )
        self.assertIn("INFO SubmitBlock error: Invalid block provided: bad pow", lines)


if __name__ == "__main__":
    unittest.main()
