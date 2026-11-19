-- Portaxi bootstrap: namespace, internal event bus, API resolver, SavedVariables defaults, /ptx.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Init". Owned by the architect.

local ADDON, ns = ...
ns.ADDON = ADDON
ns.VERSION = "0.3.0"

function ns.say(msg)
  print("|cffffd100Portaxi|r " .. tostring(msg))
end
local say = ns.say

-- API resolver ---------------------------------------------------------------

-- Resolves "A.B.C" against _G without erroring on missing tables.
local function resolve(path)
  local t = _G
  for part in path:gmatch("[^%.]+") do
    if type(t) ~= "table" then
      return nil
    end
    t = t[part]
  end
  return t
end

-- Returns the first function found among the given API paths (D4), or nil.
function ns.api(...)
  for i = 1, select("#", ...) do
    local f = resolve((select(i, ...)))
    if type(f) == "function" then
      return f
    end
  end
end

function ns.hasApi(path)
  return resolve(path) ~= nil
end

-- Player keys (D5). Forever has no realms: a character has a first name and a surname, and only the pair
-- is unique (first names repeat). Name parts never contain a space or a dash. The key is "First Surname":
-- the same form as addon message senders and GetUnitName(unit, true); UnitName(unit) returns the two
-- parts (/ptx diag, 2026-11-18). A source that gives only a first name yields a first-name-only key.

-- "Varekhal Stonefel", "Varekhal-Stonefel", " Varekhal  Stonefel " -> "Varekhal Stonefel"; "Varekhal" stays.
function ns.playerKey(sender)
  if type(sender) ~= "string" then
    return nil
  end
  local first, surname = sender:match("^%s*([^%s%-]+)[%s%-]+([^%s%-]+)")
  if first then
    return first .. " " .. surname
  end
  return sender:match("^%s*([^%s%-]+)")
end

-- The key of a unit token ("player", "party1", "target", "NPC"), or nil.
function ns.unitKey(unit)
  local first, surname = UnitName(unit)
  if not first or first == "" then
    return nil
  end
  if surname and surname ~= "" then
    return first .. " " .. surname
  end
  return first
end

function ns.selfKey()
  return ns.unitKey("player")
end

-- True when two keys name the same character. Full keys must match exactly; when one side has only a first
-- name (a source without the surname), the first names are compared.
function ns.sameName(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  if a == b then
    return true
  end
  local fa, sa = a:match("^(%S+) (%S+)$")
  local fb, sb = b:match("^(%S+) (%S+)$")
  if sa and sb then
    return false
  end
  return (fa or a) == (fb or b)
end

-- The first name of a key, for short texts.
function ns.firstName(key)
  return type(key) == "string" and key:match("^(%S+)") or key
end

function ns.now()
  return GetTime()
end

-- Internal event bus ---------------------------------------------------------

local listeners = {}

-- Registers fn for an internal event; returns a handle for ns.off.
function ns.on(event, fn)
  local list = listeners[event]
  if not list then
    list = {}
    listeners[event] = list
  end
  local handle = { event = event, fn = fn }
  list[#list + 1] = handle
  return handle
end

function ns.off(handle)
  local list = handle and listeners[handle.event]
  if not list then
    return
  end
  handle.dead = true
  for i = #list, 1, -1 do
    if list[i] == handle then
      table.remove(list, i)
    end
  end
end

local function reportError(err)
  local handler = geterrorhandler and geterrorhandler()
  if handler then
    handler(err)
  else
    say("error: " .. tostring(err))
  end
end

-- Calls listeners synchronously in registration order. One failing listener does not stop the rest.
function ns.fire(event, ...)
  local list = listeners[event]
  if not list then
    return
  end
  local n, args = select("#", ...), { ... }
  local snapshot = { unpack(list) }
  for _, handle in ipairs(snapshot) do
    if not handle.dead then
      xpcall(function()
        handle.fn(unpack(args, 1, n))
      end, reportError)
    end
  end
end

-- SavedVariables --------------------------------------------------------------

local DB_DEFAULTS = {
  version = 1,
  ui = { minimap = { angle = 200 } },
  caps = {},
}

local CHAR_DEFAULTS = {
  prices = { COME = 30000, PICK = 15000 },
  onDuty = false,
  respTimes = {},
  lastRideAt = 0,
  lateCancels = {},
}

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = type(v) == "table" and copy(v) or v
  end
  return out
end

-- Fills missing keys from defaults, recursively; existing values win.
local function fill(dst, defaults)
  for k, v in pairs(defaults) do
    if dst[k] == nil then
      dst[k] = type(v) == "table" and copy(v) or v
    elseif type(v) == "table" and type(dst[k]) == "table" then
      fill(dst[k], v)
    end
  end
  return dst
end
ns.fillDefaults = fill

-- Capabilities (D11) -----------------------------------------------------------------
-- PortaxiDB.caps[what] = "manual" remembers, for good, that the client refused an automatic step
-- (ADDON_ACTION_BLOCKED, an error). A step that merely did not happen in time is handled per ride
-- by the module and is never stored here.

function ns.cap(what)
  local caps = type(PortaxiDB) == "table" and PortaxiDB.caps
  return type(caps) == "table" and caps[what] or "auto"
end

function ns.setCap(what, value)
  if type(PortaxiDB) ~= "table" then
    return
  end
  PortaxiDB.caps = PortaxiDB.caps or {}
  if PortaxiDB.caps[what] ~= value then
    PortaxiDB.caps[what] = value
    ns.fire("CAPS_CHANGED", PortaxiDB.caps)
  end
end

-- Slash commands ---------------------------------------------------------------

-- ns.commands[name] = { fn = function(args), args = "<x>", help = "..." }; other files add entries.
ns.commands = {}

local function printHelp()
  say(ns.VERSION .. " commands:")
  local names = {}
  for name in pairs(ns.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local c = ns.commands[name]
    say(("/ptx %s%s · %s"):format(name, c.args and (" " .. c.args) or "", c.help))
  end
end

SLASH_PORTAXI1 = "/ptx"
SLASH_PORTAXI2 = "/portaxi"
SlashCmdList.PORTAXI = function(msg)
  -- Only the command word is case-insensitive; arguments keep their case (player names).
  local cmd, args = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  local entry = ns.commands[cmd:lower()]
  if entry then
    entry.fn(args)
  else
    printHelp()
  end
end

-- Lifecycle ----------------------------------------------------------------------
-- ADDON_LOADED: SavedVariables get their defaults. ns.firstRun = true when PortaxiDB did not exist yet (a fresh
-- install on this account), so Version can tell a new player from one who updated (D17).
-- PLAYER_LOGIN: ns.fire("READY"); modules start from ns.on("READY", ...) in TOC order.

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    ns.firstRun = PortaxiDB == nil
    PortaxiDB = fill(PortaxiDB or {}, DB_DEFAULTS)
    PortaxiCharDB = fill(PortaxiCharDB or {}, CHAR_DEFAULTS)
  elseif event == "PLAYER_LOGIN" then
    ns.fire("READY")
    say(ns.VERSION .. " loaded. /ptx lists commands.")
  end
end)
