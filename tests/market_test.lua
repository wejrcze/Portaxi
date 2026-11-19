-- Core/Market.lua: offers, requests, expiry, hail matching (pure module, playbook §2 "Market").
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local wow = Wow.new():load()
local Market = wow.ns.Market
local Const = wow.ns.Const

local function helloMsg(over)
  local h = { fac = "Horde", cls = "MAGE", lvl = 40, place = "Orgrimmar", dests = { "OG", "UC" },
    ask = { COME = 30000, PICK = 15000 }, resp = 20, wait = 300 }
  for k, v in pairs(over or {}) do
    h[k] = v
  end
  return h
end

local function hailMsg(over)
  local h = { reqId = "Rider:1", fac = "Horde", dest = "UC", svcs = { "COME", "PICK" }, max = 40000, rest = true }
  for k, v in pairs(over or {}) do
    h[k] = v
  end
  return h
end

local function taxiOf(over)
  local t = { faction = "Horde", prices = { COME = 30000, PICK = 15000 },
    services = { canDrive = true, COME = true, PICK = true, dests = { "OG", "UC" }, pauses = {} } }
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return t
end

local function keysOf(list)
  local out = {}
  for i, e in ipairs(list) do
    out[i] = e.key or e.request.key
  end
  return out
end

-- hello / bye ---------------------------------------------------------------------------------

T.test("hello stores the offer with waitSince = now - wait and seen = now", function()
  local m = Market.new()
  m:hello("Mage", helloMsg(), 1000)
  local list = m:offers({ dest = "UC", svc = "PICK", faction = "Horde" })
  T.eq(#list, 1)
  local o = list[1].offer
  T.eq(o.key, "Mage")
  T.eq(o.waitSince, 700)
  T.eq(o.seen, 1000)
  T.eq({ o.fac, o.cls, o.lvl, o.place, o.resp }, { "Horde", "MAGE", 40, "Orgrimmar", 20 })
  T.eq(o.dests, { "OG", "UC" })
  T.eq(o.ask, { COME = 30000, PICK = 15000 })
end)

T.test("a newer hello from the same key replaces the offer", function()
  local m = Market.new()
  m:hello("Mage", helloMsg(), 1000)
  m:hello("Mage", helloMsg({ ask = { PICK = 9000 }, wait = 10 }), 1050)
  local list = m:offers({ dest = "UC", svc = "PICK", faction = "Horde" })
  T.eq(#list, 1)
  T.eq(list[1].price, 9000)
  T.eq(list[1].offer.waitSince, 1040)
  T.eq(list[1].offer.seen, 1050)
  T.eq(#m:offers({ dest = "UC", svc = "COME", faction = "Horde" }), 0, "COME no longer offered")
end)

T.test("bye removes the offer; bye of an unknown key is harmless", function()
  local m = Market.new()
  m:hello("Mage", helloMsg(), 1000)
  m:bye("Mage")
  m:bye("Nobody")
  T.eq(m:offers({ dest = "UC", svc = "PICK", faction = "Horde" }), {})
end)

-- offers ----------------------------------------------------------------------------------------

T.test("offers filters by dest, svc and faction", function()
  local m = Market.new()
  m:hello("A", helloMsg({ dests = { "OG" } }), 0)
  m:hello("B", helloMsg({ dests = { "UC" }, ask = { PICK = 12000 } }), 0)
  m:hello("C", helloMsg({ fac = "Alliance", dests = { "SW" } }), 0)
  T.eq(keysOf(m:offers({ dest = "OG", svc = "COME", faction = "Horde" })), { "A" })
  T.eq(keysOf(m:offers({ dest = "UC", svc = "PICK", faction = "Horde" })), { "B" })
  T.eq(keysOf(m:offers({ dest = "UC", svc = "COME", faction = "Horde" })), {})
  T.eq(keysOf(m:offers({ dest = "SW", svc = "COME", faction = "Horde" })), {}, "other faction")
  T.eq(keysOf(m:offers({ dest = "SW", svc = "COME", faction = "Alliance" })), { "C" })
end)

T.test("offers are sorted by price, then key, and have the contract shape", function()
  local m = Market.new()
  m:hello("Zed", helloMsg({ ask = { PICK = 10000 } }), 0)
  m:hello("Bob", helloMsg({ ask = { PICK = 20000 } }), 0)
  m:hello("Amy", helloMsg({ ask = { PICK = 10000 } }), 0)
  local list = m:offers({ dest = "OG", svc = "PICK", faction = "Horde" })
  T.eq(keysOf(list), { "Amy", "Zed", "Bob" })
  local e = list[1]
  T.eq({ e.key, e.svc, e.price }, { "Amy", "PICK", 10000 })
  T.ok(e.offer.key == "Amy", "offer attached")
end)

-- expire ----------------------------------------------------------------------------------------

T.test("expire drops an offer exactly T.OFFER after the last hello, not before", function()
  local m = Market.new()
  m:hello("Old", helloMsg(), 100)
  m:hello("New", helloMsg(), 200)
  local keys, ids = m:expire(100 + Const.T.OFFER - 1)
  T.eq(keys, {})
  T.eq(ids, {})
  keys = m:expire(100 + Const.T.OFFER)
  T.eq(keys, { "Old" })
  T.eq(keysOf(m:offers({ dest = "OG", svc = "PICK", faction = "Horde" })), { "New" })
end)

T.test("a new hello refreshes the offer's expiry", function()
  local m = Market.new()
  m:hello("Mage", helloMsg(), 0)
  m:hello("Mage", helloMsg(), 100)
  T.eq(m:expire(Const.T.OFFER), {})
  T.eq(m:expire(100 + Const.T.OFFER), { "Mage" })
end)

T.test("expire drops requests exactly T.REQUEST after the hail and returns sorted reqIds", function()
  local m = Market.new()
  m:hail("Rb", hailMsg({ reqId = "Rb:1" }), 50)
  m:hail("Ra", hailMsg({ reqId = "Ra:7" }), 50)
  m:hail("Rc", hailMsg({ reqId = "Rc:2" }), 60)
  local keys, ids = m:expire(50 + Const.T.REQUEST - 1)
  T.eq(ids, {})
  keys, ids = m:expire(50 + Const.T.REQUEST)
  T.eq(keys, {})
  T.eq(ids, { "Ra:7", "Rb:1" })
  T.eq(keysOf(m:openRequests(taxiOf(), 50 + Const.T.REQUEST)), { "Rc" })
end)

T.test("expire returns removed offer keys sorted A-Z", function()
  local m = Market.new()
  for _, k in ipairs({ "Delta", "Alpha", "Charlie", "Bravo" }) do
    m:hello(k, helloMsg(), 0)
  end
  T.eq(m:expire(1000), { "Alpha", "Bravo", "Charlie", "Delta" })
end)

-- hail / gone -----------------------------------------------------------------------------------

T.test("hail stores the request fields with at = now", function()
  local m = Market.new()
  m:hail("Rider", hailMsg(), 42)
  local r = m:openRequests(taxiOf(), 42)[1].request
  T.eq(r, { key = "Rider", reqId = "Rider:1", fac = "Horde", dest = "UC", svcs = { "COME", "PICK" },
    max = 40000, rest = true, at = 42 })
end)

T.test("a new hail from the same key replaces the previous open request", function()
  local m = Market.new()
  m:hail("Rider", hailMsg({ reqId = "Rider:1", dest = "UC" }), 10)
  m:hail("Rider", hailMsg({ reqId = "Rider:2", dest = "OG" }), 20)
  local list = m:openRequests(taxiOf(), 20)
  T.eq(#list, 1)
  T.eq(list[1].request.reqId, "Rider:2")
  T.eq(list[1].request.at, 20)
  T.eq(m:gone("Rider:1"), false, "old reqId is gone already")
end)

T.test("gone removes a request by reqId and leaves others", function()
  local m = Market.new()
  m:hail("A", hailMsg({ reqId = "A:1" }), 0)
  m:hail("B", hailMsg({ reqId = "B:1" }), 0)
  T.eq(m:gone("A:1"), true)
  T.eq(m:gone("Nope:1"), false)
  T.eq(keysOf(m:openRequests(taxiOf(), 0)), { "B" })
end)

-- openRequests ----------------------------------------------------------------------------------

T.test("openRequests: same faction only", function()
  local m = Market.new()
  m:hail("H", hailMsg({ reqId = "H:1" }), 0)
  m:hail("A", hailMsg({ reqId = "A:1", fac = "Alliance" }), 0)
  T.eq(keysOf(m:openRequests(taxiOf(), 0)), { "H" })
end)

T.test("openRequests: dest must be one of services.dests", function()
  local m = Market.new()
  m:hail("R", hailMsg({ dest = "TB" }), 0)
  T.eq(m:openRequests(taxiOf(), 0), {})
end)

T.test("openRequests: COME only when services.COME and the rider rests", function()
  local m = Market.new()
  m:hail("R", hailMsg({ svcs = { "COME" } }), 0)
  T.eq(#m:openRequests(taxiOf(), 0), 1)
  local noCome = taxiOf()
  noCome.services.COME = false
  T.eq(m:openRequests(noCome, 0), {}, "taxi cannot COME")
  m:hail("R", hailMsg({ svcs = { "COME" }, rest = false }), 0)
  T.eq(m:openRequests(taxiOf(), 0), {}, "rider not resting")
end)

T.test("openRequests: falls back to PICK when COME is not possible", function()
  local m = Market.new()
  m:hail("R", hailMsg({ rest = false }), 0)
  local list = m:openRequests(taxiOf(), 0)
  T.eq({ list[1].svc, list[1].price }, { "PICK", 15000 })
end)

T.test("openRequests: price must be <= max, boundary included", function()
  local m = Market.new()
  m:hail("R", hailMsg({ max = 30000 }), 0)
  T.eq({ m:openRequests(taxiOf(), 0)[1].svc, m:openRequests(taxiOf(), 0)[1].price }, { "COME", 30000 })
  m:hail("R", hailMsg({ max = 29999 }), 0)
  T.eq(m:openRequests(taxiOf(), 0)[1].svc, "PICK", "COME too expensive, PICK fits")
  m:hail("R", hailMsg({ max = 14999 }), 0)
  T.eq(m:openRequests(taxiOf(), 0), {}, "nothing fits")
end)

T.test("openRequests: prefers COME over PICK and needs a service the rider wants", function()
  local m = Market.new()
  m:hail("R", hailMsg(), 0)
  local e = m:openRequests(taxiOf(), 0)[1]
  T.eq({ e.svc, e.price }, { "COME", 30000 })
  m:hail("R", hailMsg({ svcs = { "PICK" } }), 0)
  T.eq(m:openRequests(taxiOf(), 0)[1].svc, "PICK", "rider wants only PICK")
  local onlyCome = taxiOf()
  onlyCome.services.PICK = false
  T.eq(m:openRequests(onlyCome, 0), {}, "taxi offers only COME, rider only PICK")
end)

T.test("openRequests: skips the taxi's own hail", function()
  local m = Market.new()
  m:hail("Mage", hailMsg({ reqId = "Mage:1" }), 0)
  m:hail("Rider", hailMsg({ reqId = "Rider:1" }), 0)
  T.eq(keysOf(m:openRequests(taxiOf({ key = "Mage" }), 0)), { "Rider" })
  T.eq(keysOf(m:openRequests(taxiOf(), 0)), { "Mage", "Rider" }, "without taxi.key nothing is skipped")
end)

T.test("openRequests: oldest request first, ties by reqId", function()
  local m = Market.new()
  m:hail("C", hailMsg({ reqId = "C:1" }), 30)
  m:hail("A", hailMsg({ reqId = "A:1" }), 20)
  m:hail("B", hailMsg({ reqId = "B:1" }), 10)
  m:hail("D", hailMsg({ reqId = "D:1" }), 20)
  T.eq(keysOf(m:openRequests(taxiOf(), 40)), { "B", "A", "D", "C" })
end)

T.test("openRequests: skips requests already past T.REQUEST without expire()", function()
  local m = Market.new()
  m:hail("R", hailMsg(), 0)
  T.eq(#m:openRequests(taxiOf(), Const.T.REQUEST - 1), 1)
  T.eq(m:openRequests(taxiOf(), Const.T.REQUEST), {})
end)

-- pickHailWinner --------------------------------------------------------------------------------

local function take(key, eta, wait)
  return { key = key, eta = eta, wait = wait, price = 15000, svc = "PICK" }
end

-- Every permutation of a list (small lists only).
local function permutations(list)
  if #list <= 1 then
    return { list }
  end
  local out = {}
  for i = 1, #list do
    local rest = {}
    for j = 1, #list do
      if j ~= i then
        rest[#rest + 1] = list[j]
      end
    end
    for _, p in ipairs(permutations(rest)) do
      table.insert(p, 1, list[i])
      out[#out + 1] = p
    end
  end
  return out
end

T.test("pickHailWinner: lowest eta wins when nobody is within the tie", function()
  local w = Market.pickHailWinner({ take("A", 100, 999), take("B", 40, 0), take("C", 70, 500) }, 15)
  T.eq(w.key, "B")
end)

T.test("pickHailWinner: within the tie the longest wait wins", function()
  local w = Market.pickHailWinner({ take("A", 40, 10), take("B", 50, 300), take("C", 60, 900) }, 15)
  T.eq(w.key, "B", "C is outside min + tie")
end)

T.test("pickHailWinner: eta exactly min + tie is a candidate", function()
  local w = Market.pickHailWinner({ take("A", 40, 10), take("B", 55, 300) }, 15)
  T.eq(w.key, "B")
  w = Market.pickHailWinner({ take("A", 40, 10), take("B", 56, 300) }, 15)
  T.eq(w.key, "A", "one second over the tie")
end)

T.test("pickHailWinner: equal wait goes to key A-Z", function()
  local w = Market.pickHailWinner({ take("Zed", 40, 100), take("Amy", 45, 100), take("Bob", 40, 100) }, 15)
  T.eq(w.key, "Amy")
end)

T.test("pickHailWinner: tie defaults to Const.HAIL_TIE", function()
  local tie = Const.HAIL_TIE
  T.eq(Market.pickHailWinner({ take("A", 40, 10), take("B", 40 + tie, 300) }).key, "B")
  T.eq(Market.pickHailWinner({ take("A", 40, 10), take("B", 41 + tie, 300) }).key, "A")
end)

T.test("pickHailWinner: no takes -> nil", function()
  T.eq(Market.pickHailWinner({}, 15), nil)
  T.eq(Market.pickHailWinner(nil, 15), nil)
end)

T.test("pickHailWinner: same winner for every order of the same takes", function()
  local sets = {
    { take("A", 40, 10), take("B", 50, 300), take("C", 55, 300), take("D", 80, 999) },
    { take("Zed", 40, 100), take("Amy", 45, 100), take("Bob", 40, 100), take("Cid", 30, 50) },
    { take("X", 10, 0), take("X", 10, 0), take("Y", 25, 0), take("W", 26, 5) },
  }
  for i, set in ipairs(sets) do
    local first = Market.pickHailWinner(set, 15)
    for _, p in ipairs(permutations(set)) do
      local w = Market.pickHailWinner(p, 15)
      T.eq({ w.key, w.eta, w.wait }, { first.key, first.eta, first.wait }, "set " .. i)
    end
  end
end)

-- affordable --------------------------------------------------------------------------------------

-- Taxis on the map (D19) ----------------------------------------------------------------------

local function spotMsg(inst, n, w, busy)
  return { inst = inst, n = n, w = w, busy = busy or false }
end

local function rider(over)
  local q = { faction = "Horde", dest = "UC", inst = 1, n = 0, w = 0 }
  for k, v in pairs(over or {}) do
    q[k] = v
  end
  return q
end

T.test("spot: kept apart from offers, counts once the HELLO is there; inst -1 removes it", function()
  local m = Market.new()
  T.eq(m:spot("Mage", spotMsg(1, 300, 400), 1000), true, "a SPOT before the first HELLO is kept")
  T.eq(#m:nearby(rider(), 1000), 0, "but not shown without an offer")
  m:hello("Mage", helloMsg(), 1001)
  T.eq(#m:nearby(rider(), 1001), 1)
  T.eq(m.spotByKey.Mage, { inst = 1, n = 300, w = 400, busy = false, at = 1000 })
  T.eq(m:spot("Mage", spotMsg(-1, 0, 0), 1020), true)
  T.eq(m.spotByKey.Mage, nil)
  T.eq(m:spot("Mage", spotMsg(-1, 0, 0), 1021), false, "nothing left to remove")
  T.eq(m.offerByKey.Mage ~= nil, true, "the offer stays: the taxi is back in town")
end)

T.test("nearby: same instance, in range, PICK for the city and faction, nearest first, with yards", function()
  local m = Market.new()
  local R = Const.FIELD.RANGE
  m:hello("Far", helloMsg(), 0)
  m:spot("Far", spotMsg(1, 0, R + 1), 0)
  m:hello("Near", helloMsg(), 0)
  m:spot("Near", spotMsg(1, 300, 400, true), 0)
  m:hello("Edge", helloMsg(), 0)
  m:spot("Edge", spotMsg(1, R, 0), 0)
  m:hello("Other", helloMsg(), 0)
  m:spot("Other", spotMsg(0, 10, 10), 0)
  m:hello("NoUC", helloMsg({ dests = { "OG" } }), 0)
  m:spot("NoUC", spotMsg(1, 10, 10), 0)
  m:hello("ComeOnly", helloMsg({ ask = { COME = 30000 } }), 0)
  m:spot("ComeOnly", spotMsg(1, 10, 10), 0)
  m:hello("Ally", helloMsg({ fac = "Alliance" }), 0)
  m:spot("Ally", spotMsg(1, 10, 10), 0)
  m:hello("NoSpot", helloMsg(), 0)
  local list = m:nearby(rider(), 5)
  T.eq(keysOf(list), { "Near", "Edge" })
  T.eq(list[1].yards, 500)
  T.eq(list[1].busy, true)
  T.eq({ list[1].svc, list[1].price }, { "PICK", 15000 })
  T.eq(list[2].yards, R, "the range itself counts")
  T.eq(keysOf(m:nearby(rider({ exclude = "Near" }), 5)), { "Edge" }, "own key left out")
end)

T.test("a spot lives T.SPOT_TTL without a new SPOT; expire drops it but keeps the offer", function()
  local m = Market.new()
  local ttl = Const.T.SPOT_TTL
  m:hello("Mage", helloMsg(), 0)
  m:spot("Mage", spotMsg(1, 10, 10), 0)
  T.eq(#m:nearby(rider(), ttl - 1), 1)
  T.eq(#m:nearby(rider(), ttl), 0, "stale without expire()")
  m:hello("Mage", helloMsg(), ttl)
  m:expire(ttl)
  T.eq(m.offerByKey.Mage ~= nil, true)
  T.eq(m.spotByKey.Mage, nil)
  m:spot("Mage", spotMsg(1, 10, 10), ttl + 1)
  m:bye("Mage")
  T.eq(#m:nearby(rider(), ttl + 2), 0, "bye takes the spot with the offer")
end)

T.test("affordable: money >= price", function()
  T.eq(Market.affordable(30000, 30000), true)
  T.eq(Market.affordable(30001, 30000), true)
  T.eq(Market.affordable(29999, 30000), false)
  T.eq(Market.affordable(0, 1000), false)
end)

-- purity ----------------------------------------------------------------------------------------

T.test("Market.lua runs with only ns.Const and the Lua standard library (no game API)", function()
  local std = { "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "setmetatable",
    "getmetatable", "tonumber", "tostring", "type", "unpack", "string", "table", "math" }
  local touched = {}
  local env = {}
  for _, name in ipairs(std) do
    env[name] = _G[name]
  end
  setmetatable(env, { __index = function(_, k)
    touched[#touched + 1] = k
    error("global access: " .. tostring(k), 2)
  end })
  local ns = {}
  local constChunk = assert(loadfile("Portaxi/Core/Const.lua"))
  setfenv(constChunk, env)
  constChunk("Portaxi", ns)
  local chunk = assert(loadfile("Portaxi/Core/Market.lua"))
  setfenv(chunk, env)
  chunk("Portaxi", ns)
  T.eq(type(ns.Market), "table")

  local M = ns.Market
  local m = M.new()
  m:hello("Mage", helloMsg(), 0)
  m:hail("Rider", hailMsg(), 0)
  T.eq(#m:offers({ dest = "OG", svc = "COME", faction = "Horde" }), 1)
  T.eq(#m:openRequests(taxiOf({ key = "Mage" }), 0), 1)
  m:gone("Rider:1")
  m:bye("Mage")
  m:expire(1000)
  T.eq(M.pickHailWinner({ take("A", 1, 1) }).key, "A")
  T.eq(M.affordable(1, 1), true)
  T.eq(touched, {}, "no other global was read")
end)

-- Inn hop hosts (D20) ------------------------------------------------------------------------------

local function hostMsg(over)
  local h = { fac = "Horde", lvl = 30, zone = "The Barrens", sub = "The Crossroads", city = "", free = true }
  for k, v in pairs(over or {}) do
    h[k] = v
  end
  return h
end

T.test("hosts: grouped by place, cities first in CITY_ORDER, then inns by zone and sub; labels", function()
  local m = Market.new()
  m:host("Zed", hostMsg(), 10)
  m:host("Amy", hostMsg(), 10)
  m:host("Uli", hostMsg({ zone = "Undercity", sub = "Trade Quarter", city = "UC" }), 10)
  m:host("Ola", hostMsg({ zone = "Orgrimmar", sub = "Valley of Strength", city = "OG" }), 10)
  m:host("Rog", hostMsg({ zone = "Riverglades", sub = "Rog'mar" }), 10)
  m:host("Ash", hostMsg({ zone = "Ashenvale", sub = "" }), 10)
  local places = m:hosts({ faction = "Horde" })
  local labels = {}
  for i, p in ipairs(places) do
    labels[i] = p.label
  end
  T.eq(labels, { "Orgrimmar", "Undercity", "Ashenvale", "Rog'mar, Riverglades", "The Crossroads, The Barrens" })
  T.eq({ places[1].kind, places[1].city, places[3].kind, places[3].city }, { "city", "OG", "inn", nil })
  T.eq({ places[5].hosts[1].key, places[5].hosts[2].key }, { "Amy", "Zed" }, "hosts by key")
  T.eq(places[1].sub, "", "a city is one place whatever the quarter")
end)

T.test("hosts: busy hosts, other factions and the own key are left out; HOST replaces, UNHOST and BYE remove", function()
  local m = Market.new()
  m:host("Busy", hostMsg({ free = false }), 0)
  m:host("Ally", hostMsg({ fac = "Alliance" }), 0)
  m:host("Me", hostMsg(), 0)
  m:host("Kim", hostMsg(), 0)
  local places = m:hosts({ faction = "Horde", exclude = "Me" })
  T.eq(#places, 1)
  T.eq(#places[1].hosts, 1)
  T.eq(places[1].hosts[1].key, "Kim")
  m:host("Kim", hostMsg({ zone = "Orgrimmar", sub = "", city = "OG" }), 5)
  T.eq(m:hosts({ faction = "Horde", exclude = "Me" })[1].label, "Orgrimmar", "a newer HOST moves the host")
  m:unhost("Kim")
  m:bye("Me")
  T.eq(m:hosts({ faction = "Horde" }), {})
end)

T.test("hosts expire after T.HOST without HOST; expire returns their keys third", function()
  local m = Market.new()
  m:host("Old", hostMsg(), 0)
  m:host("New", hostMsg(), 100)
  local keys, ids, hosts = m:expire(Const.T.HOST - 1)
  T.eq({ keys, ids, hosts }, { {}, {}, {} })
  keys, ids, hosts = m:expire(Const.T.HOST)
  T.eq(hosts, { "Old" })
  T.eq(#m:hosts({ faction = "Horde" })[1].hosts, 1)
end)

T.done()
