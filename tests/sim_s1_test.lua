-- Scenario 1 (plan §9): a mage without a Rune of Portals is not offered; once a rune is in the bags,
-- riders see the offer within 60 s. Real Detect, Protocol, Net, Market and Dispatch on the simulator.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local RUNE = 17032

local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra", { items = { [RUNE] = 0 } })
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Orc" })
  sim:advance(2)
  return sim, taxi, rider
end

local function offers(rider, svc)
  return rider.ns.Dispatch.market:offers({ dest = "OG", svc = svc, faction = "Horde" })
end

T.test("without a rune the taxi is on duty but offers nothing", function()
  local sim, taxi, rider = world()
  local _, services = taxi.ns.Detect.current()
  T.eq({ services.canDrive, services.PICK, services.COME }, { true, false, false })
  taxi.ns.Dispatch.setOnDuty(true)
  sim:advance(30)
  T.ok(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"], "the HELLO arrived")
  T.eq(rider.ns.Dispatch.market.offerByKey["Thalindra Forever"].ask, {}, "with an empty ask")
  T.eq(#offers(rider), 0, "no offer at all")
  T.eq(#offers(rider, "PICK"), 0, "no PICK")
  rider:slash("show")
  T.eq(rider.ns.UI.RideTab.ui.tiles[1].sub:GetText(), "no taxis")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("after the rune arrives the rider sees the offer within 60 s", function()
  local sim, taxi, rider = world()
  taxi.ns.Dispatch.setOnDuty(true)
  sim:advance(20)
  T.eq(#offers(rider), 0)
  local seenAt
  rider.ns.on("MARKET_CHANGED", function()
    if not seenAt and #offers(rider, "PICK") > 0 then
      seenAt = sim:now()
    end
  end)
  local boughtAt = sim:now()
  taxi:setItem(RUNE, 5)
  sim:advance(60)
  T.ok(seenAt, "offer seen")
  T.ok(seenAt - boughtAt <= 60, "within 60 s, took " .. tostring(seenAt and seenAt - boughtAt))
  T.ok(seenAt - boughtAt < 10, "in practice right after the debounce and the 5 s HELLO limit")
  local o = offers(rider)
  T.eq(#o, 2)
  T.eq({ o[1].svc, o[1].price, o[2].svc, o[2].price }, { "PICK", 15000, "COME", 30000 })
  rider:slash("show")
  T.eq(rider.ns.UI.RideTab.ui.tiles[1].sub:GetText(), "from 1g 50s · 1 taxi")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.done()
