-- Who: the /who fallback of Inn hop (D20) for hosts without Portaxi. Game glue.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Inn hop (D20)". Plan: docs/INN_HOP_PLAN.md §2.
--   Who.search(query) -> true | nil, err  from a click only (C_FriendList.SendWho needs a hardware event; probe
--                                         2026-11-19); query = a zone, or a town with an inn (searched by its zone);
--                                         err "zone", "cooldown", "who"; results in WHO_RESULTS
--   Who.results() -> list, zone, town     the last answer: { key, raw, level, class, race, area, inn, here }, own key
--                                         left out; area is the subzone on Forever (in game 2026-11-19); here = in the
--                                         town searched for; order: here, then inn towns, then the rest, each by key
--   Who.isInn(area) -> bool ; Who.resolve(query) -> zone, town | nil ; Who.learn(zone, sub)
--                                         towns with an inn: Const.INNS plus places where we or a host rested
--                                         (PortaxiDB.inns, keyed by the lower-case town)
--   Who.ask(key) -> true | nil, err       whispers the request template; err "who" (not in the results), "busy"
--   Who.awaiting() -> { [key] = time }    players asked within T.INVITE
-- An invite from an asked player is accepted by the mage's own click (R4); once that player is in the group and no
-- ride runs, a Ride { svc = "HOP", role = "taxi", peer.noAddon = true } starts, so the Portaxi button gets the scroll.
-- Events: WHO_RESULTS(list, zone) ; WHO_CHANGED (asked list changed)
-- luacheck: read globals time

local _, ns = ...
local C = ns.Const

local Who = ns.Who or {}
ns.Who = Who

local SEARCH_GAP = 5   -- seconds between two searches (the server's own cooldown is unverified)
local ANSWER_WAIT = 10 -- a WHO_LIST_UPDATE later than this after our search is someone else's

local WHISPER = "Hi! I'm a mage with a Scroll of Liminal Passage. Could you invite me to your group? I'll teleport "
  .. "to you if you stay rested in the inn, then leave. Thanks!"

local results, resultsZone, resultsTown = {}, nil, nil
local wantTown = nil
local pendingZone, searchedAt = nil, nil
local asked = {}       -- key -> { raw, at }
local seq = nil
local started = false

local function now()
  return ns.now()
end

local function activeRide()
  local R = ns.Ride
  return type(R) == "table" and type(R.current) == "function" and R.current() or nil
end

-- Inns ------------------------------------------------------------------------------------------------

local function lower(s)
  return type(s) == "string" and s:lower() or ""
end

local function learned()
  if type(PortaxiDB) ~= "table" then
    return {}
  end
  PortaxiDB.inns = type(PortaxiDB.inns) == "table" and PortaxiDB.inns or {}
  return PortaxiDB.inns
end

local function isCapital(zone)
  for _, city in pairs(C.CITY) do
    if city.name == zone then
      return true
    end
  end
  return false
end

-- The inn town record { zone, town } for a town name (Const.INNS first, then the learned ones), or nil.
local function innTown(name)
  local key = lower(name)
  if key == "" then
    return nil
  end
  for _, inn in ipairs(C.INNS or {}) do
    if lower(inn.town) == key then
      return inn
    end
  end
  return learned()[key]
end

function Who.isInn(area)
  return innTown(area) ~= nil
end

-- A query that names an inn town is searched by its zone; anything else is taken as a zone.
function Who.resolve(query)
  local inn = innTown(query)
  if inn then
    return inn.zone, inn.town
  end
  return query, nil
end

-- Remembers a resting place outside the capitals (our own, or a host's HOST) as a town with an inn.
function Who.learn(zone, sub)
  if type(zone) ~= "string" or zone == "" or type(sub) ~= "string" or sub == "" or sub == zone
      or isCapital(zone) or innTown(sub) then
    return false
  end
  learned()[lower(sub)] = { zone = zone, town = sub, at = time() }
  return true
end

-- Search ----------------------------------------------------------------------------------------------

function Who.search(query)
  query = type(query) == "string" and query:gsub('"', ""):match("^%s*(.-)%s*$") or ""
  if query == "" then
    return nil, "zone"
  end
  local zone, town = Who.resolve(query)
  local t = now()
  if searchedAt and t - searchedAt < SEARCH_GAP then
    return nil, "cooldown"
  end
  local send = ns.api("C_FriendList.SendWho", "SendWho")
  if not send then
    return nil, "who"
  end
  local ok = pcall(send, ('z-"%s"'):format(zone))
  if not ok then
    return nil, "who"
  end
  searchedAt, pendingZone, wantTown = t, zone, town
  return true
end

local function readResults()
  local out = {}
  local count = ns.api("C_FriendList.GetNumWhoResults", "GetNumWhoResults")
  local info = ns.api("C_FriendList.GetWhoInfo", "GetWhoInfo")
  if not (count and info) then
    return out
  end
  local me = ns.selfKey()
  for i = 1, (count()) or 0 do
    local w = info(i)
    if type(w) == "table" and type(w.fullName) == "string" and w.fullName ~= "" then
      local key = ns.playerKey(w.fullName)
      if not ns.sameName(key, me) then
        out[#out + 1] = { key = key, raw = w.fullName, level = w.level, class = w.classStr, race = w.raceStr,
                          area = w.area, inn = Who.isInn(w.area),
                          here = wantTown ~= nil and lower(w.area) == lower(wantTown) }
      end
    end
  end
  local function rank(e)
    return e.here and 0 or (e.inn and 1 or 2)
  end
  table.sort(out, function(a, b)
    if rank(a) ~= rank(b) then
      return rank(a) < rank(b)
    end
    return a.key < b.key
  end)
  return out
end

local function onWhoList()
  if not (pendingZone and searchedAt and now() - searchedAt <= ANSWER_WAIT) then
    return -- someone else's /who (the player, or ChatOffers' Where?)
  end
  results, resultsZone, resultsTown, pendingZone = readResults(), pendingZone, wantTown, nil
  ns.fire("WHO_RESULTS", results, resultsZone, resultsTown)
end

function Who.results()
  return results, resultsZone, resultsTown
end

-- Ask -------------------------------------------------------------------------------------------------

function Who.ask(key)
  local entry
  for _, r in ipairs(results) do
    if r.key == key then
      entry = r
    end
  end
  if not entry then
    return nil, "who"
  end
  if activeRide() then
    return nil, "busy"
  end
  local send = ns.api("C_ChatInfo.SendChatMessage", "SendChatMessage")
  if send then
    pcall(send, WHISPER, "WHISPER", nil, entry.raw)
  end
  asked[key] = { raw = entry.raw, at = now() }
  ns.fire("WHO_CHANGED")
  return true
end

function Who.awaiting()
  local out = {}
  for key, a in pairs(asked) do
    out[key] = a.at
  end
  return out
end

-- Hand-over to Ride --------------------------------------------------------------------------------

local function nextReqId()
  seq = (seq or (time() % 100000)) + 1
  return ns.selfKey() .. ":w" .. seq
end

local function inGroup(key)
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) and ns.sameName(ns.unitKey(unit), key) then
      return true
    end
  end
  return false
end

local function onRoster()
  if activeRide() then
    return
  end
  local t = now()
  for key, a in pairs(asked) do
    if t - a.at >= C.T.INVITE then
      asked[key] = nil
    elseif inGroup(key) then
      asked[key] = nil
      local R = ns.Ride
      if type(R) == "table" and type(R.start) == "function" then
        R.start({ reqId = nextReqId(), role = "taxi", svc = "HOP", price = 0, dest = nil,
                  peer = { key = key, raw = a.raw, noAddon = true }, eta = C.CAST.SCROLL })
      end
      ns.fire("WHO_CHANGED")
      return
    end
  end
end

function Who.start()
  if started then
    return
  end
  started = true
  local frame = CreateFrame("Frame")
  for _, event in ipairs({ "WHO_LIST_UPDATE", "GROUP_ROSTER_UPDATE" }) do
    pcall(frame.RegisterEvent, frame, event)
  end
  frame:SetScript("OnEvent", function(_, event)
    if event == "WHO_LIST_UPDATE" then
      onWhoList()
    else
      onRoster()
    end
  end)
end

ns.on("READY", Who.start)
ns.on("PROFILE_CHANGED", function(profile)
  if type(profile) == "table" and profile.resting then
    Who.learn(profile.zone, profile.subzone)
  end
end)
ns.on("NET_MSG", function(msg)
  if type(msg) == "table" and msg.type == "HOST" and msg.city == "" then
    Who.learn(msg.zone, msg.sub)
  end
end)
