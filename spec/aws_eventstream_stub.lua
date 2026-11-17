-- Test doubles for AWS event stream specs: a streaming transport and a duplex transport
-- over canned bytes, following the stream contract (docs/interfaces.md) and the duplex
-- entry point proposed by task 31 (STATUS.md, section 31):
--   transport.stream(req) -> { status, headers, body = reader }
--   transport.duplex(req) -> conn = { write, close_input, response, close }
-- `chunks` lets a body arrive in pieces (read_exact still returns exactly n bytes).
local M = {}

--- M.reader(bytes, opts) -> reader; opts.fail_after = n: a TransportError after n bytes
function M.reader(bytes, opts)
  opts = opts or {}
  local at = 1
  local r = { closed = false, reads = 0 }
  function r:read_exact(n)
    self.reads = self.reads + 1
    if opts.fail_after and at + n - 1 > opts.fail_after then
      return nil,
        require("distilled.errors").new("TransportError", { message = "connection reset" })
    end
    if at > #bytes then
      return nil, nil
    end
    local piece = string.sub(bytes, at, at + n - 1)
    at = at + n
    if #piece < n then
      return nil, { eof = true, partial = piece, message = "the body ended" }
    end
    return piece
  end
  function r:read_all()
    local piece = string.sub(bytes, at)
    at = #bytes + 1
    return piece
  end
  function r:close()
    self.closed = true
  end
  function r:read_line()
    return nil, nil
  end
  return r
end

--- M.stream_transport(reply) -> transport, log
-- reply = { status, headers, body } or a function(req) -> reply
function M.stream_transport(reply)
  local log = { requests = {}, readers = {} }
  local t = {}
  t.stream = function(req)
    log.requests[#log.requests + 1] = req
    local r = type(reply) == "function" and reply(req) or reply
    if r.fail then
      return nil, r.fail
    end
    local reader = M.reader(r.body or "", r)
    log.readers[#log.readers + 1] = reader
    return { status = r.status or 200, headers = r.headers or {}, body = reader }
  end
  return setmetatable(t, {
    __call = function(_, req)
      log.requests[#log.requests + 1] = req
      local r = type(reply) == "function" and reply(req) or reply
      return { status = r.status or 200, headers = r.headers or {}, body = r.body or "" }
    end,
  }),
    log
end

--- M.duplex_transport(reply) -> transport, log
-- log.written holds every byte string written; log.input_closed once close_input ran
function M.duplex_transport(reply)
  local log = { requests = {}, written = {}, input_closed = false, closed = false }
  local t = {}
  t.duplex = function(req)
    log.requests[#log.requests + 1] = req
    local conn = {}
    function conn:write(bytes)
      if log.input_closed then
        return nil, require("distilled.errors").new("TransportError", { message = "stdin closed" })
      end
      log.written[#log.written + 1] = bytes
      return true
    end
    function conn:close_input()
      log.input_closed = true
    end
    function conn:response()
      local r = type(reply) == "function" and reply(req, log) or reply
      log.reader = M.reader(r.body or "", r)
      return { status = r.status or 200, headers = r.headers or {}, body = log.reader }
    end
    function conn:close()
      log.closed = true
    end
    return conn
  end
  return setmetatable(t, {
    __call = function()
      return nil, require("distilled.errors").new("TransportError", { message = "no plain calls" })
    end,
  }),
    log
end

--- M.open(client, method, input) -> stream-like parts | nil, err
-- Through the client's `<method>_stream` when it exists (task 29's client surface), else
-- the protocol's stream entry point directly with the client's context.
function M.open(client, method, input)
  local m = client[method .. "_stream"]
  if m then
    return m(client, input)
  end
  local st = client._state
  local op = st.service.ops[method]
  local ctx = {
    host = st.ctx.host,
    credentials = st.ctx.credentials,
    tracer = st.ctx.tracer,
    validation = st.ctx.validation,
    user_agent = st.ctx.user_agent,
  }
  return st.protocol.stream(ctx, op, input)
end

--- M.next(stream) -> item | nil, err (a Stream object or protocol parts)
function M.next(s)
  if type(s.next) == "function" then
    return s:next()
  end
end

return M
