-- Scenario 7 (plan §9): pickup via Browse. The rider books a taxi from the Browse list, the taxi gets a
-- raid warning and takes it from its duty box, the rider confirms the TAKE at once, and both sides start
-- a ride with matching data. Ride (card H) is faked: start(match) records the match.
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

local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local other = sim:client("Aaron")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Orc", resting = false, zone = "Durotar" })
  for _, c in ipairs({ taxi, other, rider }) do
    fakeRide(c)
  end
  sim:advance(2)
  taxi.env.PortaxiCharDB.prices.PICK = 12000
  taxi.ns.Dispatch.setOnDuty(true)
  other.ns.Dispatch.setOnDuty(true)
  sim:advance(2)
  return sim, taxi, other, rider
end

local function sentTypes(c)
  local out = {}
  for _, e in ipairs(c.sent) do
    out[#out + 1] = e.msg:match("^(%u+)|")
  end
  return table.concat(out, " ")
end

T.test("pickup booked from the Browse list matches both sides at once", function()
  local sim, taxi, other, rider = world()
  rider:slash("show")
  local R = rider.ns.UI.RideTab
  R.ui.modes.browse:Click()
  R.ui.tiles[2]:Click() -- Undercity
  local rows = R.ui.rows
  T.eq(rows[1].who:GetText(), "Thalindra Forever · Pickup", "cheapest first")
  T.eq(rows[1].price:GetText(), "1g 20s")
  T.eq(rows[2].who:GetText(), "Aaron Forever · Pickup")
  T.eq(rows[3].who:GetText(), "Aaron Forever · Come-to-you")
  T.ok(not rows[3].book:IsEnabled(), "Come-to-you is grey: the rider is not resting")
  rows[1].book:Click()
  sim:advance(1)
  T.eq(R.ui.status:GetText(), "Waiting for Thalindra Forever to accept...")
  T.eq(taxi.raidWarnings, { "Portaxi: Velvet Forever booked you to Undercity (Pickup, 1g 20s)" })
  T.eq(#other.raidWarnings, 0, "the other taxi never hears of the booking")
  local box = taxi.ns.UI.DutyBox
  T.ok(box.isShown())
  T.eq(box.best:GetText():match("^[^\n]+"), "Velvet Forever to Undercity (booked you)")
  box.take:Click()
  local tookAt = sim:now()
  sim:advance(0.5)
  local m = rider.ns.Ride.matches[1]
  T.ok(m, "confirmed at once, no 3 s collection")
  T.ok(sim:now() - tookAt < 3)
  sim:advance(1)
  local t = taxi.ns.Ride.matches[1]
  T.ok(t, "taxi side started")
  T.eq({ m.reqId, m.role, m.svc, m.price, m.dest, m.eta }, { t.reqId, "rider", "PICK", 12000, "UC", t.eta })
  T.eq({ t.role, t.svc, t.price, t.dest }, { "taxi", "PICK", 12000, "UC" })
  T.eq(m.peer, { key = "Thalindra Forever", raw = "Thalindra Forever" })
  T.eq(t.peer, { key = "Velvet Forever", raw = "Velvet Forever" })
  T.eq(t.eta, 600 + 30 + 0, "ETA_PICK + RESP_DEFAULT")
  T.ok(sentTypes(rider):find("BOOK CONFIRM GONE", 1, true), "rider sent " .. sentTypes(rider))
  T.eq(R.ui.status:GetText(), "Matched with Thalindra Forever, here in about 11 min.")
  T.eq(#other.ns.Ride.matches, 0)
  T.eq(#taxi.errors + #other.errors + #rider.errors, 0)
end)

T.test("a booking nobody takes ends after T.REQUEST without a ride", function()
  local sim, taxi, _, rider = world()
  local results = {}
  rider.ns.on("HAIL_RESULT", function(reqId, winner) results[#results + 1] = { reqId, winner } end)
  T.ok(rider.ns.Dispatch.book("Thalindra Forever", "OG", "PICK"))
  sim:advance(1)
  T.eq(#taxi.ns.Dispatch.requests(), 1)
  sim:advance(121)
  T.eq(#results, 1)
  T.eq(results[1][2], nil)
  T.eq(#taxi.ns.Dispatch.requests(), 0, "GONE removes the booking on the taxi")
  T.eq(#rider.ns.Ride.matches, 0)
end)

T.done()
