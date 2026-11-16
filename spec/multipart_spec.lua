-- distilled.multipart: the encoder, and request.build's multipart branch checked against
-- an independent parser (Node's `Request.formData()`, undici). The parser runs through
-- io.popen under lua and luajit and through rex.exec under gopher-lua; it is skipped
-- (pending) when node is missing.
local t = require("spec.harness")
local multipart = require("distilled.multipart")
local request = require("distilled.request")
local S = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local compat = require("distilled.compat")

local m = S.member

-- the boundary a fresh testing.random(seed) gives first
local function boundary_for(seed)
  return multipart.boundary(testing.random(seed or 1))
end

local function all_bytes()
  local list = {}
  for i = 0, 255 do
    list[#list + 1] = string.char(i)
  end
  return compat.concat(list, "")
end

t.describe("multipart.file", function()
  t.it("makes a value distinguishable from an ordinary table", function()
    local f =
      multipart.file({ data = "PK\0", filename = "a.zip", content_type = "Application/ZIP" })
    t.truthy(multipart.is_file(f))
    t.eq(f.data, "PK\0")
    t.eq(f.filename, "a.zip")
    -- Blob lowercases its type
    t.eq(f.content_type, "application/zip")
    t.eq(multipart.is_file({ data = "x", filename = "a" }), false)
    t.eq(multipart.is_file("x"), false)
    t.eq(multipart.is_file(nil), false)
    t.eq(tostring(f), "distilled.file(a.zip, 3 bytes)")
  end)

  t.it("survives secret.unwrap_deep (request.build works on such a copy)", function()
    local f = multipart.file({ data = secret("bytes") })
    local copy = secret.unwrap_deep({ zip = f })
    t.truthy(multipart.is_file(copy.zip))
    t.eq(copy.zip.data, "bytes")
    t.truthy(secret.is(f.data))
  end)

  t.it("raises on misuse", function()
    t.raises(function()
      multipart.file("x")
    end, "expected a table")
    t.raises(function()
      multipart.file({ data = 1 })
    end, "data must be a string")
    t.raises(function()
      multipart.file({ data = "x", filename = 2 })
    end, "filename must be a string")
    t.raises(function()
      multipart.file({ data = "x", content_type = "text/plain\r\nX-Evil: 1" })
    end, "printable ASCII")
    t.raises(function()
      multipart.file({ data = "x", name = "a" })
    end, "unknown field name")
  end)
end)

t.describe("multipart.encode", function()
  t.it("writes RFC 7578 parts with a deterministic boundary from random", function()
    local b = boundary_for(1)
    t.match(b, "^%-%-%-%-distilled%-lua%-[%w]+$")
    t.eq(#b, #"----distilled-lua-" + 24)
    local out = multipart.encode({
      { name = "environment", value = "{}" },
      { name = "zip", value = "PK\0\r\n", filename = "a.zip" },
      { name = "doc", value = "x", filename = "d.txt", content_type = "text/plain" },
    }, { random = testing.random(1) })
    t.eq(out.boundary, b)
    t.eq(out.content_type, "multipart/form-data; boundary=" .. b)
    t.eq(
      out.body,
      "--"
        .. b
        .. '\r\nContent-Disposition: form-data; name="environment"\r\n\r\n{}\r\n'
        .. "--"
        .. b
        .. '\r\nContent-Disposition: form-data; name="zip"; filename="a.zip"\r\n'
        .. "Content-Type: application/octet-stream\r\n\r\nPK\0\r\n\r\n"
        .. "--"
        .. b
        .. '\r\nContent-Disposition: form-data; name="doc"; filename="d.txt"\r\n'
        .. "Content-Type: text/plain\r\n\r\nx\r\n"
        .. "--"
        .. b
        .. "--\r\n"
    )
  end)

  t.it("an empty form is only the closing delimiter", function()
    local out = multipart.encode({}, { random = testing.random(1) })
    t.eq(out.body, "--" .. boundary_for(1) .. "--\r\n")
  end)

  t.it("escapes quotes, CR and LF in names and filenames as undici does", function()
    t.eq(multipart.escape_name('a"b\r\nc\nd\re'), "a%22b%0D%0Ac%0D%0Ad%0D%0Ae")
    t.eq(multipart.escape_filename('x"y\r\nz'), "x%22y%0D%0Az")
    local out = multipart.encode({
      { name = 'n"\n', value = "v" },
      { name = "f", value = "", filename = 'q"\r.bin' },
    }, { random = testing.random(1) })
    t.match(out.body, 'name="n%22%0D%0A"\r\n', true)
    t.match(out.body, 'filename="q%22%0D.bin"\r\n', true)
  end)

  t.it("normalizes line breaks in text values, never in file data", function()
    local out = multipart.encode({
      { name = "t", value = "a\nb\rc\r\nd" },
      { name = "f", value = "a\nb\rc", filename = "f" },
    }, { random = testing.random(1) })
    t.match(out.body, "\r\n\r\na\r\nb\r\nc\r\nd\r\n", true)
    t.match(out.body, "\r\n\r\na\nb\rc\r\n", true)
  end)

  t.it("picks another boundary while the first occurs in the data", function()
    local first = boundary_for(1)
    local r = testing.random(1)
    local out = multipart.encode({ { name = "f", value = "x" .. first .. "y", filename = "f" } }, {
      random = r,
    })
    t.ne(out.boundary, first)
    -- the second draw of the same generator
    local again = testing.random(1)
    multipart.boundary(again)
    t.eq(out.boundary, multipart.boundary(again))
    t.match(out.body, "x" .. first .. "y", true)
  end)

  t.it("fails with SdkError when random never yields a usable boundary", function()
    local constant = function()
      return 0
    end
    local b = multipart.boundary(constant)
    local res, err = multipart.encode({ { name = "t", value = b } }, { random = constant })
    t.fails_with("SdkError", res, err)
    t.match(err.message, "no boundary", true)
  end)

  t.it("refuses non-string values and a content type with a line break", function()
    local res, err = multipart.encode({ { name = "t", value = 1 } }, { random = testing.random(1) })
    t.fails_with("InvalidInput", res, err)
    res, err = multipart.encode(
      { { name = "f", value = "", filename = "f", content_type = "a\r\nb: c" } },
      { random = testing.random(1) }
    )
    t.fails_with("InvalidInput", res, err)
  end)

  t.it("is binary safe and linear for large data (every byte value, 2 MB)", function()
    local bytes = all_bytes()
    local big = string.rep(bytes, 8192)
    local parts = {}
    for i = 1, 3000 do
      parts[i] = { name = "p" .. i, value = "v" }
    end
    parts[#parts + 1] = { name = "big", value = big, filename = "big.bin" }
    local out = multipart.encode(parts, { random = testing.random(3) })
    t.truthy(out)
    local head = 'filename="big.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'
    local s = string.find(out.body, head, 1, true)
    t.truthy(s)
    t.eq(string.sub(out.body, s + #head, s + #head + #big - 1) == big, true)
  end)

  t.it("without random uses distilled.host's generator", function()
    local out = multipart.encode({ { name = "t", value = "v" } })
    t.match(out.boundary, "^%-%-%-%-distilled%-lua%-")
  end)
end)

---------------------------------------------------------------------------------------
-- request.build (Distilled protocol-http.test.ts "multipart binary parts" and
-- "multipart file lists", with the same inputs where Lua has an equivalent)
---------------------------------------------------------------------------------------

local DEPLOY = {
  name = "CreateDeployment",
  method = "POST",
  uri = "/deployments",
  content_type = "multipart",
  input = S.struct({
    members = {
      m({ name = "zip", schema = S.blob }),
      m({ name = "environment", schema = S.string }),
    },
  }),
}

local INGEST = {
  name = "Ingest",
  method = "POST",
  uri = "/context/ingest",
  content_type = "multipart",
  input = S.struct({
    members = {
      m({ name = "documents", schema = S.list(S.unknown) }),
      m({ name = "attachments", wire = "files[]", schema = S.list(S.unknown) }),
      m({ name = "blobs", schema = S.list(S.blob) }),
      m({ name = "tags", schema = S.list(S.string) }),
      m({ name = "database", schema = S.string }),
    },
  }),
}

local function build(op, input, seed)
  return request.build({
    op = op,
    input = input,
    base_url = "https://example.test",
    random = testing.random(seed or 1),
  })
end

-- a minimal RFC 7578 reader for these specs: name -> list of { filename, type, data }
local function parse(body, content_type)
  local b = string.match(content_type, "boundary=(.+)$")
  local parts = {}
  local delim = "--" .. b
  local pos = 1
  local order = {}
  while true do
    local s, e = string.find(body, delim, pos, true)
    if not s then
      break
    end
    if string.sub(body, e + 1, e + 2) == "--" then
      break
    end
    local next_s = string.find(body, "\r\n" .. delim, e + 1, true)
    local chunk = string.sub(body, e + 3, next_s - 1)
    local hs, he = string.find(chunk, "\r\n\r\n", 1, true)
    local head, data = string.sub(chunk, 1, hs - 1), string.sub(chunk, he + 1)
    local name = string.match(head, 'name="([^"]*)"')
    local filename = string.match(head, 'filename="([^"]*)"')
    local ctype = string.match(head, "Content%-Type: ([^\r]*)")
    parts[name] = parts[name] or {}
    table.insert(parts[name], { filename = filename, type = ctype, data = data })
    order[#order + 1] = name
    pos = next_s + 2
  end
  return parts, order
end

t.describe("request.build: multipart bodies", function()
  t.it("a blob member is a file part named after the member; text stays text", function()
    local environment = json.encode({ SECRET = "value", REMOVED = "" })
    local r, err = build(DEPLOY, { zip = "PK\0\255", environment = environment })
    t.eq(err, nil)
    local b = boundary_for(1)
    t.eq(r.method, "POST")
    t.eq(r.url, "https://example.test/deployments")
    t.eq(r.headers["content-type"], "multipart/form-data; boundary=" .. b)
    t.eq(
      r.body,
      "--"
        .. b
        .. '\r\nContent-Disposition: form-data; name="zip"; filename="zip"\r\n'
        .. "Content-Type: application/octet-stream\r\n\r\nPK\0\255\r\n"
        .. "--"
        .. b
        .. '\r\nContent-Disposition: form-data; name="environment"\r\n\r\n'
        .. environment
        .. "\r\n--"
        .. b
        .. "--\r\n"
    )
  end)

  t.it("a distilled.file keeps its filename and content type", function()
    local zip = multipart.file({ data = "PK\255", filename = "bundle.zip" })
    local r = build(DEPLOY, { zip = zip, environment = "{}" })
    local parts = parse(r.body, r.headers["content-type"])
    t.same(
      parts.zip,
      { { filename = "bundle.zip", type = "application/octet-stream", data = "PK\255" } }
    )
    zip = multipart.file({ data = "x", content_type = "application/zip" })
    parts =
      parse(build(DEPLOY, { zip = zip }).body, build(DEPLOY, { zip = zip }).headers["content-type"])
    -- a nameless file is named after the member (Distilled: a Blob without a name)
    t.same(parts.zip, { { filename = "zip", type = "application/zip", data = "x" } })
  end)

  t.it("every file in a list is a part under the member's wire name", function()
    local r = build(INGEST, {
      database = "acme_corp",
      documents = {
        multipart.file({ data = "\1\2", filename = "policy.pdf" }),
        multipart.file({ data = "\3", filename = "notes.txt" }),
      },
    })
    local parts, order = parse(r.body, r.headers["content-type"])
    t.same(parts.documents, {
      { filename = "policy.pdf", type = "application/octet-stream", data = "\1\2" },
      { filename = "notes.txt", type = "application/octet-stream", data = "\3" },
    })
    t.eq(parts["policy.pdf"], nil)
    t.same(parts.database, { { data = "acme_corp" } })
    t.same(order, { "documents", "documents", "database" })
  end)

  t.it("a renamed member keeps its wire name and the file's path-like filename", function()
    local r = build(INGEST, {
      database = "acme_corp",
      attachments = { multipart.file({ data = "\9", filename = "skill/SKILL.md" }) },
    })
    local parts = parse(r.body, r.headers["content-type"])
    t.same(parts["files[]"], {
      { filename = "skill/SKILL.md", type = "application/octet-stream", data = "\9" },
    })
    t.eq(parts.attachments, nil)
  end)

  t.it("strings in a list of blobs are binary parts named after the member", function()
    local r = build(INGEST, {
      database = "d",
      blobs = { "\4\5", multipart.file({ data = "\8" }) },
    })
    local parts = parse(r.body, r.headers["content-type"])
    t.same(parts.blobs, {
      { filename = "blobs", type = "application/octet-stream", data = "\4\5" },
      { filename = "blobs", type = "application/octet-stream", data = "\8" },
    })
  end)

  t.it("a list of non-binary values is one JSON part; an empty list is []", function()
    local r = build(INGEST, { database = "acme_corp", tags = { "a", "b" }, documents = {} })
    local parts = parse(r.body, r.headers["content-type"])
    t.same(parts.tags, { { data = '["a","b"]' } })
    t.same(parts.documents, { { data = "[]" } })
    -- mixed: strings at an unknown node are not bytes, so the list is JSON
    r = build(INGEST, { database = "d", documents = { multipart.file({ data = "x" }), "y" } })
    local mixed = parse(r.body, r.headers["content-type"]).documents
    t.eq(#mixed, 1)
    t.eq(mixed[1].filename, nil)
    t.match(mixed[1].data, '^%[.*"y"%]$')
  end)

  t.it("tables are JSON parts, scalars are String(v), null and absent are omitted", function()
    local op = {
      name = "Mixed",
      method = "PUT",
      uri = "/m",
      content_type = "multipart",
      input = S.struct({
        members = {
          m({ name = "meta", schema = S.unknown }),
          m({ name = "count", schema = S.number }),
          m({ name = "on", schema = S.boolean }),
          m({ name = "flag", schema = S.boolean, string_encoded = true }),
          m({ name = "gone", schema = S.string }),
          m({ name = "absent", schema = S.string }),
        },
      }),
    }
    local r =
      build(op, { meta = { a = 1 }, count = 1.5, on = false, flag = true, gone = json.null })
    local parts, order = parse(r.body, r.headers["content-type"])
    t.same(order, { "meta", "count", "on", "flag" })
    t.eq(parts.meta[1].data, '{"a":1}')
    t.eq(parts.count[1].data, "1.5")
    t.eq(parts.on[1].data, "false")
    t.eq(parts.flag[1].data, "true")
  end)

  t.it("secrets inside parts and files are unwrapped; the caller's input is not changed", function()
    local zip = multipart.file({ data = secret("PK-SECRET-BYTES") })
    local input = { zip = zip, environment = secret('{"K":"V"}') }
    local r = build(DEPLOY, input)
    local parts = parse(r.body, r.headers["content-type"])
    t.eq(parts.zip[1].data, "PK-SECRET-BYTES")
    t.eq(parts.environment[1].data, '{"K":"V"}')
    t.truthy(secret.is(input.environment))
    t.truthy(secret.is(zip.data))
  end)

  t.it("a payload record is one part per entry, in sorted key order", function()
    local op = {
      name = "Assets",
      method = "POST",
      uri = "/assets",
      content_type = "multipart",
      input = S.struct({
        members = { m({ name = "files", bind = "payload", schema = S.map(S.blob) }) },
      }),
    }
    local r = build(op, {
      files = {
        h2 = multipart.file({ data = "B", filename = "b.js" }),
        h1 = "A",
      },
    })
    local parts, order = parse(r.body, r.headers["content-type"])
    t.same(order, { "h1", "h2" })
    t.same(parts.h1, { { filename = "h1", type = "application/octet-stream", data = "A" } })
    t.same(parts.h2, { { filename = "b.js", type = "application/octet-stream", data = "B" } })
  end)

  t.it("a blob payload is one file part under the member's wire name", function()
    local op = {
      name = "Put",
      method = "PUT",
      uri = "/blob",
      content_type = "multipart",
      input = S.struct({ members = { m({ name = "body", bind = "payload", schema = S.blob }) } }),
    }
    local r = build(op, { body = "\0\1" })
    local parts = parse(r.body, r.headers["content-type"])
    t.same(parts.body, { { filename = "body", type = "application/octet-stream", data = "\0\1" } })
  end)

  t.it("undeclared input keys are parts too; labels, query and headers are not", function()
    local op = {
      name = "Up",
      method = "POST",
      uri = "/u/{id}",
      content_type = "multipart",
      input = S.struct({
        members = {
          m({ name = "id", bind = "label", schema = S.string, required = true }),
          m({ name = "q", bind = "query", schema = S.string }),
          m({ name = "trace", wire = "X-Trace", bind = "header", schema = S.string }),
          m({ name = "file", schema = S.blob }),
        },
      }),
    }
    local r = build(op, { id = "a b", q = "x", trace = "t1", file = "F", extra = "E" })
    t.eq(r.url, "https://example.test/u/a%20b?q=x")
    t.eq(r.headers["x-trace"], "t1")
    local _, order = parse(r.body, r.headers["content-type"])
    t.same(order, { "file", "extra" })
  end)

  t.it("the boundary comes from host.random when a host is given", function()
    local r = request.build({
      op = DEPLOY,
      input = { environment = "{}" },
      host = testing.host({ seed = 7 }),
    })
    t.eq(r.headers["content-type"], "multipart/form-data; boundary=" .. boundary_for(7))
  end)

  t.it("a file whose data was replaced by a non-string fails with InvalidInput", function()
    local zip = multipart.file({ data = "x" })
    zip.data = 5
    local r, err = build(DEPLOY, { zip = zip })
    t.fails_with("InvalidInput", r, err)
    t.eq(err.member, "zip")
  end)

  t.it("a GET multipart operation still sends the form (as Distilled does)", function()
    local op =
      { name = "G", method = "GET", uri = "/g", content_type = "multipart", input = DEPLOY.input }
    local r = build(op, { environment = "{}" })
    t.match(r.headers["content-type"], "multipart/form-data; boundary=", true)
    t.match(r.body, 'name="environment"', true)
  end)
end)

---------------------------------------------------------------------------------------
-- an independent parser: Node's Request.formData() (undici)
---------------------------------------------------------------------------------------

-- Reads the body from stdin (rex.exec) or a file (argv[2]); prints one JSON array of
-- [name, value] or [name, { filename, type, hex }] in form order.
local NODE_SCRIPT = table.concat({
  "const fs=require('fs');",
  "const body=process.argv[2]?fs.readFileSync(process.argv[2]):fs.readFileSync(0);",
  "const r=new Request('http://x/',{method:'POST',headers:{'content-type':process.argv[1]},body});",
  "r.formData().then(async f=>{const out=[];",
  "for(const [k,v] of f){out.push(typeof v==='string'?[k,v]:",
  "[k,{filename:v.name,type:v.type,hex:Buffer.from(await v.arrayBuffer()).toString('hex')}]);}",
  "process.stdout.write(JSON.stringify(out));}).catch(e=>{process.stdout.write('ERR '+e.message);});",
}, "")

local rex_api = rawget(_G, "rex")
local popen = io and rawget(io, "popen")

local function shell_quote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- -> stdout | nil, reason
local function run_node(content_type, body)
  if rex_api and rawget(rex_api, "exec") then
    local res = rex_api.exec(
      { "node", "-e", NODE_SCRIPT, content_type },
      { stdin = body, timeout = 30 }
    )
    if type(res) ~= "table" or not res.ok then
      return nil, "node via rex.exec failed: " .. tostring(res and res.stderr)
    end
    return res.stdout
  end
  if not popen then
    return nil, "no io.popen and no rex.exec"
  end
  local path = os.tmpname()
  local f = io.open(path, "wb")
  f:write(body)
  f:close()
  local h = popen(
    "node -e "
      .. shell_quote(NODE_SCRIPT)
      .. " "
      .. shell_quote(content_type)
      .. " "
      .. path
      .. " 2>&1"
  )
  local out = h:read("*a")
  h:close()
  os.remove(path)
  return out
end

local function node_available()
  local out = run_node("multipart/form-data; boundary=x", "--x--\r\n")
  return out == "[]"
end

local function hex(s)
  return (string.gsub(s, ".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local ok_node, has_node = t.pcall(node_available)
if ok_node and has_node then
  t.describe("multipart: Node's formData() parser reads what request.build writes", function()
    t.it("names, filenames, content types and exact bytes come back", function()
      local bytes = all_bytes()
      local tricky = "--\r\n--" .. boundary_for(1) .. "\r\n\0\r\n\r\n--"
      local op = {
        name = "Ingest",
        method = "POST",
        uri = "/i",
        content_type = "multipart",
        input = S.struct({
          members = {
            m({ name = "zip", schema = S.blob }),
            m({ name = "documents", wire = "files[]", schema = S.list(S.unknown) }),
            m({ name = "meta", schema = S.unknown }),
            m({ name = "environment", schema = S.string }),
          },
        }),
      }
      local r, err = build(op, {
        zip = bytes .. tricky,
        documents = {
          multipart.file({
            data = "\0",
            filename = 'we"ird\r\nname.bin',
            content_type = "Text/Plain",
          }),
          multipart.file({ data = string.rep(bytes, 64), filename = "dir/all.bin" }),
        },
        meta = { list = json.array({ 1, "two" }), ["é"] = "ü" },
        environment = 'line1\nline2 "q"',
      })
      t.eq(err, nil)
      -- the tricky data holds the first boundary, so another one was picked
      t.ne(string.match(r.headers["content-type"], "boundary=(.+)$"), boundary_for(1))
      local out, why = run_node(r.headers["content-type"], r.body)
      t.truthy(out, why)
      local got, derr = json.decode(out)
      t.truthy(got, tostring(derr) .. ": " .. tostring(out))
      t.eq(#got, 5)
      t.eq(got[1][1], "zip")
      t.same(
        got[1][2],
        { filename = "zip", type = "application/octet-stream", hex = hex(bytes .. tricky) }
      )
      t.eq(got[2][1], "files[]")
      t.same(got[2][2], { filename = 'we"ird\r\nname.bin', type = "text/plain", hex = "00" })
      t.eq(got[3][1], "files[]")
      t.same(got[3][2], {
        filename = "dir/all.bin",
        type = "application/octet-stream",
        hex = hex(string.rep(bytes, 64)),
      })
      t.same(got[4], { "meta", json.encode({ list = json.array({ 1, "two" }), ["é"] = "ü" }) })
      -- text values travel with CRLF line breaks, as undici sends them
      t.same(got[5], { "environment", 'line1\r\nline2 "q"' })
    end)

    t.it("names with quotes and line breaks come back decoded", function()
      local out = multipart.encode({
        { name = 'a"b', value = "1" },
        { name = "c\nd", value = "2" },
      }, { random = testing.random(5) })
      local got = json.decode(run_node(out.content_type, out.body))
      t.same(got, { { 'a"b', "1" }, { "c\r\nd", "2" } })
    end)
  end)
else
  t.pending("multipart: Node's formData() parser (node not runnable here)")
end
