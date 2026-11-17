#!/usr/bin/env python3
"""dl serve: a scriptable local HTTP fixture server for the transport specs.

Standard library only. Listens on 127.0.0.1, on a free port unless --port is given, and
writes the port to --port-file once it is listening (so a caller can wait for that file).

Built-in paths (all under /_dl/ so they cannot collide with a scripted path):

  POST /_dl/script     {"path": "/x", "responses": [<response>, ...], "repeat_last": false}
                       scripts the responses for path /x (query ignored), served in order
  POST /_dl/reset      forget every script and every recorded request
  GET  /_dl/requests   the recorded requests (JSON list, see record() below)
  GET  /_dl/health     200 "ok"
  POST /_dl/shutdown   stop the server
  ANY  /_dl/echo...    200, JSON description of the request it received
  ANY  /_dl/mirror     200, the request body sent back byte for byte
  GET  /_dl/bytes?n=N  200, N bytes where byte i (0-based) is i % 256
  ANY  /_dl/status/N   status N, JSON body {"status": N}
  ANY  /_dl/slow?delay=S   sleeps S seconds, then 200 {"slept": S}
  ANY  /_dl/drop       closes the connection without answering
  ANY  /_dl/continue   sends "100 Continue", then 200 JSON echo

A <response> is an object with any of:
  status (default 200), headers ({name: value} or [[name, value], ...], repeats allowed),
  body (text), body_b64 (bytes), json (any value, encoded; sets content-type),
  delay (seconds before answering), drop (true: close without answering),
  continue (true: send "100 Continue" first), stall (seconds between headers and body).
  Streaming (task 29): chunks (list of text) or chunks_b64 (list of base64 bytes) send a
  chunked body one chunk at a time, chunk_delay seconds apart (after `stall`);
  drop_after (n: cut the connection after n chunks, half-way through the next one);
  hang (seconds to wait after the last chunk before ending the body: a stalled stream).
  GET /_dl/streams lists each streamed response: {path, sent: [unix times], ended}.

A path with no script, or whose script ran out (and repeat_last is false), gets 404 with
header x-dl-serve: unscripted, so a test that sends too many requests sees it.
"""

import argparse
import base64
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

sys.dont_write_bytecode = True  # no __pycache__ in the tree for the module below
import serve_eventstream  # noqa: E402  AWS event stream endpoints (task 31), next to this file

LOCK = threading.Lock()
SCRIPTS = {}  # path -> {"responses": [...], "next": 0, "repeat_last": bool}
REQUESTS = []  # recorded requests, oldest first
STREAMS = []  # streamed responses (task 29): {"path", "sent": [times], "ended"}


def raw_text(value):
    """http.server decodes header bytes as latin-1; give back the UTF-8 text that was sent."""
    try:
        return value.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return value


def header_map(headers):
    """Lowercased names; repeated headers joined with ", " (what fetch's Headers.get does)."""
    out = {}
    for name, value in headers.items():
        value = raw_text(value)
        key = name.lower()
        out[key] = out[key] + ", " + value if key in out else value
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "dl-serve/1"

    def log_message(self, fmt, *args):  # quiet: the request log is /_dl/requests
        pass

    # -- request reading ------------------------------------------------------------

    def read_body(self):
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def describe(self, body):
        parts = urlsplit(self.path)
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            text = None
        return {
            "method": self.command,
            "target": self.path,
            "path": parts.path,
            "query": parts.query,
            "args": {k: v for k, v in parse_qs(parts.query, keep_blank_values=True).items()},
            "headers": header_map(self.headers),
            "raw_headers": [[k, raw_text(v)] for k, v in self.headers.items()],
            "body": text,
            "body_b64": base64.b64encode(body).decode("ascii"),
            "body_length": len(body),
        }

    # -- response writing -----------------------------------------------------------

    def send(self, status, headers, body, stall=0):
        self.send_response_only(status)
        names = set()
        for name, value in headers:
            names.add(name.lower())
            self.send_header(name, value)
        if "content-length" not in names:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.flush()
        if stall:
            time.sleep(stall)
        if self.command != "HEAD":
            self.wfile.write(body)
        self.wfile.flush()

    def send_json(self, status, value, extra=()):
        body = json.dumps(value, sort_keys=True).encode("utf-8")
        self.send(status, [("Content-Type", "application/json")] + list(extra), body)

    def drop(self):
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def send_continue(self):
        self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
        self.wfile.flush()

    def write_chunk(self, data):
        self.wfile.write(("%x\r\n" % len(data)).encode("ascii") + data + b"\r\n")
        self.wfile.flush()

    def streamed(self, entry, info, headers):
        """A chunked body sent piece by piece (task 29): slow, stalled or dropped streams."""
        if "chunks_b64" in entry:
            chunks = [base64.b64decode(c) for c in entry["chunks_b64"]]
        else:
            chunks = [str(c).encode("utf-8") for c in entry["chunks"]]
        log = {"path": info["path"], "sent": [], "ended": None}
        with LOCK:
            STREAMS.append(log)
        self.send_response_only(int(entry.get("status", 200)))
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.wfile.flush()
        if entry.get("stall"):
            time.sleep(float(entry["stall"]))
        delay = float(entry.get("chunk_delay") or 0)
        drop_after = entry.get("drop_after")
        try:
            for i, chunk in enumerate(chunks):
                if i > 0 and delay:
                    time.sleep(delay)
                if drop_after is not None and i == int(drop_after):
                    self.wfile.write(("%x\r\n" % len(chunk)).encode("ascii") + chunk[: len(chunk) // 2])
                    self.wfile.flush()
                    return self.drop()
                self.write_chunk(chunk)
                log["sent"].append(time.time())
            if entry.get("hang"):
                time.sleep(float(entry["hang"]))
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            log["ended"] = time.time()
        except (BrokenPipeError, ConnectionResetError):
            log["ended"] = "client closed"
        self.close_connection = True

    def scripted(self, entry, info):
        if entry.get("delay"):
            time.sleep(float(entry["delay"]))
        if entry.get("drop"):
            return self.drop()
        if "chunks" in entry or "chunks_b64" in entry:
            headers = entry.get("headers") or []
            if isinstance(headers, dict):
                headers = list(headers.items())
            return self.streamed(entry, info, [(str(k), str(v)) for k, v in headers])
        if entry.get("continue"):
            self.send_continue()
        headers = entry.get("headers") or []
        if isinstance(headers, dict):
            headers = list(headers.items())
        headers = [(str(k), str(v)) for k, v in headers]
        if "json" in entry:
            body = json.dumps(entry["json"]).encode("utf-8")
            if not any(k.lower() == "content-type" for k, _ in headers):
                headers.append(("Content-Type", "application/json"))
        elif "body_b64" in entry:
            body = base64.b64decode(entry["body_b64"])
        elif entry.get("echo"):
            body = json.dumps(info, sort_keys=True).encode("utf-8")
            headers.append(("Content-Type", "application/json"))
        else:
            body = str(entry.get("body", "")).encode("utf-8")
        self.send(int(entry.get("status", 200)), headers, body, float(entry.get("stall") or 0))

    # -- dispatch -------------------------------------------------------------------

    def handle_any(self):
        if serve_eventstream.dispatch(self):  # they read the body as it arrives
            return None
        body = self.read_body()
        info = self.describe(body)
        path = info["path"]
        control = path in (
            "/_dl/script",
            "/_dl/reset",
            "/_dl/requests",
            "/_dl/health",
            "/_dl/shutdown",
            "/_dl/streams",
        )
        if not control:
            with LOCK:
                REQUESTS.append(info)

        if path == "/_dl/health":
            return self.send(200, [("Content-Type", "text/plain")], b"ok")
        if path == "/_dl/script":
            spec = json.loads(body.decode("utf-8"))
            with LOCK:
                SCRIPTS[spec["path"]] = {
                    "responses": list(spec.get("responses") or []),
                    "next": 0,
                    "repeat_last": bool(spec.get("repeat_last")),
                }
            return self.send_json(200, {"scripted": spec["path"], "count": len(spec.get("responses") or [])})
        if path == "/_dl/streams":
            with LOCK:
                return self.send_json(200, list(STREAMS))
        if path == "/_dl/reset":
            with LOCK:
                SCRIPTS.clear()
                REQUESTS.clear()
                STREAMS.clear()
            return self.send_json(200, {"reset": True})
        if path == "/_dl/requests":
            with LOCK:
                snapshot = list(REQUESTS)
            return self.send_json(200, snapshot)
        if path == "/_dl/shutdown":
            self.send_json(200, {"stopping": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return None

        with LOCK:
            script = SCRIPTS.get(path)
            entry = None
            if script is not None:
                responses = script["responses"]
                if script["next"] < len(responses):
                    entry = responses[script["next"]]
                    script["next"] += 1
                elif script["repeat_last"] and responses:
                    entry = responses[-1]
        if entry is not None:
            return self.scripted(entry, info)
        if script is not None:
            return self.send_json(404, {"error": "script exhausted", "path": path}, [("x-dl-serve", "exhausted")])

        args = parse_qs(info["query"])
        if path.startswith("/_dl/echo"):
            return self.send_json(200, info)
        if path == "/_dl/mirror":
            ctype = self.headers.get("content-type") or "application/octet-stream"
            return self.send(200, [("Content-Type", ctype)], body)
        if path == "/_dl/bytes":
            n = int(args.get("n", ["0"])[0])
            pattern = bytes(range(256))
            data = (pattern * (n // 256 + 1))[:n]
            return self.send(200, [("Content-Type", "application/octet-stream")], data)
        if path.startswith("/_dl/status/"):
            status = int(path.rsplit("/", 1)[1])
            return self.send_json(status, {"status": status})
        if path == "/_dl/slow":
            delay = float(args.get("delay", ["1"])[0])
            time.sleep(delay)
            return self.send_json(200, {"slept": delay})
        if path == "/_dl/drop":
            return self.drop()
        if path == "/_dl/continue":
            self.send_continue()
            return self.send_json(200, info)
        return self.send_json(404, {"error": "unscripted", "path": path}, [("x-dl-serve", "unscripted")])

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_any

    def handle_expect_100(self):
        # curl is told not to send Expect; if a client does, answer like a normal server.
        return super().handle_expect_100()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    opts = parser.parse_args()
    server = Server(("127.0.0.1", opts.port), Handler)
    port = server.server_address[1]
    tmp = opts.port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(port) + "\n")
    os.replace(tmp, opts.port_file)  # atomic: a reader never sees a half-written port
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
