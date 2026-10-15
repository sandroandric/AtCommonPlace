// /api/stats: the counts, for the private stats page.  Needs the STATS_TOKEN.
const crypto = require("crypto");
const { redis, day, month } = require("./_store");

const same = (a, b) => {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};
const pairs = (flat) => {
  const out = {};
  for (let i = 0; i + 1 < (flat || []).length; i += 2) out[flat[i]] = Number(flat[i + 1]);
  return out;
};

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Robots-Tag", "noindex");
  const token = (req.headers.authorization || "").replace(/^Bearer /, "");
  const expected = (process.env.STATS_TOKEN || "").trim();
  if (!expected || !token || !same(token, expected)) {
    res.statusCode = 401;
    return res.end();
  }
  const days = [];
  for (let i = 29; i >= 0; i--) days.push(day(new Date(Date.now() - i * 86400000)));
  try {
    const perDay = await redis(days.flatMap((d) => [
      ["GET", `cp:dl:${d}`], ["GET", `cp:pv:${d}`], ["PFCOUNT", `cp:dau:${d}`], ["GET", `cp:kept:${d}`],
    ]), 4000);
    const [downloads, installs, mau, kept, versions, verLatest] = await redis([
      ["GET", "cp:dl:total"], ["PFCOUNT", "cp:installs"], ["PFCOUNT", `cp:mau:${month()}`],
      ["GET", "cp:kept:total"], ["HGETALL", "cp:dl:versions"], ["HGETALL", `cp:ver:${day()}`],
    ], 4000);
    const refs = {};
    const refDays = await redis(days.map((d) => ["HGETALL", `cp:ref:${d}`]), 4000);
    for (const flat of refDays) for (const [host, n] of Object.entries(pairs(flat))) refs[host] = (refs[host] || 0) + n;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({
      totals: { downloads: Number(downloads || 0), installs: Number(installs || 0), monthlyActive: Number(mau || 0), kept: Number(kept || 0) },
      days: days.map((d, i) => ({
        day: d,
        downloads: Number(perDay[i * 4] || 0),
        views: Number(perDay[i * 4 + 1] || 0),
        active: Number(perDay[i * 4 + 2] || 0),
        kept: Number(perDay[i * 4 + 3] || 0),
      })),
      referrers: Object.entries(refs).sort((a, b) => b[1] - a[1]).slice(0, 12),
      downloadsByVersion: pairs(versions),
      appVersionsToday: pairs(verLatest),
    }));
  } catch {
    res.statusCode = 503;
    res.end();
  }
};
