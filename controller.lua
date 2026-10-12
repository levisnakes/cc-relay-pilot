-- Relay Pilot: the CONTROLLER computer (the one with the Linked Typewriter).
--
-- Flies a ship whose propellers are all driven by Redstone Relays. The
-- ship has its own computer running ship.lua; the two talk over Ender
-- Modems, so this one can be anywhere.
--
-- Keys on the typewriter (change them in Keybinds):
--   W / S        both propellers forward / reverse (while held)
--   A / D        turn left / right (while held); with W or S it arcs
--   Space/Shift  up speed one step faster / slower (0-9, stays where set)
--   0-9          up speed straight to that level (if bound, see README)
--   Q            bottom signal off (press again: on)
--
-- Menu:
--   D  Drive
--   P  Pair with the ship (type the code its screen shows)
--   S  Propeller setup: which relay sides spin each propeller each way
--   L  Lift setup: which relay sides carry the up speed
--   T  Typewriter test     K  Keybinds
--
-- Everything is written to controller.log (the run before is kept as
-- controller.log.old).

VERSION = "1.0.1"

local PROTOCOL = "relaypilot"
local CONFIG_FILE = "controller.cfg"
local SEND_EVERY = 0.25     -- drive updates while keys are held (seconds)
local LINK_LOST = 2.5       -- no reply this long = no link

local ACTIONS = {
  { id = "forward", label = "Forward" },
  { id = "back",    label = "Backward" },
  { id = "left",    label = "Turn left" },
  { id = "right",   label = "Turn right" },
  { id = "up",      label = "Up faster" },
  { id = "down",    label = "Up slower" },
  { id = "bottom",  label = "Bottom signal" },
}
local DEFAULT_KEYS = { forward = "w", back = "s", left = "a", right = "d", up = "space", down = "leftShift", bottom = "q" }
local DIGIT_NAMES = { "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
local function now() return os.epoch("utc") / 1000 end

-- ---------- hardware ----------

local typewriter = peripheral.find("linked_typewriter")
local modemName = nil
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and not modemName then
    local ok, wireless = pcall(peripheral.call, name, "isWireless")
    if ok and wireless then modemName = name end
  end
end

-- ---------- log ----------
local LOG_FILE, LOG_LIMIT = "controller.log", 120000
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
  logFile.writeLine(line)
  logFile.flush()
end

-- ---------- saved setup ----------

local cfg
local function saveConfig()
  local h = fs.open(CONFIG_FILE, "w")
  h.write(textutils.serialize(cfg))
  h.close()
end
local function loadConfig()
  cfg = {}
  if fs.exists(CONFIG_FILE) then
    local h = fs.open(CONFIG_FILE, "r")
    local saved = textutils.unserialize(h.readAll() or "")
    h.close()
    if type(saved) == "table" then cfg = saved end
  end
  cfg.keys = type(cfg.keys) == "table" and cfg.keys or {}
  for id, name in pairs(DEFAULT_KEYS) do cfg.keys[id] = cfg.keys[id] or name end
end
loadConfig()

-- ---------- typewriter keys ----------

local twHeld = {}     -- keys held on the typewriter right now
local twSeen = {}     -- code -> when the typewriter last had it held
local lastHeldText, twError = nil, nil
local function pollTypewriter()
  local held = {}
  if typewriter then
    local ok, codes = pcall(typewriter.getPressedKeyCodes)
    if ok and type(codes) == "table" then
      local t = now()
      for _, c in ipairs(codes) do held[c], twSeen[c] = true, t end
    elseif not ok and tostring(codes) ~= twError then
      twError = tostring(codes)
      log("typewriter getPressedKeyCodes FAILED: %s", twError)
    end
  end
  twHeld = held
  local names = {}
  for c in pairs(held) do names[#names + 1] = (keys.getName(c) or "?") .. "(" .. c .. ")" end
  table.sort(names)
  local text = #names > 0 and table.concat(names, " ") or "-"
  if text ~= lastHeldText then
    lastHeldText = text
    log("typewriter keys: %s", text)
  end
end

-- Whether a key event came from the typewriter (the computer's own
-- keyboard sends the same events).
local function fromTypewriter(code)
  pollTypewriter()
  return twHeld[code] or (twSeen[code] ~= nil and now() - twSeen[code] < 0.5)
end

local function keyName(code)
  return (code and keys.getName(code)) or ("code " .. tostring(code))
end

local function down(action)
  local code = keys[cfg.keys[action]]
  return code ~= nil and twHeld[code] == true
end

local function actionFor(code)
  for _, act in ipairs(ACTIONS) do
    if keys[cfg.keys[act.id]] == code then return act.id end
  end
end

local function digitFor(code)
  for i, name in ipairs(DIGIT_NAMES) do
    if keys[name] ~= nil and keys[name] == code then return i - 1 end
  end
end

-- ---------- link to the ship ----------

local ship = nil          -- the ship's last status message
local lastReply = nil
local notPaired = false
local lastSent = 0

local function paired() return cfg.ship ~= nil and cfg.key ~= nil end
local function linked() return lastReply ~= nil and now() - lastReply < LINK_LOST end

local function send(msg)
  if not paired() or not modemName then return end
  msg.k = cfg.key
  lastSent = now()
  pcall(rednet.send, cfg.ship, msg, PROTOCOL)
end

local function upAdd(n)
  log("up %+d", n)
  send({ t = "up", add = n })
end
local function upSet(n)
  log("up = %d", n)
  send({ t = "up", set = n })
end
local function toggleBottom()
  -- Unknown (no reply yet) counts as on, so the first Q switches it off.
  local on = not (ship == nil or ship.bottom ~= false)
  log("bottom signal -> %s", on and "ON" or "off")
  send({ t = "bottom", on = on })
  if ship then ship.bottom = on end
end

local function netLoop()
  while true do
    local _, from, msg, proto = os.pullEvent("rednet_message")
    if proto == PROTOCOL and type(msg) == "table" and from == cfg.ship then
      if msg.t == "status" then
        if not linked() then log("link to ship #%d up", from) end
        ship, lastReply, notPaired = msg, now(), false
      elseif msg.t == "notPaired" then
        if not notPaired then log("ship #%d says this controller isn't paired", from) end
        notPaired, lastReply = true, nil
      end
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
local C = {
  bar = colors.blue, key = colors.yellow, head = colors.lightBlue, dim = colors.lightGray,
  good = colors.lime, bad = colors.red, warn = colors.orange,
}
local function fg(c) if COLOR then term.setTextColor(c) end end
local function bg(c) if COLOR then term.setBackgroundColor(c) end end

-- Tappable areas on the current screen: { x1, x2, y, char = , key = , event = }.
local buttons = {}
local tapAnywhere = false

local function cursor()
  local ok, x, y = pcall(term.getCursorPos)
  if ok and type(x) == "number" then return x, y end
end

-- Which key(s) a yellow key label stands for.
local function keysIn(text)
  if text == "Enter" then return { { key = keys.enter } } end
  if text:match("^%d%-%d$") then return {} end
  local list = {}
  for ch in text:gmatch("[^%s/]") do list[#list + 1] = { char = ch:lower() } end
  if #list > 1 and not text:find("/") then return {} end
  return list
end

-- One line from pieces: "text", { color, "text" } or a function that
-- draws. Yellow (key) pieces become buttons reaching to the end of the line.
local function out(...)
  local current = nil
  for _, part in ipairs({ ... }) do
    local x, y = cursor()
    if type(part) == "table" then
      fg(part[1]) write(part[2]) fg(colors.white)
      if part[1] == C.key and x then
        current = nil
        local ks = keysIn(part[2])
        if #ks == 1 then
          current = { x1 = x, x2 = x + #part[2] - 1, y = y, char = ks[1].char, key = ks[1].key }
          buttons[#buttons + 1] = current
        elseif #ks > 1 then
          local i = 0
          for c in part[2]:gmatch(".") do
            if c ~= " " and c ~= "/" then
              buttons[#buttons + 1] = { x1 = x + i, x2 = x + i, y = y, char = c:lower() }
            end
            i = i + 1
          end
        end
      elseif current and x then
        current.x2 = x + #part[2] - 1
      end
    elseif type(part) == "function" then
      current = nil
      part()
    else
      write(tostring(part))
      if current and x then current.x2 = x + #tostring(part) - 1 end
    end
  end
  print("")
end

local function hint(text) out({ C.dim, text }) end

-- A button: " K label " on a grey background.
-- action: { char = } or { key = } or { event = , value = }
local function chip(x, y, k, label, action, color)
  term.setCursorPos(x, y)
  local text = (k ~= "" and (" " .. k) or "") .. (label ~= "" and (" " .. label) or "") .. " "
  if COLOR then
    bg(color or colors.gray)
    write(" ")
    if k ~= "" then fg(C.key) write(k) fg(colors.white) end
    if label ~= "" then write((k ~= "" and " " or "") .. label) end
    write(" ")
    bg(colors.black)
  else
    text = "[" .. k .. (label ~= "" and ((k ~= "" and " " or "") .. label) or "") .. "]"
    write(text)
  end
  buttons[#buttons + 1] = { x1 = x, x2 = x + #text - 1, y = y,
    char = action and action.char, key = action and action.key,
    event = action and action.event, value = action and action.value }
  return x + #text + 1
end

local function footer(items)
  local cx, cy = cursor()
  term.setCursorPos(1, H)
  bg(colors.black)
  term.clearLine()
  local x = 2
  for _, it in ipairs(items) do
    if it[3] then x = chip(x, H, it[1], it[2], it[3]) else
      term.setCursorPos(x, H) fg(C.dim) write(it[2]) fg(colors.white)
      x = x + #it[2] + 1
    end
  end
  if cx then term.setCursorPos(cx, cy) end
end

local function tile(x, y, w, k, title, desc, odd)
  if COLOR then
    bg(odd and colors.blue or colors.gray)
    for row = y, y + 1 do term.setCursorPos(x, row) write(string.rep(" ", w)) end
    term.setCursorPos(x + 1, y) fg(C.key) write(k) fg(colors.white) write("  " .. title)
    term.setCursorPos(x + 1, y + 1) fg(colors.lightGray) write(desc:sub(1, w - 2))
    fg(colors.white) bg(colors.black)
  else
    term.setCursorPos(x, y) write("[" .. k .. "] " .. title)
    term.setCursorPos(x + 1, y + 1) write(desc:sub(1, w - 2))
  end
  buttons[#buttons + 1] = { x1 = x, x2 = x + w - 1, y1 = y, y2 = y + 1, char = k:lower() }
end

local function linkBadge()
  if not paired() then return "NOT PAIRED", colors.gray end
  if notPaired then return "PAIR AGAIN", colors.red end
  if linked() then return "LINKED", colors.green end
  return "NO SHIP", colors.red
end

local currentScreen = nil
local function screen(title)
  buttons = {}
  if title ~= currentScreen then
    currentScreen = title
    log("screen: %s", title)
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  local badge, bcol = linkBadge()
  local left = COLOR and (" Relay Pilot  \16 " .. title) or (" Relay Pilot > " .. title)
  local right = COLOR and (" " .. badge .. " ") or ("[" .. badge .. "]")
  bg(C.bar)
  write(left .. string.rep(" ", math.max(1, W - #left - #right)))
  bg(bcol) fg(colors.white) write(right)
  bg(colors.black)
  term.setCursorPos(1, 3)
end

-- Waits for one of the allowed chars (or Enter, as "\n"); redraws every
-- `every` seconds by returning nil.
local function waitInput(allowed, every)
  local timer = every and os.startTimer(every)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then return nil end
    if ev == "char" then
      local ch = a:lower()
      if not allowed or allowed:find(ch, 1, true) then
        if timer then os.cancelTimer(timer) end
        return ch
      end
    elseif ev == "key" and a == keys.enter and allowed and allowed:find("\n", 1, true) then
      if timer then os.cancelTimer(timer) end
      return "\n"
    end
  end
end

local function pause(msg)
  print("")
  hint(msg or " Press any key (or tap).")
  tapAnywhere = true
  os.pullEvent("char")
  tapAnywhere = false
end

local STATE_TEXT = { fwd = "forward", rev = "reverse", off = "off" }
local STATE_ICON = { fwd = "\30 ", rev = "\31 ", off = "- " }

local function splitId(id) return id:match("^(.*):(%a+)$") end
local function short(id)
  local relay, side = splitId(id)
  if not relay then return tostring(id) end
  return relay:gsub("^redstone_", "") .. " " .. side
end
local function sidesText(list)
  if not list or #list == 0 then return "-" end
  local t = {}
  for _, id in ipairs(list) do t[#t + 1] = short(id) end
  return table.concat(t, ", ")
end

local function propsReady()
  local p = ship and ship.props
  return p ~= nil and p.L ~= nil and p.R ~= nil and (#p.L.fwd + #p.L.rev + #p.R.fwd + #p.R.rev) > 0
end
local function liftReady()
  return ship ~= nil and ship.lift ~= nil and #ship.lift.sides > 0
end

-- Why there's no ship to talk to, or nil.
local function linkProblem()
  if not modemName then return "No Ender Modem on this computer." end
  if not paired() then return "Not paired with a ship yet: menu P." end
  if notPaired then return "Ship #" .. cfg.ship .. " forgot this controller: pair again (P)." end
  if not linked() then
    return string.format("No reply from ship #%d%s.", cfg.ship,
      lastReply and string.format(" for %ds", math.floor(now() - lastReply)) or "")
  end
end

-- A full-screen "connect first" notice; true if there's a link.
local function needLink(title)
  if linked() and ship then return true end
  screen(title)
  out({ C.warn, " " .. (linkProblem() or "Waiting for the ship...") })
  print("")
  hint(" The ship computer has to be running, with its chunk")
  hint(" loaded and an Ender Modem.")
  pause()
  return false
end

-- ---------- Drive ----------

local function upBar(y, level, max)
  term.setCursorPos(2, y)
  write("Up speed  ") fg(C.key) write(string.format("%d", level)) fg(colors.white)
  local cx = chip(14, y, "-", "", { char = "-" })
  for i = 1, max do
    local x = cx + (i - 1) * 2
    term.setCursorPos(x, y)
    if COLOR then
      bg(i <= level and C.good or colors.gray) write(" ") bg(colors.black) write(" ")
    else
      write(i <= level and "#" or "-") write(" ")
    end
    buttons[#buttons + 1] = { x1 = x, x2 = x + 1, y = y, event = "up_set", value = i }
  end
  chip(cx + max * 2, y, "+", "", { char = "+" })
  term.setCursorPos(1, y + 1)
end

local function driveScreen()
  local timer = os.startTimer(0)
  while true do
    local ev, a = os.pullEvent()
    if ev == "char" then
      local c = a:lower()
      if c == "m" then break
      elseif c == "+" or c == "=" then upAdd(1)
      elseif c == "-" then upAdd(-1) end
    elseif ev == "up_set" and type(a) == "number" then
      upSet(a)
    elseif ev == "timer" and a == timer then
      screen("Drive")
      local names = {}
      for _, act in ipairs(ACTIONS) do
        if (act.id == "forward" or act.id == "back" or act.id == "left" or act.id == "right") and down(act.id) then
          names[#names + 1] = act.label
        end
      end
      out(" Keys      ", #names > 0 and { C.key, table.concat(names, ", ") } or { C.dim, "none held" })
      local l, r = ship and ship.left or "off", ship and ship.right or "off"
      local function st(v) return { v == "off" and C.dim or C.good, STATE_ICON[v] .. string.format("%-8s", STATE_TEXT[v]) } end
      out(" Props     left ", st(l), "   right ", st(r))
      print("")
      local max = ship and ship.max or 9
      local _, y = cursor()
      upBar(y or 6, ship and ship.up or 0, max)
      local on = not ship or ship.bottom ~= false
      out(" Bottom    ", on and { C.good, "ON " } or { C.warn, "OFF" },
        { C.dim, string.format("   press %s to switch it %s", #cfg.keys.bottom == 1 and cfg.keys.bottom:upper() or cfg.keys.bottom,
          on and "off" or "on") })
      print("")
      local msgs = {}
      local problem = linkProblem()
      if problem then msgs[#msgs + 1] = { { C.bad, " " .. problem } }
      else
        msgs[#msgs + 1] = { { C.dim, string.format(" Ship #%d%s  reply %.1fs ago", cfg.ship,
          ship.label and (" " .. ship.label) or "", now() - lastReply) } }
        if not propsReady() then msgs[#msgs + 1] = { { C.warn, " Propellers aren't set up yet: menu S." } } end
        if not liftReady() then msgs[#msgs + 1] = { { C.warn, " Up speed isn't wired to a relay yet: menu L." } } end
        if ship.setup then msgs[#msgs + 1] = { { C.warn, " The ship is in setup mode." } } end
        if ship.err then msgs[#msgs + 1] = { { C.bad, " Relay error: " .. tostring(ship.err):sub(1, W - 15) } } end
      end
      if not typewriter then msgs[#msgs + 1] = { { C.bad, " No Linked Typewriter on this computer's network." } } end
      if not cfg.bottomKeySeen then
        msgs[#msgs + 1] = { { C.dim, " Bind Q (and 0-9) to a link frequency on the" } }
        msgs[#msgs + 1] = { { C.dim, " typewriter (sneak + right-click it)." } }
      end
      for i = 1, math.min(#msgs, 6) do out(table.unpack(msgs[i])) end
      footer({ { "M", "Menu", { char = "m" } }, { "-", "Slower", { char = "-" } }, { "+", "Faster", { char = "+" } },
        { cfg.keys.bottom:upper():sub(1, 5), "Bottom", { event = "bottom_toggle" } } })
      timer = os.startTimer(0.1)
    elseif ev == "bottom_toggle" then
      toggleBottom()
    end
  end
end

-- ---------- Pair ----------

local function pairScreen()
  local code, msg, msgCol = "", nil, C.dim
  while true do
    screen("Pair")
    if paired() then
      out(" Paired with ship ", { C.head, "#" .. cfg.ship }, cfg.shipLabel and (" " .. cfg.shipLabel) or "",
        linked() and { C.good, "  linked" } or { C.warn, "  no reply" })
      print("")
    end
    out(" Type the 4-digit code from the ", { C.head, "ship computer" }, ".")
    hint(" The code changes after every pairing.")
    print("")
    out(" Code   ", { C.key, (code .. "____"):sub(1, 4) })
    print("")
    -- Keypad
    local _, y = cursor()
    y = y or 9
    local x = 4
    for d = 1, 9 do x = chip(x, y, tostring(d), "", { char = tostring(d) }) end
    x = chip(x, y, "0", "", { char = "0" })
    chip(4, y + 1, "", "Del", { key = keys.backspace })
    chip(12, y + 1, "", "Enter", { key = keys.enter })
    term.setCursorPos(1, y + 3)
    if msg then out({ msgCol, " " .. msg }) end
    local items = { { "Q", "Back", { char = "q" } } }
    if paired() then items[#items + 1] = { "F", "Forget this ship", { char = "f" } } end
    footer(items)

    local ev, a = os.pullEvent()
    if ev == "char" then
      local c = a:lower()
      if c == "q" then return end
      if c:match("%d") and #code < 4 then code = code .. c end
      if c == "f" and paired() then
        send({ t = "unpair" })
        log("forgot ship #%d", cfg.ship)
        cfg.ship, cfg.key, cfg.shipLabel = nil, nil, nil
        saveConfig()
        ship, lastReply = nil, nil
        msg, msgCol = "Forgot the ship.", C.dim
      end
    elseif ev == "key" and a == keys.backspace then
      code = code:sub(1, -2)
    elseif ev == "key" and (a == keys.enter or a == keys.numPadEnter) then
      if #code < 4 then
        msg, msgCol = "The code has 4 digits.", C.warn
      elseif not modemName then
        msg, msgCol = "No Ender Modem on this computer.", C.bad
      else
        screen("Pair")
        out(" Looking for the ship with code ", { C.key, code }, "...")
        log("pairing with code %s", code)
        pcall(rednet.broadcast, { t = "pair", code = code }, PROTOCOL)
        local timer = os.startTimer(3)
        local result = nil
        while not result do
          local e, from, m, proto = os.pullEvent()
          if e == "timer" and from == timer then
            result = { ok = false, why = "No ship answered. Check the code and that the ship computer is running." }
          elseif e == "rednet_message" and proto == PROTOCOL and type(m) == "table" then
            if m.t == "paired" and type(m.key) == "string" then
              result = { ok = true, from = from, m = m }
            elseif m.t == "pairFail" then
              result = { ok = false, why = "Ship #" .. from .. ": " .. tostring(m.why) }
            end
          end
        end
        os.cancelTimer(timer)
        if result.ok then
          cfg.ship, cfg.key, cfg.shipLabel = result.from, result.m.key, result.m.label
          saveConfig()
          ship, lastReply, notPaired = nil, nil, false
          log("paired with ship #%d", cfg.ship)
          send({ t = "hello" })
          msg, msgCol = "Paired with ship #" .. cfg.ship .. ".", C.good
        else
          log("pairing failed: %s", result.why)
          msg, msgCol = result.why, C.bad
        end
        code = ""
      end
    end
  end
end

-- ---------- setup helpers ----------

local function contains(list, id)
  for _, x in ipairs(list or {}) do if x == id then return true end end
  return false
end

-- The ship's relay sides minus `skip` (a set), 9 to a page.
local function choices(skip)
  local list = {}
  for _, id in ipairs(ship.outputs or {}) do
    if not skip[id] then list[#list + 1] = id end
  end
  return list
end

local function pageOf(list, page)
  local pages = math.max(1, math.ceil(#list / 9))
  page = clamp(page, 1, pages)
  local first = (page - 1) * 9
  local items = {}
  for i = 1, 9 do
    if list[first + i] then items[i] = list[first + i] end
  end
  return items, page, pages
end

-- ---------- Propeller setup ----------

local STEPS = {
  { prop = "L", dir = "fwd", text = "LEFT propeller pushing FORWARD" },
  { prop = "L", dir = "rev", text = "LEFT propeller pushing BACKWARD" },
  { prop = "R", dir = "fwd", text = "RIGHT propeller pushing FORWARD" },
  { prop = "R", dir = "rev", text = "RIGHT propeller pushing BACKWARD" },
}

local function copyProps(p)
  local c = {}
  for _, k in ipairs({ "L", "R" }) do
    local m = p and p[k] or {}
    c[k] = { fwd = {}, rev = {} }
    for _, d in ipairs({ "fwd", "rev" }) do
      for _, id in ipairs(m[d] or {}) do c[k][d][#c[k][d] + 1] = id end
    end
  end
  return c
end

local function propWarnings(p)
  local w = {}
  local function overlap(a, b)
    for _, id in ipairs(a) do if contains(b, id) then return id end end
  end
  for _, k in ipairs({ "L", "R" }) do
    local name = k == "L" and "Left" or "Right"
    local o = overlap(p[k].fwd, p[k].rev)
    if o then w[#w + 1] = name .. " forward and backward both use " .. short(o) end
    if #p[k].fwd == 0 then w[#w + 1] = name .. " forward isn't set." end
    if #p[k].rev == 0 then w[#w + 1] = name .. " backward isn't set." end
  end
  local all = {}
  for _, d in ipairs({ "fwd", "rev" }) do for _, id in ipairs(p.L[d]) do all[#all + 1] = id end end
  for _, d in ipairs({ "fwd", "rev" }) do
    local o = overlap(p.R[d], all)
    if o then w[#w + 1] = "Both propellers use " .. short(o) end
  end
  return w
end

local function propSummary(p)
  while true do
    screen("Propeller setup")
    out(" Saved on the ship:")
    print("")
    out(" Left   forward  ", { C.head, sidesText(p.L.fwd) })
    out("        backward ", { C.head, sidesText(p.L.rev) })
    out(" Right  forward  ", { C.head, sidesText(p.R.fwd) })
    out("        backward ", { C.head, sidesText(p.R.rev) })
    print("")
    for _, w in ipairs(propWarnings(p)) do out({ C.warn, " " .. w }) end
    hint(" Try it in Drive: W forward, A turns left. If A")
    hint(" turns right, swap the propellers (X).")
    footer({ { "X", "Swap left/right", { char = "x" } }, { "Q", "Done", { char = "q" } } })
    local ch = waitInput("xq", 1)
    if ch == "q" then return end
    if ch == "x" then
      p.L, p.R = p.R, p.L
      send({ t = "saveProps", props = p })
      log("propellers swapped")
    end
  end
end

local function propellerSetup()
  if not needLink("Propeller setup") then return end
  local p = copyProps(ship.props)
  local skip = {}
  for _, id in ipairs(ship.lift and ship.lift.sides or {}) do skip[id] = true end
  local list = choices(skip)
  if #list == 0 then
    screen("Propeller setup")
    out({ C.bad, " The ship has no Redstone Relays (or they're all" })
    out({ C.bad, " used by the up speed)." })
    pause()
    return
  end

  local stepN, page, lastPush = 1, 1, 0
  local on = {}
  local function startStep()
    on = {}
    for _, id in ipairs(p[STEPS[stepN].prop][STEPS[stepN].dir]) do on[id] = true end
    page = 1
  end
  local function push()
    local sides = {}
    for _, id in ipairs(list) do sides[id] = on[id] and 15 or 0 end
    send({ t = "setup", sides = sides })
    lastPush = now()
  end
  startStep()
  push()
  local finished = false
  while true do
    local step = STEPS[stepN]
    screen("Propeller setup")
    out(" Step ", { C.head, stepN .. " of 4" }, ": ", { C.head, step.text })
    hint(" Switch relay sides on until it does just that.")
    hint(" Watch the ship; the up speed keeps running.")
    print("")
    local items, pg, pages = pageOf(list, page)
    page = pg
    for i = 1, 9 do
      if items[i] then
        local id = items[i]
        out(" ", { C.key, tostring(i) }, string.format("  %-22s ", short(id)), on[id] and { C.good, "ON" } or { C.dim, "off" })
      end
    end
    term.setCursorPos(1, H - 2)
    if pages > 1 then out(" Page ", { C.head, page .. "/" .. pages }, "  ", { C.key, "N/P" }, " next/previous") end
    if linkProblem() then out({ C.bad, " " .. linkProblem() }) end
    footer({ { "Enter", "Save step", { key = keys.enter } }, { "K", "Skip", { char = "k" } },
      { "C", "All off", { char = "c" } }, { "Q", "Cancel", { char = "q" } } })

    local ch = waitInput("123456789npkcq\n", 0.5)
    if ch == nil then
      if now() - lastPush >= 0.5 then push() end
    else
      local n = tonumber(ch)
      if n and items[n] then
        on[items[n]] = not on[items[n]]
        push()
      elseif ch == "n" then page = page + 1
      elseif ch == "p" then page = page - 1
      elseif ch == "c" then on = {} push()
      elseif ch == "q" then break
      elseif ch == "\n" or ch == "k" then
        if ch == "\n" then
          local sel = {}
          for _, id in ipairs(list) do if on[id] then sel[#sel + 1] = id end end
          p[step.prop][step.dir] = sel
          log("propeller step %s %s = %s", step.prop, step.dir, sidesText(sel))
        end
        if stepN == 4 then finished = true break end
        stepN = stepN + 1
        startStep()
        push()
      end
    end
  end
  send({ t = "setup", done = true })
  if finished then
    send({ t = "saveProps", props = p })
    log("propellers saved")
    propSummary(p)
  end
end

-- ---------- Lift setup ----------

local function liftSetup()
  if not needLink("Lift setup") then return end
  local skip = {}
  for _, k in ipairs({ "L", "R" }) do
    for _, d in ipairs({ "fwd", "rev" }) do
      for _, id in ipairs(ship.props and ship.props[k] and ship.props[k][d] or {}) do skip[id] = true end
    end
  end
  local list = choices(skip)
  local page = 1
  while true do
    screen("Lift setup")
    if not ship then pause() return end
    local sides = ship.lift and ship.lift.sides or {}
    local stretch = ship.lift and ship.lift.stretch
    out(" Pick the relay side(s) that carry the ", { C.head, "up speed" }, ".")
    out(" Up speed ", { C.key, tostring(ship.up) }, string.format("/%d", ship.max or 9),
      { C.dim, "  (+/- to test it, live)" })
    print("")
    local items, pg, pages = pageOf(list, page)
    page = pg
    for i = 1, 9 do
      if items[i] then
        local id = items[i]
        local used = contains(sides, id)
        local strength = ship.on and ship.on[id] or 0
        out(" ", { C.key, tostring(i) }, string.format("  %-22s ", short(id)),
          used and { C.good, "up speed" } or { C.dim, "-       " },
          { C.dim, string.format("   strength %d", strength) })
      end
    end
    if #list == 0 then out({ C.bad, " The ship has no free relay sides." }) end
    term.setCursorPos(1, H - 3)
    out(" Signal  ", stretch and { C.head, "stretched: 9 = strength 15" } or { C.head, "as is: 9 = strength 9" },
      "  ", { C.key, "X" }, " change")
    if pages > 1 then out(" Page ", { C.head, page .. "/" .. pages }, "  ", { C.key, "N/P" }, " next/previous") end
    if linkProblem() then out({ C.bad, " " .. linkProblem() }) end
    footer({ { "-", "", { char = "-" } }, { "+", "", { char = "+" } }, { "Q", "Done", { char = "q" } } })

    local ch = waitInput("123456789npxq+-=", 0.5)
    local n = ch and tonumber(ch)
    if ch == "q" then return
    elseif n and items[n] then
      local new = {}
      local id = items[n]
      for _, x in ipairs(sides) do if x ~= id then new[#new + 1] = x end end
      if not contains(sides, id) then new[#new + 1] = id end
      send({ t = "saveLift", sides = new, stretch = stretch })
      log("lift sides = %s", sidesText(new))
    elseif ch == "x" then
      send({ t = "saveLift", sides = sides, stretch = not stretch })
    elseif ch == "+" or ch == "=" then upAdd(1)
    elseif ch == "-" then upAdd(-1)
    elseif ch == "n" then page = page + 1
    elseif ch == "p" then page = page - 1 end
  end
end

-- ---------- Typewriter test and Keybinds ----------

local function typewriterTest()
  local lastKey = nil
  while true do
    screen("Typewriter test")
    out(" Press keys on the ", { C.head, "typewriter" }, ".")
    print("")
    if lastKey then
      out(" Last key  ", { C.head, keyName(lastKey.code) }, { C.dim, string.format("  (code %d)", lastKey.code) })
      out(" From      ", { lastKey.from == "typewriter" and C.good or C.warn, lastKey.from })
      local act = actionFor(lastKey.code)
      local label = nil
      for _, a in ipairs(ACTIONS) do if a.id == act then label = a.label end end
      local digit = digitFor(lastKey.code)
      out(" Does      ", label or (digit and ("up speed " .. digit)) or { C.dim, "nothing (not bound)" })
    else
      out(" Last key  ", { C.dim, "none yet" })
    end
    local heldNames = {}
    for c in pairs(twHeld) do heldNames[#heldNames + 1] = keyName(c) end
    table.sort(heldNames)
    out(" Held now  ", #heldNames > 0 and { C.head, table.concat(heldNames, " ") } or { C.dim, "-" })
    print("")
    hint(" Keys from the computer keyboard show orange.")
    hint(" Nothing here reaches the ship.")
    print("")
    hint(" Only keys bound to a link frequency arrive: W A S D,")
    hint(" Space and Shift come bound. Bind Q (and 0-9) by")
    hint(" sneak + right-clicking the typewriter.")
    footer({ { "Q", "Back", { char = "q" } } })
    local timer = os.startTimer(0.25)
    local ev, a = os.pullEvent()
    if ev == "key" then
      lastKey = { code = a, from = fromTypewriter(a) and "typewriter" or "computer keyboard" }
      log("key event %s (%d) from %s", keyName(a), a, lastKey.from)
    elseif ev == "char" and a:lower() == "q" and not (lastKey and lastKey.code == keys.q and lastKey.from == "typewriter"
        and fromTypewriter(keys.q)) then
      os.cancelTimer(timer)
      return
    end
    os.cancelTimer(timer)
  end
end

local function keybinds()
  while true do
    screen("Keybinds")
    for i, act in ipairs(ACTIONS) do
      out(" ", { C.key, tostring(i) }, string.format("  %-14s ", act.label), { C.head, cfg.keys[act.id] })
    end
    out(" -  ", string.format("%-14s ", "Up speed 0-9"), { C.head, "zero ... nine" })
    print("")
    hint(" Tap an action (or press 1-7) to change its key.")
    footer({ { "R", "Reset to defaults", { char = "r" } }, { "Q", "Back", { char = "q" } } })
    local ch = waitInput("1234567rq")
    if ch == "q" then return end
    if ch == "r" then
      for id, name in pairs(DEFAULT_KEYS) do cfg.keys[id] = name end
      saveConfig()
    elseif ch then
      local act = ACTIONS[tonumber(ch)]
      screen("Keybinds")
      out(" Press the new key for ", { C.head, act.label })
      out(" on the ", { C.head, "typewriter" }, ".")
      print("")
      hint(" The typewriter only passes on keys bound to a")
      hint(" Redstone Link frequency (W A S D, Space and Shift")
      hint(" come bound).")
      footer({ { "Q", "Cancel", { char = "q" } } })
      while true do
        local ev, a = os.pullEvent()
        if ev == "char" and a:lower() == "q" and not fromTypewriter(keys.q) then break end
        if ev == "key" then
          if fromTypewriter(a) and keys.getName(a) then
            local name = keys.getName(a)
            for id, k in pairs(cfg.keys) do
              if k == name and id ~= act.id then cfg.keys[id] = cfg.keys[act.id] end
            end
            cfg.keys[act.id] = name
            saveConfig()
            log("key for %s = %s", act.id, name)
            break
          elseif a ~= keys.q then
            local _, y = cursor()
            term.setCursorPos(1, (y or 10))
            out({ C.warn, " That was the computer keyboard; press it on the" })
            out({ C.warn, " typewriter." })
          end
        end
      end
    end
  end
end

-- ---------- Menu ----------

local function menu()
  while true do
    screen("Menu")
    if paired() then
      out(" Ship     ", { C.head, "#" .. cfg.ship }, cfg.shipLabel and (" " .. cfg.shipLabel) or "",
        linked() and { C.good, "  linked" } or { C.bad, notPaired and "  forgot this controller: pair again" or "  no reply" })
    else
      out(" Ship     ", { C.warn, "not paired: press P" })
    end
    if ship and linked() then
      out(" Up speed ", { C.head, ship.up .. "/" .. (ship.max or 9) }, "   Bottom ",
        ship.bottom and { C.good, "ON" } or { C.warn, "OFF" },
        "   Props ", propsReady() and { C.good, "set up" } or { C.warn, "not set up" },
        "   Lift ", liftReady() and { C.good, "set up" } or { C.warn, "not set up" })
    else
      print("")
    end
    if not typewriter then out({ C.bad, " No Linked Typewriter found on this computer." }) else print("") end
    local cw = math.floor((W - 3) / 2)
    local tiles = {
      { "D", "Drive", "fly the ship" },
      { "P", "Pair", "link to the ship" },
      { "S", "Propeller setup", "sides for each prop" },
      { "L", "Lift setup", "sides for up speed" },
      { "T", "Typewriter test", "see which keys arrive" },
      { "K", "Keybinds", "change the keys" },
    }
    for i, t in ipairs(tiles) do
      local col = (i - 1) % 2
      local row = math.floor((i - 1) / 2)
      tile(2 + col * (cw + 1), 7 + row * 3, cw, t[1], t[2], t[3], (row + col) % 2 == 1)
    end
    term.setCursorPos(1, 16)
    hint(" Space/Shift on the typewriter change the up speed")
    hint(" and Q the bottom signal from any screen.")
    footer({ { "", "v" .. VERSION } })
    local ch = waitInput("dpslkt", 0.5)
    if ch == "d" then driveScreen()
    elseif ch == "p" then pairScreen()
    elseif ch == "s" then propellerSetup()
    elseif ch == "l" then liftSetup()
    elseif ch == "t" then typewriterTest()
    elseif ch == "k" then keybinds() end
  end
end

-- ---------- background loops ----------

-- Up speed, digits and the bottom signal: one step per key press, from the
-- typewriter on any screen (and the keyboard on the Drive screen). A key
-- is ignored until it's let go, so held keys and repeats don't run away.
local latched = {}
local QUIET_SCREENS = { ["Typewriter test"] = true, ["Keybinds"] = true }
local function keyLoop()
  while true do
    local ev, code = os.pullEvent()
    if ev == "key" and not latched[code] and not QUIET_SCREENS[currentScreen] then
      local tw = fromTypewriter(code)
      if tw or currentScreen == "Drive" then
        local act = actionFor(code)
        local digit = digitFor(code)
        if act == "up" or act == "down" or act == "bottom" or digit then
          latched[code] = { at = now(), tw = tw }
          if act == "up" then upAdd(1)
          elseif act == "down" then upAdd(-1)
          elseif act == "bottom" then
            toggleBottom()
            if tw and not cfg.bottomKeySeen then
              cfg.bottomKeySeen = true
              saveConfig()
            end
          else
            upSet(digit)
          end
        end
      end
    elseif ev == "key_up" then
      latched[code] = nil
    end
  end
end

-- 20 times a second: read the typewriter, send what's held while driving,
-- and keep the link alive.
local function pollLoop()
  local lastText, lastDriveSend = nil, 0
  while true do
    pollTypewriter()
    local t = now()
    -- A typewriter latch whose key_up never came: clear it once let go.
    for code, l in pairs(latched) do
      if l.tw and not twHeld[code] and t - l.at > 0.5 then latched[code] = nil end
    end
    if paired() then
      if currentScreen == "Drive" then
        local f, b, l, r = down("forward"), down("back"), down("left"), down("right")
        local text = (f and "W" or "") .. (l and "A" or "") .. (b and "S" or "") .. (r and "D" or "")
        local any = text ~= ""
        if text ~= lastText or (any and t - lastDriveSend >= SEND_EVERY) or t - lastDriveSend >= 1 then
          if text ~= lastText then log("drive %s", any and text or "none") end
          lastText, lastDriveSend = text, t
          send({ t = "drive", f = f, b = b, l = l, r = r })
        end
      else
        if lastText ~= nil and lastText ~= "" then
          send({ t = "drive" })   -- left the Drive screen: everything off
          log("drive none (left Drive)")
        end
        lastText = nil
        if t - lastSent >= 1 then send({ t = "hello" }) end
      end
    end
    sleep(0.05)
  end
end

local function touchLoop()
  while true do
    local ev, _, x, y = os.pullEvent()
    if ev == "mouse_click" or ev == "monitor_touch" then
      local hit = nil
      for _, b in ipairs(buttons) do
        if y >= (b.y1 or b.y) and y <= (b.y2 or b.y) and x >= b.x1 and x <= b.x2 then hit = b break end
      end
      if hit then
        log("tap %d,%d -> %s", x, y, tostring(hit.char or hit.event or hit.key))
        if hit.event then os.queueEvent(hit.event, hit.value)
        elseif hit.key then os.queueEvent("key", hit.key, false) os.queueEvent("key_up", hit.key)
        elseif hit.char then os.queueEvent("char", hit.char) end
      elseif tapAnywhere then
        os.queueEvent("char", " ")
      end
    end
  end
end

-- An Advanced Monitor, if there is one big enough, shows the same screens.
local function mirrorToMonitor()
  local m = peripheral.find("monitor", function(_, p) return p.isColor and p.isColor() end)
  if not m then return end
  local fits = false
  for _, scale in ipairs({ 1, 0.5 }) do
    m.setTextScale(scale)
    local mw, mh = m.getSize()
    if mw >= W and mh >= H then fits = true break end
  end
  if not fits then log("monitor too small for the screens, not used") return end
  m.setBackgroundColor(colors.black)
  m.clear()
  local native = term.current()
  local both = {}
  for k, f in pairs(native) do
    if type(f) == "function" then
      both[k] = function(...)
        pcall(m[k], ...)
        return f(...)
      end
    end
  end
  both.getSize = native.getSize
  both.isColor = native.isColor
  both.isColour = native.isColour
  term.redirect(both)
  log("mirroring to a %dx%d monitor", m.getSize())
end

local args = { ... }
local function ui()
  if args[1] == "drive" then driveScreen() end
  menu()
end

-- ---------- start ----------

if fs.exists(LOG_FILE) then
  if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
  fs.move(LOG_FILE, LOG_FILE .. ".old")
end
logFile = fs.open(LOG_FILE, "w")
log("Relay Pilot controller v%s, computer #%d", VERSION, os.getComputerID())
for _, name in ipairs(peripheral.getNames()) do log("peripheral %s: %s", name, tostring(peripheral.getType(name))) end
log("wireless modem: %s, typewriter: %s, ship: %s", tostring(modemName), typewriter and "yes" or "no", tostring(cfg.ship))
log("keys: %s", textutils.serialize(cfg.keys):gsub("%s+", " "))

if modemName then pcall(rednet.open, modemName) end
pcall(mirrorToMonitor)
if paired() then send({ t = "hello" }) end

local ok, err = xpcall(function()
  parallel.waitForAny(ui, netLoop, keyLoop, pollLoop, touchLoop)
end, debug.traceback)
log("stopped: %s", ok and "ok" or tostring(err))
-- Propellers off on the way out (the ship would stop them in a second anyway).
pcall(send, { t = "drive" })
if logFile then logFile.close() end
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
  print("Stopped: " .. tostring(err):match("^[^\n]*"))
  print("Details are in controller.log.")
end
