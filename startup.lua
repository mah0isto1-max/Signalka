local FILE = "guard_data"
local RECENT = 15
local MAP_URL = "http://mc.vestalis.xyz:25971/#world"
local CAM_DIST = 150
local SEND_EVERY = 0.5
local data = { webhook = "", friends = {}, cooldown = 15, site = "", key = "" }

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
  end
end

local radar = peripheral.find("create_radar:radar_bearing")
           or peripheral.find("create_radar:monitor")
assert(radar, "Radar not found: place the computer next to the radar")

local seen = {}
local function now() return os.epoch("utc") / 1000 end

local function getPlayers()
  local ok, tracks = pcall(radar.getTracks)
  local res = {}
  if ok and tracks then
    for _, t in ipairs(tracks) do
      if t.category == "PLAYER" then res[#res + 1] = t end
    end
  end
  return res
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
  local list = {}
  for _, t in ipairs(getPlayers()) do
    list[#list + 1] = {
      id = t.id,
      name = data.friends[t.id] or "",
      friend = data.friends[t.id] ~= nil,
      x = t.position.x, y = t.position.y, z = t.position.z,
    }
  end
  local url = data.site:gsub("/+$", "") .. "/api/update?key=" .. textutils.urlEncode(data.key)
  local body = textutils.serializeJSON({ players = list })
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

local function cmdAddId(nick)
  if not nick or nick == "" then print("Usage: addid <nick>") return end
  local r, err = http.get("https://api.mojang.com/users/profiles/minecraft/" .. textutils.urlEncode(nick))
  if not r then print("Mojang error: " .. tostring(err)) return end
  local body = r.readAll()
  r.close()
  local j = textutils.unserializeJSON(body)
  if not j or not j.id then print("Player not found: " .. nick) return end
  local hex = j.id:lower()
  local id = hex:gsub("(%x%x%x%x%x%x%x%x)(%x%x%x%x)(%x%x%x%x)(%x%x%x%x)(%x+)", "%1-%2-%3-%4-%5")
  for sid in pairs(seen) do
    if sid:lower():gsub("%-", "") == hex then id = sid end
  end
  data.friends[id] = j.name or nick
  save()
  print("Added: " .. (j.name or nick) .. "  " .. id)
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
  for id, n in pairs(data.friends) do
    if n:lower() == (nick or ""):lower() then
      data.friends[id] = nil
      save()
      print("Removed: " .. n)
      return
    end
  end
  print("Not found")
end

local function help()
  print("add [nick] - add friend (stand near radar)")
  print("addid <nick> - add friend by nick (player can be offline)")
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
