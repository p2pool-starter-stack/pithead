"""Recording Tari base node for the merge-mining submission phase (#2586).

Serves P2Pool the three RPCs its Tari client calls (GetTipInfo, GetNewBlockTemplateWithCoinbases,
SubmitBlock) from the protobuf bytes the fixture wrote, and records every SubmitBlock request
verbatim. Bytes pass through untouched (no proto stubs): what P2Pool sent is what the validator reads.

Each submission advances to the next fork-boundary template, cycling, so a late solution for an
older template never leaves a height uncovered. Nothing here judges a block; the fixture does.
"""

import sys
import threading
import time
from concurrent import futures
from pathlib import Path

import grpc

HEIGHTS = (349_999, 350_000, 350_001)


class Node:
    def __init__(self, work: Path):
        self.work = work
        self.lock = threading.Lock()
        self.index = 0
        self.count = 0

    def current(self, kind: str) -> bytes:
        with self.lock:
            height = HEIGHTS[self.index % len(HEIGHTS)]
        return (self.work / f"{kind}-{height}.bin").read_bytes()

    def tip(self, _request: bytes, _context) -> bytes:
        return self.current("tip")

    def template(self, _request: bytes, _context) -> bytes:
        return self.current("template")

    def submit(self, request: bytes, _context) -> bytes:
        with self.lock:
            self.count += 1
            (self.work / f"submit-{self.count:04d}.bin").write_bytes(request)
            self.index += 1
        return b""  # an empty SubmitBlockResponse


def main() -> None:
    port, work = sys.argv[1], Path(sys.argv[2])
    node = Node(work)
    methods = {
        "GetTipInfo": node.tip,
        "GetNewBlockTemplateWithCoinbases": node.template,
        "SubmitBlock": node.submit,
    }

    class Handler(grpc.GenericRpcHandler):
        def service(self, details):
            fn = methods.get(details.method.rsplit("/", 1)[-1])
            return fn and grpc.unary_unary_rpc_method_handler(fn)

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    server.add_generic_rpc_handlers((Handler(),))
    server.add_insecure_port(f"127.0.0.1:{port}")
    server.start()
    print(f"fake tari node on 127.0.0.1:{port}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
