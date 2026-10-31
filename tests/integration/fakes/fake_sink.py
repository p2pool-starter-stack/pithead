"""Fake alert receiver for the mini-stack e2e (#2263)."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--log", default="/tmp/requests.log")  # noqa: S108 — itest container
    args = ap.parse_args()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8")
            with open(args.log, "a") as f:
                json.dump(
                    {
                        "method": self.command,
                        "path": self.path,
                        "headers": dict(self.headers),
                        "body": body,
                    },
                    f,
                )
                f.write("\n")
                f.flush()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        def log_message(self, *_):
            pass

    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
