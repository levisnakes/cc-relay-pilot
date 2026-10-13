-- Relay Pilot: the SHIP computer.
--
-- Drives a Create Aeronautics ship entirely through Redstone Relays, on
-- orders from the controller computer (the one with the Linked
-- Typewriter). Both computers talk over Ender Modems.
--
--   Up speed    0-9, sent as a redstone strength on the lift side(s).
--               It stays where it's set (it's not a hold-to-climb key).
--   Propellers  two turning propellers, each forward / reverse / off
--               through a Directional Gearshift:
--                 W both forward        S both reverse
--                 A/D spin on the spot  W+A, W+D, S+A, S+D arc (one stops)
--   Bottom      a constant signal on this computer's bottom side.
--               Q on the controller switches it off (and on again).
--
-- Setup (which relay sides do what) is done from the controller's menu
-- and saved here in relayship.cfg, so the ship keeps it whatever
-- controller flies it.
--
-- Safety: the propellers stop if the controller goes quiet for a second.
-- The up speed and the bottom signal stay as they are, so the ship doesn't
-- drop, and both come back the same after a reboot or server restart.
--
-- Everything is written to ship.log (the run before is ship.log.old).

VERSION = "1.0.2"

-- ======================== SETTINGS ===========================
-- To keep changes over updates, put them in ship_settings.lua instead.

BOTTOM_SIDE = "bottom"   -- this computer's side with the constant signal
DRIVE_TIMEOUT = 1.0      -- propellers stop after this long without word from the controller (seconds)
SETUP_TIMEOUT = 3        -- setup switches drop back after this long without the controller
MAX_UP = 9               -- top up speed

-- ===================== END OF SETTINGS =======================

if fs.exists("ship_settings.lua") then
  local f, err = loadfile("ship_settings.lua", nil, _ENV)
  if not f then error("ship_settings.lua: " .. err, 0) end
  f()
end

local PROTOCOL = "relaypilot"
local CONFIG_FILE = "relayship.cfg"
local RELAY_SIDES = { "front", "back", "left", "right", "top", "bottom" }

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
local function now() return os.epoch("utc") / 1000 end

-- ---------- log ----------
local LOG_FILE, LOG_LIMIT = "ship.log", 120000
local logFile, logBytes, logFull = nil, 0, false
local logStart = now()
local function log(fmt, ...)
  if not logFile or logFull then return end
  local line = string.format("%8.2f ", now() - logStart) .. string.format(fmt, ...)
  logBytes = logBytes + #line + 1
  if logBytes > LOG_LIMIT then
    logFull = true
    line = "log full, stopped writing"
  end
  -- A full disk must never stop the program.
  if not pcall(function() logFile.writeLine(line) logFile.flush() end) then logFile = nil end
end

-- ---------- hardware ----------

local function natural(name)
  local base, n = name:match("^(.-)(%d+)$")
  return base or name, tonumber(n) or -1
end
local function byNatural(a, b)
  local ab, an = natural(a)
  local bb, bn = natural(b)
  if ab ~= bb then return ab < bb end
  return an < bn
end

local modemName = nil
local relays = {}        -- relay peripheral names
local relaySet = {}
local outputs = {}       -- "relay:side" for every relay side
local function scanHardware()
  relays, relaySet, outputs = {}, {}, {}
  modemName = nil
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t == "redstone_relay" then
      relays[#relays + 1] = name
      relaySet[name] = true
    elseif t == "modem" and not modemName then
      local ok, wireless = pcall(peripheral.call, name, "isWireless")
      if ok and wireless then modemName = name end
    end
  end
  table.sort(relays, byNatural)
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do outputs[#outputs + 1] = r .. ":" .. side end
  end
end
scanHardware()

local function splitId(id)
  return id:match("^(.*):(%a+)$")
end

-- ---------- saved setup and state ----------

local cfg
local function newCode()
  return string.format("%04d", math.random(0, 9999))
end
local function newKey()
  local chars = "abcdefghijkmnpqrstuvwxyz23456789"
  local t = {}
  for i = 1, 16 do
    local n = math.random(1, #chars)
    t[i] = chars:sub(n, n)
  end
  return table.concat(t)
end

local function saveConfig()
  local h = fs.open(CONFIG_FILE .. ".new", "w")
  h.write(textutils.serialize(cfg))
  h.close()
  if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
  fs.move(CONFIG_FILE .. ".new", CONFIG_FILE)
end

local function listOf(v)
  local out = {}
  if type(v) == "table" then
    for _, id in ipairs(v) do if type(id) == "string" and splitId(id) then out[#out + 1] = id end end
  end
  return out
end

local function loadConfig()
  math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)
  cfg = {}
  local path = fs.exists(CONFIG_FILE) and CONFIG_FILE or (fs.exists(CONFIG_FILE .. ".new") and CONFIG_FILE .. ".new")
  if path then
    local h = fs.open(path, "r")
    local saved = textutils.unserialize(h.readAll() or "")
    h.close()
    if type(saved) == "table" then cfg = saved end
  end
  cfg.key = type(cfg.key) == "string" and cfg.key or newKey()
  cfg.code = type(cfg.code) == "string" and cfg.code or newCode()
  cfg.paired = type(cfg.paired) == "table" and cfg.paired or {}
  cfg.props = type(cfg.props) == "table" and cfg.props or {}
  for _, p in ipairs({ "L", "R" }) do
    local m = type(cfg.props[p]) == "table" and cfg.props[p] or {}
    cfg.props[p] = { fwd = listOf(m.fwd), rev = listOf(m.rev) }
  end
  cfg.lift = type(cfg.lift) == "table" and cfg.lift or {}
  cfg.lift.sides = listOf(cfg.lift.sides)
  cfg.lift.stretch = cfg.lift.stretch == true
  cfg.up = clamp(math.floor(tonumber(cfg.up) or 0), 0, MAX_UP)
  if cfg.bottom == nil then cfg.bottom = true end
  saveConfig()
end
loadConfig()

local function propsReady()
  local p = cfg.props
  return #p.L.fwd + #p.L.rev + #p.R.fwd + #p.R.rev > 0
end

-- ---------- outputs ----------

-- Strength the up speed gives: 0-9 as it is, or stretched over 0-15.
local function upStrength(level)
  if cfg.lift.stretch then return math.floor(level * 15 / MAX_UP + 0.5) end
  return level
end

-- What the controller asks for right now.
local drive = nil          -- { f, b, l, r, at, from }
local setup = nil          -- { sides = { id = strength }, at }
local function driveActive()
  return drive ~= nil and now() - drive.at <= DRIVE_TIMEOUT
end

-- Each propeller: "fwd", "rev" or "off".
local function propStates()
  if not driveActive() then return "off", "off" end
  local fb = (drive.f and 1 or 0) - (drive.b and 1 or 0)
  local lr = (drive.r and 1 or 0) - (drive.l and 1 or 0)   -- +1 turns right
  if fb == 0 and lr == 0 then return "off", "off" end
  if fb == 0 then
    -- Spin on the spot: one forward, one reverse.
    if lr > 0 then return "fwd", "rev" else return "rev", "fwd" end
  end
  local dir = fb > 0 and "fwd" or "rev"
  if lr == 0 then return dir, dir end
  -- Arc: the propeller on the inside of the turn stops. A always swings
  -- the nose left, going forward or backward.
  if fb > 0 then
    if lr > 0 then return "fwd", "off" else return "off", "fwd" end
  else
    if lr > 0 then return "off", "rev" else return "rev", "off" end
  end
end

local function wanted()
  local want = {}
  for _, id in ipairs(outputs) do want[id] = 0 end
  local s = upStrength(cfg.up)
  for _, id in ipairs(cfg.lift.sides) do want[id] = s end
  local l, r = propStates()
  if setup then l, r = "off", "off" end
  for _, pair in ipairs({ { "L", l }, { "R", r } }) do
    local sides = pair[2] ~= "off" and cfg.props[pair[1]][pair[2]] or {}
    for _, id in ipairs(sides) do want[id] = 15 end
  end
  if setup then
    for id, v in pairs(setup.sides) do
      if want[id] ~= nil then want[id] = v end
    end
  end
  return want
end

local outNow = {}         -- id -> strength last set
local outError = nil
local function setStrength(id, n)
  if outNow[id] == n then return end
  local relay, side = splitId(id)
  if not relaySet[relay] then return end
  local ok, err = pcall(peripheral.call, relay, "setAnalogOutput", side, n)
  if ok then
    outNow[id] = n
    log("out %s = %d", id, n)
    if outError and outError:find(relay, 1, true) then outError = nil end
  else
    outError = string.format("%s: %s", id, tostring(err))
    log("out %s = %d FAILED: %s", id, n, tostring(err))
  end
end

-- Switching off goes first, so a gearshift is never told "forward" and
-- "reverse" at the same moment.
local function applyOutputs()
  local want = wanted()
  local ids = {}
  for id in pairs(want) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if outNow[id] == nil or want[id] < outNow[id] then setStrength(id, want[id]) end
  end
  for _, id in ipairs(ids) do
    if want[id] > (outNow[id] or 0) then setStrength(id, want[id]) end
  end
end

local function applyBottom()
  local ok, err = pcall(redstone.setOutput, BOTTOM_SIDE, cfg.bottom)
  if not ok then log("bottom signal FAILED: %s", tostring(err)) end
end

-- ---------- network ----------

local heard = {}          -- controller id -> when last heard
local statusDirty = true
local lastStatusTo = {}
local pairFails = {}      -- computer id -> times of its wrong codes
local lastMoveText = nil

local function status()
  local l, r = propStates()
  local on = {}
  for id, v in pairs(outNow) do if v > 0 then on[id] = v end end
  return {
    t = "status", v = VERSION, id = os.getComputerID(), label = os.getComputerLabel(),
    up = cfg.up, max = MAX_UP, bottom = cfg.bottom, left = l, right = r,
    outputs = outputs, on = on, props = cfg.props, lift = cfg.lift,
    err = outError, relays = #relays, setup = setup ~= nil,
  }
end

local function send(to, msg)
  if not modemName then return end
  pcall(rednet.send, to, msg, PROTOCOL)
end

local function sendStatus(to)
  lastStatusTo[to] = now()
  send(to, status())
end

-- Status to every controller heard from lately.
local function broadcastStatus()
  local t = now()
  for id, at in pairs(heard) do
    if t - at < 15 then sendStatus(id) end
  end
  statusDirty = false
end

local function cleanSides(v)
  local out = {}
  if type(v) ~= "table" then return out end
  for id, n in pairs(v) do
    if type(id) == "string" and splitId(id) and type(n) == "number" then
      out[id] = clamp(math.floor(n), 0, 15)
    end
  end
  return out
end

local function setUp(level, why)
  level = clamp(math.floor(level), 0, MAX_UP)
  if level ~= cfg.up then
    log("up speed %d -> %d (%s)", cfg.up, level, why)
    cfg.up = level
    saveConfig()
    statusDirty = true
  end
end

local function setBottom(on, why)
  if on ~= cfg.bottom then
    cfg.bottom = on
    log("bottom signal %s (%s)", on and "ON" or "off", why)
    saveConfig()
    applyBottom()
    statusDirty = true
  end
end

local warned = {}
local function handle(from, msg)
  if msg.t == "pair" then
    local t = now()
    local recent = {}
    for _, at in ipairs(pairFails[from] or {}) do if t - at < 60 then recent[#recent + 1] = at end end
    pairFails[from] = recent
    if #recent >= 5 then
      send(from, { t = "pairFail", why = "too many wrong codes - wait a minute" })
      return
    end
    if tostring(msg.code) == cfg.code then
      cfg.paired[from] = true
      cfg.code = newCode()   -- a used code can't be used again
      saveConfig()
      log("paired with computer #%d", from)
      heard[from] = t
      send(from, { t = "paired", key = cfg.key, id = os.getComputerID(), label = os.getComputerLabel() })
      statusDirty = true
    else
      -- No answer: the code was broadcast, so every other ship heard it too.
      recent[#recent + 1] = t
      log("wrong pairing code from #%d (%d in the last minute)", from, #recent)
    end
    return
  end

  if not cfg.paired[from] or msg.k ~= cfg.key then
    if not warned[from] then
      warned[from] = true
      log("ignored a message from unpaired computer #%d", from)
    end
    if msg.t == "hello" then send(from, { t = "notPaired" }) end
    return
  end
  heard[from] = now()

  if msg.t == "drive" then
    drive = { f = msg.f == true, b = msg.b == true, l = msg.l == true, r = msg.r == true, at = now(), from = from }
    local text = (drive.f and "W" or "") .. (drive.l and "A" or "") .. (drive.b and "S" or "") .. (drive.r and "D" or "")
    if text ~= lastMoveText then
      lastMoveText = text
      log("drive from #%d: %s", from, text ~= "" and text or "none")
      statusDirty = true
    end
  elseif msg.t == "up" then
    if msg.add then setUp(cfg.up + (tonumber(msg.add) or 0), "controller #" .. from)
    elseif msg.set then setUp(tonumber(msg.set) or cfg.up, "controller #" .. from) end
  elseif msg.t == "bottom" then
    setBottom(msg.on == true, "controller #" .. from)
  elseif msg.t == "setup" then
    if msg.done then
      if setup then log("setup ended") end
      setup = nil
    else
      if not setup then log("setup started by #%d", from) end
      setup = { sides = cleanSides(msg.sides), at = now() }
    end
    statusDirty = true
  elseif msg.t == "saveProps" and type(msg.props) == "table" then
    for _, p in ipairs({ "L", "R" }) do
      local m = type(msg.props[p]) == "table" and msg.props[p] or {}
      cfg.props[p] = { fwd = listOf(m.fwd), rev = listOf(m.rev) }
    end
    saveConfig()
    log("propellers saved: %s", textutils.serialize(cfg.props):gsub("%s+", " "))
    statusDirty = true
  elseif msg.t == "saveLift" then
    cfg.lift = { sides = listOf(msg.sides), stretch = msg.stretch == true }
    saveConfig()
    log("lift saved: %s", textutils.serialize(cfg.lift):gsub("%s+", " "))
    statusDirty = true
  elseif msg.t == "unpair" then
    cfg.paired[from] = nil
    saveConfig()
    log("computer #%d unpaired itself", from)
  end
  -- Drive messages come 4 times a second; answer those at most 4 times a second.
  if msg.t ~= "drive" or now() - (lastStatusTo[from] or 0) > 0.25 then sendStatus(from) end
end

local function netLoop()
  while true do
    local _, from, msg, proto = os.pullEvent("rednet_message")
    if proto == PROTOCOL and type(msg) == "table" and type(from) == "number" then
      local ok, err = pcall(handle, from, msg)
      if not ok then log("message from #%d failed: %s", from, tostring(err)) end
    end
  end
end

-- 20 times a second: time-outs, then the relays.
local function controlLoop()
  local lastL, lastR = "off", "off"
  while true do
    if drive and not driveActive() and (drive.f or drive.b or drive.l or drive.r) then
      log("no word from the controller for %.1f s - propellers stop", DRIVE_TIMEOUT)
      drive = nil
      statusDirty = true
    end
    if setup and now() - setup.at > SETUP_TIMEOUT then
      log("setup timed out")
      setup = nil
      statusDirty = true
    end
    local l, r = propStates()
    if l ~= lastL or r ~= lastR then
      log("propellers: left %s, right %s", l, r)
      lastL, lastR = l, r
      statusDirty = true
    end
    applyOutputs()
    if statusDirty then broadcastStatus() end
    sleep(0.05)
  end
end

-- Relays coming and going (a chunk loading, a modem clicked).
local function peripheralLoop()
  while true do
    local ev, name = os.pullEvent()
    if ev == "peripheral" or ev == "peripheral_detach" then
      local before = #relays
      scanHardware()
      for id in pairs(outNow) do
        local r = splitId(id)
        if r == name or not relaySet[r] then outNow[id] = nil end
      end
      if modemName and not rednet.isOpen(modemName) then pcall(rednet.open, modemName) end
      log("%s %s: %d relays now (was %d)", ev, tostring(name), #relays, before)
      statusDirty = true
    end
  end
end

-- ---------- screen ----------

local COLOR = term.isColor ~= nil and term.isColor() == true
local W, H = 51, 19
do
  local ok, w, h = pcall(term.getSize)
  if ok and type(w) == "number" then W, H = w, h or 19 end
end
local C = { bar = colors.blue, key = colors.yellow, head = colors.lightBlue, dim = colors.lightGray,
  good = colors.lime, bad = colors.red, warn = colors.orange }
local function fg(c) if COLOR then term.setTextColor(c) end end
local function bg(c) if COLOR then term.setBackgroundColor(c) end end

local buttons = {}
local function cursor()
  local ok, x, y = pcall(term.getCursorPos)
  if ok and type(x) == "number" then return x, y end
end

-- One line from pieces: "text" or { color, "text" }.
local function out(...)
  for _, part in ipairs({ ... }) do
    if type(part) == "table" then
      fg(part[1]) write(part[2]) fg(colors.white)
    else
      write(tostring(part))
    end
  end
  print("")
end

local function chip(x, y, k, label, char)
  term.setCursorPos(x, y)
  local text
  local rest = label ~= "" and (" " .. label) or ""
  if COLOR then
    bg(colors.gray) write(" ") fg(C.key) write(k) fg(colors.white) write(rest .. " ") bg(colors.black)
    text = " " .. k .. rest .. " "
  else
    text = "[" .. k .. rest .. "]"
    write(text)
  end
  buttons[#buttons + 1] = { x1 = x, x2 = x + #text - 1, y = y, char = char }
  return x + #text + 1
end

local function footer(items)
  term.setCursorPos(1, H)
  term.clearLine()
  local x = 2
  for _, it in ipairs(items) do x = chip(x, H, it[1], it[2], it[3]) end
end

local function short(id)
  local relay, side = splitId(id)
  relay = relay:gsub("^redstone_", "")
  return relay .. " " .. side
end

local function sidesText(list)
  if #list == 0 then return "-" end
  local t = {}
  for _, id in ipairs(list) do t[#t + 1] = short(id) end
  return table.concat(t, ", ")
end

local STATE_TEXT = { fwd = "forward", rev = "reverse", off = "off" }

local function draw()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  local linked = false
  for _, at in pairs(heard) do if now() - at < 3 then linked = true end end
  local left = " Relay Pilot - ship  #" .. os.getComputerID()
  local right = linked and " LINKED " or " WAITING "
  bg(C.bar) write(left .. string.rep(" ", math.max(1, W - #left - #right)))
  bg(linked and colors.green or colors.gray) write(right) bg(colors.black)
  term.setCursorPos(1, 3)

  out(" Pairing code  ", { C.key, cfg.code }, { C.dim, "  (type it on the controller: P)" })
  local ids = {}
  for id in pairs(cfg.paired) do ids[#ids + 1] = id end
  table.sort(ids)
  local ctl = {}
  for _, id in ipairs(ids) do
    local at = heard[id]
    ctl[#ctl + 1] = "#" .. id .. (at and string.format(" (%.0fs ago)", now() - at) or "")
  end
  out(" Controllers   ", #ctl > 0 and table.concat(ctl, ", ") or { C.dim, "none paired yet" })
  if not modemName then out({ C.bad, " No Ender Modem (or other wireless modem) found!" }) end
  print("")
  local s = upStrength(cfg.up)
  out(" Up speed      ", { C.key, string.format("%d", cfg.up) }, string.format("/%d", MAX_UP),
    #cfg.lift.sides > 0 and { C.dim, string.format("  strength %d on %s", s, sidesText(cfg.lift.sides)) }
      or { C.warn, "  lift sides not set up yet" })
  local l, r = propStates()
  local function st(v) return { v == "off" and C.dim or C.good, string.format("%-8s", STATE_TEXT[v]) } end
  out(" Propellers    left ", st(l), "  right ", st(r))
  if not propsReady() then out({ C.warn, "               not set up yet (controller menu S)" }) end
  out(" Bottom signal ", cfg.bottom and { C.good, "ON" } or { C.dim, "off" }, { C.dim, "  (" .. BOTTOM_SIDE .. " of this computer)" })
  out(" Relays        ", #relays > 0 and tostring(#relays) or { C.bad, "none found" })
  if setup then out({ C.warn, " Setup running from the controller" }) end
  if outError then out({ C.bad, " Relay error: " .. outError:sub(1, W - 15) }) end
  footer({ { "B", "Bottom", "b" }, { "-", "", "-" }, { "+", "", "+" }, { "S", "Stop", "s" },
    { "N", "Code", "n" }, { "U", "Unpair", "u" } })
end

local function uiLoop()
  local timer = os.startTimer(0)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then
      draw()
      timer = os.startTimer(0.5)
    elseif ev == "char" then
      local c = a:lower()
      if c == "b" then setBottom(not cfg.bottom, "ship computer")
      elseif c == "+" or c == "=" then setUp(cfg.up + 1, "ship computer")
      elseif c == "-" then setUp(cfg.up - 1, "ship computer")
      elseif c == "s" then
        drive = nil
        log("propellers stopped from the ship computer")
      elseif c == "n" then
        cfg.code = newCode()
        saveConfig()
        log("new pairing code")
      elseif c == "u" then
        cfg.paired = {}
        heard = {}
        saveConfig()
        log("unpaired every controller")
      end
      draw()
    end
  end
end

local function touchLoop()
  while true do
    local ev, _, x, y = os.pullEvent()
    if ev == "mouse_click" or ev == "monitor_touch" then
      for _, b in ipairs(buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then os.queueEvent("char", b.char) break end
      end
    end
  end
end

-- ---------- start ----------

if fs.exists(LOG_FILE) then
  if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
  fs.move(LOG_FILE, LOG_FILE .. ".old")
end
logFile = fs.open(LOG_FILE, "w")
log("Relay Pilot ship v%s, computer #%d", VERSION, os.getComputerID())
for _, name in ipairs(peripheral.getNames()) do log("peripheral %s: %s", name, tostring(peripheral.getType(name))) end
log("wireless modem: %s, relays: %d", tostring(modemName), #relays)
log("config: %s", (textutils.serialize(cfg):gsub("%s+", " "):gsub('key = "[^"]*"', 'key = "..."')))

-- Put everything back the way it was before any network traffic.
applyBottom()
applyOutputs()
if modemName then pcall(rednet.open, modemName) end

local ok, err = xpcall(function()
  parallel.waitForAny(netLoop, controlLoop, peripheralLoop, uiLoop, touchLoop)
end, debug.traceback)
log("stopped: %s", ok and "ok" or tostring(err))
-- Propellers off; the up speed and bottom signal stay so the ship doesn't drop.
drive, setup = nil, nil
pcall(applyOutputs)
if logFile then logFile.close() end
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
  print("Stopped: " .. tostring(err):match("^[^\n]*"))
  print("Details are in ship.log.")
end
print("Propellers off. Up speed still " .. cfg.up .. ", bottom signal " .. (cfg.bottom and "on" or "off") .. ".")
