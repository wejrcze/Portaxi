-- Who: the /who fallback of Inn hop (D20) for hosts without Portaxi. Game glue.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Inn hop (D20)". Plan: docs/INN_HOP_PLAN.md §2.
--   Who.search(zone) -> true | nil, err   from a click only (C_FriendList.SendWho needs a hardware event; probe
--                                         2026-11-19); err "zone", "cooldown", "who"; results in WHO_RESULTS
--   Who.results() -> list, zone           the last answer: { key, raw, level, class, race, area }, own key left out
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

local results, resultsZone = {}, nil
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

-- Search ----------------------------------------------------------------------------------------------

function Who.search(zone)
  zone = type(zone) == "string" and zone:gsub('"', ""):match("^%s*(.-)%s*$") or ""
  if zone == "" then
    return nil, "zone"
  end
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
  searchedAt, pendingZone = t, zone
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
                          area = w.area }
      end
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

local function onWhoList()
  if not (pendingZone and searchedAt and now() - searchedAt <= ANSWER_WAIT) then
    return -- someone else's /who (the player, or ChatOffers' Where?)
  end
  results, resultsZone, pendingZone = readResults(), pendingZone, nil
  ns.fire("WHO_RESULTS", results, resultsZone)
end

function Who.results()
  return results, resultsZone
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
