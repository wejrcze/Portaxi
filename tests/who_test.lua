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

-- Towns with an inn ----------------------------------------------------------------------------------

T.test("a town with an inn is searched by its zone; players there come first, then inn towns, then the rest", function()
  local wow, fl, answer = client()
  T.eq({ wow.ns.Who.resolve("the crossroads") }, { "The Barrens", "The Crossroads" })
  T.eq({ wow.ns.Who.resolve("Ashenvale") }, { "Ashenvale", nil })
  T.eq({ wow.ns.Who.resolve("Crossroads") }, { "Crossroads", nil }, "a partial name is taken as a zone")
  T.ok(wow.ns.Who.search("The Crossroads"))
  T.eq(fl.sent[#fl.sent], 'z-"The Barrens"')
  answer({
    { fullName = "Amy Field", level = 20, classStr = "Hunter", area = "Camp Taurajo" },
    { fullName = "Bob Road", level = 21, classStr = "Rogue", area = "Gold Road" },
    { fullName = "Cid Inn", level = 22, classStr = "Priest", area = "The Crossroads" },
  })
  local list, zone, town = wow.ns.Who.results()
  T.eq({ zone, town }, { "The Barrens", "The Crossroads" })
  T.eq({ list[1].key, list[1].here, list[1].inn }, { "Cid Inn", true, true })
  T.eq({ list[2].key, list[2].here, list[2].inn }, { "Amy Field", false, true }, "Camp Taurajo has an inn too")
  T.eq({ list[3].key, list[3].inn }, { "Bob Road", false })
  T.eq(#wow.errors, 0)
end)

T.test("resting places are learned: our own outside the capitals, and hosts' HOST at an inn", function()
  local wow = client()
  T.eq(wow.ns.Who.isInn("Sunnyglade"), false)
  wow.ns.fire("PROFILE_CHANGED", { resting = true, zone = "Riverglades", subzone = "Sunnyglade" }, {})
  T.eq(wow.ns.Who.isInn("sunnyglade"), true)
  T.eq(wow.env.PortaxiDB.inns.sunnyglade.zone, "Riverglades")
  T.eq({ wow.ns.Who.resolve("Sunnyglade") }, { "Riverglades", "Sunnyglade" })
  wow.ns.fire("PROFILE_CHANGED", { resting = true, zone = "Orgrimmar", subzone = "Valley of Strength" }, {})
  T.eq(wow.ns.Who.isInn("Valley of Strength"), false, "capital quarters are not inn towns")
  wow.ns.fire("PROFILE_CHANGED", { resting = false, zone = "Durotar", subzone = "Senjin Village" }, {})
  T.eq(wow.ns.Who.isInn("Senjin Village"), false, "only while resting")
  wow.ns.fire("NET_MSG", { type = "HOST", fac = "Horde", lvl = 30, zone = "Azshara", sub = "Valormok", city = "",
    free = true }, "Kim Forever", "Kim Forever")
  T.eq(wow.ns.Who.isInn("Valormok"), true)
end)

T.done()
