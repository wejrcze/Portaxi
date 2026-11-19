-- Dispatch (card G): every rule of the playbook §2 "Dispatch" contract, on the multi-client simulator
-- with the real Detect, Protocol, Net and Market. Ride (card H) is faked: start(match) records the match
-- and current() returns a MATCHED ride built from it until the test ends it.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

-- Resting in Razor Hill: not in a destination city, so hails to Orgrimmar are allowed (G2 review: "here").
local RIDER = { class = "WARRIOR", race = "Orc", zone = "Durotar", subzone = "Razor Hill" }

-- Fake Ride per playbook §2: start records, current returns the ride, finish ends it with RIDE_STATE.
local function fakeRide(c)
  local R = c.ns.Ride
  R.matches = {}
  R.start = function(match)
    R.matches[#R.matches + 1] = match
    local ride = {}
    for k, v in pairs(match) do ride[k] = v end
    ride.state, ride.since = "MATCHED", c.ns.now()
    R.ride = ride
  end
  R.current = function() return R.ride end
  R.finish = function(state)
    local ride = R.ride
    R.ride = nil
    ride.state = state or "DONE"
    c.ns.fire("RIDE_STATE", ride)
  end
  return R
end

local function client(sim, name, player, loadOpts)
  local c = sim:client(name, player, loadOpts)
  fakeRide(c)
  return c
end

-- A sim with one taxi per name (default fake mage: OG + UC, runes, scrolls, resting) and one rider.
local function world(taxiNames, riderPlayer)
  local sim = Sim.new()
  local taxis = {}
  for i, name in ipairs(taxiNames or { "Thalindra" }) do
    taxis[i] = client(sim, name)
  end
  local rider = client(sim, "Velvet", riderPlayer or RIDER)
  sim:advance(2) -- channel joined everywhere
  return sim, rider, taxis
end

-- Decoded messages a client sent, optionally of one type; each gets .kind and .target.
local function sent(c, msgType)
  local out = {}
  for _, e in ipairs(c.sent) do
    local m = c.ns.Protocol.decode(e.msg)
    if m and (msgType == nil or m.type == msgType) then
      m.kind, m.target = e.kind, e.target
      out[#out + 1] = m
    end
  end
  return out
end

-- Records the listener's arguments for an internal event.
local function record(c, event)
  local got = {}
  c.ns.on(event, function(...) got[#got + 1] = { ... } end)
  return got
end

-- Delivers a message to c as if `from` sent it.
local function inject(c, msg, from, via)
  c:receive("PTX", assert(c.ns.Protocol.encode(msg)), via or "CHANNEL", from .. " Forever")
end

local function onDuty(sim, ...)
  for _, taxi in ipairs({ ... }) do
    taxi.ns.Dispatch.setOnDuty(true)
  end
  sim:advance(1)
end

local function noErrors(...)
  for _, c in ipairs({ ... }) do
    T.eq(#c.errors, 0, c.player.name .. " errors: " .. tostring(c.errors[1]))
  end
end

local function requestIds(c)
  local ids = {}
  for _, entry in ipairs(c.ns.Dispatch.requests()) do
    ids[#ids + 1] = entry.request.reqId
  end
  return ids
end

-- Duty and HELLO -------------------------------------------------------------------------------

T.test("going on duty saves the flag and sends a HELLO built from Detect and the prices", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  T.eq(taxi.env.PortaxiCharDB.onDuty, true)
  local hello = sent(taxi, "HELLO")
  T.eq(#hello, 1)
  local h = hello[1]
  T.eq({ h.fac, h.cls, h.lvl, h.place, h.kind }, { "Horde", "MAGE", 40, "Orgrimmar", "CHANNEL" })
  T.eq(h.dests, { "OG", "UC" })
  T.eq(h.ask, { COME = 30000, PICK = 15000 })
  T.eq(h.resp, 30, "Const.RESP_DEFAULT without history")
  T.eq(h.wait, 2, "seconds since login before the first ride")
  local offers = rider.ns.Dispatch.market:offers({ dest = "OG", faction = "Horde" })
  T.eq(#offers, 2, "the rider's market has both services")
  T.eq(taxi.ns.Dispatch.status().onDuty, true)
  noErrors(taxi, rider)
end)

T.test("HELLO asks only for the services Detect allows right now", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  taxi:setResting(false)
  sim:advance(3)
  onDuty(sim, taxi)
  T.eq(sent(taxi, "HELLO")[1].ask, { PICK = 15000 })
  T.eq(#rider.ns.Dispatch.market:offers({ dest = "OG", svc = "COME" }), 0)
  T.eq(#rider.ns.Dispatch.market:offers({ dest = "OG", svc = "PICK" }), 1)
end)

T.test("a character that cannot drive sends no HELLO even on duty", function()
  local sim, rider = world({})
  rider.ns.Dispatch.setOnDuty(true)
  sim:advance(120)
  T.eq(#sent(rider, "HELLO"), 0)
  noErrors(rider)
end)

T.test("HELLO repeats every T.HELLO +- T.HELLO_JITTER while on duty", function()
  local sim, rider, taxis = world()
  local times = {}
  rider.ns.on("NET_MSG", function(msg) if msg.type == "HELLO" then times[#times + 1] = sim:now() end end)
  onDuty(sim, taxis[1])
  sim:advance(600)
  T.ok(#times >= 9, "at least 9 HELLOs in 10 minutes, got " .. #times)
  for i = 2, #times do
    local gap = times[i] - times[i - 1]
    T.ok(gap >= 50 - 0.3 and gap <= 70 + 0.3, "gap " .. gap)
  end
end)

T.test("the jitter bounds are exactly T.HELLO - and + T.HELLO_JITTER", function()
  local real = math.random
  local ok, err = pcall(function()
    for _, case in ipairs({ { 0, 50 }, { 1, 70 } }) do
      math.random = function() return case[1] end
      local sim, rider, taxis = world()
      local times = {}
      rider.ns.on("NET_MSG", function(msg) if msg.type == "HELLO" then times[#times + 1] = sim:now() end end)
      onDuty(sim, taxis[1])
      sim:advance(case[2] * 2 + 1)
      T.eq(#times, 3)
      T.ok(math.abs(times[2] - times[1] - case[2]) < 0.3, "first gap " .. (times[2] - times[1]))
      T.ok(math.abs(times[3] - times[2] - case[2]) < 0.3, "second gap")
    end
  end)
  math.random = real
  assert(ok, err)
end)

T.test("PROFILE_CHANGED sends a HELLO at most every 5 s, and only when riders would see a change", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  local times = {}
  rider.ns.on("NET_MSG", function(msg) if msg.type == "HELLO" then times[#times + 1] = sim:now() end end)
  onDuty(sim, taxi) -- HELLO at ~t0
  local t0 = times[1]
  taxi:setMoney(100) -- not part of the HELLO: no extra one
  sim:advance(4)
  T.eq(#times, 1, "money change sends nothing")
  taxi:setResting(false) -- PROFILE_CHANGED at t0 + ~6: more than 5 s after the last HELLO
  sim:advance(3)
  T.eq(#times, 2)
  T.ok(times[2] - t0 >= 5, "second HELLO 5 s after the first")
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"].ask, { PICK = 15000 })
  taxi:setResting(true) -- PROFILE_CHANGED 2 s later: waits until 5 s after the previous HELLO
  sim:advance(2.5)
  T.eq(#times, 2, "rate-limited")
  sim:advance(3)
  T.eq(#times, 3)
  T.ok(times[3] - times[2] >= 5 - 0.01 and times[3] - times[2] <= 5.5, "gap " .. (times[3] - times[2]))
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"].ask, { COME = 30000, PICK = 15000 })
  noErrors(taxi, rider)
end)

T.test("going off duty sends BYE, stops the HELLO cycle and the rider drops the offer", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  T.ok(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"])
  taxi.ns.Dispatch.setOnDuty(false)
  sim:advance(1)
  T.eq(taxi.env.PortaxiCharDB.onDuty, false)
  T.eq(#sent(taxi, "BYE"), 1)
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"], nil)
  local before = #sent(taxi, "HELLO")
  sim:advance(200)
  T.eq(#sent(taxi, "HELLO"), before, "no HELLO off duty")
  T.eq(taxi.ns.Dispatch.status().onDuty, false)
end)

T.test("on READY a taxi that was on duty resumes: HELLO once the channel is joined", function()
  local sim = Sim.new()
  local rider = client(sim, "Velvet", RIDER)
  local taxi = client(sim, "Thalindra", nil, { saved = { PortaxiCharDB = { onDuty = true } } })
  sim:advance(3)
  T.eq(#sent(taxi, "HELLO"), 1)
  T.ok(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"], "the rider sees the taxi")
  T.eq(taxi.ns.Dispatch.status().onDuty, true)
end)

T.test("going on duty asks Net to rejoin the channel when it is not joined", function()
  local sim, _, taxis = world()
  local ns = taxis[1].ns
  local rejoins = 0
  ns.Net.joined = function() return false end
  ns.Net.rejoin = function() rejoins = rejoins + 1 end
  ns.Dispatch.setOnDuty(true)
  T.eq(rejoins, 1)
  ns.Dispatch.setOnDuty(false)
  ns.Net.joined = function() return true end
  ns.Dispatch.setOnDuty(true)
  T.eq(rejoins, 1, "no rejoin while joined")
  sim:advance(1)
end)

-- Hail: rider side -------------------------------------------------------------------------------

T.test("hail errors: money, dest, busy (hail or ride), cooldown", function()
  local sim, rider = world()
  local D = rider.ns.Dispatch
  rider.player.money = 5000
  T.eq({ D.hail("OG", 30000) }, { nil, "money" })
  T.eq({ D.hail("SW", 1000) }, { nil, "dest" }, "a city of the other faction")
  T.eq({ D.hail("XX", 1000) }, { nil, "dest" })
  T.eq(#sent(rider, "HAIL"), 0, "nothing broadcast")
  rider.player.money = 455723
  T.eq({ D.hail("OG", 30000) }, { true })
  T.eq({ D.hail("OG", 30000) }, { nil, "busy" })
  D.cancel()
  T.eq({ D.hail("OG", 30000) }, { nil, "cooldown" })
  sim:advance(10)
  rider.ns.Ride.start({ reqId = "x:1", role = "rider", svc = "PICK", price = 1000, dest = "OG",
    peer = { key = "A", raw = "A Forever" }, eta = 1 })
  T.eq({ D.hail("OG", 30000) }, { nil, "busy" }, "a ride is active")
  rider.ns.Ride.finish("DONE")
  T.eq({ D.hail("OG", 30000) }, { true })
  sim:advance(1)
  T.eq(#sent(rider, "HAIL"), 2)
  noErrors(rider)
end)

T.test("G2 review: hail errors here (already in that city) and group (already grouped)", function()
  local sim, rider = world()
  local D = rider.ns.Dispatch
  rider.player.zone = "Orgrimmar"
  rider:fire("ZONE_CHANGED_NEW_AREA")
  sim:advance(3)
  T.eq({ D.hail("OG", 30000) }, { nil, "here" })
  T.eq({ D.hail("UC", 30000) }, { true }, "another city is fine")
  D.cancel()
  sim:advance(11)
  rider:joinParty("Friend")
  T.eq({ D.hail("UC", 30000) }, { nil, "group" })
  T.eq(#sent(rider, "HAIL"), 1)
  noErrors(rider)
end)

T.test("G2 review: a TAKE long after the request was seen does not count as a response time", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(90) -- the taxi was away
  local reqId = rider.ns.Dispatch.status().hail.reqId
  T.ok(taxi.ns.Dispatch.take(reqId))
  T.eq(taxi.env.PortaxiCharDB.respTimes, {}, "not recorded")
  noErrors(taxi)
end)

T.test("HAIL fields: svcs and rest follow resting; reqId is key:n and counts up", function()
  local sim, rider = world()
  local D = rider.ns.Dispatch
  T.ok(D.hail("UC", 40000))
  sim:advance(1)
  local h = sent(rider, "HAIL")[1]
  T.eq({ h.fac, h.dest, h.max, h.rest, h.kind }, { "Horde", "UC", 40000, true, "CHANNEL" })
  T.eq(h.svcs, { "COME", "PICK" })
  local n = tonumber(h.reqId:match("^Velvet Forever:(%d+)$"))
  T.ok(n, "reqId format " .. h.reqId)
  D.cancel()
  rider:setResting(false)
  sim:advance(12)
  T.ok(D.hail("UC", 40000))
  sim:advance(1)
  local h2 = sent(rider, "HAIL")[2]
  T.eq(h2.svcs, { "PICK" })
  T.eq(h2.rest, false)
  T.eq(h2.reqId, "Velvet Forever:" .. (n + 1))
  local st = D.status()
  T.eq({ st.hail.reqId, st.hail.dest, st.hail.max, st.hail.takes }, { h2.reqId, "UC", 40000, 0 })
end)

T.test("TAKEs are collected for T.COLLECT s after the first; the Market winner gets CONFIRM", function()
  local sim, rider, taxis = world({ "Aaron", "Bert", "Cyril" })
  local A, B, Cy = taxis[1], taxis[2], taxis[3]
  onDuty(sim, A, B, Cy)
  A.env.PortaxiCharDB.respTimes = { 50 } -- COME eta 60
  B.env.PortaxiCharDB.respTimes = { 5 }  -- COME eta 15: fastest
  Cy.env.PortaxiCharDB.respTimes = { 1 } -- eta 11 but too late
  local results = record(rider, "HAIL_RESULT")
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  T.ok(A.ns.Dispatch.take(sent(rider, "HAIL")[1].reqId))
  sim:advance(0.5)
  T.eq(rider.ns.Dispatch.status().hail.takes, 1)
  sim:advance(1.5)
  T.ok(B.ns.Dispatch.take(sent(rider, "HAIL")[1].reqId))
  sim:advance(0.5)
  T.eq(rider.ns.Dispatch.status().hail.takes, 2)
  sim:advance(0.5) -- 3 s after the first TAKE arrived: decided
  T.ok(Cy.ns.Dispatch.take(sent(rider, "HAIL")[1].reqId))
  sim:advance(1)
  local confirm = sent(rider, "CONFIRM")
  T.eq(#confirm, 1)
  T.eq(confirm[1].kind, "WHISPER")
  T.eq(confirm[1].target, "Bert Forever", "whisper to the raw sender")
  T.eq({ confirm[1].svc, confirm[1].price }, { "COME", 30000 })
  T.eq(#sent(rider, "GONE"), 1)
  T.eq(#results, 1)
  T.eq(results[1][2].key, "Bert Forever")
  T.eq(results[1][2].eta, 6)
  local m = rider.ns.Ride.matches[1]
  T.eq(m, { reqId = confirm[1].reqId, role = "rider", svc = "COME", price = 30000, dest = "OG",
    peer = { key = "Bert Forever", raw = "Bert Forever" }, eta = 6 })
  T.eq(#B.ns.Ride.matches, 1, "the winner starts its ride")
  T.eq(#A.ns.Ride.matches + #Cy.ns.Ride.matches, 0)
  T.eq(rider.ns.Dispatch.status().hail, nil)
  T.eq(rider.ns.Dispatch.status().last.result, "matched")
  noErrors(rider, A, B, Cy)
end)

T.test("TAKEs above the maximum or for a service the rider did not ask for are ignored", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  rider:setResting(false)
  sim:advance(3)
  T.ok(rider.ns.Dispatch.hail("OG", 20000))
  sim:advance(1)
  local reqId = sent(rider, "HAIL")[1].reqId
  inject(rider, { type = "TAKE", reqId = reqId, svc = "COME", price = 15000, eta = 1, wait = 1 }, "Thalindra",
    "WHISPER")
  inject(rider, { type = "TAKE", reqId = reqId, svc = "PICK", price = 25000, eta = 1, wait = 1 }, "Thalindra",
    "WHISPER")
  inject(rider, { type = "TAKE", reqId = "Other:1", svc = "PICK", price = 15000, eta = 1, wait = 1 }, "Thalindra",
    "WHISPER")
  T.eq(rider.ns.Dispatch.status().hail.takes, 0)
end)

T.test("no TAKE within T.REQUEST: GONE and HAIL_RESULT(reqId, nil)", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  local results = record(rider, "HAIL_RESULT")
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  local reqId = sent(rider, "HAIL")[1].reqId
  T.ok(taxi.ns.Dispatch.market.requestByKey["Velvet Forever"], "the taxi stores the request")
  sim:advance(118)
  T.eq(#results, 0)
  sim:advance(1.5)
  T.eq(#results, 1)
  T.eq(results[1][1], reqId)
  T.eq(results[1][2], nil)
  T.eq(sent(rider, "GONE")[1].reqId, reqId)
  T.eq(taxi.ns.Dispatch.market.requestByKey["Velvet Forever"], nil, "GONE removes it on the taxi")
  T.eq(rider.ns.Dispatch.status().last.result, "none")
  T.eq(#rider.ns.Ride.matches, 0)
end)

T.test("cancel withdraws the hail with GONE; nothing to cancel returns false", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  T.eq(rider.ns.Dispatch.cancel(), false)
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  T.eq(#requestIds(taxi), 1)
  T.eq(rider.ns.Dispatch.cancel(), true)
  sim:advance(1)
  T.eq(#sent(rider, "GONE"), 1)
  T.eq(rider.ns.Dispatch.status().hail, nil)
  T.eq(rider.ns.Dispatch.status().last.result, "cancelled")
  T.eq(#requestIds(taxi), 0)
  -- A TAKE that comes after the cancel is ignored.
  inject(rider, { type = "TAKE", reqId = sent(rider, "HAIL")[1].reqId, svc = "COME", price = 30000, eta = 1,
    wait = 1 }, "Thalindra", "WHISPER")
  sim:advance(5)
  T.eq(#sent(rider, "CONFIRM"), 0)
end)

-- Book ---------------------------------------------------------------------------------------------

T.test("book: BOOK whispered to that taxi, it is alerted as booked, its TAKE is confirmed at once", function()
  local sim, rider, taxis = world({ "Aaron", "Bert" })
  local A, B = taxis[1], taxis[2]
  onDuty(sim, A, B)
  local incoming = record(B, "INCOMING_REQUEST")
  local incomingA = record(A, "INCOMING_REQUEST")
  T.eq({ rider.ns.Dispatch.book("Zed", "OG", "PICK") }, { nil, "offer" })
  T.ok(rider.ns.Dispatch.book("Bert Forever", "OG", "PICK"))
  sim:advance(1)
  local book = sent(rider, "BOOK")[1]
  T.eq({ book.kind, book.target, book.dest, book.svc, book.price }, { "WHISPER", "Bert Forever", "OG", "PICK", 15000 })
  T.eq(#incoming, 1)
  T.eq(incoming[1][1].booked, true)
  T.eq(incoming[1][1].request.reqId, book.reqId)
  T.eq(#incomingA, 0, "other taxis never hear of a booking")
  T.eq(rider.ns.Dispatch.status().hail.booked, "Bert Forever")
  T.ok(B.ns.Dispatch.take(book.reqId))
  sim:advance(0.6) -- TAKE arrives; no T.COLLECT wait
  local confirm = sent(rider, "CONFIRM")
  T.eq(#confirm, 1)
  T.eq(confirm[1].target, "Bert Forever")
  sim:advance(1)
  T.eq(rider.ns.Ride.matches[1].peer, { key = "Bert Forever", raw = "Bert Forever" })
  T.eq(B.ns.Ride.matches[1].peer, { key = "Velvet Forever", raw = "Velvet Forever" })
  T.eq(B.ns.Ride.matches[1].svc, "PICK")
  T.eq(B.ns.Dispatch.status().pendingTake, nil)
  noErrors(rider, A, B)
end)

T.test("book errors: COME needs resting; busy while a hail is open", function()
  local sim, rider, taxis = world()
  onDuty(sim, taxis[1])
  rider:setResting(false)
  sim:advance(3)
  T.eq({ rider.ns.Dispatch.book("Thalindra Forever", "OG", "COME") }, { nil, "resting" })
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  T.eq({ rider.ns.Dispatch.book("Thalindra Forever", "OG", "PICK") }, { nil, "busy" })
  rider.player.money = 100
  rider.ns.Dispatch.cancel()
  sim:advance(11)
  T.eq({ rider.ns.Dispatch.book("Thalindra Forever", "OG", "PICK") }, { nil, "money" })
end)

T.test("a taxi ignores a BOOK below its own price or for a service it cannot give", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  local incoming = record(taxi, "INCOMING_REQUEST")
  inject(taxi, { type = "BOOK", reqId = "Velvet:1", dest = "OG", svc = "PICK", price = 10000 }, "Velvet", "WHISPER")
  inject(taxi, { type = "BOOK", reqId = "Velvet:2", dest = "TB", svc = "PICK", price = 20000 }, "Velvet", "WHISPER")
  taxi:setResting(false)
  sim:advance(3)
  inject(taxi, { type = "BOOK", reqId = "Velvet:3", dest = "OG", svc = "COME", price = 40000 }, "Velvet", "WHISPER")
  T.eq(#incoming, 0)
  inject(taxi, { type = "BOOK", reqId = "Velvet:4", dest = "OG", svc = "PICK", price = 20000 }, "Velvet", "WHISPER")
  T.eq(#incoming, 1)
  T.eq(incoming[1][1].price, 15000, "the taxi takes at its own price")
end)

-- Take: taxi side ---------------------------------------------------------------------------------

T.test("take: TAKE whisper with svc/price/eta/wait; one pending TAKE; free again after T.CONFIRM", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  local D = taxi.ns.Dispatch
  T.eq({ D.take("Velvet:1") }, { nil, "duty" })
  onDuty(sim, taxi)
  inject(taxi, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" },
    max = 40000, rest = true }, "Velvet")
  inject(taxi, { type = "HAIL", reqId = "Kira:1", fac = "Horde", dest = "UC", svcs = { "PICK" },
    max = 40000, rest = false }, "Kira")
  T.eq({ D.take("Nope:1") }, { nil, "request" })
  T.ok(D.take("Velvet:1"))
  sim:advance(1)
  local take = sent(taxi, "TAKE")[1]
  T.eq({ take.kind, take.target, take.reqId, take.svc, take.price, take.eta, take.wait },
    { "WHISPER", "Velvet Forever", "Velvet:1", "COME", 30000, 31, 3 })
  T.eq(D.status().pendingTake, "Velvet:1")
  T.eq({ D.take("Kira:1") }, { nil, "pending" })
  sim:advance(9.5)
  T.eq(D.status().pendingTake, nil, "free again after T.CONFIRM")
  T.ok(D.take("Kira:1"))
  sim:advance(1)
  T.eq(sent(taxi, "TAKE")[2].svc, "PICK")
  T.eq(#taxi.ns.Ride.matches, 0)
  noErrors(taxi)
end)

T.test("take is refused during a ride; CONFIRM from someone else is ignored", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  inject(taxi, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
    rest = false }, "Velvet")
  T.ok(taxi.ns.Dispatch.take("Velvet:1"))
  inject(taxi, { type = "CONFIRM", reqId = "Velvet:1", svc = "PICK", price = 15000 }, "Mallory", "WHISPER")
  T.eq(#taxi.ns.Ride.matches, 0)
  inject(taxi, { type = "CONFIRM", reqId = "Velvet:1", svc = "PICK", price = 15000 }, "Velvet", "WHISPER")
  T.eq(#taxi.ns.Ride.matches, 1)
  T.eq(taxi.ns.Ride.matches[1], { reqId = "Velvet:1", role = "taxi", svc = "PICK", price = 15000, dest = "OG",
    peer = { key = "Velvet Forever", raw = "Velvet Forever" }, eta = 630 })
  inject(taxi, { type = "HAIL", reqId = "Kira:1", fac = "Horde", dest = "UC", svcs = { "PICK" },
    max = 40000, rest = false }, "Kira")
  T.eq({ taxi.ns.Dispatch.take("Kira:1") }, { nil, "busy" })
  sim:advance(1)
end)

T.test("GONE frees a pending taxi; a CONFIRM overtaken by its GONE still starts the ride", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  inject(taxi, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
    rest = false }, "Velvet")
  T.ok(taxi.ns.Dispatch.take("Velvet:1"))
  inject(taxi, { type = "GONE", reqId = "Velvet:1" }, "Velvet")
  T.eq(taxi.ns.Dispatch.status().pendingTake, nil, "free after GONE")
  T.eq(#requestIds(taxi), 0)
  inject(taxi, { type = "CONFIRM", reqId = "Velvet:1", svc = "PICK", price = 15000 }, "Velvet", "WHISPER")
  T.eq(#taxi.ns.Ride.matches, 1)
  -- Too late: after T.CONFIRM a stray CONFIRM does nothing.
  taxi.ns.Ride.finish("DONE")
  inject(taxi, { type = "HAIL", reqId = "Kira:1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
    rest = false }, "Kira")
  T.ok(taxi.ns.Dispatch.take("Kira:1"))
  inject(taxi, { type = "GONE", reqId = "Kira:1" }, "Kira")
  sim:advance(11)
  inject(taxi, { type = "CONFIRM", reqId = "Kira:1", svc = "PICK", price = 15000 }, "Kira", "WHISPER")
  T.eq(#taxi.ns.Ride.matches, 1)
end)

-- INCOMING_REQUEST and filters ----------------------------------------------------------------------

T.test("INCOMING_REQUEST fires once per reqId, only on duty, and not during a ride", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  local incoming = record(taxi, "INCOMING_REQUEST")
  local hail = { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" },
    max = 40000, rest = true }
  inject(taxi, hail, "Velvet")
  T.eq(#incoming, 0, "off duty")
  onDuty(sim, taxi)
  -- G2 review: requests already open when duty starts are listed, not announced (no burst of raid warnings).
  T.eq(#incoming, 0, "no alert for requests that were open before duty")
  T.eq(#taxi.ns.Dispatch.requests(), 1, "but it is on the list")
  inject(taxi, { type = "HAIL", reqId = "Zug:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" },
    max = 40000, rest = true }, "Zug")
  T.eq(#incoming, 1, "a new request on duty is announced")
  T.eq({ incoming[1][1].svc, incoming[1][1].price, incoming[1][1].booked }, { "COME", 30000, false })
  taxi:setResting(false) -- PROFILE_CHANGED: the request is still served (PICK) but not new
  sim:advance(3)
  T.eq(#incoming, 1)
  taxi.ns.Ride.start({ reqId = "x:1", role = "taxi", svc = "PICK", price = 1000, dest = "OG",
    peer = { key = "A", raw = "A Forever" }, eta = 1 })
  sim:advance(20)
  inject(taxi, { type = "HAIL", reqId = "Kira:1", fac = "Horde", dest = "UC", svcs = { "PICK" }, max = 40000,
    rest = false }, "Kira")
  T.eq(#incoming, 1, "nothing during a ride")
  taxi.ns.Ride.finish("DONE")
  T.eq(#incoming, 2, "announced when the ride ends")
  T.eq(incoming[2][1].request.reqId, "Kira:1")
end)

T.test("taxis only see requests of their faction, for cities and services they serve, at their price", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  taxi:setResting(false)
  sim:advance(3)
  local incoming = record(taxi, "INCOMING_REQUEST")
  local function hail(from, fields)
    local msg = { type = "HAIL", reqId = from .. ":1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
      rest = false }
    for k, v in pairs(fields) do msg[k] = v end
    inject(taxi, msg, from)
  end
  hail("Ally", { fac = "Alliance", dest = "SW" })
  hail("Ally2", { fac = "Alliance" })
  hail("Thun", { dest = "TB" })
  hail("Comer", { svcs = { "COME" }, rest = true }) -- COME is paused (not resting)
  hail("Cheap", { max = 10000 })
  T.eq(#incoming, 0)
  T.eq(requestIds(taxi), {})
  T.eq({ taxi.ns.Dispatch.take("Ally:1") }, { nil, "request" })
  hail("Good", {})
  T.eq(#incoming, 1)
  T.eq(requestIds(taxi), { "Good:1" })
end)

T.test("a second HAIL from the same player within the cooldown is ignored", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  inject(taxi, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
    rest = false }, "Velvet")
  sim:advance(3)
  inject(taxi, { type = "HAIL", reqId = "Velvet:2", fac = "Horde", dest = "UC", svcs = { "PICK" }, max = 40000,
    rest = false }, "Velvet")
  T.eq(requestIds(taxi), { "Velvet:1" })
  sim:advance(8)
  inject(taxi, { type = "HAIL", reqId = "Velvet:3", fac = "Horde", dest = "UC", svcs = { "PICK" }, max = 40000,
    rest = false }, "Velvet")
  T.eq(requestIds(taxi), { "Velvet:3" }, "one open request per player")
end)

-- Estimates ------------------------------------------------------------------------------------------

T.test("eta, wait and respTimes", function()
  local sim, _, taxis = world()
  local taxi = taxis[1]
  local D, db = taxi.ns.Dispatch, taxi.env.PortaxiCharDB
  T.eq(D.eta("COME"), 31, "RESP_DEFAULT + CAST.SCROLL")
  T.eq(D.eta("PICK"), 630, "ETA_PICK + RESP_DEFAULT")
  onDuty(sim, taxi)
  inject(taxi, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" },
    max = 40000, rest = true }, "Velvet")
  sim:advance(7)
  T.ok(D.take("Velvet:1"))
  T.eq(db.respTimes, { 7 }, "request seen -> TAKE sent")
  T.eq(D.eta("COME"), 8)
  db.respTimes = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
  sim:advance(11)
  inject(taxi, { type = "HAIL", reqId = "Kira:1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
    rest = false }, "Kira")
  sim:advance(4)
  T.ok(D.take("Kira:1"))
  T.eq(db.respTimes, { 2, 3, 4, 5, 6, 7, 8, 9, 10, 4 }, "only the last 10 are kept")
  sim:advance(1)
  T.eq(sent(taxi, "TAKE")[2].eta, 600 + 6, "eta from the average before this TAKE (5.5 rounds to 6)")
  -- wait: from login until the first ride, then from lastRideAt.
  local sinceLogin = D.wait()
  T.ok(sinceLogin >= 25 and sinceLogin <= 27, "wait since login " .. sinceLogin)
  db.lastRideAt = taxi.env.time() - 500
  T.eq(D.wait(), 500)
  sim:advance(1)
end)

T.test("HELLO carries the average response and the wait", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  taxi.env.PortaxiCharDB.respTimes = { 10, 21 }
  taxi.env.PortaxiCharDB.lastRideAt = taxi.env.time() - 300
  onDuty(sim, taxi)
  local h = sent(taxi, "HELLO")[1]
  T.eq(h.resp, 16) -- 15.5 rounded
  T.eq(h.wait, 300)
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"].resp, 16)
end)

T.test("while a ride is active the HELLO offers nothing; afterwards it offers again", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  taxi.ns.Ride.start({ reqId = "x:1", role = "taxi", svc = "PICK", price = 1000, dest = "OG",
    peer = { key = "A", raw = "A Forever" }, eta = 1 })
  taxi.ns.fire("RIDE_STARTED", taxi.ns.Ride.current())
  sim:advance(6)
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"].ask, {})
  T.eq(#rider.ns.Dispatch.market:offers({ dest = "OG" }), 0)
  taxi.ns.Ride.finish("DONE")
  sim:advance(6)
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"].ask, { COME = 30000, PICK = 15000 })
end)

-- Expiry ----------------------------------------------------------------------------------------------

T.test("expiry runs every 10 s and fires MARKET_CHANGED when something went", function()
  local sim, rider, taxis = world()
  local taxi = taxis[1]
  onDuty(sim, taxi)
  inject(taxi, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "PICK" }, max = 40000,
    rest = false }, "Velvet")
  T.eq(#requestIds(taxi), 1)
  local changes = record(taxi, "MARKET_CHANGED")
  sim:advance(10)
  T.ok(#changes >= 1, "redraw while requests are open")
  sim:advance(125)
  T.eq(taxi.ns.Dispatch.market.requestByKey["Velvet Forever"], nil, "expired after T.REQUEST")
  -- The taxi goes silent (logout without BYE): the rider drops its offer after T.OFFER.
  taxi.ns.Dispatch.setOnDuty(false)
  rider.ns.Dispatch.market:hello("Ghost", { fac = "Horde", dests = { "OG" }, ask = { PICK = 1000 }, wait = 0 },
    rider.ns.now())
  sim:advance(160)
  T.eq(rider.ns.Dispatch.market.offerByKey.Ghost, nil)
end)

T.test("Dispatch works without Ride (an empty table) and without a profile", function()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", RIDER)
  sim:advance(2)
  onDuty(sim, taxi)
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  T.ok(taxi.ns.Dispatch.take(sent(rider, "HAIL")[1].reqId))
  sim:advance(5)
  T.eq(#sent(rider, "CONFIRM"), 1)
  rider.ns.Detect.current = function() return nil end
  T.eq({ rider.ns.Dispatch.hail("OG", 40000) }, { nil, "profile" })
  T.eq(rider.ns.Dispatch.requests(), {})
  noErrors(taxi, rider)
end)

T.done()
