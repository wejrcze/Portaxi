-- Version: tells the player when a newer Portaxi runs on the network, and decides when to show What's new (D17).
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Version". Owned by the architect.
--   Version.parse(s) -> { major, minor, patch, pre } | nil       pure; "1.2.3" or "1.2.3-dev" (pre = "dev")
--   Version.compare(a, b) -> -1 | 0 | 1, or nil when either is not a version     pure; "0.2.0-dev" < "0.2.0"
--   Version.isRelease(s) -> bool                                  pure; true for "0.2.0", false for "0.2.0-dev"
--   Version.notes(changelog, from, to) -> entries                 pure; from < entry.version <= to (to without
--                                                                 its "-pre"), newest first; from nil = all
--   Version.newest -> highest release heard on the network this session, when it is newer than ours; else nil
--   events: VERSION_NEWER (version) for each newer release heard; WHATS_NEW (entries) to open the window
--   PortaxiDB.lastVersion = the version that ran last time on this account
--
-- No server, so the addons gossip (D17). Each Portaxi broadcasts "VER|<its version>" once, ANNOUNCE_MIN..
-- ANNOUNCE_MAX s after login (out of the login burst, spread when a whole raid reloads). A client
-- that hears an older version on the channel answers there with its own after a random REPLY_MIN..REPLY_MAX s,
-- unless someone with at least its version speaks first; it answers at most once per REPLY_COOLDOWN. One answer
-- reaches every outdated player online, so an update spreads as soon as one player has it. Pre-release builds
-- ("-dev") announce themselves but never answer, and nobody is told to update to a pre-release.

local _, ns = ...

local L = ns.L
local Version = {}
ns.Version = Version

local ANNOUNCE_MIN, ANNOUNCE_MAX = 10, 20 -- seconds after login before the own version goes out
local REPLY_MIN, REPLY_MAX = 2, 30 -- seconds before answering an outdated player
local REPLY_COOLDOWN = 300         -- at most one answer per this many seconds
local WHATS_NEW_DELAY = 4          -- seconds after login, so the window does not drown in the login burst

-- Pure ---------------------------------------------------------------------------------

local MAX_PART = 9999 -- version numbers above this are nonsense, not versions

function Version.parse(s)
  if type(s) ~= "string" then
    return nil
  end
  local major, minor, patch, rest = s:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
  if not major then
    return nil
  end
  local pre
  if rest ~= "" then
    pre = rest:match("^%-([%w%.]+)$")
    if not pre then
      return nil
    end
  end
  local v = { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch), pre = pre }
  if v.major > MAX_PART or v.minor > MAX_PART or v.patch > MAX_PART then
    return nil
  end
  return v
end

local function sign(a, b)
  if a < b then
    return -1
  elseif a > b then
    return 1
  end
  return 0
end

function Version.compare(a, b)
  local va, vb = Version.parse(a), Version.parse(b)
  if not va or not vb then
    return nil
  end
  for _, part in ipairs({ "major", "minor", "patch" }) do
    local c = sign(va[part], vb[part])
    if c ~= 0 then
      return c
    end
  end
  if va.pre == vb.pre then
    return 0
  elseif not va.pre then
    return 1 -- a release is newer than its own pre-release
  elseif not vb.pre then
    return -1
  end
  return sign(va.pre, vb.pre)
end

function Version.isRelease(s)
  local v = Version.parse(s)
  return v ~= nil and v.pre == nil
end

-- "0.2.0-dev" -> "0.2.0"
local function base(s)
  local v = Version.parse(s)
  return v and ("%d.%d.%d"):format(v.major, v.minor, v.patch)
end

function Version.notes(changelog, from, to)
  local out = {}
  local upTo = base(to)
  if type(changelog) ~= "table" or not upTo then
    return out
  end
  for _, entry in ipairs(changelog) do
    local atMost = (Version.compare(entry.version, upTo) or 1) <= 0
    local after = from == nil or (Version.compare(entry.version, from) or 0) > 0
    if atMost and after then
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(x, y)
    return Version.compare(x.version, y.version) > 0
  end)
  return out
end

-- Network ----------------------------------------------------------------------------------

Version.newest = nil
local told = false        -- the chat notice was printed this session
local replyTimer = nil    -- pending answer to an outdated player
local lastReplyAt = nil   -- ns.now() of the last answer

local function announce()
  if ns.Net then
    ns.Net.broadcast({ type = "VER", ver = ns.VERSION })
  end
end

local function cancelReply()
  if replyTimer then
    replyTimer:Cancel()
    replyTimer = nil
  end
end

local function between(min, max)
  return min + math.random() * (max - min)
end

local function scheduleReply()
  if replyTimer or not Version.isRelease(ns.VERSION) then
    return
  end
  if lastReplyAt and ns.now() - lastReplyAt < REPLY_COOLDOWN then
    return
  end
  replyTimer = C_Timer.NewTimer(between(REPLY_MIN, REPLY_MAX), function()
    replyTimer = nil
    lastReplyAt = ns.now()
    announce()
  end)
end

local function heardNewer(ver)
  if Version.newest and Version.compare(ver, Version.newest) <= 0 then
    return
  end
  Version.newest = ver
  if not told then
    told = true -- once per session: a later, higher number is kept for /ptx version but not printed again
    ns.say(L["Version %s is available (you have %s). Update Portaxi to get it."]:format(ver, ns.VERSION))
  end
  ns.fire("VERSION_NEWER", ver)
end

local function onMessage(msg, _, _, via)
  if msg.type ~= "VER" then
    return
  end
  local cmp = Version.compare(msg.ver, ns.VERSION)
  if not cmp then
    return
  end
  local release = Version.isRelease(msg.ver)
  if cmp > 0 and release then
    heardNewer(msg.ver)
  end
  if via ~= "CHANNEL" then
    return
  end
  if cmp >= 0 and release then
    cancelReply() -- someone at least as new has spoken; every outdated player heard it
  elseif cmp < 0 then
    scheduleReply()
  end
end

-- What's new --------------------------------------------------------------------------------

-- Entries to show after login, or nil. Records the running version as seen.
local function pendingNotes()
  if type(PortaxiDB) ~= "table" then
    return nil
  end
  local last, mine = PortaxiDB.lastVersion, ns.VERSION
  PortaxiDB.lastVersion = mine
  if last == nil then
    if ns.firstRun then
      return nil -- a new player: nothing is "new" to them
    end
    -- Installed before lastVersion existed: show the notes of the running version only.
    local notes = Version.notes(ns.Changelog, nil, mine)
    return { notes[1] }
  end
  local cmp = Version.compare(last, mine)
  if not cmp or cmp >= 0 then
    return nil
  end
  return Version.notes(ns.Changelog, last, mine)
end

function Version.showNotes(entries)
  ns.fire("WHATS_NEW", entries or Version.notes(ns.Changelog, nil, ns.VERSION))
end

-- Lifecycle ---------------------------------------------------------------------------------

function Version.start()
  ns.on("NET_MSG", onMessage)
  C_Timer.After(between(ANNOUNCE_MIN, ANNOUNCE_MAX), announce) -- Net queues it until the channel is joined
  local notes = pendingNotes()
  if notes and #notes > 0 then
    C_Timer.After(WHATS_NEW_DELAY, function()
      Version.showNotes(notes)
    end)
  end
end

ns.on("READY", Version.start)

-- /ptx version, /ptx news ------------------------------------------------------------------------

local function versionCommand()
  if Version.newest then
    ns.say(L["You have %s. Version %s is available."]:format(ns.VERSION, Version.newest))
  else
    ns.say(L["You have %s, the newest version seen on the network."]:format(ns.VERSION))
  end
end

ns.commands.version = { fn = versionCommand, help = "show your version and the newest one seen on the network" }
ns.commands.news = { fn = function() Version.showNotes() end, help = "show what's new" }
