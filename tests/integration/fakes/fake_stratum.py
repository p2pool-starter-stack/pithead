import json
import socketserver
import sys
import threading

MAX_LINE = 65536
MAX_LINES = 1000

JOB = {
    "blob": "0c0c" + "00" * 74,
    "job_id": "failover-view",
    "target": "b88d0600",
    "algo": "rx/0",
    "seed_hash": "00" * 32,
    "height": 3000000,
}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(30)
        for _ in range(MAX_LINES):
            try:
                msg = json.loads(self.rfile.readline(MAX_LINE))
            except (OSError, ValueError):
                return
            if not isinstance(msg, dict):
                return
            method = msg.get("method")
            if method == "login":
                self.server.record("login")
                result = {"id": "failover-view", "job": JOB, "status": "OK"}
            elif method == "submit":
                self.server.record("submit")
                result = {"status": "OK"}
            else:
                result = {"status": "KEEPALIVED"}
            reply = {"id": msg.get("id"), "jsonrpc": "2.0", "error": None, "result": result}
            self.wfile.write((json.dumps(reply) + "\n").encode())


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, log_path):
        super().__init__(address, Handler)
        self.log_path = log_path
        self.lock = threading.Lock()

    def record(self, event):
        with self.lock, open(self.log_path, "a") as log:
            log.write(f"{event}\n")


if __name__ == "__main__":
    bind, port, log_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    Server((bind, port), log_path).serve_forever()
