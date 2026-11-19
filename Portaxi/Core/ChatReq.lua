-- ChatReq: taxi requests from public chat, so a taxi can also serve players without Portaxi
-- (user request 2026-11-19, playbook D16). While on duty and able to drive, every line of say, yell,
-- whisper and the numbered channels goes through ChatParse; a port request to a city this taxi serves is
-- listed for Const.T.CHAT_REQUEST seconds. /ptx chat turns reading chat off and on (PortaxiCharDB.chatRequests).
--   ChatReq.list()        -> entries, oldest first, in Dispatch.requests() shape plus chat fields:
--                            { chat = true, request = { reqId = "chat:<key>", key, dest, at }, svc, price,
--                              raw, lang, text, invited }
--   ChatReq.invite(reqId) -> true | nil, err ("duty" "busy" "request" "invite"). Only from the player's click:
--                            C_PartyInfo.InviteUnit(raw) and a whisper with the city and price in the
--                            rider's language. The ride itself (portal, trade) is the taxi's, by hand.
-- Events: INCOMING_REQUEST(entry) for a new request (as Dispatch's, entry.chat = true; not during a ride),
--         CHAT_REQUESTS_CHANGED whenever the list changes.
-- luacheck: read globals GetPlayerInfoByGUID

local _, ns = ...
local C = ns.Const

local ChatReq = {}
ns.ChatReq = ChatReq

local EVENTS = { "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_CHANNEL" }
local EXPIRE_EVERY = 10

-- What the rider reads: the city in their language and the price.
local CITY_RU = { OG = "Оргриммар", UC = "Подгород", TB = "Громовой Утес", SW = "Штормград", IF = "Стальгорн",
  DN = "Дарнас" }
local WHISPER = {
  en = "Hi! I can open a portal to %s for %s. Sending you a group invite.",
  ru = "Привет! Могу открыть портал в %s за %s. Отправляю приглашение в группу.",
}
local COIN = { en = { "g", "s", "c" }, ru = { "з", "с", "м" } }

local entries = {} -- key -> entry
local frame = nil

-- Helpers -------------------------------------------------------------------------------------------

local function charDB()
  return type(PortaxiCharDB) == "table" and PortaxiCharDB or {}
end

local function enabled()
  local db = charDB()
  return db.onDuty == true and db.chatRequests ~= false
end

local function services()
  local detect = ns.Detect
  if type(detect) == "table" and type(detect.current) == "function" then
    local _, s = detect.current()
    return s or {}
  end
  return {}
end

local function activeRide()
  local ride = ns.Ride
  return type(ride) == "table" and type(ride.current) == "function" and ride.current() or nil
end

local function serves(s, dest)
  for _, d in ipairs(s.dests or {}) do
    if d == dest then
      return true
    end
  end
  return false
end

local function changed()
  ns.fire("CHAT_REQUESTS_CHANGED")
end

-- "1g 50s" / "1з 50с": gold and silver, copper only below one silver.
function ChatReq.money(copper, lang)
  local unit = COIN[lang] or COIN.en
  copper = math.floor(tonumber(copper) or 0)
  local g, s = math.floor(copper / 10000), math.floor(copper / 100) % 100
  local out = {}
  if g > 0 then
    out[#out + 1] = g .. unit[1]
  end
  if s > 0 then
    out[#out + 1] = s .. unit[2]
  end
  if #out == 0 then
    out[1] = copper .. unit[3]
  end
  return table.concat(out, " ")
end

-- The service and price offered to a chat rider: a portal pickup when offered, else come-to-you.
local function offer(s)
  local prices = charDB().prices or {}
  if s.PICK and prices.PICK then
    return "PICK", prices.PICK
  end
  return "COME", prices.COME
end

-- The sender as "First Surname" (D5). A sender without a surname gets it from the GUID when possible.
local function senderKey(sender, guid)
  local key = ns.playerKey(sender)
  if key and not key:find(" ", 1, true) and guid and guid ~= "" then
    local info = ns.api("GetPlayerInfoByGUID")
    if info then
      local _, _, _, _, _, name, surname = info(guid)
      if type(name) == "string" and name ~= "" and type(surname) == "string" and surname ~= "" then
        key = name .. " " .. surname
      end
    end
  end
  return key
end

local function expired(entry, t)
  return t - entry.request.at >= C.T.CHAT_REQUEST
end

-- Incoming chat --------------------------------------------------------------------------------------

local function onChat(event, text, sender, _, _, _, _, _, _, channelBase, _, _, guid)
  if not enabled() or type(text) ~= "string" then
    return
  end
  if event == "CHAT_MSG_CHANNEL" and channelBase == C.CHANNEL then
    return
  end
  local key = senderKey(sender, guid)
  if not key or ns.sameName(key, ns.selfKey()) then
    return
  end
  local s = services()
  if not s.canDrive then
    return
  end
  local parsed = ns.ChatParse.parse(text)
  if not parsed or parsed.kind ~= "port" or not serves(s, parsed.dest) then
    return
  end
  local market = ns.Dispatch and ns.Dispatch.market
  if market and market.requestByKey[key] then
    return -- the rider has Portaxi: their hail is already on the list
  end
  local t = ns.now()
  local old = entries[key]
  local svc, price = offer(s)
  local entry = {
    chat = true,
    request = { reqId = "chat:" .. key, key = key, dest = parsed.dest, at = t },
    svc = svc, price = price, raw = key, lang = parsed.lang, text = ns.ChatParse.clean(text),
  }
  entries[key] = entry
  local repeated = old and old.request.dest == parsed.dest and not expired(old, t)
  if repeated then
    entry.request.at = old.request.at -- the same request said again keeps its place on the list
  elseif not activeRide() then
    ns.fire("INCOMING_REQUEST", entry)
  end
  changed()
end

-- List and invite ----------------------------------------------------------------------------------

function ChatReq.list()
  if not enabled() then
    return {}
  end
  local s, t = services(), ns.now()
  local list = {}
  for _, entry in pairs(entries) do
    if not expired(entry, t) and serves(s, entry.request.dest) then
      list[#list + 1] = entry
    end
  end
  table.sort(list, function(a, b)
    if a.request.at ~= b.request.at then
      return a.request.at < b.request.at
    end
    return a.request.key < b.request.key
  end)
  return list
end

function ChatReq.find(reqId)
  for _, entry in ipairs(ChatReq.list()) do
    if entry.request.reqId == reqId then
      return entry
    end
  end
end

function ChatReq.invite(reqId)
  if not enabled() then
    return nil, "duty"
  end
  if activeRide() then
    return nil, "busy"
  end
  local entry = ChatReq.find(reqId)
  if not entry then
    return nil, "request"
  end
  local invite = ns.api("C_PartyInfo.InviteUnit", "InviteUnit")
  if not invite then
    return nil, "invite"
  end
  invite(entry.raw)
  local send = ns.api("C_ChatInfo.SendChatMessage", "SendChatMessage")
  if send then
    local lang = WHISPER[entry.lang] and entry.lang or "en"
    local city = lang == "ru" and CITY_RU[entry.request.dest] or C.CITY[entry.request.dest].name
    send(WHISPER[lang]:format(city, ChatReq.money(entry.price, lang)), "WHISPER", nil, entry.raw)
  end
  entry.invited = true
  changed()
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
  -- Ages on the list move; redraw while there is anything to show.
  if any or next(entries) then
    changed()
  end
end

-- /ptx chat: reading taxi requests from chat on or off.
function ChatReq.command()
  local db = charDB()
  db.chatRequests = db.chatRequests == false
  if not db.chatRequests then
    entries = {}
  end
  ns.say(db.chatRequests and ns.L["Taxi requests from chat: on."] or ns.L["Taxi requests from chat: off."])
  changed()
end

function ChatReq.start()
  if frame then
    return
  end
  frame = CreateFrame("Frame")
  for _, event in ipairs(EVENTS) do
    pcall(frame.RegisterEvent, frame, event) -- an event unknown to this client must not stop the rest
  end
  frame:SetScript("OnEvent", function(_, event, ...) onChat(event, ...) end)
  C_Timer.NewTicker(EXPIRE_EVERY, expire)
end

ns.commands.chat = { fn = ChatReq.command, help = "taxi requests from public chat: on or off" }
ns.on("READY", ChatReq.start)
ns.on("MARKET_CHANGED", function()
  if not enabled() and next(entries) then
    entries = {} -- off duty: the list starts empty next time
    changed()
  end
end)
