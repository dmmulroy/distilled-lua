// Differential cases for `dl test --xml-fuzz`: documents and Distilled's outcome for each.
//   node --conditions=bun --experimental-transform-types xml_gen.mjs \
//     <seed> <count> <inputs.bin> <expected.txt> <distilled xml.ts> <fixtures dir>
// inputs.bin: per document, its byte length in decimal, "\n", then the bytes. Documents
//   are JS strings written as WTF-8 (UTF-8, with a lone surrogate as its 3-byte form),
//   which is what a Lua string holding the same text looks like.
// expected.txt: one line per document: the parseXmlSync result as JSON with object keys
//   sorted by UTF-8 bytes (what distilled.json emits), or "ERROR <message>".
// Cases: the upstream fast-xml-parser corpus and the hand-written cases of Distilled's
// xml.test.ts, the XML fixtures under spec/fixtures/xml, xml.test.ts's generator, and a
// wider generator (Unicode names, astral and forbidden characters, character references
// at the range edges, line endings, declarations), each with corruptions.
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const [seedArg, countArg, inPath, expectedPath, xmlTs, fixturesDir] = process.argv.slice(2);
const original = await import(xmlTs);
const reference = await import(join(dirname(xmlTs), "../test/fixtures/xml/reference-parser.ts"));

// xml.ts's ASCII-name fast path is /[A-Za-z_:][\w:.-]*(?![^\0-\x7f])/y: when the name
// runs into a non-ASCII character the `*` backtracks until the next character is ASCII,
// so <Straße> reads the name "Stra" and fails ("Expected whitespace or tag terminator").
// Its own reference parser (no fast paths) reads "Straße", as XML says, and so does
// distilled.xml. The expected outcome comes from xml.ts with that one pattern fixed (the
// lookahead also refuses a name character, so nothing backtracks); every document is
// also checked against the reference parser, and the documents where unpatched xml.ts
// differs are counted.
const require = createRequire(xmlTs);
const patchedSource = readFileSync(xmlTs, "utf8")
  .replace(
    "const asciiName = /[A-Za-z_:][\\w:.-]*(?![^\\0-\\x7f])/y;",
    "const asciiName = /[A-Za-z_:][\\w:.-]*(?![\\w:.-]|[^\\0-\\x7f])/y;",
  )
  .replace(/from "effect\/(\w+)"/g, (_, mod) => `from ${JSON.stringify(pathToFileURL(require.resolve(`effect/${mod}`)).href)}`);
if (!patchedSource.includes("(?![\\w:.-]|")) throw new Error("xml_gen: the asciiName pattern of xml.ts changed; update the patch");
mkdirSync(dirname(inPath), { recursive: true });
const patchedPath = join(dirname(inPath), "xml_patched.ts");
writeFileSync(patchedPath, patchedSource);
const { parseXmlSync, XmlParseError } = await import(pathToFileURL(patchedPath).href);

let state = Number(seedArg) >>> 0;
const rand = () => {
  // mulberry32
  state = (state + 0x6d2b79f5) >>> 0;
  let t = state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const int = (n) => Math.floor(rand() * n);
const pick = (xs) => xs[int(xs.length)];

const docs = [];

// --- fixed cases -----------------------------------------------------------------------
const corpus = JSON.parse(readFileSync(join(fixturesDir, "upstream-validator.json"), "utf8"));
for (const c of corpus) docs.push(c.xml);
for (const f of readdirSync(fixturesDir).sort()) {
  if (f.endsWith(".xml")) docs.push(readFileSync(join(fixturesDir, f), "utf8"));
}
// xml.test.ts, "XML object format" and "malformed and unsupported XML"
docs.push(
  "<R><x>001</x><x>false</x><x>1e3</x><empty/><empty></empty></R>",
  '<ns:R xmlns:ns="urn:r"><ns:x ns:id="01">value</ns:x><empty a=""/></ns:R>',
  '<R><Key> key </Key><blank> \t </blank><x a=" b "> text </x><c><![CDATA[ c ]]></c></R>',
  "<R>\n  <x/>\n  <y/>\n</R>",
  "<R>Hello <b>world</b> !</R>",
  "<R><![CDATA[ ]]><b/></R>",
  '<R a="&quot;&apos;&#9;">&amp;&lt;&gt;&#65;&#x1F600;&amp;lt;</R>',
  '<R a="x\r\ny\tz\r&#13;&#10;&#9;">a\r\nb\rc&#13;</R>',
  "<R>a<![CDATA[<b>&amp;]]><![CDATA[c]]>d&amp;</R>",
  "<R><![CDATA[]]></R>",
  '\uFEFF<?xml version="1.0" encoding="UTF-8" standalone="yes"?><!--before--><?before a?><R>a<!--ignored--><?in x?>b</R><?after?><!--after-->',
  '<根 é="oui"><𐀀>😀</𐀀><á/></根>',
  "",
  " \r\n\t",
  "\uFEFF",
  "<__proto__><constructor>one</constructor><constructor>two</constructor><__proto__>safe</__proto__><toString/></__proto__>",
  "<R>\r\n&bad;</R>",
  `<R>${'<item a="1">value</item>'.repeat(10_000)}</R>`,
  "<a>".repeat(256) + "</a>".repeat(256),
  "<a>".repeat(257) + "</a>".repeat(257),
);
const invalid = [
  '<R a="1"a="2"/>', '<R a="<"/>', '<R a="&bad;"/>', "<R a=1/>", '<R a="1" a="2"/>', "<R/ >",
  "< R/>", "<R></ R>", "<R></R x>", "<R>]]></R>", "<R>&</R>", "<R>&amp</R>", "<R>&nope;</R>",
  "<R>&#0;</R>", "<R>&#xD800;</R>", "<R>&#x110000;</R>", "<R>&#xFFFE;</R>", "<R>&#-1;</R>",
  "<R>&#X41;</R>", "<R>&#x;</R>", "<R>&#;</R>", "<R>\u0000</R>", "<R>\u000B</R>", "<R>\uD800</R>",
  "<R>\uDC00</R>", "<R>\uFFFE</R>", "<R>\uFFFF</R>", "<R><!--a--b--></R>", "<R><!--a---></R>",
  "<R><!--", "<R><![CDATA[", "<![CDATA[x]]><R/>", "<R/><![CDATA[x]]>", "<R><?pi", "<R><?1bad?></R>",
  "<R><?pi!?></R>", '<?XML version="1.0"?><R/>', "<?xml?><R/>", '<?xml version="1.1"?><R/>',
  '<?xml encoding="UTF-8"?><R/>', '<?xml version="1.0" junk="x"?><R/>',
  '<R><?xml version="1.0"?></R>', '<!--x--><?xml version="1.0"?><R/>', '<?xml version="1.0"?>',
  "<!--only-->", "<!DOCTYPE R><R/>", '<!DOCTYPE R SYSTEM "file:///etc/passwd"><R/>',
  '<!DOCTYPE R [<!ENTITY a "&a;">]><R>&a;</R>', "<R/><R/>", "before<R/>", "<R/>after",
  "<R><x></R>", "<R>", "<", '<R a="', "<R a", "<R a=", "<R ", "</R>", "<1bad/>", '<R\u00A0a="x"/>',
];
docs.push(...invalid);

// --- xml.test.ts's generator (same constructs, our seed) -------------------------------
{
  const names = ["a", "B", "x:y", "_n", "item", "member", "__proto__", "Name1", "k-v.w", "é", "#"];
  const texts = [
    "", " ", "v", " x ", "a&amp;b", "&lt;&gt;&quot;&apos;", "&#65;&#x42;", "&bad;", "&#0;",
    "l\r\nm", "t\rn", "\t", "]]>", "😀", "&", "x>y", "\u0001",
  ];
  const attrValues = ['"1"', "'2'", '" a\tb "', '"x&amp;y"', '"<"', '"&#10;"', "noquote", '"\r\n"'];
  const element = (depth) => {
    const name = pick(names);
    let attrs = "";
    for (let i = int(3); i > 0; i--) {
      attrs += `${pick([" ", "\n", "  "])}${pick(names)}${pick(["=", " = "])}${pick(attrValues)}`;
    }
    if (rand() < 0.25) return `<${name}${attrs}${pick(["/>", " />"])}`;
    let body = "";
    for (let i = int(4); i > 0; i--) {
      const r = rand();
      if (depth < 4 && r < 0.5) body += element(depth + 1);
      else if (r < 0.85) body += pick(texts);
      else body += pick(["<!-- c -->", "<![CDATA[ d ]]>", "<?pi x?>"]);
    }
    return `<${name}${attrs}>${body}</${pick([name, name, name, "other"])}${pick(["", " "])}>`;
  };
  const prologs = [
    "", '<?xml version="1.0"?>', '<?xml version="1.0" encoding="UTF-8"?>\n', "\uFEFF", " ",
    "<?xml version='2.0'?>", "<!DOCTYPE r>",
  ];
  generate(() => pick(prologs) + element(0) + pick(["", " ", "\n", "<x/>", "t"]));
}

// --- a wider generator -------------------------------------------------------------------
// Each choice is valid most of the time (so about half the documents parse) and
// sometimes one of the invalid forms.
{
  const maybe = (valid, invalid) => (rand() < 0.02 ? pick(invalid) : pick(valid));
  const names = [
    "a", "R", "ns:x", "_", ":", "x-y.z", "n1", "Key", "Contents", "é", "根", "𐀀", "a·b", "x\u0300",
    "a\u203Fb", "Ⅻ", "Straße", "Größe", "ab\u00B7", "\u{EFFFF}", "\u200Cx", "\u2070", "Ab1é2",
  ];
  const badNames = ["1bad", "-x", ".x", "a\u00D7b", "\u00B7x", "\uFDD0", "\u{F0000}", "x\u037E", "#"];
  const texts = [
    "", " ", "\n  ", "\r\n", "\r", "\t\r\n ", "plain", "ünï", "😀𝄞", "\u2028\u2029", "\u0085",
    "&amp;&lt;&gt;&quot;&apos;", "&#65;", "&#x41;", "&#0000065;", "&#x0010FFFF;", "&#xD7FF;",
    "&#xE000;", "&#xFFFD;", "&#x10000;", "&#9;&#10;&#13;", "&#32;", "&#13;\r\n", "]]", "]>", ">",
    "'\"", "\uDBFF\uDFFF", "\uFEFF", "\u{10FFFF}", "\u007F", "x".repeat(300),
  ];
  const badTexts = [
    "&#x110000;", "&#xFFFE;", "&#31;", "&#99999999999999999999;", "&#x;", "&lt", "&AMP;", "& amp;",
    "]]>", "\u0000", "\u0008", "\u000C", "\u001F", "\uD800", "\uDFFF", "\uFFFE", "\uFFFF",
  ];
  const attrValues = [
    '""', "''", '"v"', '"a\'b"', "'a\"b'", '"\t\n\r"', '"\r\n\r\n"', '"&#9;&#10;"', '" &amp; "',
    '"&quot;"', '">"', '"😀"', "'x'",
  ];
  const badAttrValues = ['"<"', '"&"', '"\uD800"', "'unterminated", "bare", "\"&#0;\""];
  const specials = [
    "<!---->", "<!-- - -->", "<!--é-->", "<![CDATA[]]>", "<![CDATA[\r\n]]>", "<![CDATA[a]]b]]>",
    "<![CDATA[&amp;<x>]]>", "<?pi?>", "<?pi data?>", "<?pi\tdata?>", "<?xml-stylesheet href='x'?>",
  ];
  const badSpecials = ["<!--a--b-->", "<!--a--->", "<?Xml?>", "<?pi", "<!DOCTYPE x>", "<!ELEMENT>"];
  const element = (depth) => {
    const name = maybe(names, badNames);
    let attrs = "";
    const used = new Set();
    for (let i = int(4); i > 0; i--) {
      const attr = maybe(names, badNames);
      if (used.has(attr) && rand() < 0.9) continue;
      used.add(attr);
      attrs += `${pick([" ", "\t", "\r\n", "  "])}${attr}${pick(["=", " =", "= ", "\t=\n"])}${maybe(attrValues, badAttrValues)}`;
    }
    if (rand() < 0.2) return `<${name}${attrs}${maybe(["/>", " />", "\n/>"], ["/ >"])}`;
    let body = "";
    for (let i = int(6); i > 0; i--) {
      const r = rand();
      if (depth < 6 && r < 0.45) body += element(depth + 1);
      else if (r < 0.85) body += maybe(texts, badTexts);
      else body += maybe(specials, badSpecials);
    }
    return `<${name}${attrs}>${body}</${maybe([name], ["R", name + "x"])}${pick(["", " ", "\n"])}>`;
  };
  const prologs = [
    "", "\uFEFF", "\n", '<?xml version="1.0"?>', "<?xml version='1.0'?>",
    '<?xml version="1.0" encoding="UTF-8"?>', "<?xml version='1.0' encoding='utf-8' standalone='no'?>",
    '<?xml version="1.0" standalone="yes"?>', '<?xml  version = "1.0"  ?>', "<!--c-->", "<?pi?>",
    '<?xml version="1.0"?>\r\n<!--c-->\n',
  ];
  const badPrologs = [
    '<?xml version="1.0" encoding="UTF-8" standalone="maybe"?>', '<?xml version="1.0\'?>',
    '<?xml version="1.0" standalone="yes" encoding="UTF-8"?>', '<?xml version="1.0" encoding="8bit"?>',
    ' <?xml version="1.0"?>',
  ];
  generate(() => maybe(prologs, badPrologs) + element(0) + maybe(["", " ", "\r\n", "<!--c-->", "<?pi?>"], ["x", "<R/>"]));
}

function generate(make) {
  const corruptions = ["<", ">", "&", '"', "'", "/", " ", "=", ";", "\u0000", "é", "\uD800", "]]>", "<!--", "\r"];
  for (let i = 0; i < Number(countArg); i++) {
    const doc = make();
    docs.push(doc);
    docs.push(doc.slice(0, int(doc.length + 1)));
    const at = int(doc.length);
    docs.push(doc.slice(0, at) + pick(corruptions) + doc.slice(at + int(2)));
  }
}

// --- output ------------------------------------------------------------------------------
function wtf8(s) {
  const bytes = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + (cp - 0xd800) * 0x400 + (lo - 0xdc00);
        i++;
      }
    }
    if (cp < 0x80) bytes.push(cp);
    else if (cp < 0x800) bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
    else if (cp < 0x10000) bytes.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    else bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
  }
  return Buffer.from(bytes);
}

const byUtf8 = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
function canonical(v) {
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  const keys = Object.keys(v).sort(byUtf8);
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
}

function outcome(parse, ErrorClass, doc) {
  try {
    return canonical(parse(doc));
  } catch (error) {
    if (!(error instanceof ErrorClass)) throw error;
    return `ERROR ${error.message}`;
  }
}

const chunks = [];
const lines = [];
let bytes = 0;
let failures = 0;
let nameBug = 0;
for (const doc of docs) {
  const encoded = wtf8(doc);
  bytes += encoded.length;
  chunks.push(Buffer.from(`${encoded.length}\n`), encoded);
  const line = outcome(parseXmlSync, XmlParseError, doc);
  if (line !== outcome(reference.parseXmlReference, reference.XmlParseError, doc)) {
    throw new Error(`xml_gen: patched xml.ts and the reference parser disagree on ${JSON.stringify(doc)}`);
  }
  if (line !== outcome(original.parseXmlSync, original.XmlParseError, doc)) nameBug++;
  if (line.startsWith("ERROR ")) failures++;
  lines.push(line);
}
writeFileSync(inPath, Buffer.concat(chunks));
writeFileSync(expectedPath, lines.join("\n") + "\n");
console.log(
  `node: ${docs.length} documents (${docs.length - failures} parse, ${failures} rejected), ${(bytes / 1048576).toFixed(2)} MB; ${nameBug} differ from unpatched xml.ts only by its ASCII-name bug`,
);
