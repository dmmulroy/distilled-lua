"""dl serve: AWS event stream endpoints (task 31), loaded by serve.py.

Both read the request incrementally (serve.py's handler reads a whole body first), so
they are dispatched before it:

  POST /_dl/eventstream/script   {"path": "/p", "frames_b64": [...], "delay": s,
                                   "drop_after": n, "status": 200, "headers": {...}}
        scripts an output event stream for path /p (the next request to /p only)
  ANY  /p (scripted)             200, the frames one at a time, `delay` seconds apart
                                 (chunked); `drop_after` n: the connection is cut after
                                 n frames, mid-way through the next one
  ANY  /_dl/eventstream/duplex/<type>/<member>/<key>[/anything]
        full duplex: answers 200 at once, then for every signed envelope frame of the
        request body (as soon as it arrives) sends back one event message of type
        <type> whose JSON payload is {<member>: "<n>|<inner event type>|<ok|bad>|<hex of
        the inner payload>"}; ok means the frame's :chunk-signature verifies against the
        previous signature (the first against the request's own), with signing key
        derived from <key> (a test secret). The signed empty frame ends the response.
  GET  /_dl/eventstream/log      what the endpoints did: the duplex frames received (times,
                                 signatures), the scripted frames sent (times)

Standard library only. The codec is the AWS one: prelude (total, headers length, CRC32),
headers, payload, message CRC32.
"""

import base64
import binascii
import hashlib
import hmac
import json
import re
import struct
import threading
import time
from urllib.parse import parse_qs, urlsplit

LOCK = threading.Lock()
SCRIPTS = {}
LOG = []


def crc(b):
    return binascii.crc32(b) & 0xFFFFFFFF


def encode_headers(headers):
    out = b""
    for name, kind, value in headers:
        n = name.encode("utf-8")
        out += bytes([len(n)]) + n
        if kind == "string":
            v = value.encode("utf-8")
            out += b"\x07" + struct.pack(">H", len(v)) + v
        elif kind == "binary":
            out += b"\x06" + struct.pack(">H", len(value)) + value
        elif kind == "timestamp":
            out += b"\x08" + struct.pack(">q", value)
        else:
            raise ValueError(kind)
    return out


def encode_message(headers, payload):
    h = encode_headers(headers)
    total = 12 + len(h) + len(payload) + 4
    prelude = struct.pack(">II", total, len(h))
    body = prelude + struct.pack(">I", crc(prelude)) + h + payload
    return body + struct.pack(">I", crc(body))


def decode_headers(block):
    headers = {}
    raw = {}
    at = 0
    while at < len(block):
        n = block[at]
        name = block[at + 1 : at + 1 + n].decode("utf-8")
        at += 1 + n
        kind = block[at]
        at += 1
        if kind in (0, 1):
            value = kind == 0
        elif kind == 2:
            value = struct.unpack(">b", block[at : at + 1])[0]
            at += 1
        elif kind == 3:
            value = struct.unpack(">h", block[at : at + 2])[0]
            at += 2
        elif kind == 4:
            value = struct.unpack(">i", block[at : at + 4])[0]
            at += 4
        elif kind in (5, 8):
            value = struct.unpack(">q", block[at : at + 8])[0]
            at += 8
        elif kind in (6, 7):
            size = struct.unpack(">H", block[at : at + 2])[0]
            value = block[at + 2 : at + 2 + size]
            if kind == 7:
                value = value.decode("utf-8")
            at += 2 + size
        elif kind == 9:
            value = block[at : at + 16]
            at += 16
        else:
            raise ValueError("header type %d" % kind)
        headers[name] = value
        raw[name] = kind
    return headers


def decode_message(data):
    total, hlen, pcrc = struct.unpack(">III", data[:12])
    if crc(data[:8]) != pcrc:
        raise ValueError("prelude crc")
    if crc(data[: total - 4]) != struct.unpack(">I", data[total - 4 : total])[0]:
        raise ValueError("message crc")
    headers = decode_headers(data[12 : 12 + hlen])
    return headers, data[12 + hlen : total - 4]


def amz_date(ms):
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(ms // 1000))


def hmac256(key, msg):
    return hmac.new(key, msg.encode("utf-8") if isinstance(msg, str) else msg, hashlib.sha256).digest()


def signing_key(secret, date, region, service):
    k = hmac256(("AWS4" + secret).encode("utf-8"), date)
    k = hmac256(k, region)
    k = hmac256(k, service)
    return hmac256(k, "aws4_request")


class ChunkedReader:
    """The request body as it arrives: chunked transfer encoding, or a known length."""

    def __init__(self, handler):
        self.rfile = handler.rfile
        self.chunked = handler.headers.get("transfer-encoding", "").lower() == "chunked"
        self.left = int(handler.headers.get("content-length") or 0)
        self.done = False

    def read_some(self):
        if self.done:
            return b""
        if self.chunked:
            line = self.rfile.readline()
            if not line:
                self.done = True
                return b""
            size = int(line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                    pass
                self.done = True
                return b""
            data = self.rfile.read(size)
            self.rfile.readline()
            return data
        if self.left <= 0:
            self.done = True
            return b""
        data = self.rfile.read1(min(self.left, 65536)) if hasattr(self.rfile, "read1") else self.rfile.read(self.left)
        self.left -= len(data)
        return data


def write_chunk(handler, data):
    handler.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
    handler.wfile.flush()


def end_chunks(handler):
    handler.wfile.write(b"0\r\n\r\n")
    handler.wfile.flush()


def duplex(handler, path, args):
    # /_dl/eventstream/duplex/<event>/<field>/<secret>/<the operation's own path>
    segments = path.split("/")[4:]
    event = segments[0] if len(segments) > 0 and segments[0] else "Echo"
    field = segments[1] if len(segments) > 1 and segments[1] else "value"
    secret = segments[2] if len(segments) > 2 and segments[2] else None
    auth = handler.headers.get("authorization", "")
    seed = re.search(r"Signature=([0-9a-f]+)$", auth)
    scope = re.search(r"Credential=[^/]+/(\d{8})/([^/]+)/([^/]+)/aws4_request", auth)
    prior = seed.group(1) if seed else ""
    entry = {
        "path": path,
        "headers": {k.lower(): v for k, v in handler.headers.items()},
        "frames": [],
        "started": time.time(),
    }
    with LOCK:
        LOG.append(entry)
    handler.send_response_only(200)
    handler.send_header("Content-Type", "application/vnd.amazon.eventstream")
    handler.send_header("Transfer-Encoding", "chunked")
    handler.end_headers()
    handler.wfile.flush()
    reader = ChunkedReader(handler)
    buf = b""
    n = 0
    while True:
        while len(buf) >= 12 and len(buf) >= struct.unpack(">I", buf[:4])[0]:
            total = struct.unpack(">I", buf[:4])[0]
            frame, buf = buf[:total], buf[total:]
            headers, inner = decode_message(frame)
            ok = False
            if secret and scope:
                ms = headers.get(":date")
                date_header = encode_headers([(":date", "timestamp", ms)])
                sts = "\n".join(
                    [
                        "AWS4-HMAC-SHA256-PAYLOAD",
                        amz_date(ms),
                        "%s/%s/%s/aws4_request" % (amz_date(ms)[:8], scope.group(2), scope.group(3)),
                        prior,
                        hashlib.sha256(date_header).hexdigest(),
                        hashlib.sha256(inner).hexdigest(),
                    ]
                )
                key = signing_key(secret, amz_date(ms)[:8], scope.group(2), scope.group(3))
                want = hmac256(key, sts)
                ok = hmac.compare_digest(want, headers.get(":chunk-signature", b""))
                prior = want.hex()
            n += 1
            record = {"n": n, "at": time.time(), "signature_ok": ok, "inner_length": len(inner)}
            entry["frames"].append(record)
            if inner == b"":
                end_chunks(handler)
                entry["ended"] = time.time()
                return
            inner_headers, inner_payload = decode_message(inner)
            record["event_type"] = inner_headers.get(":event-type")
            summary = "%d|%s|%s|%s" % (n, inner_headers.get(":event-type"), "ok" if ok else "bad", inner_payload.hex())
            reply = encode_message(
                [
                    (":message-type", "string", "event"),
                    (":event-type", "string", event),
                    (":content-type", "string", "application/json"),
                ],
                json.dumps({field: summary}).encode("utf-8"),
            )
            write_chunk(handler, reply)
        data = reader.read_some()
        if not data:
            end_chunks(handler)
            entry["ended"] = time.time()
            entry["unterminated"] = True
            return
        buf += data


def scripted(handler, spec):
    entry = {"path": spec["path"], "sent": [], "started": time.time()}
    with LOCK:
        LOG.append(entry)
    status = int(spec.get("status", 200))
    handler.send_response_only(status)
    headers = spec.get("headers") or {}
    if not any(k.lower() == "content-type" for k in headers):
        handler.send_header("Content-Type", "application/vnd.amazon.eventstream")
    for k, v in headers.items():
        handler.send_header(k, v)
    handler.send_header("Transfer-Encoding", "chunked")
    handler.end_headers()
    handler.wfile.flush()
    frames = [base64.b64decode(f) for f in spec.get("frames_b64") or []]
    delay = float(spec.get("delay") or 0)
    drop_after = spec.get("drop_after")
    for i, frame in enumerate(frames):
        if drop_after is not None and i == int(drop_after):
            write_chunk(handler, frame[: len(frame) // 2])
            handler.close_connection = True
            handler.connection.shutdown(2)
            return
        if i > 0 and delay:
            time.sleep(delay)
        write_chunk(handler, frame)
        entry["sent"].append(time.time())
    end_chunks(handler)
    entry["ended"] = time.time()


def dispatch(handler):
    """True when the request was one of these endpoints (and has been answered)."""
    parts = urlsplit(handler.path)
    path = parts.path
    args = parse_qs(parts.query)
    if path == "/_dl/eventstream/script":
        length = int(handler.headers.get("content-length") or 0)
        spec = json.loads(handler.rfile.read(length).decode("utf-8"))
        with LOCK:
            SCRIPTS[spec["path"]] = spec
        body = json.dumps({"scripted": spec["path"]}).encode("utf-8")
        handler.send_response_only(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
        handler.wfile.flush()
        return True
    if path == "/_dl/eventstream/reset":
        with LOCK:
            SCRIPTS.clear()
            LOG.clear()
        handler.send_response_only(200)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        handler.wfile.flush()
        return True
    if path == "/_dl/eventstream/log":
        with LOCK:
            body = json.dumps(LOG).encode("utf-8")
        handler.send_response_only(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
        handler.wfile.flush()
        return True
    if path.startswith("/_dl/eventstream/duplex"):
        duplex(handler, path, args)
        handler.close_connection = True
        return True
    with LOCK:
        spec = SCRIPTS.pop(path, None)
    if spec is not None:
        # the request body is read whole first (an output-only stream's input)
        reader = ChunkedReader(handler)
        while reader.read_some():
            pass
        scripted(handler, spec)
        handler.close_connection = True
        return True
    return False
