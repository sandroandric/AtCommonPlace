// /api/hit: one page view, and the host it came from (no cookies, no IPs).
const { redis, day, isBot, body } = require("./_store");

module.exports = async (req, res) => {
  if (req.method === "POST" && !isBot(req.headers["user-agent"])) {
    const data = (await body(req)) || {};
    const commands = [["INCR", `cp:pv:${day()}`]];
    let host = "";
    try { host = data.ref ? new URL(String(data.ref)).hostname.replace(/^www\./, "") : ""; } catch {}
    if (host && host !== "atcommonplace.com" && host.length <= 80 && /^[a-z0-9.-]+$/i.test(host)) {
      commands.push(["HINCRBY", `cp:ref:${day()}`, host.toLowerCase(), 1]);
    }
    await redis(commands).catch(() => {});
  }
  res.statusCode = 204;
  res.setHeader("Cache-Control", "no-store");
  res.end();
};
