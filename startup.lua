local FILE = "guard_data"
local RECENT = 15
local MAP_URL = "http://mc.vestalis.xyz:25971/#world"
local CAM_DIST = 150
local SEND_EVERY = 0.3
local data = { webhook = "", friends = {}, cooldown = 15, site = "", key = "", radar = nil, objfilter = "auto", objcats = {}, sizes = {} }

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

local function sendDiscord(text)
  if data.webhook == "" then
    print("Webhook not set")
    return false
  end
  local body = textutils.serializeJSON({ content = text })
  local ok, err = http.post(data.webhook, body, { ["Content-Type"] = "application/json" })
  if ok then ok.close() return true end
  print("Webhook error: " .. tostring(err))
  return false
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
      list[#list + 1] = {
        id = t.id,
        name = data.friends[t.id] or "",
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
  local url = data.site:gsub("/+$", "") .. "/api/update?key=" .. textutils.urlEncode(data.key)
  local body = textutils.serializeJSON({ players = list, objects = objs, radar = data.radar })
  local ok, err = http.post(url, body, { ["Content-Type"] = "application/json" })
  if ok then ok.close() return true end
  return false, err
end

local function siteLoop()
  local failed = false
  while true do
    local ok, err = pushSite()
    if ok == false and not failed then
      print("Site error: " .. tostring(err))
      failed = true
    elseif ok then
      failed = false
    end
    sleep(SEND_EVERY)
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
          local msg = ("ALERT! Unknown player\nUUID: %s\nPos: x=%d y=%d z=%d\n%s"):format(
            t.id, t.position.x, t.position.y, t.position.z, mapLink(t.position))
          if data.site ~= "" then msg = msg .. "\nLive: " .. data.site end
          sendDiscord(msg)
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
    print("No new players seen in last " .. RECENT .. "s")
    return
  end
  local n = 1
  if #list > 1 then
    for i, t in ipairs(list) do
      print(("%d) x=%d z=%d  %s"):format(i, t.position.x, t.position.z, t.id:sub(1, 8)))
    end
    write("Number: ")
    n = tonumber(read())
    if not n or not list[n] then print("Cancelled") return end
  end
  local nick = arg
  if not nick or nick == "" then
    write("Nick: ")
    nick = read()
  end
  if nick == "" then print("Cancelled") return end
  data.friends[list[n].id] = nick
  save()
  print("Added: " .. nick)
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
  print("  " .. id)
end

-- addid <nick>                 : adds the online (Mojang) UUID and the offline UUID
-- addid <nick> <uuid> [uuid..] : adds exactly the UUIDs you give
local function cmdAddId(arg)
  local toks = {}
  for t in (arg or ""):gmatch("%S+") do toks[#toks + 1] = t end
  local nick = table.remove(toks, 1)
  if not nick then print("Usage: addid <nick> [uuid] [uuid]") return end
  local ids = {}
  if #toks > 0 then
    for _, t in ipairs(toks) do
      local id = normUuid(t)
      if not id then print("Bad UUID: " .. t) return end
      ids[#ids + 1] = id
    end
  else
    ids[1] = offlineUuid(nick)
    local r = http.get("https://api.mojang.com/users/profiles/minecraft/" .. textutils.urlEncode(nick))
    if r then
      local j = textutils.unserializeJSON(r.readAll())
      r.close()
      local online = j and normUuid(j.id)
      if online and online ~= ids[1] then ids[#ids + 1] = online end
      if online then nick = j.name or nick end
    else
      print("Mojang lookup failed, adding offline UUID only")
    end
  end
  print("Added " .. nick .. ":")
  for _, id in ipairs(ids) do setFriend(nick, id) end
  save()
end

local function cmdList()
  local any = false
  for id, nick in pairs(data.friends) do
    print(nick .. "  " .. id:sub(1, 8))
    any = true
  end
  if not any then print("List is empty") end
end

local function cmdDel(nick)
  local n = 0
  for id, name in pairs(data.friends) do
    if name:lower() == (nick or ""):lower() then
      data.friends[id] = nil
      n = n + 1
    end
  end
  if n > 0 then save() print("Removed " .. n .. " UUID(s) of " .. nick) else print("Not found") end
end

-- radar <x> <y> <z> <range> | radar here <range> | radar off
local function cmdRadar(arg)
  local t = {}
  for w in (arg or ""):gmatch("%S+") do t[#t + 1] = w end
  if t[1] == "off" then
    data.radar = nil save() print("Radar circle removed")
  elseif t[1] == "here" then
    local x, y, z = gps.locate(2)
    local range = tonumber(t[2])
    if not x then print("GPS not available, use: radar <x> <y> <z> <range>") return end
    if not range then print("Usage: radar here <range>") return end
    data.radar = { x = x, y = y, z = z, range = range } save() print("Radar saved")
  elseif #t == 4 and tonumber(t[1]) and tonumber(t[2]) and tonumber(t[3]) and tonumber(t[4]) then
    data.radar = { x = tonumber(t[1]), y = tonumber(t[2]), z = tonumber(t[3]), range = tonumber(t[4]) }
    save() print("Radar saved")
  elseif data.radar then
    print(("Radar: x=%d y=%d z=%d range=%d"):format(data.radar.x, data.radar.y, data.radar.z, data.radar.range))
  else
    print("Usage: radar <x> <y> <z> <range> | radar here <range> | radar off")
  end
end

-- size <name or id-start> <length> <width> <height> | size del <key>
local function cmdSize(arg)
  local t = {}
  for w in (arg or ""):gmatch("%S+") do t[#t + 1] = w end
  if t[1] == "del" and t[2] then
    data.sizes[t[2]] = nil save() print("Removed " .. t[2])
  elseif #t == 4 and tonumber(t[2]) and tonumber(t[3]) and tonumber(t[4]) then
    data.sizes[t[1]] = { l = tonumber(t[2]), w = tonumber(t[3]), h = tonumber(t[4]) }
    save() print("Size saved for " .. t[1])
  else
    for k, s in pairs(data.sizes) do print(("%s: %sx%sx%s"):format(k, s.l, s.w, s.h)) end
    print("Usage: size <name|id-start> <length> <width> <height>")
  end
end

-- objects auto | all | off | only <CATEGORY> [CATEGORY..]
local function cmdObjects(arg)
  local t = {}
  for w in (arg or ""):gmatch("%S+") do t[#t + 1] = w end
  if t[1] == "auto" or t[1] == "all" or t[1] == "off" then
    data.objfilter = t[1] data.objcats = {} save() print("Objects: " .. t[1])
  elseif t[1] == "only" and #t > 1 then
    table.remove(t, 1)
    data.objfilter = "only" data.objcats = t save()
    print("Objects only: " .. table.concat(t, " "))
  else
    print("Objects: " .. data.objfilter .. " " .. table.concat(data.objcats, " "))
    print("Usage: objects auto | all | off | only <CATEGORY>..")
  end
end

-- what does the radar report? one line per category + full sample saved to tracks_dump.txt
local function cmdTracks()
  local tracks = getAllTracks()
  if #tracks == 0 then print("No contacts right now") return end
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
    print(("%s x%d: %s"):format(c, g.n, table.concat(keys, ",")))
    samples[#samples + 1] = g.sample
  end
  local f = fs.open("tracks_dump.txt", "w")
  f.write(textutils.serialize(samples))
  f.close()
  print("Sample of each category saved: tracks_dump.txt")
end

local function help()
  print("add [nick] - add friend (stand near radar)")
  print("addid <nick> - add friend by nick, both online+offline UUID")
  print("addid <nick> <uuid> [uuid] - add exact UUIDs")
  print("radar <x> <y> <z> <range> - show radar circle on the site")
  print("objects auto|all|off|only <CAT>.. - constructions/other contacts")
  print("tracks - what the radar reports, saves tracks_dump.txt")
  print("size <name> <len> <wid> <hgt> - set box size of a construction")
  print("list - show friends")
  print("del <nick> - remove friend")
  print("webhook <url> - set webhook")
  print("site <url> - set website address")
  print("key <secret> - set website secret key")
  print("test - send test message")
  print("cooldown <sec> - pause between alerts")
end

local function cmdLoop()
  print("Guard started. Type help")
  while true do
    write("> ")
    local line = read()
    local cmd, arg = line:match("^(%S+)%s*(.-)$")
    if cmd == "add" then cmdAdd(arg)
    elseif cmd == "addid" then cmdAddId(arg)
    elseif cmd == "radar" then cmdRadar(arg)
    elseif cmd == "objects" then cmdObjects(arg)
    elseif cmd == "tracks" then cmdTracks()
    elseif cmd == "size" then cmdSize(arg)
    elseif cmd == "list" then cmdList()
    elseif cmd == "del" then cmdDel(arg)
    elseif cmd == "webhook" then
      data.webhook = arg
      save()
      print("Webhook saved")
    elseif cmd == "site" then
      data.site = arg
      save()
      print("Site saved")
    elseif cmd == "key" then
      data.key = arg
      save()
      print("Key saved")
    elseif cmd == "test" then
      print(sendDiscord("Guard test message\n" .. mapLink({ x = 0, y = 70, z = 0 })) and "Sent" or "Not sent")
    elseif cmd == "cooldown" then
      data.cooldown = tonumber(arg) or data.cooldown
      save()
      print("Cooldown: " .. data.cooldown)
    elseif cmd == "help" then help()
    elseif cmd then print("Unknown command, type help") end
  end
end

parallel.waitForAny(guardLoop, cmdLoop, siteLoop)
