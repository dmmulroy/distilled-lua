-- A scripted streaming transport for specs (task 29). Library code never requires it.
--
--   local tr = require("distilled.testing").stream_transport{ responses = {
--     { status = 200, headers = { ["content-type"] = "application/x-ndjson" },
--       chunks = { '{"a":1}\n', '{"a":2}\n' } },
--     { status = 200, chunks = { "{", errors.new("TransportError", { ... }) } },  -- a drop
--     errors.new("TransportError", { message = "refused" }),   -- transport.stream fails
--   } }
--   tr.stream(request) -> { status, headers, body = reader } | nil, err
--   tr(request) -> the whole response (a plain call reads every chunk)
--   tr.requests        -- what it saw (method, url, headers, body, timeout, max_time, ...)
--   tr.readers[n]      -- the reader of request n: .pulled (chunks handed out), .closed
--
-- A chunk is a string (bytes that arrive together), an error table (the read fails
-- there: a dropped connection) or a function() called when the reader reaches it (a
-- spec observes the moment, e.g. that an item was delivered before the next chunk).
local errors = require("distilled.errors")
local compat = require("distilled.compat")

local M = {}

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = v
  end
  return out
end

--- M.reader(chunks) -> reader with the stream contract over scripted chunks
function M.reader(chunks)
  local r = { closed = false, pulled = 0 }
  local buf = ""
  local i = 0
  local failed
  -- pulls the next chunk into buf; false at the end (or after a failure)
  local function pull()
    while true do
      if failed or r.closed then
        return false
      end
      i = i + 1
      local c = chunks[i]
      if c == nil then
        return false
      end
      r.pulled = i
      if type(c) == "function" then
        c()
      elseif errors.is(c) then
        failed = c
        return false
      else
        buf = buf .. c
        return true
      end
    end
  end
  local function closed_error()
    return errors.new("TransportError", { message = "the body reader is closed" })
  end
  function r:read_line()
    if r.closed then
      return nil, closed_error()
    end
    while not string.find(buf, "\n", 1, true) do
      if not pull() then
        break
      end
    end
    local at = string.find(buf, "\n", 1, true)
    local line
    if at then
      line = string.sub(buf, 1, at - 1)
      buf = string.sub(buf, at + 1)
    elseif buf ~= "" and not failed then
      line = buf
      buf = ""
    else
      return nil, failed
    end
    return (string.gsub(line, "\r$", ""))
  end
  function r:read_exact(n)
    if r.closed then
      return nil, closed_error()
    end
    while #buf < n do
      if not pull() then
        break
      end
    end
    if #buf >= n then
      local s = string.sub(buf, 1, n)
      buf = string.sub(buf, n + 1)
      return s
    end
    if failed then
      return nil, failed
    end
    if buf == "" then
      return nil, nil
    end
    local partial = buf
    buf = ""
    return nil,
      errors.new("TransportError", {
        message = "the response body ended inside a frame",
        eof = true,
        partial = partial,
      })
  end
  function r:read_all()
    if r.closed then
      return nil, closed_error()
    end
    while pull() do
    end
    if failed then
      return nil, failed
    end
    local s = buf
    buf = ""
    return s
  end
  function r:close()
    r.closed = true
  end
  return r
end

--- M.transport{ responses = { ... } } -> transport (callable table with .stream)
function M.transport(opts)
  opts = opts or {}
  local responses = opts.responses or {}
  local t = { requests = {}, readers = {} }
  local function entry_for(req)
    local n = #t.requests + 1
    local seen = copy(req)
    seen.headers = copy(req and req.headers)
    t.requests[n] = seen
    local e = responses[n]
    if e == nil then
      compat.raise(
        "testing.stream_transport: no scripted response for request #"
          .. n
          .. "; "
          .. (n - 1)
          .. " scripted",
        3
      )
    end
    if type(e) == "function" then
      e = e(req)
    end
    return n, e
  end
  local function headers_of(e)
    local h = {}
    for k, v in pairs(e.headers or {}) do
      h[string.lower(k)] = v
    end
    return h
  end
  function t.stream(req)
    local n, e = entry_for(req)
    if errors.is(e) then
      return nil, e
    end
    local reader = M.reader(e.chunks or { e.body or "" })
    t.readers[n] = reader
    return { status = e.status or 200, headers = headers_of(e), body = reader }
  end
  return setmetatable(t, {
    __call = function(_, req)
      local n, e = entry_for(req)
      if errors.is(e) then
        return nil, e
      end
      local reader = M.reader(e.chunks or { e.body or "" })
      t.readers[n] = reader
      local body, err = reader:read_all()
      if body == nil then
        return nil, err
      end
      return { status = e.status or 200, headers = headers_of(e), body = body }
    end,
  })
end

return M
