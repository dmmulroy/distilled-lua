local t = require("spec.harness")
local url = require("distilled.url")
local json = require("distilled.json")

-- Recorded from Node 24: encodeURIComponent(String.fromCharCode(i)) and
-- URLSearchParams' value encoding for i = 0..127, concatenated.
local NODE_COMPONENT_ASCII =
  "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F%20!%22%23%24%25%26'()*%2B%2C-.%2F0123456789%3A%3B%3C%3D%3E%3F%40ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~%7F"
local NODE_FORM_ASCII =
  "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F+%21%22%23%24%25%26%27%28%29*%2B%2C-.%2F0123456789%3A%3B%3C%3D%3E%3F%40ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D%7E%7F"

t.describe("url: percent-encoding", function()
  t.it("encode_component equals encodeURIComponent for every ASCII byte", function()
    local parts = {}
    for b = 0, 127 do
      parts[#parts + 1] = url.encode_component(string.char(b))
    end
    t.eq(table.concat(parts), NODE_COMPONENT_ASCII)
  end)

  t.it("encode_form equals URLSearchParams for every ASCII byte", function()
    local parts = {}
    for b = 0, 127 do
      parts[#parts + 1] = url.encode_form(string.char(b))
    end
    t.eq(table.concat(parts), NODE_FORM_ASCII)
  end)

  t.it("bytes 128-255 are escaped one by one (JavaScript escapes each UTF-8 byte)", function()
    for b = 128, 255 do
      local expected = string.format("%%%02X", b)
      t.eq(url.encode_component(string.char(b)), expected)
      t.eq(url.encode_form(string.char(b)), expected)
    end
  end)

  t.it("matches Node on UTF-8 text", function()
    local cases = {
      -- text, encodeURIComponent, URLSearchParams name=value
      { "\195\169", "%C3%A9", "%C3%A9=%C3%A9" },
      { "\230\151\165\230\156\172", "%E6%97%A5%E6%9C%AC", "%E6%97%A5%E6%9C%AC=%E6%97%A5%E6%9C%AC" },
      { "\240\159\152\128", "%F0%9F%98%80", "%F0%9F%98%80=%F0%9F%98%80" },
      { "a b+c", "a%20b%2Bc", "a+b%2Bc=a+b%2Bc" },
      { "~!*()'", "~!*()'", "%7E%21*%28%29%27=%7E%21*%28%29%27" },
    }
    for _, c in ipairs(cases) do
      t.eq(url.encode_component(c[1]), c[2])
      t.eq(url.query():add(c[1], c[1]):encode(), c[3])
    end
  end)

  t.it("a % in the text is escaped, so no double decoding", function()
    t.eq(url.encode_component("%3A"), "%253A")
  end)
end)

t.describe("url: greedy labels", function()
  t.it(
    "keeps slashes, encodes segments, drops leading slashes (Distilled greedy labels)",
    function()
      t.eq(
        url.encode_greedy_label("/subscriptions/abc/resourceGroups/my rg"),
        "subscriptions/abc/resourceGroups/my%20rg"
      )
      t.eq(url.encode_greedy_label("subscriptions/abc"), "subscriptions/abc")
      t.eq(url.encode_greedy_label("///a//b/"), "a//b/")
      t.eq(url.encode_greedy_label(""), "")
      t.eq(url.encode_greedy_label("a?b#c"), "a%3Fb%23c")
    end
  )
end)

t.describe("url: String(v)", function()
  t.it("numbers print like JavaScript", function()
    t.eq(url.text(1), "1")
    t.eq(url.text(1.5), "1.5")
    t.eq(url.text(0.1), "0.1")
    t.eq(url.text(1e21), "1e+21")
    t.eq(url.text(1e-7), "1e-7")
    t.eq(url.text(-0.0), "0")
    t.eq(url.text(123456789012), "123456789012")
    t.eq(url.text(2 ^ 53), "9007199254740992")
    t.eq(url.text(0.000001), "0.000001")
    t.eq(url.text(0 / 0), "NaN")
    t.eq(url.text(1 / 0), "Infinity")
  end)

  t.it("booleans, null, lists and objects", function()
    t.eq(url.text(true), "true")
    t.eq(url.text(false), "false")
    t.eq(url.text(json.null), "null")
    t.eq(url.text({ 1, json.null, "a", { 2, 3 } }), "1,,a,2,3")
    t.eq(url.text(json.array({})), "")
    t.eq(url.text({ a = 1 }), "[object Object]")
  end)
end)

t.describe("url: query and templates", function()
  t.it("query keeps insertion order and repeated names", function()
    local q = url.query()
    t.truthy(q:empty())
    q:add("tag", "x"):add("limit", "5"):add("tag", "y")
    t.falsy(q:empty())
    t.eq(q:encode(), "tag=x&limit=5&tag=y")
  end)

  t.it("a large query works on every runtime (compat.concat)", function()
    local q = url.query()
    for i = 1, 3000 do
      q:add("k", tostring(i))
    end
    local s = q:encode()
    t.eq(select(2, string.gsub(s, "&", "&")), 2999)
  end)

  t.it("fill replaces the first placeholder, plain text (no pattern characters)", function()
    t.eq(url.fill("/a/{id}/b/{id}", "id", "%41"), "/a/%41/b/{id}")
    t.eq(url.fill("/x/{a.b}", "a.b", "v"), "/x/v")
    t.eq(url.fill("/{scope+}/p", "scope", "s/t", true), "/s/t/p")
    t.eq(url.fill("/{scope+}/p", "scope", "s", false), "/{scope+}/p")
  end)

  t.it("placeholders lists names and greediness", function()
    t.same(url.placeholders("/{scope+}/things/{name}"), {
      { name = "scope", greedy = true },
      { name = "name", greedy = false },
    })
    t.same(url.placeholders("/plain"), {})
  end)
end)
