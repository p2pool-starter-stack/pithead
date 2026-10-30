import argparse
import json
import socketserver
import threading


class _Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = False


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        owner = self.server.owner
        if owner.refuse or owner.mode == "refuse":
            return
        self.request.settimeout(0.1)
        pending = b""
        session = None
        try:
            while not owner._stopped.is_set():
                try:
                    chunk = self.request.recv(4096)
                except TimeoutError:
                    continue
                if not chunk:
                    return
                pending += chunk
                if len(pending) > 65536:
                    return
                while b"\n" in pending:
                    line, _, pending = pending.partition(b"\n")
                    message = json.loads(line)
                    if not isinstance(message, dict):
                        return
                    params = message.get("params", {})
                    if not isinstance(params, dict):
                        return
                    reply = {"id": message.get("id"), "jsonrpc": "2.0"}
                    if message.get("method") == "login":
                        observed = {key: params.get(key) for key in ("login", "pass", "agent")}
                        with owner._lock:
                            owner.logins.append(observed)
                            session = f"{len(owner.logins):x}"
                            owner._record("login", observed)
                        reply["result"] = {
                            "id": session,
                            "job": dict(owner.job),
                            "extensions": ["algo"],
                            "status": "OK",
                        }
                    elif message.get("method") == "submit" and session is not None:
                        with owner._lock:
                            owner.submissions.append(dict(params))
                            if owner.mode == "silent":
                                owner._record("submit", {"outcome": "silent"})
                                continue
                            if owner.mode == "reject":
                                owner.rejected += 1
                                reply["error"] = {"message": "Low diff share"}
                            else:
                                owner.accepted += 1
                                reply.update(error=None, result={"status": "OK"})
                            owner._record("submit", {"outcome": owner.mode})
                    else:
                        reply["error"] = {"message": "Unsupported request or not logged in"}
                    self.request.sendall(json.dumps(reply).encode() + b"\n")
        except (OSError, ValueError):
            return


class FakeStratum:
    def __init__(
        self, mode="accept", *, refuse=False, host="127.0.0.1", port=0, coin="monero", log=None
    ):
        if mode not in ("accept", "reject", "silent", "refuse"):
            raise ValueError("unknown stratum mode")
        self.mode = mode
        self.refuse = refuse
        self.logins = []
        self.submissions = []
        self.accepted = 0
        self.rejected = 0
        self.job = {
            "blob": "10" + "00" * 75,
            "job_id": "1",
            "target": "ffffffff",
            "algo": "rx/0",
            "height": 1,
            "seed_hash": "00" * 32,
        }
        self._log = log
        self._lock = threading.Lock()
        self._stopped = threading.Event()
        self._server = _Server((host, port), _Handler)
        self._server.owner = self
        self.host, self.port = self._server.server_address
        self.fixture_metadata = {"url": f"{self.host}:{self.port}", "coin": coin}

    def _record(self, event, observed):
        if self._log:
            with open(self._log, "a", encoding="utf-8") as stream:
                stream.write(json.dumps({"event": event, "observed": observed}) + "\n")

    def __enter__(self):
        self._thread = threading.Thread(target=self._server.serve_forever)
        self._thread.start()
        return self

    def __exit__(self, *_exc):
        self._stopped.set()
        self._server.shutdown()
        self._server.server_close()
        self._thread.join()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3333)
    parser.add_argument(
        "--mode", choices=("accept", "reject", "silent", "refuse"), default="accept"
    )
    parser.add_argument("--log")
    args = parser.parse_args()
    with FakeStratum(host=args.host, port=args.port, mode=args.mode, log=args.log) as fake:
        print(json.dumps({"fixture_metadata": fake.fixture_metadata}), flush=True)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
