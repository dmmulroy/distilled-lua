# Task 29b: HTTP trailers of streamed replies: done

## Built

- **The header channel.** `transport/curl_duplex.lua` now sends curl's header dump to
  its own fd: `dump-header = "/dev/fd/5"` (`curl_duplex.HEADER_FD`). The dump holds every
  header block, then the HTTP trailers after the body. stdout carries only the body.
  - **popen** (`popen_curl_duplex.lua`): a third FIFO, `hdr`, in the private 0700
    directory. The shell redirects `5>hdr` after `>out`, and Lua opens the FIFOs in the
    same order, so neither side waits on the other.
  - **Rex** (`exec_curl_duplex.lua`): `5>&2`. The stderr callback buffers the header
    channel apart from stdout. curl's own messages share that channel: the head parser
    hands a `curl: (N)` line to the usual TransportError, and the trailer parser skips it.
  - Both `popen_curl(opts).stream/.duplex` and the Rex host's
    `exec_curl(...).stream/.duplex` go through these modules.
  - Buffered calls (`popen_curl`/`exec_curl` called directly) already had
    `response.trailers` from task 23. They are unchanged.
- **`reader:trailers()`** returns `{ [lowercase name] = value }` or nil when there are
  none. It is valid once the body has ended: it waits for curl to exit, and on popen it
  reads what is left of `hdr` before the directory is removed.
- **gRPC.** `protocol.grpc`'s stream already reads `grpc.trailers_of(res, reader)` at the
  end of the body (task 30). With the transport now providing trailers, `grpc-status` and
  `grpc-message` from HTTP trailers end binary gRPC streams (Modal's case). A non-zero
  status maps to the operation's error class, and the message is percent-decoded.
- **`dl serve`.** A streamed scripted response takes
  `trailers = { name = value } | [[name, value], ...]`. They are sent after the last
  chunk and announced in a `Trailer` header.
- **Fix found on the way.** In Rex, a refused connection used to put curl's message where
  the status line was expected, and `tonumber(nil)` then raised. It is now the
  TransportError (`curl_code = 7`, message `curl: (7) ...`).
- **Docs.** `docs/interfaces.md` (Streams), `verify/features/streaming.md`, and STATUS 29.

## Specs

`spec/stream_http_spec.lua` (`--http`, lua, luajit and Rex) now has:

- `reader:trailers()` returns the chunked trailers after the body. The body itself
  (`read_line`, `read_all`) holds no trailer text, and a reply with no trailers returns
  nil.
- Binary gRPC over HTTP/1.1 chunked: the first message arrives before the second is sent;
  trailer `grpc-status: 0` ends the stream cleanly; the request carries `te: trailers`.
- Trailer `grpc-status: 5`, `grpc-message: vm%20gone`: the stream ends with
  `ThingNotFound` (code 5, message "vm gone") after the message before it.
- A refused connection gives a TransportError with curl's code and message.

`spec/stream_core_spec.lua` checks the streamed curl config: the dump goes to fd 5, never
to stdout, and there is no write-out.

## Commands run (final)

```
git merge origin/main                    -> merged (2 files), later: already up to date
verify/dl doctor                         -> doctor: ok
verify/dl test                           -> lua 2752 passed, 10 pending; luajit 2752 passed,
                                            10 pending; rex 2739 passed, 16 pending
verify/dl test --http                    -> lua 2825 passed; luajit 2825 passed;
                                            rex 2792 passed, 6 pending
verify/dl test --http stream_            -> 188 passed on each runtime
verify/dl test --http aws_eventstream_http -> 7 passed on each runtime (duplex path intact)
ls $TMPDIR | grep -c distilled-duplex    -> 0 after the full --http run
```

## Skipped / open

- **HTTP/2 trailers** (`https` streams, where curl uses `http2`) go through the same
  header dump. They are not exercised here because `dl serve` speaks HTTP/1.1 only. The
  binary gRPC spec runs gRPC over HTTP/1.1 chunked, which the protocol accepts when
  `http2` is off.
- **No live Modal call**: tests may not call live APIs.
