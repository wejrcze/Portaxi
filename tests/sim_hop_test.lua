-- Inn hop (D20, docs/INN_HOP_PLAN.md §4): a host announces where it rests, a mage asks for a hop, the host accepts with
-- a click, the mage scrolls over and the ride ends at once. Real Detect, Protocol, Net, Hop, Ride and Secure on the
-- simulator.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local SCROLL = 213548
local HOST_KEY = "Hostess Forever"

local function world()
  local sim = Sim.new({ castTime = { scroll = 1 } })
  local mage = sim:client("Thalindra")
  local host = sim:client("Hostess", { class = "WARRIOR", race = "Orc", zone = "The Barrens",
    subzone = "The Crossroads", mapId = 1413, resting = true })
  sim:advance(3)
  return sim, mage, host
end

local function events(c, name)
  local list = {}
  c.ns.on(name, function(...) list[#list + 1] = { ... } end)
  return list
end

local function noErrors(...)
  for _, c in ipairs({ ... }) do
    T.eq(#c.errors, 0, c.player.name .. " errors: " .. tostring(c.errors[1]))
  end
end

local function hosting(sim, host)
  host.ns.Hop.setHosting(true)
  sim:advance(1)
end

T.test("a host is listed by place once it hosts; hosting is off by default", function()
  local sim, mage, host = world()
  T.eq(host.ns.Hop.hosting(), false)
  T.eq(mage.ns.Hop.places(), {})
  hosting(sim, host)
  local places = mage.ns.Hop.places()
  T.eq(#places, 1)
  T.eq({ places[1].kind, places[1].label }, { "inn", "The Crossroads, The Barrens" })
  T.eq(places[1].hosts[1].key, HOST_KEY)
  T.eq(host.ns.Hop.places(), {}, "the host does not list itself")
  noErrors(mage, host)
end)

T.test("full hop: request, the host's click, invite accepted for the host, scroll, arrival, both rides DONE", function()
  local sim, mage, host = world()
  hosting(sim, host)
  local requests = events(host, "HOP_REQUEST")
  local results = events(mage, "HOP_RESULT")
  T.ok(mage.ns.Hop.request(HOST_KEY))
  sim:advance(1) -- HOP whisper, then the host's busy HOST (both through Net's queue)
  T.eq(#requests, 1)
  local req = requests[1][1]
  T.eq({ req.key, req.lvl }, { "Thalindra Forever", 40 })
  T.eq(mage.ns.Hop.places(), {}, "a host with an open request is not free")

  T.ok(host.ns.Hop.answer(req.reqId, true))
  sim:advance(0.5)
  T.eq(results[1], { req.reqId, true })
  local mr, hr = mage.ns.Ride.current(), host.ns.Ride.current()
  T.eq({ mr.svc, mr.role, mr.price, mr.dest }, { "HOP", "taxi", 0, nil })
  T.eq({ hr.svc, hr.role }, { "HOP", "rider" })

  sim:advance(2) -- invite from a timer, the host's addon accepts it (D20), RESTING arrives
  T.eq(mage.ns.Ride.current().state, "GROUPED")
  T.eq(host.ns.Ride.current().state, "GROUPED")
  T.eq(mage.ns.Ride.current().riderResting, true)
  T.eq(mage.env.PortaxiNextButton:GetAttribute("type"), "item")

  local _, result = sim:click(mage)
  T.eq(result, "cast")
  sim:advance(2)
  T.eq(mage.player.zone, "The Barrens", "the scroll took the mage to the host")
  T.eq(mage.player.items[SCROLL], 8)
  T.eq(mage.ns.Ride.current(), nil, "the mage's ride is DONE")
  T.eq(host.ns.Ride.current(), nil, "the host followed DONE")
  sim:advance(5)
  T.eq(#mage.party, 0, "the mage left the two-person group")
  T.eq(mage.env.PortaxiCharDB.lastRideAt, 0, "a hop is no taxi ride")
  noErrors(mage, host)
end)

T.test("declined: HOPNO declined, the host is free again, the same host only after T.HOP_RETRY", function()
  local sim, mage, host = world()
  hosting(sim, host)
  local requests = events(host, "HOP_REQUEST")
  local results = events(mage, "HOP_RESULT")
  T.ok(mage.ns.Hop.request(HOST_KEY))
  sim:advance(0.5)
  T.ok(host.ns.Hop.answer(requests[1][1].reqId, false))
  sim:advance(6)
  T.eq(results[1][2], false)
  T.eq(results[1][3], "declined")
  T.eq(#mage.ns.Hop.places(), 1, "listed again")
  T.eq({ mage.ns.Hop.request(HOST_KEY) }, { nil, "retry" })
  sim:advance(60)
  T.ok(mage.ns.Hop.request(HOST_KEY), "after T.HOP_RETRY")
  T.eq(mage.ns.Ride.current(), nil)
  noErrors(mage, host)
end)

T.test("no answer within T.HOP_ANSWER: HOPNO timeout on both sides", function()
  local sim, mage, host = world()
  hosting(sim, host)
  local results = events(mage, "HOP_RESULT")
  T.ok(mage.ns.Hop.request(HOST_KEY))
  sim:advance(31)
  T.eq(host.ns.Hop.status().incoming, nil)
  T.eq(results[1][3], "timeout")
  T.eq(mage.ns.Hop.status().request, nil)
  noErrors(mage, host)
end)

T.test("the host stops resting or hosting: UNHOST, the place disappears, a request finds no host", function()
  local sim, mage, host = world()
  hosting(sim, host)
  host:setResting(false)
  sim:advance(3)
  T.eq(mage.ns.Hop.places(), {})
  T.eq({ mage.ns.Hop.request(HOST_KEY) }, { nil, "host" })
  host:setResting(true)
  sim:advance(3)
  T.eq(#mage.ns.Hop.places(), 1)
  host.ns.Hop.setHosting(false)
  sim:advance(1)
  T.eq(mage.ns.Hop.places(), {})
  noErrors(mage, host)
end)

T.test("a mage who cannot hop gets state; a second request while one is open gets busy", function()
  local sim, mage, host = world()
  hosting(sim, host)
  mage:setItem(SCROLL, 0)
  sim:advance(3)
  T.eq({ mage.ns.Hop.request(HOST_KEY) }, { nil, "state" })
  mage:setItem(SCROLL, 2)
  sim:advance(3)
  T.ok(mage.ns.Hop.request(HOST_KEY))
  T.eq({ mage.ns.Hop.request(HOST_KEY) }, { nil, "busy" })
  noErrors(mage, host)
end)

T.done()
