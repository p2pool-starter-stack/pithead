import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def make_server(host, port, log):
    condition = threading.Condition()
    updates = []
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def respond(self, payload):
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def record(self, body=""):
            row = {
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers),
                "body": body,
            }
            with condition:
                requests.append(row)
                with open(log, "a") as stream:
                    stream.write(json.dumps(row) + "\n")

        def do_GET(self):
            route = urlsplit(self.path)
            if route.path == "/control":
                with condition:
                    self.respond({"requests": requests, "updates": updates})
                return
            if not route.path.endswith("/getUpdates"):
                self.send_error(404)
                return
            self.record()
            query = parse_qs(route.query)
            offset = int(query.get("offset", [0])[0])
            limit = int(query.get("limit", [100])[0])
            with condition:
                updates[:] = [u for u in updates if u["update_id"] >= offset]
                if not updates and int(query.get("timeout", [0])[0]) > 0:
                    condition.wait(timeout=1)
                self.respond(
                    {"ok": True, "result": [u for u in updates if u["update_id"] >= offset][:limit]}
                )

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            if self.path == "/control":
                payload = json.loads(body)
                with condition:
                    if payload.get("reset"):
                        updates.clear()
                        requests.clear()
                    updates.extend(payload.get("updates", []))
                    condition.notify_all()
                self.respond({"ok": True})
                return
            self.record(body)
            self.respond({"ok": True})

        def log_message(self, *_):
            pass

    return ThreadingHTTPServer((host, port), Handler)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--log", default="/tmp/requests.log")  # noqa: S108 — itest container
    args = ap.parse_args()
    make_server("0.0.0.0", args.port, args.log).serve_forever()


if __name__ == "__main__":
    main()
