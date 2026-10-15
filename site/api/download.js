// /download: count the download, then hand over the current DMG.
const { redis, day, isBot } = require("./_store");

const VERSION = "0.1.2";
const FILE = `/download/CommonPlace-${VERSION}.dmg`;

module.exports = async (req, res) => {
  if (req.method === "GET" && !isBot(req.headers["user-agent"])) {
    // Counting never stands between a person and the file.
    await redis([
      ["INCR", "cp:dl:total"],
      ["INCR", `cp:dl:${day()}`],
      ["HINCRBY", "cp:dl:versions", VERSION, 1],
    ]).catch(() => {});
  }
  res.statusCode = 302;
  res.setHeader("Location", FILE);
  res.setHeader("Cache-Control", "no-store");
  res.end();
};
