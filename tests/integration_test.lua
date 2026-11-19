-- Wave 1 integration: real Detect + Protocol + Net + Market + UI on the multi-client simulator.
-- Dispatch does not exist yet (wave 2), so the test plays its part: it builds the messages from
-- Detect's output and feeds NET_MSG into a Market instance per client.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

-- A Horde taxi (default fake mage: OG + UC portals, runes, scrolls, resting) and a Horde rider.
local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Orc", spells = {}, items = {} })
  sim:advance(2) -- channel joined on both
  return sim, taxi, rider
end

-- Feeds every NET_MSG of a client into its own Market.
local function marketOf(wow)
  local m = wow.ns.Market.new()
  local got = {}
  wow.ns.on("NET_MSG", function(msg, key)
    got[#got + 1] = msg
    if msg.type == "HELLO" then
      m:hello(key, msg, wow.ns.now())
    elseif msg.type == "HAIL" then
      m:hail(key, msg, wow.ns.now())
    end
  end)
  return m, got
end

local function helloFrom(wow)
  local profile, services = wow.ns.Detect.current()
  local prices = wow.env.PortaxiCharDB.prices
  local ask = {}
  if services.COME then ask.COME = prices.COME end
  if services.PICK then ask.PICK = prices.PICK end
  return {
    type = "HELLO", fac = profile.faction, cls = profile.class, lvl = profile.level,
    place = profile.zone, dests = services.dests, ask = ask, resp = 20, wait = 300,
  }
end

T.test("both clients join the channel and detect their roles", function()
  local _, taxi, rider = world()
  T.ok(select(2, taxi.ns.Detect.current()).canDrive, "taxi can drive")
  T.ok(not select(2, rider.ns.Detect.current()).canDrive, "rider cannot")
  T.ok(taxi.ns.Net.stats and taxi.channels.PortaxiNet, "taxi joined")
  T.ok(rider.channels.PortaxiNet, "rider joined")
end)

T.test("a HELLO built from Detect reaches the rider's market as a priced offer", function()
  local sim, taxi, rider = world()
  local market = marketOf(rider)
  T.ok(taxi.ns.Net.broadcast(helloFrom(taxi)))
  sim:advance(1)
  local offers = market:offers({ dest = "OG", svc = "COME", faction = "Horde" })
  T.eq(#offers, 1)
  T.eq(offers[1].key, "Thalindra Forever")
  T.eq(offers[1].price, 30000)
  T.eq(offers[1].offer.waitSince, offers[1].offer.seen - 300, "wait travels as relative seconds")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("a HAIL from the rider shows up in the taxi's open requests; TAKE goes back by whisper", function()
  local sim, taxi, rider = world()
  local taxiMarket = marketOf(taxi)
  local _, riderGot = marketOf(rider)
  local raw -- the taxi answers the raw sender string it got the HAIL from
  taxi.ns.on("NET_MSG", function(_, _, rawSender) raw = rawSender end)
  rider.ns.Net.broadcast({ type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG",
    svcs = { "COME", "PICK" }, max = 40000, rest = true })
  sim:advance(1)
  local _, services = taxi.ns.Detect.current()
  local open = taxiMarket:openRequests({ key = "Thalindra", faction = "Horde", services = services,
    prices = taxi.env.PortaxiCharDB.prices }, taxi.ns.now())
  T.eq(#open, 1)
  T.eq(open[1].svc, "COME")
  T.eq(open[1].price, 30000)
  T.eq(raw, "Velvet Forever")
  taxi.ns.Net.whisper(raw, { type = "TAKE", reqId = "Velvet:1", svc = "COME", price = 30000, eta = 25, wait = 300 })
  sim:advance(1)
  local take = riderGot[#riderGot]
  T.eq(take.type, "TAKE")
  local winner = rider.ns.Market.pickHailWinner({ { key = "Thalindra", eta = take.eta, wait = take.wait,
    price = take.price, svc = take.svc } })
  T.eq(winner.key, "Thalindra")
end)

T.test("leaving the inn turns COME off on the taxi after the debounce", function()
  local sim, taxi = world()
  taxi:setResting(false)
  sim:advance(3)
  local _, services = taxi.ns.Detect.current()
  T.eq(services.COME, false)
  T.eq(services.PICK, true)
end)

T.test("the window opens with real Detect data on both clients without errors", function()
  local _, taxi, rider = world()
  taxi:slash("show")
  rider:slash("show")
  T.ok(taxi.env.PortaxiMainFrame:IsShown())
  T.ok(rider.env.PortaxiMainFrame:IsShown())
  taxi.ns.UI.show("drive")
  rider.ns.UI.show("drive") -- a warrior falls back to Ride
  T.eq(taxi.ns.UI.MainFrame.tab, "drive")
  T.eq(rider.ns.UI.MainFrame.tab, "ride")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("probe PING/PONG on the same prefix is dropped quietly by Net", function()
  local sim, taxi, rider = world()
  local got = {}
  rider.ns.on("NET_MSG", function(msg) got[#got + 1] = msg end)
  taxi:slash("net")
  sim:advance(4)
  T.eq(#got, 0)
  T.ok(rider.ns.Net.stats.dropped >= 1)
end)

T.done()
