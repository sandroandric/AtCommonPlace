// The counters' store: Upstash Redis over its REST API (no dependencies).
// Vercel's Upstash integration sets KV_REST_API_URL / KV_REST_API_TOKEN;
// the UPSTASH_* names are accepted too.  Nothing personal is stored: counts,
// HyperLogLogs of random install IDs (they give unique counts and cannot be
// read back as IDs), and referrer hosts.  No IP addresses, no cookies.

const URL_ = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

/** Run commands in one round trip; resolves to their results.  Gives up after `ms`. */
async function redis(commands, ms = 1500) {
  if (!URL_ || !TOKEN) throw new Error("store not configured");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    const response = await fetch(`${URL_}/pipeline`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify(commands.map((c) => c.map(String))),
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`store answered ${response.status}`);
    return (await response.json()).map((r) => r.result);
  } finally {
    clearTimeout(timer);
  }
}

/** The UTC day, "2026-10-16", and month, "2026-10". */
const day = (date = new Date()) => date.toISOString().slice(0, 10);
const month = (date = new Date()) => date.toISOString().slice(0, 7);

/** Crawlers, link previews and command-line fetches are not people. */
const isBot = (ua = "") => /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|curl|wget|python-requests|httpclient|headless/i.test(ua);

/** A JSON body, null when absent or unreadable.  Vercel parses JSON bodies
 *  itself, gives text bodies (sendBeacon) as a string or Buffer, and null
 *  when there is none; a plain Node request is read from its stream. */
async function body(req) {
  let raw = req.body;
  if (raw === undefined && req[Symbol.asyncIterator]) {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    raw = Buffer.concat(chunks);
  }
  if (raw == null) return null;
  if (Buffer.isBuffer(raw)) raw = raw.toString("utf8");
  if (typeof raw === "object") return raw;
  try { return JSON.parse(raw || "null"); } catch { return null; }
}

module.exports = { redis, day, month, isBot, body };
