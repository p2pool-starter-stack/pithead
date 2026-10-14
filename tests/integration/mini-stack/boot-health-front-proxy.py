"""Local front proxy fixture: unauthenticated network requests arrive at Caddy on loopback."""

import http.client
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FrontProxy(BaseHTTPRequestHandler):
    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        with closing(http.client.HTTPConnection("127.0.0.1", 8080, timeout=5)) as upstream:
            upstream.request(self.command, self.path, headers=dict(self.headers))
            response = upstream.getresponse()
            body = response.read()
            self.send_response(response.status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *_args):
        pass


ThreadingHTTPServer(("", 8081), FrontProxy).serve_forever()
