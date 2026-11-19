-- Core/Detect.lua: profile reading, services rules, debounced refresh, /ptx detect.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local DEBOUNCE = 2 -- Const.T.DEBOUNCE

-- Loads the addon and logs in, recording every PROFILE_CHANGED from the start.
-- opts.player merges into the stub's default player; opts.spells replaces the known spells.
local function login(opts)
  opts = opts or {}
  local wow = Wow.new({ player = opts.player })
  if opts.spells then
    wow.player.spells = opts.spells
  end
  wow:load({ noLogin = true })
  local fired = {}
  wow.ns.on("PROFILE_CHANGED", function(profile, services)
    fired[#fired + 1] = { profile = profile, services = services }
  end)
  wow:fire("ADDON_LOADED", "Portaxi")
  wow:fire("PLAYER_LOGIN")
  wow:fire("PLAYER_ENTERING_WORLD", true, false)
  return wow, fired
end

-- Logs in and lets the debounce from PLAYER_ENTERING_WORLD run out.
local function settled(opts)
  local wow, fired = login(opts)
  wow:advance(DEBOUNCE)
  return wow, fired
end

-- Loads Const and Detect alone into an environment with no game API at all.
local function bareDetect()
  local env = {
    ipairs = ipairs, pairs = pairs, type = type, tonumber = tonumber, tostring = tostring,
    table = table, math = math, string = string,
  }
  local ns = { on = function() end, commands = {} }
  for _, file in ipairs({ "Portaxi/Core/Const.lua", "Portaxi/Core/Detect.lua" }) do
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    chunk("Portaxi", ns)
  end
  return ns.Detect
end

local function mageProfile(over)
  local p = {
    faction = "Horde", race = "ORC", class = "MAGE", level = 40, resting = true,
    zone = "Orgrimmar", subzone = "", mapId = 1454, money = 0,
    portals = { OG = true, UC = true }, runes = 7, scrolls = 9, shards = 0,
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  return p
end

local function fakeApi()
  return {
    UnitFactionGroup = function() return "Horde" end,
    UnitRace = function() return "Orc", "ORC" end,
    UnitClass = function() return "Mage", "MAGE" end,
    UnitLevel = function() return 41 end,
    IsResting = function() return 1 end,
    GetZoneText = function() return "Orgrimmar" end,
    GetSubZoneText = function() return "Valley of Strength" end,
    GetMoney = function() return 12345 end,
    IsSpellKnown = function(id) return id == 11418 or id == 10059 end,
    GetItemCount = function(id) return ({ [17032] = 3, [213548] = 1, [6265] = 2 })[id] or 0 end,
  }
end

-- Profile and services in game ---------------------------------------------------------

T.test("default Horde mage: COME and PICK to OG and UC, PROFILE_CHANGED once at start", function()
  local wow, fired = settled()
  T.eq(#fired, 1)
  local profile, services = wow.ns.Detect.current()
  T.eq(profile, {
    faction = "Horde", race = "Orc", class = "MAGE", level = 40, resting = true,
    zone = "Orgrimmar", subzone = "", mapId = 1454, money = 455723,
    portals = { OG = true, UC = true }, runes = 7, scrolls = 9, shards = 0,
  })
  T.eq(services, { canDrive = true, COME = true, PICK = true, dests = { "OG", "UC" }, pauses = {} })
  T.ok(fired[1].profile == profile and fired[1].services == services, "fired the current tables")
  T.eq(#wow.errors, 0)
end)

T.test("leaving the inn: one PROFILE_CHANGED after the debounce, COME off, NOT_RESTING", function()
  local wow, fired = settled()
  wow:setResting(false)
  wow:advance(DEBOUNCE - 0.1)
  T.eq(#fired, 1, "nothing before the debounce")
  wow:advance(0.1)
  T.eq(#fired, 2)
  local s = fired[2].services
  T.eq(s.COME, false)
  T.eq(s.PICK, true)
  T.eq(s.pauses, { "NOT_RESTING" })
  T.eq(fired[2].profile.resting, false)
  wow:advance(10)
  T.eq(#fired, 2, "no further fire")
end)

T.test("several events inside the debounce window cause one re-read", function()
  local wow, fired = settled()
  local reads = 0
  local read = wow.ns.Detect.read
  wow.ns.Detect.read = function(api)
    reads = reads + 1
    return read(api)
  end
  wow:setResting(false)
  wow:advance(0.5)
  wow:setMoney(1000)
  wow:fire("ZONE_CHANGED")
  wow:advance(1)
  wow:fire("BAG_UPDATE_DELAYED")
  wow:advance(0.5)
  T.eq(reads, 1)
  T.eq(#fired, 2)
  T.eq(fired[2].profile.money, 1000)
  T.eq(fired[2].profile.resting, false)
  wow:fire("ZONE_CHANGED")
  wow:advance(DEBOUNCE)
  T.eq(reads, 2, "a later event schedules a new read")
end)

T.test("an event that changes nothing fires nothing", function()
  local wow, fired = settled()
  for _, event in ipairs({ "ZONE_CHANGED", "SPELLS_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD" }) do
    wow:fire(event)
    wow:advance(DEBOUNCE)
  end
  T.eq(#fired, 1)
end)

T.test("every listed game event triggers a re-read", function()
  local wow, fired = settled()
  local events = {
    "PLAYER_LEVEL_UP", "SPELLS_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_UPDATE_RESTING",
    "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_MONEY", "PLAYER_ENTERING_WORLD",
  }
  for i, event in ipairs(events) do
    wow.player.level = 40 + i
    wow:fire(event)
    wow:advance(DEBOUNCE)
    T.eq(#fired, 1 + i, event)
    T.eq(fired[#fired].profile.level, 40 + i, event)
  end
end)

-- Regression (G1, 2026-11-18): LEARNED_SPELL_IN_TAB is unknown on Forever; RegisterEvent raised and
-- every event after it stayed unregistered, so the zone read at login ("") never updated.
T.test("Forever's event list registers cleanly", function()
  local wow = settled()
  T.eq(wow.ns.Detect.unknownEvents, {})
end)

T.test("an event unknown to the client does not stop the other registrations", function()
  local wow = Wow.new()
  local create = wow.env.CreateFrame
  wow.env.CreateFrame = function(...)
    local f = create(...)
    local register = f.RegisterEvent
    f.RegisterEvent = function(self, e)
      if e == "SPELLS_CHANGED" then error("Attempt to register unknown event") end
      return register(self, e)
    end
    return f
  end
  wow:load()
  wow:advance(DEBOUNCE)
  T.eq(wow.ns.Detect.unknownEvents, { "SPELLS_CHANGED" })
  wow:setResting(false)
  wow:advance(DEBOUNCE)
  T.eq(select(2, wow.ns.Detect.current()).COME, false, "events after the unknown one still work")
end)

T.test("a zone that is empty at login is filled in after PLAYER_ENTERING_WORLD", function()
  local wow = Wow.new({ player = { zone = "", subzone = "" } })
  wow:load({ noLogin = true })
  wow:fire("ADDON_LOADED", "Portaxi")
  wow:fire("PLAYER_LOGIN")
  T.eq(wow.ns.Detect.current().zone, "")
  wow.player.zone, wow.player.subzone = "Swamp of Sorrows", "Stonard"
  wow:fire("PLAYER_ENTERING_WORLD", true, false)
  wow:advance(DEBOUNCE)
  T.eq(wow.ns.Detect.current().zone, "Swamp of Sorrows")
end)

T.test("learning a portal adds the destination after the debounce", function()
  local wow, fired = settled({ player = { level = 50 } })
  wow.player.spells[11420] = true
  wow:fire("SPELLS_CHANGED")
  wow:advance(DEBOUNCE)
  T.eq(#fired, 2)
  T.eq(fired[2].profile.portals, { OG = true, UC = true, TB = true })
  T.eq(fired[2].services.dests, { "OG", "UC", "TB" })
end)

T.test("mage without runes: PICK and COME off, NO_RUNE", function()
  local wow, fired = settled()
  wow:setItem(17032, 0)
  wow:advance(DEBOUNCE)
  T.eq(#fired, 2)
  T.eq(fired[2].services, { canDrive = true, COME = false, PICK = false, dests = { "OG", "UC" }, pauses = { "NO_RUNE" } })
end)

T.test("mage without scroll: COME off, PICK on, NO_SCROLL", function()
  local wow = settled({ player = { items = { [213548] = 0 } } })
  local _, s = wow.ns.Detect.current()
  T.eq(s, { canDrive = true, COME = false, PICK = true, dests = { "OG", "UC" }, pauses = { "NO_SCROLL" } })
end)

T.test("warrior cannot drive: NOT_MAGE only", function()
  local wow = settled({ player = { class = "WARRIOR" }, spells = {} })
  local p, s = wow.ns.Detect.current()
  T.eq(p.class, "WARRIOR")
  T.eq(s, { canDrive = false, COME = false, PICK = false, dests = {}, pauses = { "NOT_MAGE" } })
end)

T.test("mage with no portal: NO_PORTAL", function()
  local wow = settled({ player = { level = 30 }, spells = {} })
  local p, s = wow.ns.Detect.current()
  T.eq(p.portals, {})
  T.eq(s, { canDrive = false, COME = false, PICK = false, dests = {}, pauses = { "NO_PORTAL" } })
end)

T.test("Alliance mage lists only Alliance portals", function()
  local wow = settled({
    player = { faction = "Alliance", race = "Human", zone = "Stormwind City" },
    spells = { [10059] = true, [11417] = true },
  })
  local p, s = wow.ns.Detect.current()
  T.eq(p.portals, { SW = true })
  T.eq(s.dests, { "SW" })
  T.eq(s.canDrive, true)
end)

T.test("missing C_Map.GetBestMapForUnit gives mapId nil, no error", function()
  local wow = Wow.new()
  wow.env.C_Map = nil
  wow:load()
  local p = wow.ns.Detect.current()
  T.eq(p.mapId, nil)
  T.eq(p.zone, "Orgrimmar")
  T.eq(#wow.errors, 0)
end)

T.test("start runs once even if READY fires again", function()
  local wow, fired = settled()
  wow.ns.fire("READY")
  T.eq(#fired, 1)
end)

-- Pure functions without the game ----------------------------------------------------------

T.test("services is pure: hand-made profiles, no game API in the environment", function()
  local Detect = bareDetect()
  T.eq(Detect.services(mageProfile()),
    { canDrive = true, COME = true, PICK = true, dests = { "OG", "UC" }, pauses = {} })
  T.eq(Detect.services(mageProfile({ scrolls = 0, resting = false })),
    { canDrive = true, COME = false, PICK = true, dests = { "OG", "UC" }, pauses = { "NO_SCROLL", "NOT_RESTING" } })
  T.eq(Detect.services(mageProfile({ portals = {}, runes = 0, scrolls = 0, resting = false })).pauses,
    { "NO_PORTAL", "NO_RUNE", "NO_SCROLL", "NOT_RESTING" })
  T.eq(Detect.services(mageProfile({ class = "WARLOCK", portals = {}, shards = 3 })),
    { canDrive = false, COME = false, PICK = false, dests = {}, pauses = { "NOT_MAGE" } })
end)

T.test("services orders dests by CITY_ORDER, not by table order", function()
  local Detect = bareDetect()
  local s = Detect.services(mageProfile({ faction = "Alliance", portals = { DN = true, SW = true, IF = true } }))
  T.eq(s.dests, { "SW", "IF", "DN" })
end)

T.test("services does not modify the profile", function()
  local Detect = bareDetect()
  local p = mageProfile({ resting = false })
  Detect.services(p)
  T.eq(p, mageProfile({ resting = false }))
end)

T.test("read uses only the api table; GetBestMapForUnit may be missing", function()
  local Detect = bareDetect()
  local p = Detect.read(fakeApi())
  T.eq(p, {
    faction = "Horde", race = "ORC", class = "MAGE", level = 41, resting = true,
    zone = "Orgrimmar", subzone = "Valley of Strength", mapId = nil, money = 12345,
    portals = { UC = true }, runes = 3, scrolls = 1, shards = 2,
  })
end)

T.test("read passes the unit and item IDs from Const", function()
  local Detect = bareDetect()
  local api = fakeApi()
  local units, items = {}, {}
  api.GetBestMapForUnit = function(unit) units[#units + 1] = unit return 1454 end
  api.GetItemCount = function(id) items[#items + 1] = id return 0 end
  local p = Detect.read(api)
  T.eq(p.mapId, 1454)
  T.eq(units, { "player" })
  T.eq(items, { 17032, 213548, 6265 })
end)

T.test("read with no spell or item API: no portals, zero counts", function()
  local Detect = bareDetect()
  local api = fakeApi()
  api.IsSpellKnown, api.GetItemCount = nil, nil
  local p = Detect.read(api)
  T.eq(p.portals, {})
  T.eq({ p.runes, p.scrolls, p.shards }, { 0, 0, 0 })
end)

T.test("current is nil before start", function()
  local Detect = bareDetect()
  T.eq(select("#", Detect.current()), 2)
  T.eq(Detect.current(), nil)
end)

-- /ptx detect -----------------------------------------------------------------------------

T.test("/ptx detect prints profile and services", function()
  local wow = settled()
  local before = #wow.printed
  wow:slash("detect")
  local out = table.concat(wow.printed, "\n", before + 1)
  T.ok(out:find("Horde Orc MAGE 40", 1, true), out)
  T.ok(out:find("resting yes", 1, true), out)
  T.ok(out:find("45g 57s 23c", 1, true), out)
  T.ok(out:find("portals OG UC · runes 7 · scrolls 9 · shards 0", 1, true), out)
  T.ok(out:find("COME on · PICK on · dests OG UC · pauses none", 1, true), out)
  wow:slash("")
  T.ok(table.concat(wow.printed, "\n"):find("/ptx detect · show what the addon detects", 1, true), "help line")
end)

T.test("/ptx detect shows pauses for a warrior", function()
  local wow = settled({ player = { class = "WARRIOR" } })
  local before = #wow.printed
  wow:slash("detect")
  local out = table.concat(wow.printed, "\n", before + 1)
  T.ok(out:find("drive no", 1, true), out)
  T.ok(out:find("pauses NOT_MAGE", 1, true), out)
end)

T.done()
