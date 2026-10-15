// /api/checkin: the app's daily check-in.  A random install ID, the app and
// macOS versions, and how many things were kept since the last check-in (a
// number).  The ID only feeds HyperLogLogs, which count uniques and cannot
// be read back.
const { redis, day, month, body } = require("./_store");

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const VERSION = /^\d{1,3}\.\d{1,3}(\.\d{1,3})?$/;

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") { res.statusCode = 405; return res.end(); }
  const data = await body(req);
  const id = String(data?.id || "").toLowerCase();
  const version = String(data?.version || "");
  const os = String(data?.os || "");
  const kept = Number.isInteger(data?.kept) ? Math.min(Math.max(data.kept, 0), 10000) : NaN;
  if (!ID.test(id) || !VERSION.test(version) || !VERSION.test(os) || Number.isNaN(kept)) {
    res.statusCode = 400;
    return res.end();
  }
  try {
    const [newToday] = await redis([
      ["PFADD", `cp:dau:${day()}`, id],
      ["PFADD", `cp:mau:${month()}`, id],
      ["PFADD", "cp:installs", id],
      ["INCRBY", `cp:kept:${day()}`, kept],
      ["INCRBY", "cp:kept:total", kept],
    ]);
    // Versions are counted once per Mac per day (a retry does not count twice).
    if (newToday === 1) {
      await redis([
        ["HINCRBY", `cp:ver:${day()}`, version, 1],
        ["HINCRBY", `cp:os:${day()}`, os, 1],
      ]);
    }
    res.statusCode = 204;
  } catch {
    res.statusCode = 503;
  }
  res.end();
};
