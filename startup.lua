local FILE = "guard_data"
local RECENT = 15
local MAP_URL = "http://mc.vestalis.xyz:25971/#world"
local CAM_DIST = 150
local SEND_EVERY = 0.1
local data = { webhook = "", friends = {}, cooldown = 15, site = "", key = "", radar = nil, objfilter = "auto", objcats = {}, sizes = {} }

-- output goes to the terminal, or into a buffer when a command comes from the website
local capture = nil
local function say(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  local s = table.concat(parts, " ")
  if capture then capture[#capture + 1] = s else print(s) end
end
local function ask(prompt)
  if capture then return nil end
  write(prompt)
  return read()
end
local runRemote   -- defined after runLine
local pendingResults = {}

local function save()
  local f = fs.open(FILE, "w")
  f.write(textutils.serialize(data))
  f.close()
end

if fs.exists(FILE) then
  local f = fs.open(FILE, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then
    data.webhook = d.webhook or ""
    data.friends = d.friends or {}
    data.cooldown = d.cooldown or 15
    data.site = d.site or ""
    data.key = d.key or ""
    data.radar = d.radar
    data.objfilter = d.objfilter or "auto"
    data.sizes = d.sizes or {}
    data.objcats = d.objcats or {}
  end
end

local radar = peripheral.find("create_radar:radar_bearing")
           or peripheral.find("create_radar:monitor")
assert(radar, "Radar not found: place the computer next to the radar")

local seen = {}
local function now() return os.epoch("utc") / 1000 end

local function getAllTracks()
  local ok, tracks = pcall(radar.getTracks)
  if ok and type(tracks) == "table" then return tracks end
  return {}
end

local function getPlayers()
  local res = {}
  for _, t in ipairs(getAllTracks()) do
    if t.category == "PLAYER" then res[#res + 1] = t end
  end
  return res
end

-- approximate size of a contact (blocks); 0 = radar did not say
local function manualSize(t)
  for key, s in pairs(data.sizes) do
    if tostring(t.id):sub(1, #key) == key or tostring(t.name or t.entityType or "") == key then
      return s.w, s.h, s.l
    end
  end
end

local function sizeOf(t)
  local mw, mh, ml = manualSize(t)
  if mw then return mw, mh, ml end
  local w, h, l
  local s = t.size or t.dimensions or t.dims or t.boundingBox or t.bounds
  if type(s) == "number" then
    w, h, l = s, s, s
  elseif type(s) == "table" then
    l = tonumber(s.x or s.length or s.l or s[1])
    h = tonumber(s.y or s.height or s.h or s[2])
    w = tonumber(s.z or s.width or s.w or s[3])
  end
  l = l or tonumber(t.length)
  h = h or tonumber(t.height)
  w = w or tonumber(t.width)
  return w or 0, h or 0, l or 0
end

local SKIP_CATS = { PLAYER = true, ANIMAL = true, MOB = true, ITEM = true, PROJECTILE = true }

-- auto: only contacts that are not ordinary Minecraft entities (= constructions, aircraft...)
local function wantObject(t)
  if t.category == "PLAYER" or data.objfilter == "off" then return false end
  if data.objfilter == "all" then return true end
  if data.objfilter == "only" then
    for _, c in ipairs(data.objcats) do
      if c:upper() == tostring(t.category):upper() then return true end
    end
    return false
  end
  if SKIP_CATS[tostring(t.category)] then return false end
  for _, k in ipairs({ "name", "entityType", "type" }) do
    local v = t[k]
    if type(v) == "string" and (v:find("^entity%.minecraft%.") or v:find("^minecraft:")) then return false end
  end
  return true
end

-- radar range straight from the peripheral (falls back to the saved number)
local function radarRange()
  local ok, r = pcall(radar.getRange)
  r = ok and tonumber(r) or nil
  if r and r > 0 then return r end
  return data.radar and data.radar.range or nil
end

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

-- short "key=value" text of everything the radar says about a contact (shown on the site)
local function infoOf(t)
  local keys = {}
  for k in pairs(t) do
    if k ~= "id" and k ~= "category" and k ~= "position" and k ~= "velocity" then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "number" then
      parts[#parts + 1] = tostring(k) .. "=" .. round2(v)
    elseif type(v) == "string" or type(v) == "boolean" then
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    elseif type(v) == "table" then
      for k2, v2 in pairs(v) do
        if type(v2) == "number" then v2 = round2(v2) end
        if type(v2) ~= "table" then parts[#parts + 1] = tostring(k) .. "." .. tostring(k2) .. "=" .. tostring(v2) end
      end
    end
  end
  return table.concat(parts, " "):sub(1, 200)
end

local uuidNameCache = {}

-- safe http get: catches any error including "closed file" on concurrent access
local function safeGet(url)
  local ok, r = pcall(http.get, url)
  if not ok or not r or type(r.readAll) ~= "function" then return nil end
  local txt
  pcall(function() txt = r.readAll() end)
  pcall(function() r.close() end)
  return txt
end

local pollBusy = false
local function pollBlueMapPlayers()
  if pollBusy then return end
  pollBusy = true
  local txt = safeGet("http://mc.vestalis.xyz:25971/maps/world/live/players.json")
  local j = txt and textutils.unserializeJSON(txt)
  if j and type(j.players) == "table" then
    for _, pl in ipairs(j.players) do
      if pl.uuid and pl.name then
        uuidNameCache[pl.uuid] = pl.name
        uuidNameCache[tostring(pl.uuid):lower():gsub("[^%x]", "")] = pl.name
      end
    end
  end
  pollBusy = false
end

local function resolvePlayerName(uuid)
  if not uuid or uuid == "" then return "" end
  if data.friends[uuid] then return data.friends[uuid] end
  if uuidNameCache[uuid] then return uuidNameCache[uuid] end
  local clean = tostring(uuid):lower():gsub("[^%x]", "")
  if uuidNameCache[clean] then return uuidNameCache[clean] end
  if #clean ~= 32 then return "" end

  -- Try BlueMap live server players (has offline/cracked players!)
  pollBlueMapPlayers()
  if uuidNameCache[uuid] then return uuidNameCache[uuid] end
  if uuidNameCache[clean] then return uuidNameCache[clean] end

  -- 1. Try our own guard site
  if data.site and data.site ~= "" then
    local sUrl = data.site:gsub("/+$", "") .. "/api/resolve?uuid=" .. textutils.urlEncode(uuid)
    local txt = safeGet(sUrl)
    local j = txt and textutils.unserializeJSON(txt)
    if j and j.name then uuidNameCache[uuid] = j.name return j.name end
  end

  -- 2. Try PlayerDB
  local txt2 = safeGet("https://playerdb.co/api/player/minecraft/" .. clean)
  local j2 = txt2 and textutils.unserializeJSON(txt2)
  if j2 and j2.success and j2.data and j2.data.player and j2.data.player.username then
    local n = j2.data.player.username
    uuidNameCache[uuid] = n
    return n
  end

  -- 3. Try Mojang sessionserver
  local txt3 = safeGet("https://sessionserver.mojang.com/session/minecraft/profile/" .. clean)
  local j3 = txt3 and textutils.unserializeJSON(txt3)
  if j3 and j3.name then
    uuidNameCache[uuid] = j3.name
    return j3.name
  end

  return ""
end

local function distFromRadar(pos)
  if not data.radar or not pos then return nil end
  return math.floor(math.sqrt((pos.x - data.radar.x)^2 + (pos.y - data.radar.y)^2 + (pos.z - data.radar.z)^2) + 0.5)
end

local function sendDiscord(text)
  if data.webhook == "" then
    say("Webhook not set")
    return false
  end
  local body = textutils.serializeJSON({ content = text })
  local ok, err = http.post(data.webhook, body, { ["Content-Type"] = "application/json" })
  if ok then ok.close() return true end
  say("Webhook error: " .. tostring(err))
  return false
end

local function sendDiscordAlert(nick, uuid, pos, mapUrl, siteUrl)
  if data.webhook == "" then
    say("Webhook not set")
    return false
  end
  local d = distFromRadar(pos)
  local distTxt = d and (tostring(d) .. " blocks") or "unknown"
  local hasNick = nick and nick ~= "" and nick ~= uuid

  -- try to get nick from uuidNameCache one more time (may have been resolved since alert queued)
  if not hasNick then
    local cached = uuidNameCache[uuid]
                or uuidNameCache[tostring(uuid):lower():gsub("[^%x]","")]
    if cached and cached ~= "" then nick = cached; hasNick = true end
  end

  local displayNick = hasNick and nick or ("UUID:" .. uuid:sub(1,8))
  local title = hasNick and ("[!] INTRUDER: " .. nick) or "[!] UNKNOWN PLAYER"
  local avatar = hasNick and ("https://minotar.net/helm/" .. textutils.urlEncode(nick) .. "/64.png") or nil

  local fields = {
    { name = "Nick", value = "**" .. displayNick .. "**", inline = true },
    { name = "Distance", value = distTxt, inline = true },
    { name = "Coords", value = ("X:`%d` Y:`%d` Z:`%d`"):format(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)), inline = false },
    { name = "UUID", value = "`" .. uuid .. "`", inline = false }
  }
  if mapUrl and mapUrl ~= "" then
    fields[#fields + 1] = { name = "3D Map", value = "[Open](" .. mapUrl .. ")", inline = true }
  end
  if siteUrl and siteUrl ~= "" then
    fields[#fields + 1] = { name = "Radar", value = "[Open](" .. siteUrl .. ")", inline = true }
  end

  local embed = { title = title, color = 16730965, fields = fields }
  if avatar then embed.thumbnail = { url = avatar } end

  local payload = {
    content = "@here **[!] INTRUDER in radar zone!**",
    embeds = { embed }
  }
  local body = textutils.serializeJSON(payload)
  local ok, err = http.post(data.webhook, body, { ["Content-Type"] = "application/json" })
  if ok then ok.close() return true end

  -- Fallback plain text
  local plain = ("@here [!] %s\nNick: %s | Dist: %s\nX:%d Y:%d Z:%d\nUUID: %s"):format(
    title, displayNick, distTxt, math.floor(pos.x), math.floor(pos.y), math.floor(pos.z), uuid)
  if mapUrl and mapUrl ~= "" then plain = plain .. "\nMap: <" .. mapUrl .. ">" end
  if siteUrl and siteUrl ~= "" then plain = plain .. "\nSite: <" .. siteUrl .. ">" end
  return sendDiscord(plain)
end

local function mapLink(p)
  return ("%s:%d:%d:%d:%d:0:0:0:0:perspective"):format(
    MAP_URL, math.floor(p.x), math.floor(p.y), math.floor(p.z), CAM_DIST)
end

-- push radar data to the website
local function pushSite()
  if data.site == "" or data.key == "" then return false end
  local list, objs = {}, {}
  for _, t in ipairs(getAllTracks()) do
    local p = t.position or {}
    if t.category == "PLAYER" then
      local pName = data.friends[t.id]
      if not pName or pName == "" then
        pName = (type(t.name) == "string" and t.name ~= "" and t.name)
             or (type(t.username) == "string" and t.username ~= "" and t.username)
             or (type(t.displayName) == "string" and t.displayName ~= "" and t.displayName)
             or (type(t.player) == "string" and t.player ~= "" and t.player)
             or uuidNameCache[t.id]
             or uuidNameCache[tostring(t.id):lower():gsub("[^%x]", "")]
             or ""
      end
      list[#list + 1] = {
        id = t.id,
        name = pName,
        friend = data.friends[t.id] ~= nil,
        x = p.x, y = p.y, z = p.z,
      }
    elseif wantObject(t) and #objs < 40 then
      local v = t.velocity or {}
      local w, h, l = sizeOf(t)
      objs[#objs + 1] = {
        id = tostring(t.id), cat = tostring(t.category),
        name = tostring(t.name or t.entityType or t.type or t.category),
        x = p.x, y = p.y, z = p.z,
        vx = v.x, vy = v.y, vz = v.z,
        w = w, h = h, l = l,
        info = infoOf(t),
      }
    end
  end
  if data.site == "" then return false, "site URL not set (type: site https://...)" end
  if data.key == "" then return false, "secret key not set (type: key <secret>)" end
  local url = data.site:gsub("/+$", "") .. "/api/update?key=" .. textutils.urlEncode(data.key)
  local rd = nil
  if data.radar then
    rd = { x = data.radar.x, y = data.radar.y, z = data.radar.z, range = radarRange() or 0 }
  end
  local body = textutils.serializeJSON({ players = list, objects = objs, radar = rd, guns = getGunsList(), results = pendingResults })
  local ok, err = http.post(url, body, { ["Content-Type"] = "application/json" })
  if ok then
    local text = nil
    pcall(function() text = ok.readAll() end)
    pcall(function() ok.close() end)
    pendingResults = {}
    local j = text and textutils.unserializeJSON(text)
    if j and type(j.names) == "table" then
      for uid, nm in pairs(j.names) do
        if type(nm) == "string" and nm ~= "" then
          uuidNameCache[uid] = nm
          uuidNameCache[tostring(uid):lower():gsub("[^%x]", "")] = nm
        end
      end
    end
    return true, nil, type(j) == "table" and j.cmds or nil
  end
  return false, err
end

local function siteLoop()
  local lastErr = nil
  while true do
    local pOk, ok, err, cmds = pcall(pushSite)
    if not pOk then
      ok = false
      err = tostring(ok)
    end
    if ok == false then
      local errStr = tostring(err or "unknown")
      if errStr:find("403") then
        errStr = "403 Forbidden - BAD KEY! Check KEY on Render (type: key <secret>)"
      end
      if errStr ~= lastErr then
        say("Site: " .. errStr)
        lastErr = errStr
      end
      sleep(3)
    elseif ok then
      if lastErr ~= "ok" then
        say("Site: CONNECTED!")
        lastErr = "ok"
      end
      if cmds and #cmds > 0 then
        for _, c in ipairs(cmds) do
          pendingResults[#pendingResults + 1] = { id = c.id, out = runRemote(tostring(c.line or "")) }
        end
      else
        sleep(SEND_EVERY)
      end
    end
  end
end

local lastAlert = {}
local function guardLoop()
  while true do
    for _, t in ipairs(getPlayers()) do
      seen[t.id] = { t = t, time = now() }
      if not data.friends[t.id] then
        if not lastAlert[t.id] or now() - lastAlert[t.id] > data.cooldown then
          lastAlert[t.id] = now()
          -- try all sources for the nick before sending alert
          local pName = (type(t.name) == "string" and t.name ~= "" and t.name)
                     or (type(t.username) == "string" and t.username ~= "" and t.username)
                     or (type(t.displayName) == "string" and t.displayName ~= "" and t.displayName)
                     or uuidNameCache[t.id]
                     or uuidNameCache[tostring(t.id):lower():gsub("[^%x]","")]
          -- force a fresh BlueMap poll to catch offline/cracked players
          if not pName or pName == "" then
            pollBusy = false  -- reset busy flag so poll runs
            pollBlueMapPlayers()
            pName = uuidNameCache[t.id]
                 or uuidNameCache[tostring(t.id):lower():gsub("[^%x]","")]
          end
          if not pName or pName == "" then pName = resolvePlayerName(t.id) end
          sendDiscordAlert(pName, t.id, t.position, mapLink(t.position), data.site ~= "" and data.site or nil)
        end
      end
    end
    sleep(0.5)
  end
end

local function cmdAdd(arg)
  local list = {}
  for id, s in pairs(seen) do
    if now() - s.time <= RECENT and not data.friends[id] then
      list[#list + 1] = s.t
    end
  end
  if #list == 0 then
    say("No new players seen in last " .. RECENT .. "s")
    return
  end
  local n = 1
  if #list > 1 then
    for i, t in ipairs(list) do
      say(("%d) x=%d z=%d  %s"):format(i, t.position.x, t.position.z, t.id:sub(1, 8)))
    end
    n = tonumber(ask("Number: "))
    if not n or not list[n] then say("Cancelled") return end
  end
  local nick = arg
  if not nick or nick == "" then
    nick = ask("Nick: ") or ""
  end
  if nick == "" then say("Cancelled") return end
  data.friends[list[n].id] = nick
  save()
  say("Added: " .. nick)
end

-- MD5 (needs bit32, available in CC: Tweaked) and Minecraft offline UUID
local function md5(msg)
  local band, bor, bxor, bnot, lrot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.lrotate
  local MOD = 4294967296
  local s = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  }
  local K = {}
  for i = 0, 63 do K[i] = math.floor(math.abs(math.sin(i + 1)) * MOD) end

  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  for i = 0, 7 do msg = msg .. string.char(math.floor(bits / 256 ^ i) % 256) end

  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  for chunk = 1, #msg, 64 do
    local M = {}
    for i = 0, 15 do
      local b1, b2, b3, b4 = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      M[i] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    local A, B, C, D = a0, b0, c0, d0
    for i = 0, 63 do
      local F, g
      if i < 16 then
        F = bor(band(B, C), band(bnot(B), D)); g = i
      elseif i < 32 then
        F = bor(band(D, B), band(bnot(D), C)); g = (5 * i + 1) % 16
      elseif i < 48 then
        F = bxor(B, bxor(C, D)); g = (3 * i + 5) % 16
      else
        F = bxor(C, bor(B, bnot(D))); g = (7 * i) % 16
      end
      F = (F + A + K[i] + M[g]) % MOD
      A = D; D = C; C = B
      B = (B + lrot(F, s[i + 1])) % MOD
    end
    a0 = (a0 + A) % MOD; b0 = (b0 + B) % MOD
    c0 = (c0 + C) % MOD; d0 = (d0 + D) % MOD
  end

  local out = {}
  for _, w in ipairs({ a0, b0, c0, d0 }) do
    for i = 0, 3 do out[#out + 1] = math.floor(w / 256 ^ i) % 256 end
  end
  return out
end

-- UUID a cracked (offline-mode) server gives a nickname
local function offlineUuid(nick)
  local b = md5("OfflinePlayer:" .. nick)
  b[7] = bit32.bor(bit32.band(b[7], 0x0f), 0x30)
  b[9] = bit32.bor(bit32.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do hex[i] = ("%02x"):format(b[i]) end
  local h = table.concat(hex)
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21)
end

-- any UUID text (with or without dashes) -> lowercase dashed form, or nil
local function normUuid(text)
  local hex = ((text or ""):lower():gsub("[^%x]", ""))
  if #hex ~= 32 then return nil end
  return hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-" .. hex:sub(13, 16) .. "-" .. hex:sub(17, 20) .. "-" .. hex:sub(21)
end

local function setFriend(nick, id)
  for sid in pairs(seen) do          -- keep the exact spelling the radar uses
    if sid:lower():gsub("%-", "") == id:gsub("%-", "") then id = sid end
  end
  data.friends[id] = nick
  say("  " .. id)
end

-- addid <nick>                 : adds the online (Mojang) UUID and the offline UUID
-- addid <nick> <uuid> [uuid..] : adds exactly the UUIDs you give
local function cmdAddId(arg)
  local toks = {}
  for t in (arg or ""):gmatch("%S+") do toks[#toks + 1] = t end
  local nick = table.remove(toks, 1)
  if not nick then say("Usage: addid <nick> [uuid] [uuid]") return end
  local ids = {}
  if #toks > 0 then
    for _, t in ipairs(toks) do
      local id = normUuid(t)
      if not id then say("Bad UUID: " .. t) return end
      ids[#ids + 1] = id
    end
  else
    ids[1] = offlineUuid(nick)
    local txt = safeGet("https://api.mojang.com/users/profiles/minecraft/" .. textutils.urlEncode(nick))
    if txt then
      local j = textutils.unserializeJSON(txt)
      local online = j and normUuid(j.id)
      if online and online ~= ids[1] then ids[#ids + 1] = online end
      if online then nick = j.name or nick end
    else
      say("Mojang lookup failed, adding offline UUID only")
    end
  end
  say("Added " .. nick .. ":")
  for _, id in ipairs(ids) do setFriend(nick, id) end
  save()
end

-- inventory scanner: tries to find any inventory peripheral and list its contents
local function cmdInv(arg)
  -- Try to find an inventory scanner peripheral (e.g. from Plethora or similar)
  local scanner = peripheral.find("plethora:scanner") or peripheral.find("inventoryScanner")
                  or peripheral.find("inventory_scanner")
  if scanner and type(scanner.getInventory) == "function" then
    local ok, inv = pcall(scanner.getInventory)
    if ok and type(inv) == "table" then
      local lines = {}
      for slot, item in pairs(inv) do
        if item and item.name then
          lines[#lines + 1] = ("  [%d] %s x%d"):format(slot, item.name, item.count or 1)
        end
      end
      table.sort(lines)
      if #lines == 0 then say("Инвентарь пуст") else
        say("Инвентарь (" .. #lines .. " ячеек):")
        for _, l in ipairs(lines) do say(l) end
      end
      return
    end
  end
  -- Fallback: look for any chest/shulkerbox peripheral nearby
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name) or ""
    if ptype:find("chest") or ptype:find("shulker") or ptype:find("barrel") then
      local p = peripheral.wrap(name)
      if p and type(p.list) == "function" then
        local ok2, items = pcall(p.list)
        if ok2 and type(items) == "table" then
          say("Содержимое " .. name .. ":")
          local any = false
          for slot, item in pairs(items) do
            if item then
              say(("  [%d] %s x%d"):format(slot, item.name or "?", item.count or 1))
              any = true
            end
          end
          if not any then say("  Пусто") end
          return
        end
      end
    end
  end
  say("Периферал для инвентаря не найден.")
  say("Подключите Inventory Scanner (Plethora) или поставьте сундук рядом с компьютером.")
end

local function cmdList()
  local any = false
  for id, nick in pairs(data.friends) do
    say(nick .. "  " .. id:sub(1, 8))
    any = true
  end
  if not any then say("List is empty") end
end

local function cmdDel(nick)
  local n = 0
  for id, name in pairs(data.friends) do
    if name:lower() == (nick or ""):lower() then
      data.friends[id] = nil
      n = n + 1
    end
  end
  if n > 0 then save() say("Removed " .. n .. " UUID(s) of " .. nick) else say("Not found") end
end

-- radar <x> <y> <z> [range] | radar here [range] | radar off  (range is read from the radar if omitted)
local function cmdRadar(arg)
  local t = {}
  for w in (arg or ""):gmatch("%S+") do t[#t + 1] = w end
  if t[1] == "off" then
    data.radar = nil save() say("Radar circle removed")
  elseif t[1] == "here" then
    local x, y, z = gps.locate(2)
    if not x then say("GPS not available, use: radar <x> <y> <z>") return end
    data.radar = { x = x, y = y, z = z, range = tonumber(t[2]) or radarRange() or 0 }
    save() say("Radar saved, range " .. data.radar.range)
  elseif (#t == 3 or #t == 4) and tonumber(t[1]) and tonumber(t[2]) and tonumber(t[3]) then
    data.radar = { x = tonumber(t[1]), y = tonumber(t[2]), z = tonumber(t[3]), range = tonumber(t[4]) or radarRange() or 0 }
    save() say("Radar saved, range " .. data.radar.range)
  elseif data.radar then
    say(("Radar: x=%d y=%d z=%d range=%s (live)"):format(data.radar.x, data.radar.y, data.radar.z, tostring(radarRange())))
  else
    say("Usage: radar <x> <y> <z> [range] | radar here [range] | radar off")
  end
end

-- size <name or id-start> <length> <width> <height> | size del <key>
local function cmdSize(arg)
  local t = {}
  for w in (arg or ""):gmatch("%S+") do t[#t + 1] = w end
  if t[1] == "del" and t[2] then
    data.sizes[t[2]] = nil save() say("Removed " .. t[2])
  elseif #t == 4 and tonumber(t[2]) and tonumber(t[3]) and tonumber(t[4]) then
    data.sizes[t[1]] = { l = tonumber(t[2]), w = tonumber(t[3]), h = tonumber(t[4]) }
    save() say("Size saved for " .. t[1])
  else
    for k, s in pairs(data.sizes) do say(("%s: %sx%sx%s"):format(k, s.l, s.w, s.h)) end
    say("Usage: size <name|id-start> <length> <width> <height>")
  end
end

-- objects auto | all | off | only <CATEGORY> [CATEGORY..]
local function cmdObjects(arg)
  local t = {}
  for w in (arg or ""):gmatch("%S+") do t[#t + 1] = w end
  if t[1] == "auto" or t[1] == "all" or t[1] == "off" then
    data.objfilter = t[1] data.objcats = {} save() say("Objects: " .. t[1])
  elseif t[1] == "only" and #t > 1 then
    table.remove(t, 1)
    data.objfilter = "only" data.objcats = t save()
    say("Objects only: " .. table.concat(t, " "))
  else
    say("Objects: " .. data.objfilter .. " " .. table.concat(data.objcats, " "))
    say("Usage: objects auto | all | off | only <CATEGORY>..")
  end
end

-- what does the radar report? one line per category + full sample saved to tracks_dump.txt
local function cmdTracks()
  local tracks = getAllTracks()
  if #tracks == 0 then say("No contacts right now") return end
  local groups, order, samples = {}, {}, {}
  for _, t in ipairs(tracks) do
    local c = tostring(t.category)
    if not groups[c] then groups[c] = { n = 0, sample = t } order[#order + 1] = c end
    groups[c].n = groups[c].n + 1
  end
  table.sort(order)
  for _, c in ipairs(order) do
    local g = groups[c]
    local keys = {}
    for k in pairs(g.sample) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    say(("%s x%d: %s"):format(c, g.n, table.concat(keys, ",")))
    samples[#samples + 1] = g.sample
  end
  local f = fs.open("tracks_dump.txt", "w")
  f.write(textutils.serialize(samples))
  f.close()
  say("Sample of each category saved: tracks_dump.txt")
end

-- list every connected peripheral and its methods (to look for something that knows ship sizes)
local function cmdPeriph()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    local m = peripheral.getMethods(n) or {}
    table.sort(m)
    out[#out + 1] = n .. " (" .. tostring(peripheral.getType(n)) .. "): " .. table.concat(m, ", ")
    say(n .. " (" .. tostring(peripheral.getType(n)) .. ") " .. #m .. " methods")
  end
  local f = fs.open("periph_dump.txt", "w")
  f.write(table.concat(out, "\n\n"))
  f.close()
  say("Full list saved: periph_dump.txt")
end

local function help()
  say("add [nick] - add friend (stand near radar)")
  say("addid <nick> - add friend by nick, both online+offline UUID")
  say("addid <nick> <uuid> [uuid] - add exact UUIDs")
  say("radar <x> <y> <z> [range] - circle on the site (range auto from radar)")
  say("objects auto|all|off|only <CAT>.. - constructions/other contacts")
  say("tracks - what the radar reports, saves tracks_dump.txt")
  say("size <name> <len> <wid> <hgt> - set box size of a construction")
  say("periph - list peripherals+methods, saves periph_dump.txt")
  say("inv - scan nearby inventory / inventory peripheral")
  say("list - show friends")
  say("del <nick> - remove friend")
  say("webhook <url> - set webhook")
  say("site <url> - set website address")
  say("key <secret> - set website secret key")
  say("test - send test message")
  say("status - show current settings (site, key, radar, webhook)")
  say("help - show this help")
end

local function cmdStatus()
  say("=== GUARD STATUS ===")
  say("Site: " .. (data.site ~= "" and data.site or "NOT SET (type: site https://...)"))
  say("Key: " .. (data.key ~= "" and data.key or "NOT SET (type: key 5555)"))
  if data.radar then
    say(("Radar circle: X=%d Y=%d Z=%d Range=%s"):format(data.radar.x, data.radar.y, data.radar.z, tostring(data.radar.range)))
  else
    say("Radar circle: NOT SET (type: radar here OR radar <x> <y> <z>)")
  end
  say("Webhook: " .. (data.webhook ~= "" and "SET" or "NOT SET"))
  local fc = 0 for _ in pairs(data.friends) do fc = fc + 1 end
  say("Friends: " .. fc)
  local ok, err = pushSite()
  say("Test push: " .. (ok and "OK (connected)" or ("ERROR: " .. tostring(err))))
end


-- =================== PVO (Air Defense) Integration ===================
local pvoState = {
  lockedId = nil,
  target = nil,
  isAimed = false,
  lastFire = 0
}


local function autoDetectPvoGuns()
  local guns = {}
  local pCtrl, yCtrl, fCtrl = nil, nil, nil
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    local pType = tostring(peripheral.getType(name) or ""):lower()
    local nLower = name:lower()
    if not pCtrl and p and p.setAngle and (pType:find("pitch") or nLower:find("pitch")) then
      pCtrl = p
    end
    if not yCtrl and p and p.setAngle and (pType:find("yaw") or nLower:find("yaw")) then
      yCtrl = p
    end
    if not fCtrl and p and (p.fireOn or p.keepFiring or pType:find("fire") or nLower:find("fire")) then
      fCtrl = p
    end
  end
  return pCtrl, yCtrl, fCtrl
end


-- ---- Radar Management (Base Alarm Radar vs Gun Radar) ----
local function getAllRadars()
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    local pType = tostring(peripheral.getType(name) or "")
    if pType:find("radar") or pType:find("bearing") then
      local p = peripheral.wrap(name)
      if p and p.getTracks then
        table.insert(list, { name = name, wrap = p, type = pType })
      end
    end
  end
  return list
end

local function getGunRadar()
  local radars = getAllRadars()
  if #radars == 0 then return nil end

  -- 1. Check if user configured a specific gun radar name
  if data.gunRadarName then
    for _, r in ipairs(radars) do
      if r.name == data.gunRadarName then return r.wrap, r.name end
    end
  end

  -- 2. If multiple radars, pick the one connected to gun or second radar
  if #radars >= 2 then
    -- If the first radar is the base alarm radar, pick the other one for the gun
    for _, r in ipairs(radars) do
      if r.wrap ~= radar then
        return r.wrap, r.name
      end
    end
  end

  -- 3. Fallback to default radar
  return radars[1].wrap, radars[1].name
end


local function getGunsList()
  local list = {}
  local pCtrl, yCtrl, fCtrl = autoDetectPvoGuns()
  local gunR, gunRName = getGunRadar()
  
  if pCtrl or yCtrl or fCtrl or gunR then
    local curP = (pCtrl and pCtrl.getAngle and pCtrl.getAngle()) or 0
    local curY = (yCtrl and yCtrl.getAngle and yCtrl.getAngle()) or 0
    
    -- Exact gun coordinates from gun's radar position
    local gPos = (gunR and gunR.getPosition and gunR.getPosition()) or (data.radar and data.radar) or {x=0, y=70, z=0}
    local gRange = (gunR and gunR.getRange and gunR.getRange()) or 350
    
    table.insert(list, {
      id = "gun_main",
      name = "Орудие ПВО (CBC)",
      radarName = gunRName or "авто",
      x = gPos.x, y = gPos.y, z = gPos.z,
      range = gRange,
      pitch = curP,
      yaw = curY,
      lockedId = pvoState and pvoState.lockedId or nil,
      status = (pvoState and pvoState.lockedId) and "LOCKED" or "READY"
    })
  end
  return list
end




local function calculateLeadPvo(gunPos, targetPos, targetVel, muzzleVel, gravity)
  local pred = { x = targetPos.x, y = targetPos.y, z = targetPos.z }
  local tof = 0
  muzzleVel = muzzleVel or 70.0
  gravity = gravity or 1.25

  for _ = 1, 6 do
    local dx = pred.x - gunPos.x
    local dy = pred.y - gunPos.y
    local dz = pred.z - gunPos.z
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
    tof = dist / muzzleVel
    pred.x = targetPos.x + targetVel.x * tof
    pred.y = targetPos.y + targetVel.y * tof
    pred.z = targetPos.z + targetVel.z * tof
  end

  local dropComp = 0.5 * gravity * (tof * tof)
  local aimY = pred.y + dropComp
  local toY = aimY - gunPos.y
  local toH = math.sqrt((pred.x - gunPos.x)^2 + (pred.z - gunPos.z)^2)
  local targetYaw = math.deg(math.atan2(-(pred.x - gunPos.x), pred.z - gunPos.z))
  local targetPitch = math.deg(math.atan2(toY, toH))
  return targetYaw, targetPitch, tof
end



local function pvoLoop()
  while true do
    if pvoState.lockedId then
      local pitchCtrl, yawCtrl, fireCtrl = autoDetectPvoGuns()
      local gunR, gunRName = getGunRadar()
      local allTracks = (gunR and gunR.getTracks and gunR.getTracks()) or getAllTracks()
      
      local found = nil
      for _, tr in ipairs(allTracks) do
        if tostring(tr.id) == tostring(pvoState.lockedId) then
          found = tr
          break
        end
      end
      
      local gunPos = (gunR and gunR.getPosition and gunR.getPosition()) or (data.radar and data.radar)
      
      if found and gunPos then
        local pos = found.position or { x = 0, y = 0, z = 0 }
        local vel = found.velocity or { x = 0, y = 0, z = 0 }
        
        -- Exact CBC ballistic lead & gravity drop calculation
        local yaw, pitch, tof = calculateLeadPvo(gunPos, pos, vel, 70.0, 1.25)
        
        if yawCtrl and yawCtrl.setAngle then yawCtrl.setAngle(yaw) end
        if pitchCtrl and pitchCtrl.setAngle then pitchCtrl.setAngle(pitch) end
      else
        pvoState.target = nil
      end
    end
    sleep(0.05)
  end
end



local function cmdPvo(arg)
  local sub, rest = (arg or ""):match("^(%S+)%s*(.-)$")
  sub = (sub or ""):lower()
  if sub == "lock" then
    pvoState.lockedId = rest
    say("[PVO] Locked on target ID: " .. tostring(rest))
  elseif sub == "unlock" then
    pvoState.lockedId = nil
    pvoState.target = nil
    local pitchCtrl, yawCtrl, _ = autoDetectPvoGuns()
    if pitchCtrl and pitchCtrl.stopAuto then pitchCtrl.stopAuto() end
    if yawCtrl and yawCtrl.stopAuto then yawCtrl.stopAuto() end
    say("[PVO] Target unlocked. Gun standing by.")
  elseif sub == "radar" then
    if rest and rest ~= "" then
      data.gunRadarName = rest
      save()
      say("[PVO] Gun radar bound to: " .. rest)
    else
      local gunR, gunRName = getGunRadar()
      say("[PVO] Current gun radar: " .. tostring(gunRName or "not found"))
      say("Available radars:")
      for _, r in ipairs(getAllRadars()) do
        say(" - " .. r.name .. " (" .. r.type .. ")")
      end
    end
  elseif sub == "fire" then
    local _, _, fireCtrl = autoDetectPvoGuns()
    if fireCtrl and fireCtrl.fireOn then
      fireCtrl.fireOn()
      sleep(0.1)
      fireCtrl.fireOff()
      say("[PVO] >> FIRE EXECUTED BY OPERATOR <<")
    else
      redstone.setOutput("back", true)
      sleep(0.1)
      redstone.setOutput("back", false)
      say("[PVO] >> PULSED REDSTONE FIRE <<")
    end
  elseif sub == "status" then
    local gunR, gunRName = getGunRadar()
    say("[PVO] Gun Radar: " .. tostring(gunRName or "none"))
    say("[PVO] Locked target: " .. tostring(pvoState.lockedId or "none"))
  else
    say("Usage: pvo lock <id> | pvo unlock | pvo radar <name> | pvo fire | pvo status")
  end
end

-- ====================================================================

local function runLine(line)
  local cmd, arg = line:match("^(%S+)%s*(.-)$")
  if cmd == "add" then cmdAdd(arg)
  elseif cmd == "addid" then cmdAddId(arg)
  elseif cmd == "radar" then cmdRadar(arg)
  elseif cmd == "objects" then cmdObjects(arg)
  elseif cmd == "tracks" then cmdTracks()
  elseif cmd == "size" then cmdSize(arg)
  elseif cmd == "periph" then cmdPeriph()
  elseif cmd == "inv" then cmdInv(arg)
  elseif cmd == "list" then cmdList()
  elseif cmd == "del" then cmdDel(arg)
  elseif cmd == "status" then cmdStatus()
  elseif cmd == "push" or cmd == "testsite" then
    local ok, err = pushSite()
    say("Push: " .. (ok and "OK (site updated)" or ("FAILED: " .. tostring(err))))
  elseif cmd == "webhook" then
    if arg and arg ~= "" then
      data.webhook = arg
      save()
      say("Webhook saved")
    else
      say("Current webhook: " .. (data.webhook ~= "" and "(is set)" or "(not set)"))
      say("Usage: webhook <url>")
    end
  elseif cmd == "site" then
    if arg and arg ~= "" then
      data.site = arg
      save()
      say("Site saved: " .. data.site)
    else
      say("Current site: " .. (data.site ~= "" and data.site or "(not set)"))
      say("Usage: site <url>")
    end
  elseif cmd == "key" then
    if arg and arg ~= "" then
      data.key = arg
      save()
      say("Key saved")
    else
      say("Current key: " .. (data.key ~= "" and "(is set)" or "(not set)"))
      say("Usage: key <secret>")
    end
  elseif cmd == "test" then
    say(sendDiscord("Guard test message\n" .. mapLink({ x = 0, y = 70, z = 0 })) and "Sent" or "Not sent")
  elseif cmd == "cooldown" then
    data.cooldown = tonumber(arg) or data.cooldown
    save()
    say("Cooldown: " .. data.cooldown)
  elseif cmd == "pvo" then cmdPvo(arg)
  elseif cmd == "help" then help()
  elseif cmd then say("Unknown command, type help") end
end

local REMOTE_BLOCKED = { key = true, site = true }
function runRemote(line)
  local cmd = line:match("^(%S+)")
  if cmd and REMOTE_BLOCKED[cmd] then return "Command not allowed from the website" end
  capture = {}
  local ok, err = pcall(runLine, line)
  local out = capture
  capture = nil
  if not ok then out[#out + 1] = "Error: " .. tostring(err) end
  return table.concat(out, "\n"):sub(1, 2000)
end

local function cmdLoop()
  say("Guard started. Type help or status")
  if data.site == "" or data.key == "" then
    say("(!): Site or Key not set! Type 'status'")
  end
  if not data.radar then
    say("(!): Radar pos not set! Type 'radar here' (or radar x y z)")
  end
  while true do
    write("> ")
    runLine(read())
  end
end

parallel.waitForAny(guardLoop, cmdLoop, siteLoop, pvoLoop)
