// Writes spec/golden/s3/conform.lua: what Distilled's S3 client (packages/s3, the code
// clients/s3 is generated to match) does with a sample of S3 operations:
//   requests   the signed request API.encodeRequest builds (method, URL, every header,
//              the body), or the error it fails with
//   responses  the outcome of a call over a stub HttpClient replying with a canned
//              response (the decoded value, or the error's tag, categories and fields)
//   flows      ListObjectsV2 `.pages` over scripted pages (every request and the pages)
// spec/s3_conform_spec.lua runs the same cases through clients/s3 on every runtime.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/s3_conform.mjs spec/golden/s3/conform.lua
// DISTILLED_ROOT overrides ../distilled. Time is pinned (Date and the TestClock) to
// EPOCH_MS, the credentials are fixed, retries are off.
import * as path from "node:path";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const S3 = await import(path.join(P, "s3/src/services/s3.ts"));
const API = await import(path.join(P, "core/src/api.ts"));
const Category = await import(path.join(P, "core/src/category.ts"));
const Credentials = await import(path.join(P, "s3/src/credentials.ts"));
const Endpoint = await import(path.join(P, "s3/src/endpoint.ts"));
const Retry = await import(path.join(P, "s3/src/retry.ts"));
const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Stream = await import(E + "Stream.js");
const Duration = await import(E + "Duration.js");
const Fiber = await import(E + "Fiber.js");
const TestClock = await import(E + "testing/TestClock.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");

const out = process.argv[2];
if (!out) throw new Error("usage: s3_conform.mjs <out.lua>");

const EPOCH_MS = 1700000000000;
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...a) {
    if (a.length === 0) super(EPOCH_MS);
    else super(...a);
  }
  static now() {
    return EPOCH_MS;
  }
};
Math.random = () => 0.5;

const AKID = "AKIAIOSFODNN7EXAMPLE";
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const TOKEN = "FwoGZXIvYXdzEJr//////////wEaDH+session";

const credsLayer = (c) =>
  Layer.succeed(
    Credentials.Credentials,
    Effect.succeed({
      accessKeyId: Redacted.make(AKID),
      secretAccessKey: Redacted.make(SECRET),
      sessionToken: c.session_token ? Redacted.make(TOKEN) : undefined,
      region: c.cred_region ?? "us-east-1",
    }),
  );
const layersOf = (c) => {
  const ls = [credsLayer(c), TestClock.layer(), Layer.succeed(Retry.Retry, { while: () => false })];
  if (c.endpoint) ls.push(Layer.succeed(Endpoint.Endpoint, Effect.succeed(c.endpoint)));
  return Layer.mergeAll(...ls);
};

const snake = (s) => s.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").toLowerCase();
const opOf = (name) => {
  const ts = name[0].toLowerCase() + name.slice(1);
  const op = S3[ts];
  if (!op) throw new Error("no S3 operation " + ts);
  return op;
};

const plain = (v) => (Redacted.isRedacted(v) ? Redacted.value(v) : v);

// JSON-able view of a value: dates as epoch seconds, bytes and streams as text
const view = async (v) => {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object") return v;
  if (v instanceof RealDate) return { $date: v.getTime() / 1000 };
  if (Redacted.isRedacted(v)) return { $redacted: await view(Redacted.value(v)) };
  if (v instanceof Uint8Array) return { $text: Buffer.from(v).toString("utf8") };
  if (Stream.isStream?.(v) || (typeof v === "object" && "pipe" in v && "channel" in v)) {
    const bytes = await Effect.runPromise(Stream.mkUint8Array(v));
    return { $text: Buffer.from(bytes).toString("utf8") };
  }
  if (Array.isArray(v)) return Promise.all(v.map(view));
  const o = {};
  for (const [k, x] of Object.entries(v)) {
    if (x !== undefined) o[k] = await view(x);
  }
  return o;
};

const errorView = async (e) => {
  if (e === null || typeof e !== "object") return { tag: String(e) };
  const fields = {};
  for (const [k, x] of Object.entries(e)) {
    if (k.startsWith("_") || typeof x === "function" || x === undefined) continue;
    if (["status", "code", "message", "body", "headers", "retryAfter", "cause", "stack"].includes(k)) continue;
    fields[k] = await view(x);
  }
  const r = e[Category.retryableKey];
  return {
    tag: e._tag ?? e.constructor?.name,
    categories: Object.keys(e[Category.categoriesKey] ?? {}).sort(),
    retryable: r !== undefined,
    throttling: r?.throttling === true,
    message: e.message,
    member: e.member,
    fields,
  };
};

// ---------------------------------------------------------------------------------------
// cases
// ---------------------------------------------------------------------------------------

const requests = [
  { id: "get-object", op: "GetObject", input: { Bucket: "my-bucket", Key: "a/b c+é.txt" } },
  {
    id: "get-object-query-and-headers",
    op: "GetObject",
    input: {
      Bucket: "my-bucket",
      Key: "k",
      Range: "bytes=0-9",
      VersionId: "v+1/=",
      ResponseContentType: "text/plain; charset=utf-8",
      IfNoneMatch: '"etag"',
      PartNumber: 2,
      ChecksumMode: "ENABLED",
    },
  },
  { id: "get-object-dotted-bucket", op: "GetObject", input: { Bucket: "my.dotted.bucket", Key: "k" } },
  { id: "get-object-uppercase-bucket", op: "GetObject", input: { Bucket: "MyBucket", Key: "k" } },
  { id: "get-object-region-input", op: "GetObject", input: { Bucket: "b-eu", Key: "k", region: "eu-west-1" } },
  { id: "get-object-cred-region", op: "GetObject", input: { Bucket: "b-cn", Key: "k" }, cred_region: "cn-north-1" },
  { id: "get-object-session-token", op: "GetObject", input: { Bucket: "b", Key: "k" }, session_token: true },
  {
    id: "get-object-custom-endpoint",
    op: "GetObject",
    input: { Bucket: "my-bucket", Key: "dir/x y.txt" },
    endpoint: "http://localhost:9000",
  },
  {
    id: "get-object-r2-endpoint",
    op: "GetObject",
    input: { Bucket: "bkt", Key: "k" },
    endpoint: "https://acct.r2.cloudflarestorage.com/",
    cred_region: "auto",
  },
  { id: "get-object-greedy-key", op: "GetObject", input: { Bucket: "b", Key: "/lead//double/(x)!*'" } },
  { id: "get-object-empty-key", op: "GetObject", input: { Bucket: "b", Key: "" } },
  { id: "get-object-dotdot-key", op: "GetObject", input: { Bucket: "b", Key: "a/../x" } },
  { id: "get-object-missing-key", op: "GetObject", input: { Bucket: "b" } },
  {
    id: "put-object",
    op: "PutObject",
    input: {
      Bucket: "my-bucket",
      Key: "hello.txt",
      Body: "Hello!",
      ContentType: "text/plain",
      Metadata: { owner: "me", "Mixed-Case": "v" },
      CacheControl: "no-cache",
      StorageClass: "STANDARD_IA",
      Tagging: "a=1&b=2",
    },
  },
  {
    id: "put-object-crc32",
    op: "PutObject",
    input: { Bucket: "b", Key: "k", Body: "data", ChecksumAlgorithm: "CRC32" },
  },
  {
    id: "put-object-sha256",
    op: "PutObject",
    input: { Bucket: "b", Key: "k", Body: "data", ChecksumAlgorithm: "SHA256" },
  },
  { id: "put-object-md5-given", op: "PutObject", input: { Bucket: "b", Key: "k", Body: "data", ContentMD5: "given==" } },
  { id: "put-object-empty-body", op: "PutObject", input: { Bucket: "b", Key: "k", Body: "" } },
  { id: "put-object-no-body", op: "PutObject", input: { Bucket: "b", Key: "k" } },
  {
    id: "put-object-expires",
    op: "PutObject",
    input: { Bucket: "b", Key: "k", Body: "x", ContentLength: 1, ObjectLockRetainUntilDate: new Date(EPOCH_MS + 86400000) },
  },
  {
    id: "list-objects-v2",
    op: "ListObjectsV2",
    input: { Bucket: "my-bucket", Prefix: "photos/2024 ", Delimiter: "/", MaxKeys: 100, ContinuationToken: "tok+/=", StartAfter: "a" },
  },
  { id: "list-objects-v2-min", op: "ListObjectsV2", input: { Bucket: "my-bucket" } },
  { id: "list-buckets", op: "ListBuckets", input: {} },
  { id: "list-buckets-region", op: "ListBuckets", input: { MaxBuckets: 10, BucketRegion: "eu-west-1" }, cred_region: "eu-west-1" },
  {
    id: "delete-objects",
    op: "DeleteObjects",
    input: {
      Bucket: "my-bucket",
      Delete: { Objects: [{ Key: "a.txt" }, { Key: "b <&>.txt", VersionId: "v1" }], Quiet: true },
    },
  },
  {
    id: "create-bucket",
    op: "CreateBucket",
    input: { Bucket: "new-bucket", CreateBucketConfiguration: { LocationConstraint: "eu-west-1" }, ACL: "private" },
  },
  { id: "create-bucket-min", op: "CreateBucket", input: { Bucket: "new-bucket" } },
  { id: "head-object", op: "HeadObject", input: { Bucket: "b", Key: "k", IfModifiedSince: new Date(EPOCH_MS) } },
  { id: "head-bucket", op: "HeadBucket", input: { Bucket: "b" } },
  {
    id: "copy-object",
    op: "CopyObject",
    input: { Bucket: "dst", Key: "copy.txt", CopySource: "src/orig key.txt", MetadataDirective: "REPLACE" },
  },
  {
    id: "put-bucket-tagging",
    op: "PutBucketTagging",
    input: { Bucket: "b", Tagging: { TagSet: [{ Key: "env", Value: "prod" }, { Key: "team", Value: "a&b" }] } },
  },
  { id: "get-bucket-location", op: "GetBucketLocation", input: { Bucket: "b" } },
  {
    id: "upload-part",
    op: "UploadPart",
    input: { Bucket: "b", Key: "big", PartNumber: 3, UploadId: "up/id+1", Body: "part-data" },
  },
  {
    id: "complete-multipart-upload",
    op: "CompleteMultipartUpload",
    input: {
      Bucket: "b",
      Key: "big",
      UploadId: "up1",
      MultipartUpload: { Parts: [{ ETag: '"e1"', PartNumber: 1 }, { ETag: '"e2"', PartNumber: 2 }] },
    },
  },
  { id: "create-multipart-upload", op: "CreateMultipartUpload", input: { Bucket: "b", Key: "big", ContentType: "video/mp4" } },
  { id: "delete-object", op: "DeleteObject", input: { Bucket: "b", Key: "gone.txt", VersionId: "v2" } },
  {
    id: "put-object-tagging",
    op: "PutObjectTagging",
    input: { Bucket: "b", Key: "k", Tagging: { TagSet: [{ Key: "k1", Value: "v1" }] } },
  },
  {
    id: "put-bucket-versioning",
    op: "PutBucketVersioning",
    input: { Bucket: "b", VersioningConfiguration: { Status: "Enabled", MFADelete: "Disabled" } },
  },
  {
    id: "put-bucket-lifecycle",
    op: "PutBucketLifecycleConfiguration",
    input: {
      Bucket: "b",
      LifecycleConfiguration: {
        Rules: [{ ID: "r1", Status: "Enabled", Filter: { Prefix: "logs/" }, Expiration: { Days: 30 } }],
      },
    },
  },
  { id: "put-bucket-policy", op: "PutBucketPolicy", input: { Bucket: "b", Policy: '{"Version":"2012-10-17"}' } },
  { id: "get-object-attributes", op: "GetObjectAttributes", input: { Bucket: "b", Key: "k", ObjectAttributes: ["ETag", "ObjectSize"] } },
  { id: "list-object-versions", op: "ListObjectVersions", input: { Bucket: "b", KeyMarker: "k", MaxKeys: 5 } },
  { id: "list-multipart-uploads", op: "ListMultipartUploads", input: { Bucket: "b", Prefix: "p" } },
  { id: "list-parts", op: "ListParts", input: { Bucket: "b", Key: "k", UploadId: "u", PartNumberMarker: "2" } },
  { id: "get-bucket-acl", op: "GetBucketAcl", input: { Bucket: "b" } },
  { id: "delete-bucket", op: "DeleteBucket", input: { Bucket: "b", ExpectedBucketOwner: "123456789012" } },
  { id: "restore-object", op: "RestoreObject", input: { Bucket: "b", Key: "k", RestoreRequest: { Days: 2 } } },
];

const XMLNS = 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/"';
const responses = [
  {
    id: "get-object-ok",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 200,
      headers: {
        "content-type": "text/plain",
        "content-length": "11",
        etag: '"abc"',
        "last-modified": "Tue, 14 Nov 2023 22:13:20 GMT",
        "x-amz-meta-owner": "me",
        "x-amz-version-id": "v1",
        "accept-ranges": "bytes",
        "x-amz-checksum-crc32": "AAAAAA==",
      },
      body: "hello world",
    },
  },
  {
    id: "get-object-binary",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 200, headers: { "content-type": "application/octet-stream" }, body: "\u00e9\u00e8 bytes" },
  },
  {
    id: "get-object-206",
    op: "GetObject",
    input: { Bucket: "b", Key: "k", Range: "bytes=0-4" },
    response: { status: 206, headers: { "content-range": "bytes 0-4/11", "content-length": "5" }, body: "hello" },
  },
  {
    id: "get-object-empty",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 200, headers: { "content-length": "0" }, body: "" },
  },
  {
    id: "list-objects-v2-ok",
    op: "ListObjectsV2",
    input: { Bucket: "b" },
    response: {
      status: 200,
      headers: { "content-type": "application/xml" },
      body:
        `<?xml version="1.0" encoding="UTF-8"?>\n<ListBucketResult ${XMLNS}><Name>b</Name><Prefix>p/</Prefix>` +
        "<KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys><Delimiter>/</Delimiter><IsTruncated>true</IsTruncated>" +
        "<NextContinuationToken>next+tok</NextContinuationToken>" +
        "<Contents><Key>p/a.txt</Key><LastModified>2023-11-14T22:13:20.000Z</LastModified><ETag>&quot;e1&quot;</ETag>" +
        "<ChecksumAlgorithm>CRC32</ChecksumAlgorithm><Size>11</Size><StorageClass>STANDARD</StorageClass></Contents>" +
        "<Contents><Key>p/b &amp; c.txt</Key><LastModified>2023-11-14T22:13:21Z</LastModified><Size>0</Size>" +
        "<Owner><ID>o1</ID><DisplayName>me</DisplayName></Owner></Contents>" +
        "<CommonPrefixes><Prefix>p/sub/</Prefix></CommonPrefixes><CommonPrefixes><Prefix>p/two/</Prefix></CommonPrefixes>" +
        "</ListBucketResult>",
    },
  },
  {
    id: "list-objects-v2-one",
    op: "ListObjectsV2",
    input: { Bucket: "b" },
    response: {
      status: 200,
      body:
        `<ListBucketResult ${XMLNS}><Name>b</Name><KeyCount>1</KeyCount><IsTruncated>false</IsTruncated>` +
        "<Contents><Key>only</Key><Size>3</Size></Contents></ListBucketResult>",
    },
  },
  {
    id: "list-objects-v2-empty",
    op: "ListObjectsV2",
    input: { Bucket: "b" },
    response: {
      status: 200,
      body: `<ListBucketResult ${XMLNS}><Name>b</Name><Prefix></Prefix><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>`,
    },
  },
  {
    id: "list-buckets-ok",
    op: "ListBuckets",
    input: {},
    response: {
      status: 200,
      body:
        `<ListAllMyBucketsResult ${XMLNS}><Owner><ID>id1</ID><DisplayName>me</DisplayName></Owner>` +
        "<Buckets><Bucket><Name>one</Name><CreationDate>2023-01-01T00:00:00.000Z</CreationDate><BucketRegion>us-east-1</BucketRegion></Bucket>" +
        "<Bucket><Name>two</Name><CreationDate>2023-01-02T00:00:00.000Z</CreationDate></Bucket></Buckets>" +
        "</ListAllMyBucketsResult>",
    },
  },
  {
    id: "get-bucket-location-eu",
    op: "GetBucketLocation",
    input: { Bucket: "b" },
    response: { status: 200, body: `<?xml version="1.0" encoding="UTF-8"?>\n<LocationConstraint ${XMLNS}>eu-west-1</LocationConstraint>` },
  },
  {
    id: "get-bucket-location-empty",
    op: "GetBucketLocation",
    input: { Bucket: "b" },
    response: { status: 200, body: `<LocationConstraint ${XMLNS}/>` },
  },
  {
    id: "head-object-ok",
    op: "HeadObject",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 200,
      headers: {
        "content-length": "1234",
        "content-type": "image/png",
        "last-modified": "Tue, 14 Nov 2023 22:13:20 GMT",
        etag: '"e"',
        "x-amz-meta-a": "1",
        "x-amz-meta-b": "two",
        "x-amz-server-side-encryption": "AES256",
        "x-amz-missing-meta": "3",
        "x-amz-delete-marker": "false",
      },
      body: "",
    },
  },
  {
    id: "delete-objects-ok",
    op: "DeleteObjects",
    input: { Bucket: "b", Delete: { Objects: [{ Key: "a" }, { Key: "b" }] } },
    response: {
      status: 200,
      body:
        `<DeleteResult ${XMLNS}><Deleted><Key>a</Key><VersionId>v</VersionId><DeleteMarker>true</DeleteMarker></Deleted>` +
        "<Error><Key>b</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error></DeleteResult>",
    },
  },
  {
    id: "create-multipart-upload-ok",
    op: "CreateMultipartUpload",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 200,
      headers: { "x-amz-server-side-encryption": "aws:kms", "x-amz-checksum-algorithm": "CRC32" },
      body: `<InitiateMultipartUploadResult ${XMLNS}><Bucket>b</Bucket><Key>k</Key><UploadId>up-1</UploadId></InitiateMultipartUploadResult>`,
    },
  },
  {
    id: "put-object-ok",
    op: "PutObject",
    input: { Bucket: "b", Key: "k", Body: "x" },
    response: { status: 200, headers: { etag: '"e"', "x-amz-version-id": "v9", "x-amz-object-size": "1" }, body: "" },
  },
  {
    id: "get-bucket-tagging-ok",
    op: "GetBucketTagging",
    input: { Bucket: "b" },
    response: {
      status: 200,
      body: `<Tagging ${XMLNS}><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag><Tag><Key>e</Key><Value></Value></Tag></TagSet></Tagging>`,
    },
  },
  {
    id: "get-bucket-policy-ok",
    op: "GetBucketPolicy",
    input: { Bucket: "b" },
    response: { status: 200, headers: { "content-type": "application/json" }, body: '{"Version":"2012-10-17","Statement":[]}' },
  },
  {
    id: "get-bucket-versioning-ok",
    op: "GetBucketVersioning",
    input: { Bucket: "b" },
    response: { status: 200, body: `<VersioningConfiguration ${XMLNS}><Status>Enabled</Status></VersioningConfiguration>` },
  },
  {
    id: "get-bucket-acl-ok",
    op: "GetBucketAcl",
    input: { Bucket: "b" },
    response: {
      status: 200,
      body:
        `<AccessControlPolicy ${XMLNS}><Owner><ID>o</ID></Owner><AccessControlList>` +
        '<Grant><Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser"><ID>o</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant>' +
        "</AccessControlList></AccessControlPolicy>",
    },
  },
  {
    id: "error-no-such-key",
    op: "GetObject",
    input: { Bucket: "b", Key: "missing" },
    response: {
      status: 404,
      headers: { "content-type": "application/xml", "x-amz-request-id": "R1" },
      body: '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message><Key>missing</Key><RequestId>R1</RequestId><HostId>H</HostId></Error>',
    },
  },
  {
    id: "error-no-such-bucket",
    op: "ListObjectsV2",
    input: { Bucket: "nope" },
    response: {
      status: 404,
      body: "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message><BucketName>nope</BucketName></Error>",
    },
  },
  {
    id: "error-head-404-empty",
    op: "HeadObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 404, body: "" },
  },
  {
    id: "error-head-403-empty",
    op: "HeadObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 403, body: "" },
  },
  {
    id: "error-head-bucket-301",
    op: "HeadBucket",
    input: { Bucket: "b" },
    response: { status: 301, headers: { "x-amz-bucket-region": "eu-west-1" }, body: "" },
  },
  {
    id: "error-permanent-redirect",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 301,
      headers: { "x-amz-bucket-region": "eu-west-1", "content-type": "application/xml" },
      body:
        "<Error><Code>PermanentRedirect</Code><Message>The bucket you are attempting to access must be addressed using the specified endpoint.</Message>" +
        "<Endpoint>b.s3.eu-west-1.amazonaws.com</Endpoint><Bucket>b</Bucket><RequestId>R</RequestId></Error>",
    },
  },
  {
    id: "error-access-denied",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 403, body: "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>" },
  },
  {
    id: "error-signature",
    op: "ListBuckets",
    input: {},
    response: {
      status: 403,
      body: "<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match</Message><AWSAccessKeyId>AKIA</AWSAccessKeyId></Error>",
    },
  },
  {
    id: "error-slow-down-html",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 503,
      headers: { "content-type": "text/html" },
      body: "<html><head><title>503 Slow Down</title></head><body><h1>503 Slow Down</h1><ul><li>Code: SlowDown</li><li>Message: Please reduce your request rate.</li><li>RequestId: R</li></ul></body></html>",
    },
  },
  {
    id: "error-slow-down-xml",
    op: "PutObject",
    input: { Bucket: "b", Key: "k", Body: "x" },
    response: { status: 503, body: "<Error><Code>SlowDown</Code><Message>Reduce your request rate.</Message></Error>" },
  },
  {
    id: "error-internal",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 500, body: "<Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>" },
  },
  {
    id: "error-500-garbage",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 500, body: "not xml at all" },
  },
  {
    id: "error-400-garbage",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 400, body: "<<<" },
  },
  {
    id: "error-wrapped",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 400,
      body: "<ErrorResponse><Error><Type>Sender</Type><Code>InvalidArgument</Code><Message>bad</Message></Error><RequestId>R</RequestId></ErrorResponse>",
    },
  },
  {
    id: "error-unknown-code",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: { status: 409, body: "<Error><Code>SomethingNew</Code><Message>new</Message></Error>" },
  },
  {
    id: "error-no-such-upload",
    op: "UploadPart",
    input: { Bucket: "b", Key: "k", PartNumber: 1, UploadId: "u", Body: "x" },
    response: { status: 404, body: "<Error><Code>NoSuchUpload</Code><Message>gone</Message><UploadId>u</UploadId></Error>" },
  },
  {
    id: "error-bucket-exists",
    op: "CreateBucket",
    input: { Bucket: "b" },
    response: { status: 409, body: "<Error><Code>BucketAlreadyOwnedByYou</Code><Message>yours</Message><BucketName>b</BucketName></Error>" },
  },
  {
    id: "error-invalid-object-state",
    op: "GetObject",
    input: { Bucket: "b", Key: "k" },
    response: {
      status: 403,
      body: "<Error><Code>InvalidObjectState</Code><Message>archived</Message><StorageClass>GLACIER</StorageClass><AccessTier>ARCHIVE_ACCESS</AccessTier></Error>",
    },
  },
  {
    id: "error-200-in-body-copy",
    op: "CopyObject",
    input: { Bucket: "b", Key: "k", CopySource: "s/k" },
    response: { status: 200, body: "<Error><Code>InternalError</Code><Message>copy failed</Message></Error>" },
  },
  {
    id: "list-objects-v2-bad-xml",
    op: "ListObjectsV2",
    input: { Bucket: "b" },
    response: { status: 200, body: "<ListBucketResult><Name>b</Name>" },
  },
];

// ListObjectsV2 .pages over three scripted pages
const page = (keys, next) =>
  `<ListBucketResult ${XMLNS}><Name>b</Name><KeyCount>${keys.length}</KeyCount><IsTruncated>${next ? "true" : "false"}</IsTruncated>` +
  (next ? `<NextContinuationToken>${next}</NextContinuationToken>` : "") +
  keys.map((k) => `<Contents><Key>${k}</Key><Size>1</Size></Contents>`).join("") +
  "</ListBucketResult>";
const flows = [
  {
    id: "list-objects-v2-pages",
    op: "ListObjectsV2",
    input: { Bucket: "b", Prefix: "p/", MaxKeys: 2 },
    responses: [
      { status: 200, body: page(["p/1", "p/2"], "t1+/=") },
      { status: 200, body: page(["p/3", "p/4"], "t2") },
      { status: 200, body: page(["p/5"], undefined) },
    ],
  },
  {
    id: "list-objects-v2-pages-error",
    op: "ListObjectsV2",
    input: { Bucket: "b" },
    responses: [
      { status: 200, body: page(["a"], "t1") },
      { status: 404, body: "<Error><Code>NoSuchBucket</Code><Message>gone</Message></Error>" },
    ],
  },
  {
    id: "list-objects-v2-pages-one",
    op: "ListObjectsV2",
    input: { Bucket: "b" },
    responses: [{ status: 200, body: page([], undefined) }],
  },
];

// ---------------------------------------------------------------------------------------
// running them
// ---------------------------------------------------------------------------------------

const toInput = (v) => v;
const inputView = (v) => {
  if (v instanceof RealDate) return { $date: v.getTime() / 1000 };
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(inputView);
  const o = {};
  for (const [k, x] of Object.entries(v)) o[k] = inputView(x);
  return o;
};

const bodyOf = async (body) => {
  switch (body._tag) {
    case "Empty":
      return null;
    case "Uint8Array":
      return Buffer.from(body.body).toString("utf8");
    case "Raw":
    case "Text":
      return String(body.body);
    default:
      return { other: body._tag };
  }
};

const runAt = (effect, layer) =>
  Effect.runPromise(
    Effect.gen(function* () {
      yield* TestClock.setTime(EPOCH_MS);
      const fiber = yield* Effect.forkChild(Effect.result(effect));
      yield* TestClock.adjust(Duration.hours(1));
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(layer)),
  );

const stub = (replies, sent) =>
  Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.sync(() => {
        const n = sent.length;
        sent.push({ method: request.method, url: request.url });
        const r = replies[n] ?? { status: 500, body: "" };
        const status = r.status;
        const nullBody = status === 204 || status === 304;
        return HttpClientResponse.fromWeb(
          request,
          new Response(nullBody ? null : Buffer.from(r.body ?? "", "utf8"), { status, headers: r.headers ?? {} }),
        );
      }),
    ),
  );

const result = { access_key_id: AKID, secret_access_key: SECRET, session_token: TOKEN, epoch: EPOCH_MS / 1000 };

result.requests = [];
for (const c of requests) {
  const r = await runAt(API.encodeRequest(opOf(c.op), toInput(c.input)), layersOf(c));
  const entry = { id: c.id, op: snake(c.op), input: inputView(c.input), session_token: c.session_token, cred_region: c.cred_region, endpoint: c.endpoint };
  if (r._tag === "Success") {
    const req = r.success;
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = String(plain(v));
    entry.expected = { ok: true, method: req.method, url: req.url, headers, body: await bodyOf(req.body) };
  } else {
    entry.expected = { ok: false, error: await errorView(r.failure) };
  }
  result.requests.push(entry);
}

result.responses = [];
for (const c of responses) {
  const sent = [];
  const r = await runAt(opOf(c.op)(toInput(c.input)), Layer.mergeAll(layersOf(c), stub([c.response], sent)));
  const entry = { id: c.id, op: snake(c.op), input: inputView(c.input), response: c.response };
  entry.expected =
    r._tag === "Success"
      ? { ok: true, value: (await view(r.success)) ?? null }
      : { ok: false, error: await errorView(r.failure) };
  result.responses.push(entry);
}

result.flows = [];
for (const c of flows) {
  const sent = [];
  const pages = [];
  const program = Stream.runForEach(opOf(c.op).pages(toInput(c.input)), (p) =>
    Effect.promise(async () => {
      pages.push(await view(p));
    }),
  );
  const r = await runAt(program, Layer.mergeAll(layersOf(c), stub(c.responses, sent)));
  result.flows.push({
    id: c.id,
    op: snake(c.op),
    input: inputView(c.input),
    responses: c.responses,
    expected: {
      sent,
      pages,
      error: r._tag === "Success" ? null : await errorView(r.failure),
    },
  });
}

const lua = (v, indent = "") => {
  if (v === undefined || v === null) return "nil";
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (typeof v === "string") {
    let s = '"';
    for (const b of Buffer.from(v, "utf8")) {
      if (b === 0x22) s += '\\"';
      else if (b === 0x5c) s += "\\\\";
      else if (b >= 0x20 && b < 0x7f) s += String.fromCharCode(b);
      else s += "\\" + String(b).padStart(3, "0");
    }
    return s + '"';
  }
  const inner = indent + "  ";
  if (Array.isArray(v)) {
    if (!v.length) return "{ n = 0 }";
    return `{\n${v.map((x) => `${inner}${lua(x, inner)},`).join("\n")}\n${indent}}`;
  }
  const keys = Object.keys(v).sort();
  const parts = keys.filter((k) => v[k] !== undefined).map((k) => `${inner}[${lua(k)}] = ${lua(v[k], inner)},`);
  return parts.length ? `{\n${parts.join("\n")}\n${indent}}` : "{}";
};

writeFileSync(
  out,
  "-- Generated by verify/lib/s3_conform.mjs from Distilled's packages/s3. Do not edit.\n" +
    "-- Arrays are Lua lists (an empty one is `{ n = 0 }`), dates `{ $date = seconds }`,\n" +
    "-- bytes and streams `{ $text = ... }`.\nreturn " +
    lua(result) +
    "\n",
);
console.log(
  `wrote ${out}: ${result.requests.length} requests, ${result.responses.length} responses, ${result.flows.length} flows`,
);
