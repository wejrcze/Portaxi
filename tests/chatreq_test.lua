-- Core/ChatReq.lua + the Drive tab and duty box: taxi requests from public chat for players without Portaxi
-- (playbook D16). The default stub player is a resting Horde mage with OG and UC portals.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local function taxi(over)
  local wow = Wow.new(over):load()
  wow:advance(1)
  wow.ns.Dispatch.setOnDuty(true)
  return wow
end

local function record(wow, event)
  local got = {}
  wow.ns.on(event, function(...) got[#got + 1] = { ... } end)
  return got
end

local function list(wow)
  return wow.ns.ChatReq.list()
end

T.test("a port request in General is listed with the taxi's pickup price and alerted once", function()
  local wow = taxi()
  local got = record(wow, "INCOMING_REQUEST")
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  local l = list(wow)
  T.eq(#l, 1)
  T.eq({ l[1].chat, l[1].request.reqId, l[1].request.key, l[1].request.dest, l[1].svc, l[1].price, l[1].lang },
    { true, "chat:Velvet Forever", "Velvet Forever", "OG", "PICK", 15000, "en" })
  T.eq(#got, 1)
  T.ok(got[1][1] == l[1])
  T.eq(wow.ns.UI.Alerts.text(l[1]), "Portaxi: Velvet Forever wants Orgrimmar (from chat)")
  wow:advance(20)
  wow:chat("SAY", "wtb port org pls", "Velvet Forever")
  T.eq(#got, 1, "the same request said again is not alerted again")
  T.eq(list(wow)[1].request.at, l[1].request.at, "and keeps its place")
end)

T.test("say, yell and whisper count; offers, own lines, PortaxiNet and unserved cities do not", function()
  local wow = taxi()
  wow:chat("SAY", "need port to undercity?", "Aaron Forever")
  wow:chat("YELL", "куплю порт в орг", "Boris Forever")
  wow:chat("WHISPER", "port org?", "Cyra Forever")
  wow:chat("CHANNEL", "WTS portals Org UC /w me", "Dax Forever")
  wow:chat("CHANNEL", "WTB port Org", wow:fullName())
  wow:chat("CHANNEL", "WTB port Org", "Eli Forever", { channel = "PortaxiNet" })
  wow:chat("CHANNEL", "WTB port Thunder Bluff", "Fen Forever") -- TB not learned
  wow:chat("CHANNEL", "need summon BRD", "Gus Forever")       -- a mage does not summon
  local keys = {}
  for _, e in ipairs(list(wow)) do keys[#keys + 1] = e.request.key end
  table.sort(keys)
  T.eq(keys, { "Aaron Forever", "Boris Forever", "Cyra Forever" })
end)

T.test("nothing is read off duty or with /ptx chat off; going off duty clears the list", function()
  local wow = Wow.new():load()
  wow:advance(1)
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  T.eq(#list(wow), 0, "off duty")
  wow.ns.Dispatch.setOnDuty(true)
  wow:slash("chat")
  T.ok(wow.printed[#wow.printed]:find("Taxi requests from chat: off.", 1, true))
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  T.eq(#list(wow), 0, "chat off")
  wow:slash("chat")
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  T.eq(#list(wow), 1)
  wow.ns.Dispatch.setOnDuty(false)
  wow.ns.Dispatch.setOnDuty(true)
  T.eq(#list(wow), 0, "cleared by going off duty")
end)

T.test("a chat request expires after T.CHAT_REQUEST", function()
  local wow = taxi()
  local changes = record(wow, "CHAT_REQUESTS_CHANGED")
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  wow:advance(wow.ns.Const.T.CHAT_REQUEST - 5)
  T.eq(#list(wow), 1)
  wow:advance(10)
  T.eq(#list(wow), 0)
  T.ok(#changes >= 2, "redraws while listed and when it goes")
end)

T.test("a sender without a surname is completed from the GUID", function()
  local wow = taxi()
  wow.guids = { ["Player-1-0001"] = { name = "Velvet", realm = "Moonbrook" } }
  wow:chat("CHANNEL", "WTB port Org", "Velvet", { guid = "Player-1-0001" })
  T.eq(list(wow)[1].request.key, "Velvet Moonbrook")
end)

T.test("a rider whose hail is on the network is not listed twice", function()
  local wow = taxi()
  wow:receive("PTX", "HAIL|1|Velvet:1|Horde|OG|COME,PICK|40000|1", "CHANNEL", "Velvet Forever")
  T.eq(#wow.ns.Dispatch.requests(), 1)
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  T.eq(#list(wow), 0)
end)

T.test("Invite: group invite to the full name and a whisper with city and price, in the rider's language", function()
  local wow = taxi()
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  wow:chat("CHANNEL", "куплю порт в подгород", "Boris Forever")
  T.ok(wow.ns.ChatReq.invite("chat:Velvet Forever"))
  T.ok(wow.ns.ChatReq.invite("chat:Boris Forever"))
  local invites = wow:callsTo("C_PartyInfo.InviteUnit")
  T.eq({ invites[1].args[1], invites[2].args[1] }, { "Velvet Forever", "Boris Forever" })
  local whispers = wow:callsTo("SendChatMessage")
  T.eq(whispers[1].args, { "Hi! I can open a portal to Orgrimmar for 1g 50s. Sending you a group invite.",
    "WHISPER", nil, "Velvet Forever" })
  T.eq(whispers[2].args, { "Привет! Могу открыть портал в Подгород за 1з 50с. Отправляю приглашение в группу.",
    "WHISPER", nil, "Boris Forever" })
  T.ok(list(wow)[1].invited)
  T.eq({ wow.ns.ChatReq.invite("chat:Nobody Here") }, { nil, "request" })
end)

T.test("Invite is refused during a ride and off duty", function()
  local wow = taxi()
  wow:chat("CHANNEL", "WTB port Org", "Velvet Forever")
  local real = wow.ns.Ride.current
  wow.ns.Ride.current = function() return { state = "PORTAL_OPEN" } end
  T.eq({ wow.ns.ChatReq.invite("chat:Velvet Forever") }, { nil, "busy" })
  wow.ns.Ride.current = real
  wow.ns.Dispatch.setOnDuty(false)
  T.eq({ wow.ns.ChatReq.invite("chat:Velvet Forever") }, { nil, "duty" })
  T.eq(#wow:callsTo("C_PartyInfo.InviteUnit"), 0)
end)

T.test("ChatReq.money formats gold and silver in both languages", function()
  local M = Wow.new():load().ns.ChatReq.money
  T.eq({ M(30000, "en"), M(15000, "ru"), M(500, "en"), M(7, "ru") }, { "3g", "1з 50с", "5s", "7м" })
end)

T.test("Drive tab and duty box: the chat request has a blue stripe and an Invite button that invites", function()
  local wow = taxi()
  wow:slash("show")
  wow.ns.UI.show("drive")
  wow:chat("CHANNEL", "LF mage port to Orgrimmar, will tip", "Velvet Forever")
  local D = wow.ns.UI.DriveTab
  local row = D.ui.requestRows[1]
  T.ok(row:IsShown())
  T.eq(row.who:GetText(), "Velvet Forever to Orgrimmar (chat)")
  T.ok(row.what:GetText():find('^"LF mage port to Orgrimmar, will ti%.%.%."'), row.what:GetText())
  T.ok(row.stripe:IsShown())
  T.eq(row.take:GetText(), "Invite")
  row.take:Click()
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args, { "Velvet Forever" })
  T.eq(row.take:GetText(), "Invite again")
  local box = wow.ns.UI.DutyBox
  T.ok(box.isShown())
  T.eq(box.take:GetText(), "Invite again")
  T.eq(#wow.errors, 0)
end)

T.done()
