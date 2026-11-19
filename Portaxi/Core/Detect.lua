-- Detect: reads the character profile and derives the services it can offer.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Detect" (rules: docs/PORTAXI_MVP_PLAN.md §4). Card C, wave 1.
--   Detect.read(api) -> profile        reads only through the given api table (tests pass fakes)
--   Detect.services(profile) -> services   pure
--   Detect.hop(profile) -> hop             pure; Inn hop (D20): where we rest, and whether we can hop or host
--   Detect.start()                     on READY (D15): read, fire PROFILE_CHANGED, then debounce game events
--   Detect.current() -> profile, services   nil before start; callers must not modify the tables
-- class and race are the uppercase tokens (UnitClass/UnitRace second return), e.g. "MAGE", "ORC".

local _, ns = ...
local C = ns.Const

local Detect = {}
ns.Detect = Detect

-- Pause reasons in the fixed order they appear in services.pauses.
local PAUSE_ORDER = { "NOT_MAGE", "NO_PORTAL", "NO_RUNE", "NO_SCROLL", "NOT_RESTING" }

-- Game events that may change the profile; each one only schedules a debounced re-read.
-- Forever (modern client) has no LEARNED_SPELL_IN_TAB; SPELLS_CHANGED covers a learned portal.
local EVENTS = {
  "PLAYER_LEVEL_UP",
  "SPELLS_CHANGED",
  "BAG_UPDATE_DELAYED",
  "PLAYER_UPDATE_RESTING",
  "ZONE_CHANGED",
  "ZONE_CHANGED_INDOORS",
  "ZONE_CHANGED_NEW_AREA",
  "PLAYER_MONEY",
  "PLAYER_ENTERING_WORLD",
  "GROUP_ROSTER_UPDATE", -- profile.party (Inn hop, D20)
}

-- Reading -----------------------------------------------------------------------------

local function count(api, itemId)
  return api.GetItemCount and tonumber(api.GetItemCount(itemId)) or 0
end

-- Portals of the player's own faction that the player knows, as { KEY = true }.
local function knownPortals(api, faction)
  local portals = {}
  if not api.IsSpellKnown then
    return portals
  end
  for _, key in ipairs(C.CITY_ORDER) do
    local city = C.CITY[key]
    if city.faction == faction and api.IsSpellKnown(city.spell) then
      portals[key] = true
    end
  end
  return portals
end

function Detect.read(api)
  local faction = api.UnitFactionGroup("player")
  local _, race = api.UnitRace("player")
  local _, class = api.UnitClass("player")
  return {
    faction = faction,
    race = race,
    class = class,
    level = api.UnitLevel("player"),
    resting = api.IsResting() and true or false,
    zone = api.GetZoneText(),
    subzone = api.GetSubZoneText(),
    mapId = api.GetBestMapForUnit and api.GetBestMapForUnit("player") or nil,
    money = api.GetMoney(),
    portals = knownPortals(api, faction),
    runes = count(api, C.ITEM.RUNE_OF_PORTALS),
    scrolls = count(api, C.ITEM.LIMINAL_SCROLL),
    shards = count(api, C.ITEM.SOUL_SHARD),
    party = api.GetNumGroupMembers and tonumber(api.GetNumGroupMembers()) or 0, -- 0 = solo
  }
end

-- Services ----------------------------------------------------------------------------

local function destinations(portals)
  local dests = {}
  for _, key in ipairs(C.CITY_ORDER) do
    if portals and portals[key] then
      dests[#dests + 1] = key
    end
  end
  return dests
end

-- Every reason that applies, in PAUSE_ORDER. A non-mage gets only NOT_MAGE: portals,
-- runes and scrolls mean nothing to other classes in the MVP.
local function pausesFor(profile, dests)
  if profile.class ~= "MAGE" then
    return { "NOT_MAGE" }
  end
  local applies = {
    NO_PORTAL = #dests == 0,
    NO_RUNE = (profile.runes or 0) <= 0,
    NO_SCROLL = (profile.scrolls or 0) <= 0,
    NOT_RESTING = not profile.resting,
  }
  local pauses = {}
  for _, reason in ipairs(PAUSE_ORDER) do
    if applies[reason] then
      pauses[#pauses + 1] = reason
    end
  end
  return pauses
end

function Detect.services(profile)
  local dests = destinations(profile.portals)
  local canDrive = profile.class == "MAGE" and #dests > 0
  local pick = canDrive and (profile.runes or 0) > 0
  local come = pick and (profile.scrolls or 0) > 0 and profile.resting == true
  return {
    canDrive = canDrive,
    COME = come,
    PICK = pick,
    dests = dests,
    pauses = pausesFor(profile, dests),
  }
end

-- Inn hop (D20) -----------------------------------------------------------------------

local HOP_PAUSES = { "NOT_MAGE", "NO_SCROLL", "NOT_RESTING", "IN_GROUP" }
local HOST_PAUSES = { "NOT_RESTING", "IN_GROUP" }

local function pick(order, applies)
  local out = {}
  for _, reason in ipairs(order) do
    if applies[reason] then
      out[#out + 1] = reason
    end
  end
  return out
end

-- hop = { place = "city" | "inn" | nil, city = city key | nil, HOP, HOST, hopPauses, hostPauses }.
-- city: the Const.CITY whose name is the zone; place only while resting ("inn" = resting anywhere else).
-- The scroll needs both players resting and the mage forms a two-person group, so both must be solo.
function Detect.hop(profile)
  local cityKey
  for _, key in ipairs(C.CITY_ORDER) do
    if C.CITY[key].name == profile.zone then
      cityKey = key
    end
  end
  local resting = profile.resting == true
  local solo = (profile.party or 0) == 0
  local hopApplies = {
    NOT_MAGE = profile.class ~= "MAGE",
    NO_SCROLL = (profile.scrolls or 0) <= 0,
    NOT_RESTING = not resting,
    IN_GROUP = not solo,
  }
  local hopPauses = pick(HOP_PAUSES, hopApplies)
  local hostPauses = pick(HOST_PAUSES, hopApplies)
  return {
    place = resting and (cityKey and "city" or "inn") or nil,
    city = cityKey,
    HOP = #hopPauses == 0,
    HOST = #hostPauses == 0,
    hopPauses = hopPauses,
    hostPauses = hostPauses,
  }
end

-- Runtime -----------------------------------------------------------------------------

local api, profile, services
local pending = false

local function same(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function gameApi()
  return {
    UnitFactionGroup = UnitFactionGroup,
    UnitRace = UnitRace,
    UnitClass = UnitClass,
    UnitLevel = UnitLevel,
    IsResting = IsResting,
    GetZoneText = GetZoneText,
    GetSubZoneText = GetSubZoneText,
    GetMoney = GetMoney,
    IsSpellKnown = ns.api("IsPlayerSpell", "IsSpellKnown", "C_SpellBook.IsSpellKnown"),
    GetItemCount = ns.api("C_Item.GetItemCount", "GetItemCount"),
    GetBestMapForUnit = ns.api("C_Map.GetBestMapForUnit"),
    GetNumGroupMembers = ns.api("GetNumGroupMembers"),
  }
end

-- Debounced re-read; fires PROFILE_CHANGED only when profile or services changed.
local function refresh()
  pending = false
  local p = Detect.read(api)
  local s = Detect.services(p)
  if same(p, profile) and same(s, services) then
    return
  end
  profile, services = p, s
  ns.fire("PROFILE_CHANGED", profile, services)
end

local function onGameEvent()
  if pending then
    return
  end
  pending = true
  C_Timer.After(C.T.DEBOUNCE, refresh)
end

function Detect.start()
  if api then
    return
  end
  api = gameApi()
  profile = Detect.read(api)
  services = Detect.services(profile)
  ns.fire("PROFILE_CHANGED", profile, services)

  -- One by one: an event unknown to this client raises in RegisterEvent and must not stop the rest.
  local frame = CreateFrame("Frame")
  Detect.unknownEvents = {}
  for _, event in ipairs(EVENTS) do
    if not pcall(frame.RegisterEvent, frame, event) then
      Detect.unknownEvents[#Detect.unknownEvents + 1] = event
    end
  end
  frame:SetScript("OnEvent", onGameEvent)
end

function Detect.current()
  return profile, services
end

ns.on("READY", Detect.start)

-- /ptx detect -------------------------------------------------------------------------

local function gold(copper)
  copper = math.floor(copper or 0)
  return ("%dg %ds %dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function list(t)
  return #t > 0 and table.concat(t, " ") or "none"
end

local function onOff(v)
  return v and "on" or "off"
end

local function show()
  if not profile then
    ns.say("detect: not started yet")
    return
  end
  local p, s = profile, services
  ns.say(("profile: %s %s %s %s · %s%s · map %s · resting %s · %s"):format(
    tostring(p.faction), tostring(p.race), tostring(p.class), tostring(p.level),
    tostring(p.zone), (p.subzone and p.subzone ~= "") and (" / " .. p.subzone) or "",
    tostring(p.mapId), p.resting and "yes" or "no", gold(p.money)))
  ns.say(("portals %s · runes %d · scrolls %d · shards %d"):format(
    list(destinations(p.portals)), p.runes, p.scrolls, p.shards))
  ns.say(("services: drive %s · COME %s · PICK %s · dests %s · pauses %s"):format(
    s.canDrive and "yes" or "no", onOff(s.COME), onOff(s.PICK), list(s.dests), list(s.pauses)))
  local h = Detect.hop(p)
  ns.say(("inn hop: place %s · hop %s (%s) · host %s (%s) · party %d"):format(tostring(h.place or "none"),
    onOff(h.HOP), list(h.hopPauses), onOff(h.HOST), list(h.hostPauses), p.party or 0))
end

ns.commands.detect = { fn = show, help = "show what the addon detects on this character" }
