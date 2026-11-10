#!/usr/bin/env python3
"""Tiny host-side agent for the devbox dogfood VM.

QEMU's user network maps 10.0.2.2 to the host's loopback, so a server bound to
127.0.0.1 is reachable from the guest and from nowhere else. The guest posts its
report here; the harness reads the file and turns any FAIL line into a non-zero
exit. No shared filesystem and no inbound listener are needed.
"""

import argparse
import http.server
import os
import sys
import tempfile


class Handler(http.server.BaseHTTPRequestHandler):
    report_path = ""
    done_path = ""

    def log_message(self, fmt, *args):
        sys.stderr.write("agent: " + (fmt % args) + "\n")

    def _send(self, code, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, "ok\n")
        else:
            self._send(404, "not found\n")

    def do_POST(self):
        if self.path != "/report":
            self._send(404, "not found\n")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 4 * 1024 * 1024:
            self._send(400, "bad report length\n")
            return
        body = self.rfile.read(length)
        # A short read is a truncated report, and a truncated report has no FAIL
        # line, which the harness would read as a pass. Refuse it instead.
        if len(body) != length:
            self._send(400, "truncated report: %d of %d bytes\n" % (len(body), length))
            return
        directory = os.path.dirname(self.report_path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, staged = tempfile.mkstemp(dir=directory, prefix=".report.")
        with os.fdopen(fd, "wb") as handle:
            handle.write(body)
        os.replace(staged, self.report_path)
        open(self.done_path, "w").close()
        self._send(200, "ok\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8123)
    parser.add_argument("--report", required=True)
    parser.add_argument("--done", required=True)
    args = parser.parse_args()

    Handler.report_path = args.report
    Handler.done_path = args.done

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    # The bound port matters when --port 0 is used, so print it rather than the
    # argument.
    sys.stderr.write("agent: listening on 127.0.0.1:%d\n" % server.server_address[1])
    sys.stderr.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
