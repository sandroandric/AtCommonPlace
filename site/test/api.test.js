// The counting endpoints against an in-memory Upstash (its REST pipeline).
// Run: node --test site/test
const test = require("node:test");
const assert = require("node:assert");
const http = require("node:http");

const db = new Map();
const run = ([cmd, key, ...args]) => {
  switch (cmd) {
    case "INCR": db.set(key, String(Number(db.get(key) || 0) + 1)); return Number(db.get(key));
    case "INCRBY": db.set(key, String(Number(db.get(key) || 0) + Number(args[0]))); return Number(db.get(key));
    case "GET": return db.get(key) ?? null;
    case "HINCRBY": { const h = db.get(key) || {}; h[args[0]] = (h[args[0]] || 0) + Number(args[1]); db.set(key, h); return h[args[0]]; }
    case "HGETALL": return Object.entries(db.get(key) || {}).flat().map(String);
    case "PFADD": { const s = db.get(key) || new Set(); const before = s.size; args.forEach((a) => s.add(a)); db.set(key, s); return s.size > before ? 1 : 0; }
    case "PFCOUNT": return (db.get(key) || new Set()).size;
    default: throw new Error(`unexpected ${cmd}`);
  }
};
let server;
test.before(async () => {
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      assert.strictEqual(req.headers.authorization, "Bearer test-token");
      res.end(JSON.stringify(JSON.parse(raw).map((c) => ({ result: run(c) }))));
    });
  });
  await new Promise((r) => server.listen(0, r));
  process.env.KV_REST_API_URL = `http://127.0.0.1:${server.address().port}`;
  process.env.KV_REST_API_TOKEN = "test-token";
  process.env.STATS_TOKEN = "s3cret-stats";
});
test.after(() => server.close());

const call = (handler, { method = "GET", headers = {}, body } = {}) => new Promise((resolve) => {
  const res = { statusCode: 200, headers: {}, setHeader(k, v) { this.headers[k.toLowerCase()] = v; },
                end(data) { resolve({ status: this.statusCode, headers: this.headers, body: data }); } };
  handler({ method, headers, body }, res);
});
const today = new Date().toISOString().slice(0, 10);
const UA = { "user-agent": "Mozilla/5.0 (Macintosh) Safari" };

test("a download is counted and redirected to the DMG", async () => {
  const r = await call(require("../api/download"), { headers: UA });
  assert.strictEqual(r.status, 302);
  assert.match(r.headers.location, /^\/download\/CommonPlace-\d+\.\d+\.\d+\.dmg$/);
  assert.strictEqual(db.get("cp:dl:total"), "1");
  assert.strictEqual(db.get(`cp:dl:${today}`), "1");
});

test("crawlers and HEAD requests are not counted", async () => {
  await call(require("../api/download"), { headers: { "user-agent": "Googlebot/2.1" } });
  await call(require("../api/download"), { method: "HEAD", headers: UA });
  assert.strictEqual(db.get("cp:dl:total"), "1");
});

test("a page view counts, with an outside referrer's host only", async () => {
  const hit = require("../api/hit");
  assert.strictEqual((await call(hit, { method: "POST", headers: UA, body: { ref: "https://news.ycombinator.com/item?id=1" } })).status, 204);
  await call(hit, { method: "POST", headers: UA, body: { ref: "https://atcommonplace.com/" } });
  await call(hit, { method: "POST", headers: UA, body: "not json" });
  assert.strictEqual(db.get(`cp:pv:${today}`), "3");
  assert.deepStrictEqual(db.get(`cp:ref:${today}`), { "news.ycombinator.com": 1 });
});

test("a check-in counts the Mac once a day; malformed ones are refused", async () => {
  const checkin = require("../api/checkin");
  const good = { id: "3f6c2b8e-1d4a-4c9b-9e2f-5a7d8c1b2e3f", version: "0.1.1", os: "15.6", kept: 4 };
  assert.strictEqual((await call(checkin, { method: "POST", body: good })).status, 204);
  assert.strictEqual((await call(checkin, { method: "POST", body: { ...good, kept: 2 } })).status, 204);
  for (const bad of [{ ...good, id: "nope" }, { ...good, kept: 1.5 }, { ...good, version: "x" }, { ...good, os: "<script>" }, null]) {
    assert.strictEqual((await call(checkin, { method: "POST", body: bad })).status, 400);
  }
  assert.strictEqual((await call(checkin, { method: "GET" })).status, 405);
  assert.strictEqual(db.get(`cp:dau:${today}`).size, 1);
  assert.strictEqual(db.get(`cp:kept:${today}`), "6");
  assert.deepStrictEqual(db.get(`cp:ver:${today}`), { "0.1.1": 1 });
});

test("stats need the token, then report the counts", async () => {
  const stats = require("../api/stats");
  assert.strictEqual((await call(stats)).status, 401);
  assert.strictEqual((await call(stats, { headers: { authorization: "Bearer wrong-token!" } })).status, 401);
  const r = await call(stats, { headers: { authorization: "Bearer s3cret-stats" } });
  assert.strictEqual(r.status, 200);
  const data = JSON.parse(r.body);
  assert.deepStrictEqual(data.totals, { downloads: 1, installs: 1, monthlyActive: 1, kept: 6 });
  assert.strictEqual(data.days.length, 30);
  assert.deepStrictEqual(data.days.at(-1), { day: today, downloads: 1, views: 3, active: 1, kept: 6 });
  assert.deepStrictEqual(data.referrers, [["news.ycombinator.com", 1]]);
});

test("without a store, the download still works", async () => {
  delete require.cache[require.resolve("../api/_store")];
  delete require.cache[require.resolve("../api/download")];
  const saved = process.env.KV_REST_API_URL;
  delete process.env.KV_REST_API_URL;
  const r = await call(require("../api/download"), { headers: UA });
  assert.strictEqual(r.status, 302);
  process.env.KV_REST_API_URL = saved;
});
