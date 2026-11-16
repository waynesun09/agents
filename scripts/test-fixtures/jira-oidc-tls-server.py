#!/usr/bin/env python3
"""Local HTTPS stand-in for a Jira gateway, for the real-curl tests.

Usage: jira-oidc-tls-server.py CERT KEY PORTFILE LOG

Listens on 127.0.0.1 on a free port and writes the port to PORTFILE once
it is ready. Each request appends "<path> <Authorization header>" to LOG.
Paths ending in /denied answer 401, /missing 404, anything else 200 with
{"ok":true}. Runs until killed.
"""

import http.server
import os
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    log_path = ""

    def _answer(self):
        with open(self.log_path, "a", encoding="utf-8") as log:
            log.write("%s %s\n" % (self.path, self.headers.get("Authorization", "none")))
        if self.path.endswith("/denied"):
            status, body = 401, b'{"error":"denied"}'
        elif self.path.endswith("/missing"):
            status, body = 404, b'{"error":"missing"}'
        else:
            status, body = 200, b'{"ok":true}'
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _answer
    do_POST = _answer
    do_PUT = _answer

    def log_message(self, *args):
        pass


def main():
    cert, key, port_file, log_path = sys.argv[1:5]
    Handler.log_path = log_path
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    with open(port_file + ".tmp", "w", encoding="utf-8") as f:
        f.write(str(server.server_address[1]))
    os.replace(port_file + ".tmp", port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
