-- Relay Pilot launcher. On boot it checks GitHub for a newer version of
-- this computer's program (ship.lua or controller.lua), downloads it if
-- there is one, then runs it.
--   startup              update, then run
--   startup ship         make this the ship computer
--   startup controller   make this the controller (typewriter) computer

local REPO = "levisnakes/cc-relay-pilot"
local ROLE_FILE = "relaypilot_role"

local function fetch(url)
  if not http then return nil end
  local ok, res = pcall(http.get, url)
  if not ok or not res then return nil end
  local body = res.readAll()
  res.close()
  return body
end

local function readFile(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end

local function writeFile(path, s)
  local h = fs.open(path .. ".new", "w")
  h.write(s)
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".new", path)
end

local args = { ... }
term.clear()
term.setCursorPos(1, 1)

-- Which computer is this?
local role = readFile(ROLE_FILE)
role = role and role:match("%a+")
if args[1] == "ship" or args[1] == "controller" then
  role = args[1]
  table.remove(args, 1)
  writeFile(ROLE_FILE, role)
end
if role ~= "ship" and role ~= "controller" then
  local hasTypewriter = peripheral.find("linked_typewriter") ~= nil
  print("Relay Pilot setup")
  print("")
  print("Which computer is this?")
  print("  S  the SHIP computer (wired to the relays)")
  print("  C  the CONTROLLER (has the Linked Typewriter)")
  if hasTypewriter then print("") print("(A typewriter is connected, so probably C.)") end
  print("")
  write("S or C: ")
  while role ~= "ship" and role ~= "controller" do
    local _, ch = os.pullEvent("char")
    ch = ch:lower()
    if ch == "s" then role = "ship" elseif ch == "c" then role = "controller" end
  end
  print(role)
  writeFile(ROLE_FILE, role)
  print("Saved. To change it: startup ship / startup controller")
  sleep(1)
end

local FILE = role .. ".lua"
local code = readFile(FILE)
local have = code and code:match('VERSION = "([^"]+)"')
print("Relay Pilot launcher - " .. role .. "  (installed: " .. (have and "v" .. have or "none") .. ")")

-- Ask the API for the newest commit and download from it: plain
-- raw.githubusercontent.com/.../main/ links can be up to 5 minutes stale.
local api = fetch("https://api.github.com/repos/" .. REPO .. "/commits/main")
local sha = api and api:match('"sha"%s*:%s*"(%x+)"')
local base = "https://raw.githubusercontent.com/" .. REPO .. "/" .. (sha or "main") .. "/"

-- Keep this launcher up to date too.
local me = shell.getRunningProgram()
local newMe = fetch(base .. "startup.lua")
if newMe and newMe:find("Relay Pilot launcher", 1, true) and newMe ~= readFile(me)
    and not _G.relayPilotLauncherUpdated then
  writeFile(me, newMe)
  print("Launcher updated - restarting it.")
  _G.relayPilotLauncherUpdated = true  -- only once, so it can't loop
  return shell.run(me, table.unpack(args))
end

local latest = fetch(base .. "version.txt")
latest = latest and latest:match("%S+")
if not latest then
  print("Couldn't reach GitHub - running the installed version.")
elseif latest == have then
  print("Up to date.")
else
  print("Downloading v" .. latest .. "...")
  local new = fetch(base .. FILE)
  -- Only replace the old file with a complete download of the right version.
  if new and new:match('VERSION = "([^"]+)"') == latest then
    writeFile(FILE, new)
    print("Updated to v" .. latest .. ".")
  else
    print("Download failed - running the installed version.")
  end
end

if not fs.exists(FILE) then
  print("No " .. FILE .. " yet. Check the internet connection and reboot.")
  return
end
print("")
shell.run(FILE, table.unpack(args))
