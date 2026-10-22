// Guard site: receives radar data from ComputerCraft, shows it live.
// No dependencies. Env: KEY (secret, required), PORT (set by host).
const http = require("http");
const fs = require("fs");
const path = require("path");

const KEY = process.env.KEY || "change-me";
const PORT = process.env.PORT || 3000;
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

const MAP_ORIGIN = new URL(process.env.MAP_ORIGIN || "http://mc.vestalis.xyz:25971");

// Reverse proxy: serves the map from our own https origin so the page can
// move the camera inside the iframe without reloading it.
function proxyMap(req, res, upPath) {
  const headers = { ...req.headers, host: MAP_ORIGIN.host };
  delete headers.referer;
  delete headers.origin;
  const up = http.request(
    { host: MAP_ORIGIN.hostname, port: MAP_ORIGIN.port || 80, method: req.method, path: upPath, headers },
    (ur) => {
      const h = { ...ur.headers };
      delete h["x-frame-options"];
      delete h["content-security-policy"];
      if (h.location) {
        try {
          const l = new URL(h.location, MAP_ORIGIN);
          if (l.host === MAP_ORIGIN.host) h.location = "/map" + l.pathname + l.search + l.hash;
        } catch (e) {}
      }
      res.writeHead(ur.statusCode, h);
      ur.pipe(res);
    }
  );
  up.setTimeout(30000, () => up.destroy(new Error("timeout")));
  up.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Карта недоступна");
  });
  req.pipe(up);
}


// ---- live markers: merge our players into BlueMap's markers.json ----
function esc(t) {
  return String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function guardMarkerSet() {
  const markers = {};
  for (const p of Object.values(players)) {
    const c = p.friend ? { r: 95, g: 197, b: 138 } : { r: 255, g: 107, b: 85 };
    const label = p.friend ? p.name || "Друг" : "Чужой " + p.id.slice(0, 4);
    markers["beam-" + p.id] = {
      type: "line", position: { x: p.x, y: p.y, z: p.z }, label,
      line: [{ x: p.x, y: p.y, z: p.z }, { x: p.x, y: p.y + 40, z: p.z }],
      lineWidth: 5, lineColor: { ...c, a: 1 }, depthTest: false, listed: false, sorting: 0,
    };
    markers["tag-" + p.id] = {
      type: "html", position: { x: p.x, y: p.y + 42, z: p.z }, anchor: { x: 0, y: 0 }, label,
      html: '<div style="padding:2px 8px;border-radius:6px;font:600 13px sans-serif;color:#fff;background:rgb(' +
        c.r + "," + c.g + "," + c.b + ');white-space:nowrap">' + esc(label) + "</div>",
      listed: false, sorting: 0,
    };
  }
  return { label: "Радар базы", toggleable: true, defaultHidden: false, sorting: 0, markers };
}
function serveMarkers(req, res, upPath) {
  const done = (base) => {
    base["guard-radar"] = guardMarkerSet();
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(JSON.stringify(base));
  };
  const headers = { ...req.headers, host: MAP_ORIGIN.host, "accept-encoding": "identity" };
  delete headers.referer; delete headers.origin;
  const up = http.request(
    { host: MAP_ORIGIN.hostname, port: MAP_ORIGIN.port || 80, method: "GET", path: upPath, headers },
    (ur) => {
      let buf = "";
      ur.setEncoding("utf8");
      ur.on("data", (c) => (buf += c));
      ur.on("end", () => {
        let base = {};
        try { if (ur.statusCode === 200) base = JSON.parse(buf) || {}; } catch (e) {}
        done(base);
      });
    }
  );
  up.setTimeout(10000, () => up.destroy());
  up.on("error", () => done({}));
  up.end();
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");

  if (url.pathname === "/map") {
    res.writeHead(302, { Location: "/map/" + url.search });
    return res.end();
  }
  if (url.pathname.startsWith("/map/")) {
    const up = url.pathname.slice(4) + url.search;
    if (/^\/maps\/[^/]+\/live\/markers\.json$/.test(url.pathname.slice(4))) return serveMarkers(req, res, up);
    return proxyMap(req, res, up);
  }

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

  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return fs.createReadStream(path.join(__dirname, "index.html")).pipe(res);
  }

  // map pages sometimes request absolute paths (/assets/...): send those to the map too
  if ((req.headers.referer || "").includes("/map/")) {
    return proxyMap(req, res, url.pathname + url.search);
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
