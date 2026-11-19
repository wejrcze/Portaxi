-- Scenario 3 (plan §9): two taxis answer a hail. The faster ETA wins; within the 15 s tie the taxi
-- that has waited longer wins. Both taxis are free again after the GONE, and the winner's ride starts
-- with a consistent match on both sides. Ride (card H) is faked: start(match) records the match.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

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
end

-- Two taxis on duty and a resting rider; taxi.resp = response history, taxi.waited = seconds since last ride.
local function world(a, b)
  local sim = Sim.new()
  local clients = {}
  for _, spec in ipairs({ a, b }) do
    local c = sim:client(spec.name)
    fakeRide(c)
    c.env.PortaxiCharDB.respTimes = spec.resp
    c.env.PortaxiCharDB.lastRideAt = c.env.time() - spec.waited
    clients[#clients + 1] = c
  end
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Orc", zone = "Durotar" })
  fakeRide(rider)
  sim:advance(2)
  for _, c in ipairs(clients) do
    c.ns.Dispatch.setOnDuty(true)
  end
  sim:advance(2)
  return sim, rider, clients[1], clients[2]
end

local function lastSent(c, prefix)
  for i = #c.sent, 1, -1 do
    if c.sent[i].msg:find("^" .. prefix .. "|") then
      return c.sent[i]
    end
  end
end

-- The rider hails; both taxis take from their request list (as the Take button does).
local function hailAndTake(sim, rider, a, b)
  local results = {}
  rider.ns.on("HAIL_RESULT", function(reqId, winner) results[#results + 1] = { reqId, winner } end)
  T.ok(rider.ns.Dispatch.hail("UC", 40000))
  sim:advance(1)
  local reqId = rider.ns.Dispatch.status().hail.reqId
  for _, taxi in ipairs({ a, b }) do
    local list = taxi.ns.Dispatch.requests()
    T.eq(#list, 1, taxi.player.name .. " sees the request")
    T.eq(list[1].request.reqId, reqId)
    T.ok(taxi.ns.Dispatch.take(reqId))
    sim:advance(0.5)
  end
  sim:advance(5)
  return results, reqId
end

local function checkMatch(rider, winner, loser, reqId, eta)
  local rm, tm = rider.ns.Ride.matches[1], winner.ns.Ride.matches[1]
  T.ok(rm and tm, "both sides started a ride")
  T.eq({ rm.reqId, rm.role, rm.svc, rm.price, rm.dest, rm.eta }, { reqId, "rider", "COME", 30000, "UC", eta })
  T.eq({ tm.reqId, tm.role, tm.svc, tm.price, tm.dest, tm.eta }, { reqId, "taxi", "COME", 30000, "UC", eta })
  T.eq(rm.peer, { key = winner.player.name .. " Forever", raw = winner.player.name .. " Forever" })
  T.eq(tm.peer, { key = "Velvet Forever", raw = "Velvet Forever" })
  T.eq(#loser.ns.Ride.matches, 0)
  T.eq(lastSent(rider, "CONFIRM").target, winner.player.name .. " Forever")
  -- Free again: no pending TAKE, the request is gone from both markets.
  for _, taxi in ipairs({ winner, loser }) do
    T.eq(taxi.ns.Dispatch.status().pendingTake, nil, taxi.player.name .. " is free")
    T.eq(#taxi.ns.Dispatch.requests(), 0)
  end
  T.ok(loser.ns.Dispatch.take == nil or select(2, loser.ns.Dispatch.take(reqId)) == "request")
end

T.test("the faster ETA wins when the other is more than 15 s slower", function()
  -- Aaron: COME eta 5 + 1 = 6, waited 10 min. Bert: eta 40 + 1 = 41, waited an hour.
  local sim, rider, aaron, bert = world({ name = "Aaron", resp = { 5 }, waited = 600 },
    { name = "Bert", resp = { 40 }, waited = 3600 })
  local results, reqId = hailAndTake(sim, rider, aaron, bert)
  T.eq(#results, 1)
  T.eq(results[1][1], reqId)
  T.eq(results[1][2].key, "Aaron Forever")
  checkMatch(rider, aaron, bert, reqId, 6)
  T.eq(#aaron.errors + #bert.errors + #rider.errors, 0)
end)

T.test("within the 15 s tie the longer-waiting taxi wins", function()
  -- Aaron: eta 6, waited 10 min. Bert: eta 16 (within 15 s), waited an hour -> Bert.
  local sim, rider, aaron, bert = world({ name = "Aaron", resp = { 5 }, waited = 600 },
    { name = "Bert", resp = { 15 }, waited = 3600 })
  local results, reqId = hailAndTake(sim, rider, aaron, bert)
  T.eq(results[1][2].key, "Bert Forever")
  checkMatch(rider, bert, aaron, reqId, 16)
  T.eq(#aaron.errors + #bert.errors + #rider.errors, 0)
end)

T.test("the losing taxi can take the next request right after the GONE", function()
  local sim, rider, aaron, bert = world({ name = "Aaron", resp = { 5 }, waited = 600 },
    { name = "Bert", resp = { 40 }, waited = 3600 })
  hailAndTake(sim, rider, aaron, bert)
  local kira = sim:client("Kira", { class = "WARRIOR", race = "Orc", zone = "Durotar" })
  sim:advance(2)
  T.ok(kira.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  local reqId = kira.ns.Dispatch.status().hail.reqId
  T.eq({ aaron.ns.Dispatch.take(reqId) }, { nil, "busy" }, "the winner is on a ride")
  T.ok(bert.ns.Dispatch.take(reqId))
  sim:advance(5)
  T.eq(bert.ns.Ride.matches[1].peer.key, "Kira Forever")
end)

T.done()
