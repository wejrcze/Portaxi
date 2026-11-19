-- Core/ChatOffers.lua + the Ride tab's Browse list: portal ads of mages without Portaxi read from public chat
-- (playbook D18). The default stub player is a Horde mage in Orgrimmar with 45g 57s; for these tests a rider.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local function rider()
  local wow = Wow.new():load()
  wow:advance(2)
  return wow
end

local function list(wow, dest)
  return wow.ns.ChatOffers.list(dest or "OG")
end

local function keys(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = e.key
  end
  return out
end

-- /who as the modern client has it: wow.who holds the answers of the last query.
local function withWho(wow)
  wow.who = {}
  wow.env.C_FriendList = {
    SendWho = function(filter) wow:record("C_FriendList.SendWho", filter) end,
    GetNumWhoResults = function() return #wow.who end,
    GetWhoInfo = function(i) return wow.who[i] end,
  }
end

local function says(wow)
  local out = {}
  for _, c in ipairs(wow:callsTo("SendChatMessage")) do
    out[#out + 1] = { c.args[1], c.args[2], c.args[4] }
  end
  return out
end

T.test("an ad in Trade is listed for its cities with the price named for each, cheapest first", function()
  local wow = rider()
  local changes = 0
  wow.ns.on("CHAT_OFFERS_CHANGED", function() changes = changes + 1 end)
  wow:chat("CHANNEL", "WTS ports UC 50s, Org 1g", "Mira Forever", { channel = "Trade - City" })
  wow:chat("CHANNEL", "Portals to Org/UC/TB, 75s each pst", "Odo Forever", { channel = "Trade - City" })
  wow:chat("CHANNEL", "WTS portals to all cities, tips", "Pell Forever", { channel = "Trade - City" })
  T.ok(changes >= 3)
  local og = list(wow, "OG")
  T.eq(keys(og), { "Odo Forever", "Mira Forever", "Pell Forever" }, "priced first, cheapest first")
  T.eq({ og[1].chat, og[1].price, og[1].place, og[1].lang }, { true, 7500, nil, "en" })
  T.eq(og[2].price, 10000)
  T.eq({ og[3].price, og[3].tip }, { nil, true })
  T.eq(keys(list(wow, "UC")), { "Mira Forever", "Odo Forever", "Pell Forever" })
  T.eq(list(wow, "UC")[1].price, 5000)
  T.eq(keys(list(wow, "TB")), { "Odo Forever", "Pell Forever" })
end)

T.test("where the mage stands: the ad, a zone channel or say / yell from the same zone; Trade has no place", function()
  local wow = rider()
  wow:chat("CHANNEL", "WTS ports UC/TB, in Org", "Aaron Forever", { channel = "Trade - City" })
  wow:chat("CHANNEL", "WTS ports UC TB 1g", "Bert Forever", { channel = "General - Orgrimmar" })
  wow:chat("CHANNEL", "WTS ports UC TB 1g", "Cyra Forever", { channel = "General - Durotar" })
  wow:chat("YELL", "WTS ports UC TB 1g", "Dax Forever")
  wow:chat("WHISPER", "WTS ports UC TB 1g", "Eli Forever")
  local places = {}
  for _, e in ipairs(list(wow, "UC")) do
    places[e.key] = e.place or "-"
  end
  T.eq(places, { ["Aaron Forever"] = "Orgrimmar", ["Bert Forever"] = "Orgrimmar", ["Cyra Forever"] = "-",
    ["Dax Forever"] = "Orgrimmar", ["Eli Forever"] = "-" })
end)

T.test("requests, own lines, PortaxiNet, non-mages, summons and Portaxi mages are left out", function()
  local wow = rider()
  wow.guids = { ["Player-1"] = { name = "Wex", realm = "Forever" } } -- the stub answers WARRIOR
  wow:chat("CHANNEL", "WTB port Org", "Aaron Forever")
  wow:chat("CHANNEL", "WTS ports Org UC", wow:fullName())
  wow:chat("CHANNEL", "WTS ports Org UC", "Bert Forever", { channel = "PortaxiNet" })
  wow:chat("CHANNEL", "WTS ports Org UC", "Wex", { guid = "Player-1" })
  wow:chat("CHANNEL", "WTS summons 2g", "Gus Forever")
  wow:chat("CHANNEL", "WTS ports Org UC", "Hal Forever")
  T.eq(keys(list(wow)), { "Hal Forever" })
  wow:receive("PTX", assert(wow.ns.Protocol.encode({ type = "HELLO", fac = "Horde", cls = "MAGE", lvl = 40,
    place = "Orgrimmar", dests = { "OG" }, ask = { PICK = 20000 }, resp = 20, wait = 0 })), "CHANNEL", "Hal Forever")
  T.eq(#list(wow), 0, "Hal runs Portaxi: the network offer is listed instead")
end)

T.test("a newer ad replaces the old one; ads expire after T.CHAT_OFFER; /ptx chat off clears them", function()
  local wow = rider()
  wow:chat("CHANNEL", "WTS ports Org 2g", "Mira Forever")
  wow:chat("CHANNEL", "WTS ports Org 1g", "Mira Forever")
  T.eq(#list(wow), 1)
  T.eq(list(wow)[1].price, 10000)
  wow:advance(wow.ns.Const.T.CHAT_OFFER - 5)
  T.eq(#list(wow), 1)
  wow:advance(10)
  T.eq(#list(wow), 0, "expired")
  wow:chat("CHANNEL", "WTS ports Org 1g", "Mira Forever")
  wow:slash("chat")
  T.eq(#list(wow), 0, "chat off")
  wow:chat("CHANNEL", "WTS ports Org 1g", "Mira Forever")
  T.eq(#list(wow), 0, "not read while off")
  wow:slash("chat")
  wow:chat("CHANNEL", "WTS ports Org 1g", "Mira Forever")
  T.eq(#list(wow), 1)
end)

T.test("invite: a group invite and a whisper in the ad's language, with the price named", function()
  local wow = rider()
  wow:chat("CHANNEL", "WTS ports UC 50s, Org 1g", "Mira Forever")
  wow:chat("CHANNEL", "продаю порты во все столицы", "Ольга Forever")
  local ChatOffers = wow.ns.ChatOffers
  T.ok(ChatOffers.invite("Mira Forever", "UC"))
  T.ok(ChatOffers.invite("Ольга Forever", "UC"))
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args[1], "Mira Forever")
  T.eq(says(wow), {
    { "Hi! I'd like a portal to Undercity for 50s. Sending you a group invite.", "WHISPER", "Mira Forever" },
    { "Привет! Нужен портал в Подгород. Отправляю приглашение в группу.", "WHISPER", "Ольга Forever" },
  })
  T.ok(ChatOffers.find("Mira Forever").invited)
  T.eq({ ChatOffers.invite("Mira Forever", "TB") }, { nil, "offer" }, "Mira does not offer TB")
  T.eq({ ChatOffers.invite("Nobody Forever", "UC") }, { nil, "offer" })
  wow.env.UnitIsGroupLeader = function() return false end
  wow:joinParty("Friend")
  T.eq({ ChatOffers.invite("Mira Forever", "UC") }, { nil, "group" })
end)

T.test("Where? asks /who for the mage; the answer becomes the place and outlives a newer ad", function()
  local wow = rider()
  withWho(wow)
  wow:chat("CHANNEL", "WTS ports Org UC 1g", "Mira Forever", { channel = "Trade - City" })
  T.ok(wow.ns.ChatOffers.locate("Mira Forever"))
  T.eq(wow:callsTo("C_FriendList.SendWho")[1].args[1], 'n-"Mira"')
  wow.who = { { fullName = "Mira Other", area = "Durotar", filename = "MAGE" },
    { fullName = "Mira Forever", area = "Undercity", filename = "MAGE" } }
  wow:fire("WHO_LIST_UPDATE")
  local e = list(wow)[1]
  T.eq(e.place, "Undercity")
  T.ok(e.whoAt ~= nil)
  wow:chat("CHANNEL", "WTS ports Org UC 1g", "Mira Forever", { channel = "Trade - City" })
  T.eq(list(wow)[1].place, "Undercity", "a newer Trade ad keeps the /who place")
  wow.env.C_FriendList = nil
  T.eq({ wow.ns.ChatOffers.locate("Mira Forever") }, { nil, "who" })
end)

T.test("Browse shows the ads after the Portaxi taxis, with Invite, Where? and the tile count", function()
  local wow = rider()
  withWho(wow)
  local ns = wow.ns
  ns.UI.show("ride")
  local R = ns.UI.RideTab
  local ui = R.ui
  ui.modes.browse:Click()
  ui.tiles[1]:Click() -- Orgrimmar
  wow:receive("PTX", assert(ns.Protocol.encode({ type = "HELLO", fac = "Horde", cls = "MAGE", lvl = 40,
    place = "Undercity", dests = { "OG" }, ask = { PICK = 20000 }, resp = 20, wait = 0 })), "CHANNEL", "Aaron Forever")
  wow:chat("CHANNEL", "WTS ports to Org 75s pst", "Mira Forever", { channel = "Trade - City" })
  wow:chat("YELL", "WTS portals Org UC TB, tips", "Odo Forever")
  wow:chat("CHANNEL", "WTS port Org 60g", "Rich Forever", { channel = "Trade - City" })
  local rows = ui.rows
  T.eq(rows[1].who:GetText(), "Aaron Forever · Pickup")
  T.ok(not rows[1].stripe:IsShown() and not rows[1].where:IsShown())
  T.eq(rows[2].who:GetText(), "Mira Forever (chat)")
  T.eq(rows[2].place:GetText(), '"WTS ports to Org 75s pst"')
  T.eq(rows[2].price:GetText(), "75s")
  T.eq(rows[2].book:GetText(), "Invite")
  T.ok(rows[2].stripe:IsShown() and rows[2].where:IsShown() and rows[2].book:IsEnabled())
  T.eq(rows[3].who:GetText(), "Rich Forever (chat)")
  T.eq(rows[3].book:GetText(), "Too dear")
  T.ok(not rows[3].book:IsEnabled())
  T.eq(rows[4].who:GetText(), "Odo Forever (chat)")
  T.eq({ rows[4].place:GetText(), rows[4].price:GetText() }, { "Orgrimmar", "tips" })
  T.eq(ui.tiles[1].sub:GetText(), "from 75s · 4 taxis")
  T.eq(ui.tiles[2].sub:GetText(), "1 taxi", "only Odo offers UC, without a price")

  rows[2].where:Click()
  wow.who = { { fullName = "Mira Forever", area = "Undercity", filename = "MAGE" } }
  wow:fire("WHO_LIST_UPDATE")
  T.eq(rows[2].place:GetText(), "Undercity")
  T.ok(not rows[2].where:IsShown(), "the place is known")

  rows[2].book:Click()
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args[1], "Mira Forever")
  T.eq(says(wow)[1][1], "Hi! I'd like a portal to Orgrimmar for 75s. Sending you a group invite.")
  T.eq(rows[2].book:GetText(), "Invite again")
  T.eq(ui.status:GetText(), "")
end)

T.done()
