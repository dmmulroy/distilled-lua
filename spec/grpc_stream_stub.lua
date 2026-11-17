-- A local stand-in for task 29's streaming transport, used by grpc_stream_spec and
-- connect_stream_spec until distilled.testing has one: a reader over scripted chunks
-- (pulled lazily, so a spec can see which chunks the code under test has asked for)
-- and a transport whose `stream` entry point answers scripted replies.
--
--   stub.reader(chunks [, log])  chunks: strings, or error tables (a mid-stream drop)
--   stub.transport{ reply, ... } reply: { status, headers, chunks, trailers, log } | err
local errors = require("distilled.errors")

local stub = {}

local Reader = {}
Reader.__index = Reader

function stub.reader(chunks, log)
  return setmetatable(
    { chunks = chunks, i = 0, buf = "", closed = false, close_count = 0, log = log },
    Reader
  )
end

-- pulls the next chunk: true | false at the end | nil, err
function Reader:pull()
  if self.closed then
    return false
  end
  self.i = self.i + 1
  local c = self.chunks[self.i]
  if c == nil then
    self.eof = true
    return false
  end
  if self.log then
    self.log[#self.log + 1] = self.i
  end
  if type(c) == "table" then
    return nil, c
  end
  self.buf = self.buf .. c
  return true
end

function Reader:read_exact(n)
  while #self.buf < n do
    local ok, err = self:pull()
    if ok == nil then
      return nil, err
    end
    if not ok then
      if self.buf == "" then
        return nil, nil
      end
      -- a partial read at EOF: the proposed contract marks it `eof = true`
      local got = #self.buf
      self.buf = ""
      return nil,
        errors.new(
          "TransportError",
          { message = "stub: body ended mid-read", eof = true, partial = got }
        )
    end
  end
  local out = string.sub(self.buf, 1, n)
  self.buf = string.sub(self.buf, n + 1)
  return out
end

function Reader:read_line()
  while not string.find(self.buf, "\n", 1, true) do
    local ok, err = self:pull()
    if ok == nil then
      return nil, err
    end
    if not ok then
      if self.buf == "" then
        return nil, nil
      end
      local rest = self.buf
      self.buf = ""
      return rest
    end
  end
  local at = string.find(self.buf, "\n", 1, true)
  local line = string.sub(self.buf, 1, at - 1)
  self.buf = string.sub(self.buf, at + 1)
  return (string.gsub(line, "\r$", ""))
end

function Reader:read_all()
  while true do
    local ok, err = self:pull()
    if ok == nil then
      return nil, err
    end
    if not ok then
      break
    end
  end
  local out = self.buf
  self.buf = ""
  return out
end

function Reader:close()
  if not self.closed then
    self.close_count = self.close_count + 1
  end
  self.closed = true
end

function stub.transport(replies)
  local tr = { requests = {}, readers = {} }
  tr.stream = function(req)
    tr.requests[#tr.requests + 1] = req
    local r = replies[#tr.requests]
    if r == nil then
      error("stub: no reply for request #" .. #tr.requests)
    end
    if r.tag ~= nil and r.status == nil then
      return nil, r
    end
    local reader = stub.reader(r.chunks or {}, r.log)
    -- trailers become visible once the body has ended, as with curl's header dump
    if r.trailers then
      reader.trailers = function(self)
        if self.eof then
          return r.trailers
        end
        return nil
      end
    end
    tr.readers[#tr.readers + 1] = reader
    return { status = r.status, headers = r.headers, body = reader }
  end
  return setmetatable(tr, {
    __call = function()
      error("stub: the plain entry point is not scripted")
    end,
  })
end

return stub
