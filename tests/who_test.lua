-- Core/Who.lua: the /who fallback of Inn hop (D20) for hosts without Portaxi.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

-- A client with a fake C_FriendList: SendWho records the filter; answer() fills the results and fires the event.
local function client()
  local wow = Wow.new():load()
  local fl = { sent = {}, list = {} }
  wow.env.C_FriendList = {
    SendWho = function(filter) fl.sent[#fl.sent + 1] = filter end,
    GetNumWhoResults = function() return #fl.list, #fl.list end,
    GetWhoInfo = function(i) return fl.list[i] end,
  }
  local whispers = {}
  wow.env.SendChatMessage = function(msg, kind, _, target)
    whispers[#whispers + 1] = { msg = msg, kind = kind, target = target }
  end
  local function answer(list)
    fl.list = list
    wow:fire("WHO_LIST_UPDATE")
  end
  return wow, fl, answer, whispers
end

local BARRENS = {
  { fullName = "Zorg Axehand", level = 22, classStr = "Warrior", raceStr = "Orc", area = "The Barrens" },
  { fullName = "Thalindra Forever", level = 40, classStr = "Mage", raceStr = "Orc", area = "The Barrens" },
  { fullName = "Amira Sunfall", level = 18, classStr = "Priest", raceStr = "Troll", area = "The Barrens" },
}

T.test("search sends a zone filter, keeps a gap between searches; results without ourselves, by key", function()
  local wow, fl, answer = client()
  local got = {}
  wow.ns.on("WHO_RESULTS", function(list, zone) got[#got + 1] = { list, zone } end)
  T.eq({ wow.ns.Who.search("") }, { nil, "zone" })
  T.ok(wow.ns.Who.search(' "The Barrens" '))
  T.eq(fl.sent, { 'z-"The Barrens"' })
  T.eq({ wow.ns.Who.search("The Barrens") }, { nil, "cooldown" })
  answer(BARRENS)
  T.eq(#got, 1)
  T.eq(got[1][2], "The Barrens")
  local list = wow.ns.Who.results()
  T.eq(#list, 2)
  T.eq({ list[1].key, list[1].raw, list[1].level, list[1].class }, { "Amira Sunfall", "Amira Sunfall", 18, "Priest" })
  T.eq(list[2].key, "Zorg Axehand")
  wow:advance(5)
  T.ok(wow.ns.Who.search("Ashenvale"), "after the gap")
  T.eq(#wow.errors, 0)
end)

T.test("a /who answer we did not ask for (or too late) is ignored", function()
  local wow, _, answer = client()
  answer(BARRENS)
  T.eq(wow.ns.Who.results(), {})
  wow.ns.Who.search("The Barrens")
  wow:advance(11)
  answer(BARRENS)
  T.eq(wow.ns.Who.results(), {})
end)

T.test("ask whispers the template; once the asked player has us in the group, a noAddon HOP ride starts", function()
  local wow, _, answer, whispers = client()
  wow.ns.Who.search("The Barrens")
  answer(BARRENS)
  T.eq({ wow.ns.Who.ask("Nobody Here") }, { nil, "who" })
  T.ok(wow.ns.Who.ask("Zorg Axehand"))
  T.eq(whispers[1].kind, "WHISPER")
  T.eq(whispers[1].target, "Zorg Axehand")
  T.ok(whispers[1].msg:find("Scroll of Liminal Passage", 1, true))
  T.ok(wow.ns.Who.awaiting()["Zorg Axehand"])
  wow:joinParty("Somebody")
  T.eq(wow.ns.Ride.current(), nil, "another player joining starts nothing")
  wow:joinParty("Zorg", { realm = "Axehand", faction = "Horde" })
  local r = wow.ns.Ride.current()
  T.ok(r, "ride started")
  T.eq({ r.svc, r.role, r.peer.key, r.peer.noAddon, r.riderResting }, { "HOP", "taxi", "Zorg Axehand", true, true })
  T.eq(wow.ns.Who.awaiting(), {})
  T.eq(#wow.errors, 0)
end)

T.test("an ask expires after T.INVITE", function()
  local wow, _, answer = client()
  wow.ns.Who.search("The Barrens")
  answer(BARRENS)
  wow.ns.Who.ask("Zorg Axehand")
  wow:advance(61)
  wow:joinParty("Zorg", { realm = "Axehand" })
  T.eq(wow.ns.Ride.current(), nil)
  T.eq(wow.ns.Who.awaiting(), {})
end)

T.done()
