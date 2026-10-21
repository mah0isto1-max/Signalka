// Guard site: receives radar data from ComputerCraft, shows it live.
// No dependencies. Env: KEY (secret, required), PORT (set by host).
const http = require("http");
const fs = require("fs");
const path = require("path");

const KEY = process.env.KEY || "change-me";
const PORT = process.env.PORT || 3000;
const MAP_ORIGIN = process.env.MAP_ORIGIN || "http://mc.vestalis.xyz:25971";
const STALE_MS = 10000;
const TRAIL = 40;

let players = {};      // id -> player
let trails = {};       // id -> [{x,z}]
let lastUpdate = 0;
const clients = new Set();

function snapshot() {
  const now = Date.now();
  return {
    updated: lastUpdate,
    online: lastUpdate > 0 && now - lastUpdate < STALE_MS,
    players: Object.values(players).map((p) => ({ ...p, trail: trails[p.id] || [] })),
  };
}

function broadcast() {
  const msg = "data: " + JSON.stringify(snapshot()) + "\n\n";
  for (const res of clients) res.write(msg);
}

function readBody(req, cb) {
  let data = "";
  req.on("data", (c) => {
    data += c;
    if (data.length > 200000) req.destroy();
  });
  req.on("end", () => cb(data));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");

  if (req.method === "POST" && url.pathname === "/api/update") {
    if (url.searchParams.get("key") !== KEY) {
      res.writeHead(403);
      return res.end("bad key");
    }
    return readBody(req, (body) => {
      let list;
      try {
        list = JSON.parse(body).players;
      } catch (e) {
        res.writeHead(400);
        return res.end("bad json");
      }
      // old CC versions send {} instead of [] when the radar sees nobody
      if (list == null || (typeof list === "object" && !Array.isArray(list) && !Object.keys(list).length)) list = [];
      if (!Array.isArray(list)) {
        res.writeHead(400);
        return res.end("bad data");
      }
      const next = {};
      for (const p of list) {
        if (!p || typeof p.id !== "string") continue;
        next[p.id] = {
          id: p.id,
          name: typeof p.name === "string" ? p.name : "",
          friend: !!p.friend,
          x: +p.x || 0,
          y: +p.y || 0,
          z: +p.z || 0,
        };
        const t = (trails[p.id] = trails[p.id] || []);
        const last = t[t.length - 1];
        if (!last || last.x !== next[p.id].x || last.z !== next[p.id].z) {
          t.push({ x: next[p.id].x, z: next[p.id].z });
          if (t.length > TRAIL) t.shift();
        }
      }
      for (const id of Object.keys(trails)) if (!next[id]) delete trails[id];
      players = next;
      lastUpdate = Date.now();
      broadcast();
      res.writeHead(200);
      res.end("ok");
    });
  }

  if (url.pathname === "/api/state") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify(snapshot()));
  }

  if (url.pathname === "/api/stream") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    res.write("data: " + JSON.stringify(snapshot()) + "\n\n");
    clients.add(res);
    req.on("close", () => clients.delete(res));
    return;
  }

  // map proxy: /map/... -> MAP_ORIGIN/... (lets an http map load inside an https page)
  if (url.pathname === "/map") {
    res.writeHead(301, { Location: "/map/" });
    return res.end();
  }
  if (url.pathname.startsWith("/map/")) {
    const target = new URL(MAP_ORIGIN);
    const headers = {};
    for (const h of ["accept", "accept-encoding", "accept-language", "range", "if-none-match", "if-modified-since"]) {
      if (req.headers[h]) headers[h] = req.headers[h];
    }
    headers.host = target.host;
    const upstream = http.request(
      {
        hostname: target.hostname,
        port: target.port || 80,
        path: url.pathname.slice(4) + url.search,
        method: "GET",
        headers,
        timeout: 20000,
      },
      (up) => {
        const out = { ...up.headers };
        for (const h of ["connection", "transfer-encoding", "x-frame-options", "content-security-policy", "set-cookie"]) delete out[h];
        res.writeHead(up.statusCode, out);
        up.pipe(res);
      }
    );
    upstream.on("timeout", () => upstream.destroy());
    upstream.on("error", () => {
      if (!res.headersSent) res.writeHead(502);
      res.end("map unavailable");
    });
    return upstream.end();
  }

  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return fs.createReadStream(path.join(__dirname, "index.html")).pipe(res);
  }

  res.writeHead(404);
  res.end("not found");
});

// keep SSE connections alive and mark the feed offline when the computer stops
setInterval(() => {
  for (const res of clients) res.write(": ping\n\n");
  if (lastUpdate && Date.now() - lastUpdate > STALE_MS && Object.keys(players).length) {
    players = {};
    trails = {};
    broadcast();
  }
}, 5000);

server.listen(PORT, () => console.log("Guard site on port " + PORT));
