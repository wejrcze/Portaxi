-- Core/Field.lua, Market spots and the Browse / map side of D19 (taxi on the map, docs/FIELD_TAXI_PLAN.md).
-- Pure helpers first, then simulated clients with world positions. UnitPosition is not in wowstub; this file
-- defines it per client from a shared table, as tests/arrow_test.lua does.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

T.test("cell rounds world yards to the nearest grid point; walk adds the taxi's response", function()
  local sim = Sim.new()
  local F = sim:client("Thalindra").ns.Field
  local G = sim.Const.FIELD.GRID
  T.eq({ F.cell(0, 0) }, { 0, 0 })
  T.eq({ F.cell(G / 2 - 1, -(G / 2 - 1)) }, { 0, 0 })
  T.eq({ F.cell(G / 2 + 1, -(G / 2 + 1)) }, { G, -G })
  T.eq({ F.cell(1234.5, -987.6) }, { 1200, -975 })
  T.eq(F.walk(0, 0), 0)
  T.eq(F.walk(7 * sim.Const.FIELD.SPEED, 20), 27)
end)

-- World --------------------------------------------------------------------------------------------

-- pos[name] = { n, w, inst }; combat[name] = true while fighting.
local function placeable(clients)
  local pos, combat = {}, {}
  for _, wow in ipairs(clients) do
    wow.env.UnitPosition = function(token)
      if token == "player" then
        local p = pos[wow.player.name]
        if p then
          return p[1], p[2], 0, p[3] or 1
        end
      end
    end
    wow.env.UnitAffectingCombat = function(token)
      return token == "player" and combat[wow.player.name] == true
    end
  end
  return pos, combat
end

local function setResting(sim, c, on)
  c.player.resting = on
  c:fire("PLAYER_UPDATE_RESTING")
  sim:advance(3)
end

local function spots(c)
  local out = {}
  for _, e in ipairs(c.sent) do
    if e.msg:find("^SPOT|") then
      out[#out + 1] = e.msg
    end
  end
  return out
end

-- A mage levelling in Durotar and a rider walking there; both outside town.
local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra", { resting = false, zone = "Durotar" })
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll", zone = "Durotar", resting = false })
  local pos, combat = placeable({ taxi, rider })
  pos.Thalindra = { 1060, 520 }
  pos.Velvet = { 1310, 920 } -- the taxi's cell (1050, 525) is 300 / 395 yards away
  sim:advance(2)
  return sim, taxi, rider, pos, combat
end

local function mapOn(sim, taxi)
  taxi.ns.Field.setOn(true)
  sim:advance(1)
end

T.test("the map is off by default; switching it on goes on duty and sends a rounded SPOT", function()
  local sim, taxi, rider = world()
  T.eq(taxi.ns.Field.blocker(), "off")
  sim:advance(40)
  T.eq(#spots(taxi), 0, "nothing without the switch")
  mapOn(sim, taxi)
  T.eq(taxi.env.PortaxiCharDB.onDuty, true)
  T.eq(taxi.ns.Field.active(), true)
  T.eq(spots(taxi), { "SPOT|1|1|1050|525|0" }, "75-yard grid, never the exact position")
  local spot = rider.ns.Dispatch.market.spotByKey["Thalindra Forever"]
  T.eq({ spot.inst, spot.n, spot.w, spot.busy }, { 1, 1050, 525, false })
end)

T.test("the rider sees the taxi once a city is chosen and not resting; nearest first, with the walk", function()
  local sim, taxi, rider = world()
  mapOn(sim, taxi)
  local F = rider.ns.Field
  T.eq({ F.nearby(nil) }, { {}, "dest" })
  local list = F.nearby("OG")
  T.eq(#list, 1)
  local e = list[1]
  T.eq({ e.key, e.svc, e.price }, { "Thalindra Forever", "PICK", 15000 })
  T.ok(math.abs(e.yards - math.sqrt(260 * 260 + 395 * 395)) < 1e-6, "distance to the cell")
  T.eq(e.eta, F.walk(e.yards, sim.Const.RESP_DEFAULT))
  T.eq(e.walk, 68, "the walk alone: 473 yards at 7 yards a second, no response time")
  setResting(sim, rider, true)
  T.eq({ F.nearby("OG") }, { {}, "resting" }, "a resting rider gets the town taxi")
end)

T.test("Browse puts the taxi on the map first, with the distance, and books with the rider's ETA", function()
  local sim, taxi, rider = world()
  mapOn(sim, taxi)
  rider:slash("show")
  local R = rider.ns.UI.RideTab
  R.selectCity("OG")
  R.setMode("browse")
  local row = R.ui.rows[1]
  T.ok(row:IsShown())
  T.eq(row.offer.near, true)
  T.ok(row.stripe:IsShown(), "green stripe")
  T.eq(row.place:GetText(), "~473 yd · ~68 s on foot")
  T.ok(not R.ui.rows[2]:IsShown(), "the same taxi is not listed twice")
  local eta = row.offer.eta
  row.book:Click()
  sim:advance(1)
  T.eq(#taxi.ns.Dispatch.requests(), 1, "the booking reached the taxi")
  T.ok(taxi.ns.Dispatch.take(taxi.ns.Dispatch.requests()[1].request.reqId))
  sim:advance(1)
  local ride = rider.ns.Ride.current()
  T.ok(ride, "ride started")
  T.eq({ ride.svc, ride.eta }, { "PICK", eta }, "the rider's own estimate, not the fixed pickup ETA")
end)

T.test("on the map the taxi is not alerted by hails from town, only by bookings", function()
  local sim, taxi = world()
  local town = sim:client("Brakk", { class = "WARRIOR", race = "Orc", zone = "Undercity", resting = true })
  sim:advance(2)
  mapOn(sim, taxi)
  local incoming = 0
  taxi.ns.on("INCOMING_REQUEST", function() incoming = incoming + 1 end)
  T.ok(town.ns.Dispatch.hail("OG", 30000))
  sim:advance(2)
  T.eq(#taxi.ns.Dispatch.requests(), 0)
  T.eq(incoming, 0)
  setResting(sim, taxi, true) -- back in town: a normal taxi again, the hail is in the list
  T.eq(taxi.ns.Field.blocker(), "resting")
  T.eq(#taxi.ns.Dispatch.requests(), 1)
end)

T.test("a new cell goes out after the gap, the same cell only with the heartbeat; town takes the taxi off", function()
  local sim, taxi, rider, pos = world()
  mapOn(sim, taxi)
  pos.Thalindra = { 1030, 540 } -- same cell
  sim:advance(sim.Const.T.SPOT_CHECK + 1)
  T.eq(#spots(taxi), 1)
  pos.Thalindra = { 1200, 540 } -- next cells north
  sim:advance(sim.Const.T.SPOT_GAP + sim.Const.T.SPOT_CHECK)
  T.eq(#spots(taxi), 2)
  T.eq(spots(taxi)[2], "SPOT|1|1|1200|525|0")
  sim:advance(sim.Const.T.SPOT + sim.Const.T.SPOT_JITTER + sim.Const.T.SPOT_CHECK)
  T.eq(#spots(taxi), 3, "heartbeat")
  setResting(sim, taxi, true)
  local all = spots(taxi)
  T.eq(all[#all], "SPOT|1|-1|0|0|0")
  T.eq(rider.ns.Dispatch.market.spotByKey["Thalindra Forever"], nil)
  T.eq(#rider.ns.Field.nearby("OG"), 0)
end)

T.test("fighting marks the taxi busy: Browse shows Busy and does not book", function()
  local sim, taxi, rider, _, combat = world()
  mapOn(sim, taxi)
  combat.Thalindra = true
  sim:advance(sim.Const.T.SPOT_GAP + sim.Const.T.SPOT_CHECK)
  local e = rider.ns.Field.nearby("OG")[1]
  T.eq(e.busy, true)
  rider:slash("show")
  local R = rider.ns.UI.RideTab
  R.selectCity("OG")
  R.setMode("browse")
  T.eq(R.ui.rows[1].book:GetText(), "Busy")
  T.ok(not R.ui.rows[1].book:IsEnabled())
end)

T.test("another continent, an instance, or no position: nothing on the map", function()
  local sim, taxi, rider, pos = world()
  mapOn(sim, taxi)
  pos.Velvet = { 1310, 920, 0 }
  T.eq(#rider.ns.Field.nearby("OG"), 0, "other continent")
  pos.Velvet = { 1310, 920, 1 }
  rider.env.IsInInstance = function() return true, "party" end
  T.eq(select(2, rider.ns.Field.nearby("OG")), "instance")
  rider.env.IsInInstance = nil
  pos.Velvet = nil
  T.eq(select(2, rider.ns.Field.nearby("OG")), "position")
  taxi.env.IsInInstance = function() return true, "party" end
  sim:advance(sim.Const.T.SPOT_CHECK + 1)
  T.eq(taxi.ns.Field.blocker(), "instance")
  T.eq(spots(taxi)[#spots(taxi)], "SPOT|1|-1|0|0|0")
end)

-- World map pins ---------------------------------------------------------------------------------

T.test("MapPins: pins at the map position of the cell with a ring of one cell, booking on click", function()
  local sim, taxi, rider = world()
  mapOn(sim, taxi)
  local env = rider.env
  -- A 10000 x 10000 yard map whose top left corner is world (5000 N, 5000 W).
  env.C_Map = env.C_Map or {}
  env.C_Map.GetMapPosFromWorldPos = function(inst, v, mapId)
    if inst ~= 1 or mapId ~= 1411 then
      return nil
    end
    return mapId, { x = (5000 - v.y) / 10000, y = (5000 - v.x) / 10000 }
  end
  local P = rider.ns.UI.MapPins
  T.eq(#P.view(1411), 0, "no city chosen yet")
  rider:slash("show")
  rider.ns.UI.RideTab.selectCity("OG")
  local list = P.view(1411)
  T.eq(#list, 1)
  T.ok(math.abs(list[1].x - (5000 - 525) / 10000) < 1e-9)
  T.ok(math.abs(list[1].y - (5000 - 1050) / 10000) < 1e-9)
  T.ok(math.abs(list[1].r - 75 / 10000) < 1e-9, "radius = one grid cell")
  T.eq(#P.view(1412), 0, "another map")
  -- Rendering needs the map canvas; without WorldMapFrame nothing is drawn and nothing breaks.
  T.eq(P.attach(), false)
  P.refresh()
  local canvas = env.CreateFrame("Frame")
  env.WorldMapFrame = env.CreateFrame("Frame")
  env.WorldMapFrame.ScrollContainer = { Child = canvas }
  env.WorldMapFrame.GetMapID = function() return 1411 end
  env.WorldMapFrame:Show()
  T.eq(P.attach(), true)
  P.refresh()
  local pin = P.pins[1]
  T.ok(pin and pin:IsShown(), "pin shown")
  T.eq(pin.entry.key, "Thalindra Forever")
  pin:Click()
  sim:advance(1)
  T.eq(rider.ns.Dispatch.status().hail.booked, "Thalindra Forever")
  T.eq(#taxi.ns.Dispatch.requests(), 1)
  env.WorldMapFrame:Hide()
  P.refresh()
  T.ok(not pin:IsShown(), "hidden with the map")
end)

T.test("/ptx field puts the taxi back on the map after Off; /ptx where stores what the position APIs return", function()
  local sim, taxi = world()
  taxi:slash("field")
  T.eq(taxi.ns.Field.active(), true)
  taxi.ns.UI.DutyBox.goOff() -- Off leaves the switch on
  T.eq({ taxi.env.PortaxiCharDB.field, taxi.env.PortaxiCharDB.onDuty }, { true, false })
  taxi:slash("field")
  T.eq(taxi.ns.Field.active(), true, "back on the map, not switched off")
  taxi:slash("field")
  T.eq(taxi.env.PortaxiCharDB.field, false)
  sim:advance(1)
  taxi:slash("where")
  local w = taxi.env.PortaxiDB.where
  T.eq(w.unitPosition, { 1060, 520, 0, 1 })
  T.eq(w.position, { 1060, 520, 1 })
  T.eq(w.cell, { 1050, 525 })
  T.eq(w.field.blocker, "off")
end)

T.test("/ptx mapself: the taxi sees its own pin and Browse row from its last SPOT, and cannot book itself", function()
  local sim, taxi = world()
  mapOn(sim, taxi)
  local F, R = taxi.ns.Field, taxi.ns.UI.RideTab
  taxi:slash("show")
  R.selectCity("OG")
  T.eq(#F.nearby("OG"), 0, "off by default: the network never echoes the own SPOT")
  taxi:slash("mapself")
  local list = F.nearby("OG")
  T.eq(#list, 1)
  local e = list[1]
  T.eq({ e.key, e.self, e.svc, e.price }, { "Thalindra Forever", true, "PICK", 15000 })
  T.ok(math.abs(e.yards - math.sqrt(10 * 10 + 5 * 5)) < 1e-6, "from the exact position to the own cell")
  T.eq(#F.nearby("TB"), 0, "a city the taxi does not serve")
  R.setMode("browse")
  local row = R.ui.rows[1]
  T.eq(row.offer.self, true)
  T.eq(row.book:GetText(), "You")
  T.ok(not row.book:IsEnabled())
  local env = taxi.env
  env.C_Map = env.C_Map or {}
  env.C_Map.GetMapPosFromWorldPos = function(_, v, mapId)
    return mapId, { x = (5000 - v.y) / 10000, y = (5000 - v.x) / 10000 }
  end
  env.WorldMapFrame = env.CreateFrame("Frame")
  env.WorldMapFrame.ScrollContainer = { Child = env.CreateFrame("Frame") }
  env.WorldMapFrame.GetMapID = function() return 1411 end
  env.WorldMapFrame:Show()
  local P = taxi.ns.UI.MapPins
  T.ok(P.attach())
  P.refresh()
  T.ok(P.pins[1] and P.pins[1]:IsShown(), "own pin drawn")
  T.eq(P.levelSource, "canvas", "no frame level manager: far above the canvas")
  T.ok(P.level >= 1000)
  env.WorldMapFrame.GetPinFrameLevelsManager = function()
    return { GetValidFrameLevel = function(_, kind) return kind == "PIN_FRAME_LEVEL_AREA_POI" and 734 or nil end }
  end
  P.refresh()
  T.eq({ P.level, P.levelSource }, { 734, "manager" }, "the level of area POIs, above explored areas")
  P.pins[1]:Click()
  sim:advance(1)
  T.eq(taxi.ns.Dispatch.status().hail, nil, "no booking of oneself")
  taxi:slash("mapself")
  T.eq(#F.nearby("OG"), 0, "off again")
end)

T.test("Browse follows the walking rider: the distance updates within a few seconds without network news", function()
  local sim, taxi, rider, pos = world()
  mapOn(sim, taxi)
  rider:slash("show")
  local R = rider.ns.UI.RideTab
  R.selectCity("OG")
  R.setMode("browse")
  T.eq(R.ui.rows[1].place:GetText(), "~473 yd · ~68 s on foot")
  pos.Velvet = { 1050, 625 } -- walked to 100 yards south of the taxi's cell
  sim:advance(3)
  T.eq(R.ui.rows[1].place:GetText(), "~100 yd · ~14 s on foot")
end)

T.done()
