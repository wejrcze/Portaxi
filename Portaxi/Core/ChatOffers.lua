-- ChatOffers: portal ads of mages without Portaxi, read from public chat, for the rider's Browse list
-- (user request 2026-11-19, playbook D18). Every line of say, yell, whisper and the numbered channels (not
-- PortaxiNet) goes through ChatParse.offer; a port ad stays listed for Const.T.CHAT_OFFER seconds, a newer ad
-- of the same mage replaces it. A mage who runs Portaxi is left out: their own offer is already listed.
-- /ptx chat turns reading chat off and on for this too (PortaxiCharDB.chatRequests, shared with D16).
-- Where the mage stands, best first: their /who answer, "in Org" in the ad, the zone of a zone channel
-- (General, LocalDefense) or of a say / yell, both of which only reach this client from the same zone.
-- Trade spans every city, so a Trade ad has no place until the rider asks /who.
--   ChatOffers.list(dest)      -> entries offering dest, priced cheapest first (no price last), then newest:
--                                 { chat = true, key, raw, dests (nil = any), price (for dest, nil = none named),
--                                   tip, place, whoAt, at, lang, text, invited }
--   ChatOffers.find(key)       -> the entry, or nil
--   ChatOffers.invite(key, dest) -> true | nil, err ("off" "offer" "group" "invite"). Only from the player's
--                                 click: C_PartyInfo.InviteUnit(raw) and a whisper with the city (and the price
--                                 the mage named) in the ad's language. The ride itself is by hand.
--   ChatOffers.locate(key)     -> true | nil, err ("off" "offer" "who"). Only from the player's click (the client
--                                 wants a hardware event for /who): asks /who for the mage; the answer fills
--                                 entry.place. The game shows its own /who answer as well.
-- Events: CHAT_OFFERS_CHANGED whenever the list changes.
-- luacheck: read globals GetPlayerInfoByGUID UnitIsGroupLeader

local _, ns = ...
local C = ns.Const

local ChatOffers = {}
ns.ChatOffers = ChatOffers

local EVENTS = { "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_CHANNEL" }
local EXPIRE_EVERY = 10

local WHISPER = {
  en = { "Hi! I'd like a portal to %s. Sending you a group invite.",
    "Hi! I'd like a portal to %s for %s. Sending you a group invite." },
  ru = { "Привет! Нужен портал в %s. Отправляю приглашение в группу.",
    "Привет! Нужен портал в %s за %s. Отправляю приглашение в группу." },
}

local entries = {} -- key -> entry
local asked = {}   -- key -> time of the /who asked for that mage
local frame = nil

-- Helpers -------------------------------------------------------------------------------------------

local function charDB()
  return type(PortaxiCharDB) == "table" and PortaxiCharDB or {}
end

local function enabled()
  return charDB().chatRequests ~= false
end

local function changed()
  ns.fire("CHAT_OFFERS_CHANGED")
end

local function zone()
  local get = ns.api("GetRealZoneText", "GetZoneText")
  local z = get and get()
  return type(z) == "string" and z ~= "" and z or nil
end

-- The sender as "First Surname" (D5) and their class token when the client knows it.
local function sender(name, guid)
  local key = ns.playerKey(name)
  local class
  local info = guid and guid ~= "" and ns.api("GetPlayerInfoByGUID")
  if key and info then
    local _, englishClass, _, _, _, first, surname = info(guid)
    class = englishClass
    if not key:find(" ", 1, true) and type(first) == "string" and first ~= ""
        and type(surname) == "string" and surname ~= "" then
      key = first .. " " .. surname
    end
  end
  return key, class
end

-- Where the line tells us the mage stands, or nil.
local function placeOf(event, channelBase, parsed)
  if parsed.at then
    return C.CITY[parsed.at].name
  end
  local here = zone()
  if event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL" then
    return here
  end
  -- "General - Orgrimmar" reaches only players in Orgrimmar; "Trade - City" spans every city.
  local channelZone = event == "CHAT_MSG_CHANNEL" and type(channelBase) == "string"
    and channelBase:match(" %- (.+)$")
  if channelZone and channelZone == here then
    return here
  end
end

local function hasPortaxi(key)
  local market = ns.Dispatch and ns.Dispatch.market
  return market ~= nil and market.offerByKey[key] ~= nil
end

local function expired(entry, t)
  return t - entry.at >= C.T.CHAT_OFFER
end

local function offers(entry, dest)
  if not entry.dests then
    return true
  end
  for _, d in ipairs(entry.dests) do
    if d == dest then
      return true
    end
  end
  return false
end

-- Incoming chat --------------------------------------------------------------------------------------

local function onChat(event, text, name, _, _, _, _, _, _, channelBase, _, _, guid)
  if not enabled() or type(text) ~= "string" then
    return
  end
  if event == "CHAT_MSG_CHANNEL" and channelBase == C.CHANNEL then
    return
  end
  local key, class = sender(name, guid)
  if not key or ns.sameName(key, ns.selfKey()) or (class and class ~= "MAGE") then
    return
  end
  local parsed = ns.ChatParse.offer(text)
  if not parsed or parsed.kind ~= "port" then
    return -- summon ads wait for warlocks (phase 2)
  end
  local old = entries[key]
  local place = placeOf(event, channelBase, parsed)
  local entry = {
    chat = true, key = key, raw = key, at = ns.now(), lang = parsed.lang, text = ns.ChatParse.clean(text),
    dests = parsed.dests, prices = parsed.prices, lowest = parsed.price, tip = parsed.tip, place = place,
  }
  if old then
    entry.invited = old.invited
    if old.whoAt and not parsed.at then
      entry.place, entry.whoAt = old.place, old.whoAt -- a /who answer beats a guess from the channel
    elseif not place then
      entry.place = old.place
    end
  end
  entries[key] = entry
  changed()
end

-- /who answers ---------------------------------------------------------------------------------------

-- The answers of the last /who: { name, area, class } each; the modern table first, the old globals after.
local function whoResults()
  local out = {}
  local count = ns.api("C_FriendList.GetNumWhoResults", "GetNumWhoResults")
  local info = ns.api("C_FriendList.GetWhoInfo", "GetWhoInfo")
  if not (count and info) then
    return out
  end
  for i = 1, (count()) or 0 do
    local a, _, _, _, _, area = info(i)
    if type(a) == "table" then
      out[#out + 1] = { name = a.fullName, area = a.area, class = a.filename }
    elseif type(a) == "string" then
      out[#out + 1] = { name = a, area = area }
    end
  end
  return out
end

local function onWho()
  local t, any = ns.now(), false
  for _, r in ipairs(whoResults()) do
    for key, when in pairs(asked) do
      local entry = entries[key]
      if entry and t - when < C.T.WHO and ns.sameName(r.name, key) and type(r.area) == "string"
          and r.area ~= "" and (r.class == nil or r.class == "MAGE") then
        entry.place, entry.whoAt = r.area, t
        asked[key] = nil
        any = true
      end
    end
  end
  if any then
    changed()
  end
end

-- List, invite, locate -----------------------------------------------------------------------------

local function priceFor(entry, dest)
  return entry.prices and entry.prices[dest] or entry.lowest
end

local function cheaperFirst(a, b)
  if (a.price ~= nil) ~= (b.price ~= nil) then
    return a.price ~= nil
  end
  if a.price and a.price ~= b.price then
    return a.price < b.price
  end
  if a.at ~= b.at then
    return a.at > b.at
  end
  return a.key < b.key
end

function ChatOffers.list(dest)
  if not enabled() or not dest then
    return {}
  end
  local t = ns.now()
  local list = {}
  for key, entry in pairs(entries) do
    if not expired(entry, t) and offers(entry, dest) and not hasPortaxi(key) then
      entry.price = priceFor(entry, dest)
      list[#list + 1] = entry
    end
  end
  table.sort(list, cheaperFirst)
  return list
end

function ChatOffers.find(key)
  local entry = entries[key]
  if entry and not expired(entry, ns.now()) then
    return entry
  end
end

local function leaderOrAlone()
  if not IsInGroup() then
    return true
  end
  local leader = ns.api("UnitIsGroupLeader")
  return leader == nil or leader("player") == true
end

function ChatOffers.invite(key, dest)
  if not enabled() then
    return nil, "off"
  end
  local entry = ChatOffers.find(key)
  if not entry or not offers(entry, dest) then
    return nil, "offer"
  end
  if not leaderOrAlone() then
    return nil, "group"
  end
  local invite = ns.api("C_PartyInfo.InviteUnit", "InviteUnit")
  if not invite then
    return nil, "invite"
  end
  invite(entry.raw)
  local send = ns.api("C_ChatInfo.SendChatMessage", "SendChatMessage")
  if send then
    local lang = WHISPER[entry.lang] and entry.lang or "en"
    local city = ns.ChatReq.cityName(dest, lang)
    local price = priceFor(entry, dest)
    local msg = price and WHISPER[lang][2]:format(city, ns.ChatReq.money(price, lang))
      or WHISPER[lang][1]:format(city)
    send(msg, "WHISPER", nil, entry.raw)
  end
  entry.invited = true
  changed()
  return true
end

function ChatOffers.locate(key)
  if not enabled() then
    return nil, "off"
  end
  local entry = ChatOffers.find(key)
  if not entry then
    return nil, "offer"
  end
  local who = ns.api("C_FriendList.SendWho", "SendWho")
  if not who then
    return nil, "who"
  end
  asked[key] = ns.now()
  who(('n-"%s"'):format(ns.firstName(key)))
  return true
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function expire()
  local t, any = ns.now(), false
  for key, entry in pairs(entries) do
    if expired(entry, t) then
      entries[key] = nil
      any = true
    end
  end
  for key, when in pairs(asked) do
    if t - when >= C.T.WHO then
      asked[key] = nil
    end
  end
  -- Ages on the list move; redraw while there is anything to show.
  if any or next(entries) then
    changed()
  end
end

function ChatOffers.clear()
  if next(entries) then
    entries, asked = {}, {}
    changed()
  end
end

function ChatOffers.start()
  if frame then
    return
  end
  frame = CreateFrame("Frame")
  for _, event in ipairs(EVENTS) do
    pcall(frame.RegisterEvent, frame, event) -- an event unknown to this client must not stop the rest
  end
  pcall(frame.RegisterEvent, frame, "WHO_LIST_UPDATE")
  frame:SetScript("OnEvent", function(_, event, ...)
    if event == "WHO_LIST_UPDATE" then
      onWho()
    else
      onChat(event, ...)
    end
  end)
  C_Timer.NewTicker(EXPIRE_EVERY, expire)
end

ns.on("READY", ChatOffers.start)
