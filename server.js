// Guard site: receives radar data from ComputerCraft, shows it live.
// No dependencies. Env: KEY (secret, required), PORT (set by host).
const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const KEY = process.env.KEY || "change-me";
const PORT = process.env.PORT || 3000;
const STALE_MS = 10000;
const TRAIL = 120;

let players = {};      // id -> player
let trails = {};       // id -> [{x,z}]
let lastUpdate = 0;
let objects = [];     // non-player contacts (aircraft, contraptions...)
let radar = null;     // {x,y,z,range} sent by the computer
const clients = new Set();

// ---- UUID -> Nickname resolver & cache ----
const UUID_CACHE_FILE = path.join(__dirname, "uuid_cache.json");
let uuidToNick = {};
try {
  if (fs.existsSync(UUID_CACHE_FILE)) {
    uuidToNick = JSON.parse(fs.readFileSync(UUID_CACHE_FILE, "utf8")) || {};
  }
} catch (e) {}

function saveUuidCache() {
  try {
    fs.writeFileSync(UUID_CACHE_FILE, JSON.stringify(uuidToNick, null, 2));
  } catch (e) {}
}

const pendingLookups = new Set();
function resolveUuid(rawId) {
  if (!rawId || typeof rawId !== "string") return;
  const clean = rawId.replace(/-/g, "").toLowerCase();
  if (clean.length !== 32 || !/^[0-9a-f]{32}$/.test(clean)) return;
  if (uuidToNick[rawId] || uuidToNick[clean]) return;
  if (pendingLookups.has(clean)) return;
  pendingLookups.add(clean);

  // Try Mojang sessionserver first
  const req = https.get(`https://sessionserver.mojang.com/session/minecraft/profile/${clean}`, (res) => {
    if (res.statusCode === 200) {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => {
        try {
          const j = JSON.parse(data);
          if (j && j.name) {
            uuidToNick[rawId] = j.name;
            uuidToNick[clean] = j.name;
            saveUuidCache();
            if (players[rawId] && !players[rawId].name) {
              players[rawId].name = j.name;
              broadcast();
            }
          }
        } catch (e) {}
        pendingLookups.delete(clean);
      });
    } else {
      // Fallback to playerdb.co
      const req2 = https.get(`https://playerdb.co/api/player/minecraft/${clean}`, (pr) => {
        let pdata = "";
        pr.on("data", (c) => (pdata += c));
        pr.on("end", () => {
          try {
            const pj = JSON.parse(pdata);
            if (pj && pj.success && pj.data && pj.data.player && pj.data.player.username) {
              const nick = pj.data.player.username;
              uuidToNick[rawId] = nick;
              uuidToNick[clean] = nick;
              saveUuidCache();
              if (players[rawId] && !players[rawId].name) {
                players[rawId].name = nick;
                broadcast();
              }
            }
          } catch (e) {}
          pendingLookups.delete(clean);
        });
      });
      req2.on("error", () => pendingLookups.delete(clean));
      req2.setTimeout(5000, () => req2.destroy());
    }
  });
  req.on("error", () => pendingLookups.delete(clean));
  req.setTimeout(5000, () => req.destroy());
}

// ---- password gate + remote console ----
const crypto = require("crypto");
const PASS = process.env.SITE_PASS || "5555";
const TOKEN = crypto.createHash("sha256").update("signalka|" + PASS + "|" + KEY).digest("hex");
const fails = {};          // ip -> {n, until}
let cmdQueue = [];         // commands waiting for the computer
let cmdSeq = 0;
let consoleLog = [];       // {n, t, kind: "in"|"out", text}
let logSeq = 0;
function logConsole(kind, text) {
  consoleLog.push({ n: ++logSeq, t: Date.now(), kind, text });
  if (consoleLog.length > 300) consoleLog.shift();
}
function isOnline() { return lastUpdate > 0 && Date.now() - lastUpdate < STALE_MS; }
function cookieOf(req, name) {
  const m = (req.headers.cookie || "").split(/;\s*/).find((c) => c.startsWith(name + "="));
  return m ? m.slice(name.length + 1) : "";
}
function authed(req) {
  const c = cookieOf(req, "sig");
  return c.length === TOKEN.length && crypto.timingSafeEqual(Buffer.from(c), Buffer.from(TOKEN));
}
function clientIp(req) {
  return String(req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "?";
}
const HTML_HDR = { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" };
function loginPage(msg) {
  return '<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    "<title>Вход</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#141a17;color:#e4ebe5;font:16px system-ui,sans-serif}" +
    "form{background:#1b2420;border:1px solid #2f3b34;border-radius:10px;padding:24px;width:280px;display:grid;gap:12px}" +
    "h1{margin:0;font-size:18px}input,button{font:inherit;padding:9px 10px;border-radius:6px;border:1px solid #2f3b34;background:#141a17;color:inherit}" +
    "button{background:#1f5f8b;border-color:#1f5f8b;cursor:pointer}.e{color:#ff6b55;font-size:14px;min-height:1em}</style></head><body>" +
    '<form method="POST" action="/login"><h1>Радар базы</h1><input type="password" name="password" placeholder="Пароль" autofocus autocomplete="current-password">' +
    '<div class="e">' + esc(msg) + '</div><button type="submit">Войти</button></form></body></html>';
}
function handleLogin(req, res) {
  if (req.method !== "POST") { res.writeHead(200, HTML_HDR); return res.end(loginPage("")); }
  const ip = clientIp(req);
  const f = fails[ip] || { n: 0, until: 0 };
  if (Date.now() < f.until) { res.writeHead(429, HTML_HDR); return res.end(loginPage("Слишком много попыток. Подождите 5 минут.")); }
  readBody(req, (body) => {
    const pw = new URLSearchParams(body).get("password") || "";
    const a = crypto.createHash("sha256").update(pw).digest();
    const b = crypto.createHash("sha256").update(PASS).digest();
    if (crypto.timingSafeEqual(a, b)) {
      delete fails[ip];
      const secure = req.headers["x-forwarded-proto"] === "https" ? "; Secure" : "";
      res.writeHead(302, { "Set-Cookie": "sig=" + TOKEN + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000" + secure, Location: "/" });
      return res.end();
    }
    f.n++;
    if (f.n >= 5) { f.until = Date.now() + 300000; f.n = 0; }
    fails[ip] = f;
    res.writeHead(401, HTML_HDR);
    res.end(loginPage("Неверный пароль"));
  });
}

function cleanObjects(list) {
  if (!Array.isArray(list)) return [];
  return list.slice(0, 60).map((o) => ({
    id: String((o && o.id) || "").slice(0, 64),
    cat: String((o && o.cat) || "").slice(0, 32),
    name: String((o && o.name) || "").slice(0, 48),
    x: +(o && o.x) || 0, y: +(o && o.y) || 0, z: +(o && o.z) || 0,
    vx: +(o && o.vx) || 0, vy: +(o && o.vy) || 0, vz: +(o && o.vz) || 0,
    w: +(o && o.w) || 0, h: +(o && o.h) || 0, l: +(o && o.l) || 0,
    info: String((o && o.info) || "").slice(0, 200),
  })).filter((o) => o.id);
}

function snapshot() {
  const now = Date.now();
  return {
    updated: lastUpdate,
    online: lastUpdate > 0 && now - lastUpdate < STALE_MS,
    radar,
    objects,
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

const seenPaths = {}; // path -> {status, n, last}
function noteMapPath(p, status) {
  const k = p.split("?")[0];
  if (/\/tiles\//.test(k)) return;
  const e = (seenPaths[k] = seenPaths[k] || { n: 0 });
  e.n++; e.status = status; e.last = new Date().toISOString();
}

// Reverse proxy: serves the map from our own https origin so the page can
// move the camera inside the iframe without reloading it.
function proxyMap(req, res, upPath) {
  const headers = { ...req.headers, host: MAP_ORIGIN.host };
  delete headers.referer;
  delete headers.origin;
  delete headers.cookie;
  const up = http.request(
    { host: MAP_ORIGIN.hostname, port: MAP_ORIGIN.port || 80, method: req.method, path: upPath, headers },
    (ur) => {
      noteMapPath(upPath, ur.statusCode);
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
const BANDIT_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8" shape-rendering="crispEdges">' +
  '<rect width="8" height="8" fill="#c4906b"/><rect width="8" height="2" fill="#3a2a1f"/>' +
  '<rect y="2" width="1" height="1" fill="#3a2a1f"/><rect x="7" y="2" width="1" height="1" fill="#3a2a1f"/>' +
  '<rect y="3" width="8" height="2" fill="#1c1c1c"/>' +
  '<rect x="1" y="4" width="2" height="1" fill="#fff"/><rect x="2" y="4" width="1" height="1" fill="#c4321f"/>' +
  '<rect x="5" y="4" width="2" height="1" fill="#fff"/><rect x="5" y="4" width="1" height="1" fill="#c4321f"/>' +
  '<rect x="3" y="5" width="2" height="1" fill="#a36f50"/><rect x="2" y="6" width="4" height="1" fill="#6d3b2c"/></svg>';
const BANDIT_URI = "data:image/svg+xml," + encodeURIComponent(BANDIT_SVG);

function guardMarkerSet() {
  const markers = {};
  for (const p of Object.values(players)) {
    const color = p.friend ? "#5fc58a" : "#ff6b55";
    const label = p.friend ? (p.name || "Друг") : (p.name ? `${p.name} (чужой)` : "Чужой " + p.id.slice(0, 4));
    const img = p.name
      ? "https://minotar.net/helm/" + encodeURIComponent(p.name) + "/32.png"
      : BANDIT_URI;
    markers["p-" + p.id] = {
      type: "html", position: { x: p.x, y: p.y + 2, z: p.z }, anchor: { x: 17, y: 17 }, label,
      html: '<div title="' + esc(label) + '" style="width:34px;height:34px;box-sizing:border-box;border:3px solid ' +
        color + ';background:#111;box-shadow:0 0 6px #000"><img src="' + img +
        '" style="width:100%;height:100%;display:block;image-rendering:pixelated"></div>',
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
  delete headers.referer; delete headers.origin; delete headers.cookie;
  delete headers["if-none-match"]; delete headers["if-modified-since"];
  const up = http.request(
    { host: MAP_ORIGIN.hostname, port: MAP_ORIGIN.port || 80, method: "GET", path: upPath, headers },
    (ur) => {
      noteMapPath(upPath + " [merged]", ur.statusCode);
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

  if (url.pathname === "/login") return handleLogin(req, res);
  // the computer (key in the URL) and the key-protected debug pages stay reachable without the site password
  const open = (req.method === "POST" && url.pathname === "/api/update") || url.pathname === "/api/debug" || url.pathname === "/api/mapcheck";
  if (!open && !authed(req)) {
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
      res.writeHead(200, HTML_HDR);
      return res.end(loginPage(""));
    }
    res.writeHead(401, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end("login required");
  }

  if (url.pathname === "/map") {
    res.writeHead(302, { Location: "/map/" + url.search });
    return res.end();
  }
  if (url.pathname.startsWith("/map/")) {
    const up = url.pathname.slice(4) + url.search;
    if (/^\/maps\/[^/]+\/(live\/)?markers?\.json$/.test(url.pathname.slice(4))) return serveMarkers(req, res, up);
    return proxyMap(req, res, up);
  }

  if (req.method === "POST" && url.pathname === "/api/update") {
    if (url.searchParams.get("key") !== KEY) {
      res.writeHead(403);
      return res.end("bad key");
    }
    return readBody(req, (body) => {
      let list, results;
      try {
        const parsed = JSON.parse(body);
        list = parsed.players;
        objects = cleanObjects(parsed.objects);
        results = parsed.results;
        const r = parsed.radar;
        radar = r && isFinite(+r.x) && isFinite(+r.z) && +r.range > 0
          ? { x: +r.x, y: +r.y || 0, z: +r.z, range: +r.range } : null;
      } catch (e) {
        res.writeHead(400);
        return res.end("bad json");
      }
      // old CC versions turn an empty table into {} instead of []
      if (list == null || (typeof list === "object" && !Array.isArray(list) && !Object.keys(list).length)) list = [];
      if (!Array.isArray(list)) {
        res.writeHead(400);
        return res.end("bad data");
      }
      const next = {};
      for (const p of list) {
        if (!p || typeof p.id !== "string") continue;
        let nick = typeof p.name === "string" ? p.name : "";
        if (!nick) {
          nick = uuidToNick[p.id] || uuidToNick[p.id.replace(/-/g, "").toLowerCase()] || "";
          if (!nick) resolveUuid(p.id);
        } else {
          uuidToNick[p.id] = nick;
          uuidToNick[p.id.replace(/-/g, "").toLowerCase()] = nick;
        }
        next[p.id] = {
          id: p.id,
          name: nick,
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
      if (Array.isArray(results)) {
        for (const r of results.slice(0, 20)) {
          if (r) logConsole("out", String(r.out == null ? "" : r.out).slice(0, 2000) || "(нет вывода)");
        }
      }
      const cmds = cmdQueue.splice(0, 5);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, cmds }));
    });
  }

  if (url.pathname === "/api/resolve") {
    const rawUuid = url.searchParams.get("uuid") || "";
    const clean = rawUuid.replace(/-/g, "").toLowerCase();
    const name = uuidToNick[rawUuid] || uuidToNick[clean] || null;
    if (name) {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      return res.end(JSON.stringify({ uuid: rawUuid, name }));
    }
    resolveUuid(rawUuid);
    res.writeHead(202, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(JSON.stringify({ uuid: rawUuid, pending: true }));
  }

  if (url.pathname === "/api/debug") {
    if (url.searchParams.get("key") !== KEY) {
      res.writeHead(403);
      return res.end("bad key");
    }
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(JSON.stringify({ players: Object.keys(players).length, mapPaths: seenPaths, markers: guardMarkerSet() }, null, 1));
  }

  // can the site itself reach the map? (open /api/mapcheck?key=KEY)
  if (url.pathname === "/api/mapcheck") {
    if (url.searchParams.get("key") !== KEY) {
      res.writeHead(403);
      return res.end("bad key");
    }
    const probe = (p) => new Promise((resolve) => {
      const t0 = Date.now();
      const r = http.get({ host: MAP_ORIGIN.hostname, port: MAP_ORIGIN.port || 80, path: p, headers: { host: MAP_ORIGIN.host } }, (ur) => {
        let n = 0, head = "";
        ur.on("data", (c) => { n += c.length; if (head.length < 120) head += c.toString("utf8", 0, 120); });
        ur.on("end", () => resolve({ path: p, status: ur.statusCode, ms: Date.now() - t0, type: ur.headers["content-type"], bytes: n, location: ur.headers.location, start: head.slice(0, 120) }));
      });
      r.setTimeout(8000, () => r.destroy(new Error("timeout")));
      r.on("error", (e) => resolve({ path: p, error: String(e.message || e), ms: Date.now() - t0 }));
    });
    return Promise.all(["/", "/settings.json"].map(probe)).then((results) => {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ origin: MAP_ORIGIN.href, results }, null, 1));
    });
  }

  if (url.pathname === "/api/cmd" && req.method === "POST") {
    const json = (code, o) => { res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" }); res.end(JSON.stringify(o)); };
    if (!String(req.headers["content-type"] || "").includes("application/json")) return json(415, { error: "bad type" });
    return readBody(req, (body) => {
      let line = "";
      try { line = String(JSON.parse(body).line || "").trim().slice(0, 300); } catch (e) {}
      if (!line) return json(400, { error: "пустая команда" });
      if (!isOnline()) return json(503, { error: "компьютер не на связи, команда не отправлена" });
      if (cmdQueue.length >= 20) return json(429, { error: "слишком много команд в очереди" });
      cmdQueue.push({ id: ++cmdSeq, line });
      logConsole("in", line);
      json(200, { ok: true });
    });
  }

  if (url.pathname === "/api/console") {
    const since = +url.searchParams.get("since") || 0;
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
    return res.end(JSON.stringify({ n: logSeq, online: isOnline(), entries: consoleLog.filter((e) => e.n > since) }));
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
  if (lastUpdate && Date.now() - lastUpdate > STALE_MS && (Object.keys(players).length || objects.length)) {
    players = {};
    objects = [];
    trails = {};
    broadcast();
  }
}, 5000);

server.listen(PORT, () => console.log("Guard site on port " + PORT));

// Poll BlueMap's players.json to capture offline/cracked and online player nicknames
function pollServerPlayers() {
  const req = http.get({
    host: MAP_ORIGIN.hostname,
    port: MAP_ORIGIN.port || 80,
    path: "/maps/world/live/players.json",
    headers: { host: MAP_ORIGIN.host }
  }, (res) => {
    if (res.statusCode !== 200) return;
    let data = "";
    res.on("data", (c) => (data += c));
    res.on("end", () => {
      try {
        const j = JSON.parse(data);
        if (Array.isArray(j.players)) {
          let updated = false;
          for (const pl of j.players) {
            if (pl.uuid && pl.name) {
              const clean = pl.uuid.replace(/-/g, "").toLowerCase();
              if (uuidToNick[pl.uuid] !== pl.name || uuidToNick[clean] !== pl.name) {
                uuidToNick[pl.uuid] = pl.name;
                uuidToNick[clean] = pl.name;
                updated = true;
              }
              if (players[pl.uuid] && !players[pl.uuid].name) {
                players[pl.uuid].name = pl.name;
                broadcast();
              }
            }
          }
          if (updated) saveUuidCache();
        }
      } catch (e) {}
    });
  });
  req.on("error", () => {});
  req.setTimeout(5000, () => req.destroy());
}
setInterval(pollServerPlayers, 3000);
pollServerPlayers();

