-- UI.Arrow: the arrow from one side of a ride to the other. Pure helpers (bearing, turn, when it is wanted),
-- then two simulated clients on a pickup and a Come-to-you ride. UnitPosition and GetPlayerFacing are not in
-- wowstub; this file defines them per client from a shared table of world positions.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local PI = math.pi

local function near(a, b, msg)
  T.ok(math.abs(a - b) < 1e-9, (msg or "") .. (" (%s vs %s)"):format(tostring(a), tostring(b)))
end

-- One client only for the pure helpers.
local function arrowModule()
  local sim = Sim.new()
  return sim:client("Thalindra").ns.UI.Arrow
end

T.test("vector: bearing counter-clockwise from north, as GetPlayerFacing, and the distance in yards", function()
  local A = arrowModule()
  -- N grows to the north, W to the west.
  local b, d = A.vector(0, 0, 10, 0)
  near(b, 0, "north")
  near(d, 10, "distance")
  near((A.vector(0, 0, 0, 10)), PI / 2, "west")
  near((A.vector(0, 0, -10, 0)), PI, "south")
  near((A.vector(0, 0, 0, -10)), 3 * PI / 2, "east")
  b, d = A.vector(100, 200, 103, 196)
  near(d, 5, "3-4-5")
  T.ok(b > 3 * PI / 2 and b < 2 * PI, "north-east lies between east and north")
end)

T.test("turn: positive is to the left, the result stays in (-pi, pi]", function()
  local A = arrowModule()
  near(A.turn(PI / 2, 0), PI / 2, "facing north, peer west: left")
  near(A.turn(0, PI / 2), -PI / 2, "facing west, peer north: right")
  near(A.turn(0.1, 2 * PI - 0.1), 0.2, "across north")
  near(A.turn(2 * PI - 0.1, 0.1), -0.2, "across north, the other way")
  near(A.turn(PI, 0), PI, "straight behind")
end)

T.test("wanted: a pickup from GROUPED, a Come-to-you only from ARRIVED, never without the peer's unit", function()
  local A = arrowModule()
  local function ride(svc, state, unit)
    return { svc = svc, state = state, peerUnit = unit == nil and "party1" or unit or nil }
  end
  T.eq(A.wanted(ride("PICK", "MATCHED")), false)
  T.eq(A.wanted(ride("PICK", "GROUPED")), true)
  T.eq(A.wanted(ride("PICK", "EN_ROUTE")), true)
  T.eq(A.wanted(ride("PICK", "PORTAL_OPEN")), true)
  T.eq(A.wanted(ride("PICK", "DONE")), false)
  T.eq(A.wanted(ride("PICK", "EN_ROUTE", false)), false, "no peer unit")
  T.eq(A.wanted(ride("COME", "GROUPED")), false, "the taxi teleports, nobody walks")
  T.eq(A.wanted(ride("COME", "EN_ROUTE")), false)
  T.eq(A.wanted(ride("COME", "ARRIVED")), true)
  T.eq(A.wanted(ride("COME", "PAID")), true)
  T.eq(A.wanted(nil), false)
end)

-- Two clients with positions -------------------------------------------------------------------

-- pos[name] = { n, w, instance }; facing[name] = radians.
local function placeable(sim, clients)
  local pos, facing = {}, {}
  for _, wow in ipairs(clients) do
    local function nameOf(token)
      local u = token == "player" and wow.player or wow.units[token]
      return u and u.name
    end
    wow.env.UnitPosition = function(token)
      local p = pos[nameOf(token)]
      if p then
        return p[1], p[2], 0, p[3] or 1
      end
    end
    wow.env.GetPlayerFacing = function()
      return facing[wow.player.name]
    end
  end
  return pos, facing
end

local function ride(role, svc, peer)
  return { reqId = "Velvet:1", svc = svc, price = 15000, dest = "OG", eta = 25, role = role,
           peer = { key = peer, raw = peer .. " Forever" } }
end

local function world(svc)
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll", zone = "Orgrimmar" })
  local pos, facing = placeable(sim, { taxi, rider })
  pos.Thalindra = { 1000, 500 }
  pos.Velvet = { 1000, 560 } -- 60 yards west of the taxi
  facing.Thalindra = 0       -- north
  facing.Velvet = PI / 2     -- west, away from the taxi
  sim:advance(2)
  T.ok(rider.ns.Ride.start(ride("rider", svc, "Thalindra")))
  T.ok(taxi.ns.Ride.start(ride("taxi", svc, "Velvet")))
  sim:advance(2)
  return sim, taxi, rider, pos, facing
end

T.test("pickup: both sides see the arrow to each other with the name and the distance", function()
  local sim, taxi, rider = world("PICK")
  T.eq(taxi.ns.Ride.current().state, "EN_ROUTE")
  local tv, rv = taxi.ns.UI.Arrow.view(), rider.ns.UI.Arrow.view()
  T.eq(tv.shown, true, "taxi")
  T.eq(rv.shown, true, "rider")
  T.ok(taxi.env.PortaxiArrow and taxi.env.PortaxiArrow:IsShown(), "taxi frame shown")
  T.ok(rider.env.PortaxiArrow and rider.env.PortaxiArrow:IsShown(), "rider frame shown")
  T.eq(tv.name, "Velvet")
  T.eq(rv.name, "Thalindra")
  T.eq(tv.yards, 60)
  T.eq(tv.text, "60 yd")
  near(tv.angle, PI / 2, "taxi faces north, the rider is west: arrow to the left")
  near(math.abs(rv.angle), PI, "the rider faces west, the taxi is east: arrow straight back")
  T.eq(tv.close, false)
  T.eq(taxi.ns.UI.Arrow.running, true, "updates run")
  sim:advance(1)
end)

T.test("the arrow follows movement and turns green when close", function()
  local sim, taxi, rider, pos, facing = world("PICK")
  pos.Velvet = { 1006, 500 } -- 6 yards north of the taxi
  facing.Velvet = PI         -- facing south, towards the taxi
  sim:advance(1)
  local A = rider.ns.UI.Arrow
  T.eq(A.update().close, true)
  T.eq(A.last.text, "Here")
  near(A.last.angle, 0, "straight ahead")
  T.eq(taxi.ns.UI.Arrow.update().yards, 6)
end)

T.test("another continent: no arrow, a note instead; no facing: distance only", function()
  local sim, taxi, rider, pos, facing = world("PICK")
  pos.Velvet = { 1000, 560, 0 } -- instance 0, the taxi is on 1
  local v = taxi.ns.UI.Arrow.update()
  T.eq(v.shown, true)
  T.eq(v.far, true)
  T.eq(v.angle, nil)
  T.eq(v.text, "Not on your continent")
  pos.Velvet = { 1000, 560, 1 }
  facing.Thalindra = nil
  v = taxi.ns.UI.Arrow.update()
  T.eq(v.angle, nil, "no facing: no arrow")
  T.eq(v.text, "60 yd")
  sim:advance(0)
end)

T.test("no position API on the client: nothing is shown", function()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  sim:client("Velvet", { class = "WARRIOR", race = "Troll" })
  sim:advance(2)
  T.ok(taxi.ns.Ride.start(ride("taxi", "PICK", "Velvet")))
  sim:byName("Velvet").ns.Ride.start(ride("rider", "PICK", "Thalindra"))
  sim:advance(2)
  T.eq(taxi.ns.Ride.current().state, "EN_ROUTE")
  T.eq(taxi.ns.UI.Arrow.view().shown, false)
  T.ok(not (taxi.env.PortaxiArrow and taxi.env.PortaxiArrow:IsShown()))
end)

T.test("Come-to-you: no arrow before the taxi arrives", function()
  local _, taxi, rider = world("COME")
  T.eq(taxi.ns.Ride.current().state, "GROUPED")
  T.eq(taxi.ns.UI.Arrow.view().shown, false)
  T.eq(rider.ns.UI.Arrow.view().shown, false)
  T.eq(taxi.ns.UI.Arrow.running, false)
end)

T.test("right-click hides it for this ride, /ptx arrow turns it off for good", function()
  local _, taxi = world("PICK")
  local A = taxi.ns.UI.Arrow
  A.frame:GetScript("OnMouseUp")(A.frame, "RightButton")
  T.eq(A.view().shown, false)
  T.ok(not A.frame:IsShown())
  taxi:slash("arrow")
  T.eq(taxi.env.PortaxiDB.ui.arrowOff, true)
  T.eq(A.view().shown, false)
  taxi:slash("arrow")
  T.eq(taxi.env.PortaxiDB.ui.arrowOff, nil)
  T.eq(A.view().shown, true, "on again, the per-ride hide is reset")
end)

T.test("the arrow hides when the ride ends", function()
  local sim, taxi, rider = world("PICK")
  T.ok(taxi.ns.UI.Arrow.isShown())
  T.ok(rider.ns.Ride.cancel("changed plans"))
  sim:advance(1)
  T.eq(rider.ns.UI.Arrow.isShown(), false)
  T.eq(taxi.ns.UI.Arrow.isShown(), false)
  T.eq(taxi.ns.UI.Arrow.running, false)
end)

T.done()
