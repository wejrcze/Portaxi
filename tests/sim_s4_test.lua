-- Plan §9 scenario 4, full stack (architect, gate G2): a Come-to-you ride from the hail to the portal with
-- every real module: Detect, Net, Protocol, Market, Dispatch, Ride, Trade, Secure and the UI.
-- Party: automatic invite and accept. Scroll and portal: the player's click on PortaxiNextButton (sim:click).
-- Trade: opened by the taxi's addon, gold prefilled by the rider's addon, both players click Trade.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local SCROLL, PORTAL_OG, PRICE = 213548, 11417, 30000

local function history(wow)
  local seen = {}
  wow.ns.on("RIDE_STATE", function(r)
    if seen[#seen] ~= r.state then seen[#seen + 1] = r.state end
  end)
  return seen
end

local function state(wow)
  local r = wow.ns.Ride.current()
  return r and r.state
end

-- A Horde mage taxi resting in Orgrimmar and a Horde warrior resting in Undercity with 10g.
local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll", zone = "Undercity",
    subzone = "Trade Quarter", mapId = 1458, money = 100000, spells = {}, items = {} })
  sim:advance(2)
  taxi.ns.Dispatch.setOnDuty(true)
  sim:advance(2)
  return sim, taxi, rider
end

T.test("scenario 4: hail -> take -> group -> scroll -> trade with prefill -> portal after payment -> done", function()
  local sim, taxi, rider = world()
  local th, rh = history(taxi), history(rider)

  -- The rider sees the taxi's offer and hails Orgrimmar with a 4g maximum.
  local offers = rider.ns.Dispatch.market:offers({ dest = "OG", svc = "COME", faction = "Horde" })
  T.eq(#offers, 1, "the taxi's HELLO reached the rider")
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  local reqId = rider.ns.Dispatch.status().hail.reqId
  T.eq(#taxi.raidWarnings, 1, "the taxi was alerted")

  -- The taxi takes it from its request list; after the 3 s collection the rider confirms.
  local list = taxi.ns.Dispatch.requests()
  T.eq(#list, 1)
  T.eq({ list[1].svc, list[1].price }, { "COME", PRICE })
  T.ok(taxi.ns.Dispatch.take(reqId))
  sim:advance(5)
  T.ok(rider.ns.Ride.current() and taxi.ns.Ride.current(), "both sides started the ride")

  -- Automatic invite and accept form the group.
  sim:advance(3)
  T.eq(state(taxi), "GROUPED")
  T.eq(state(rider), "GROUPED")
  T.eq(taxi.party, { "Velvet" })

  -- The taxi's button is armed with the scroll on the rider; no portal before payment.
  local button = taxi.env.PortaxiNextButton
  T.ok(button:IsShown(), "the Portaxi button is visible")
  T.eq({ button:GetAttribute("type"), button:GetAttribute("item"), button:GetAttribute("unit") },
    { "item", "item:" .. SCROLL, "party1" })
  T.eq(button:GetAttribute("spell"), nil, "no portal before payment")

  -- The player clicks: the scroll is cast and the taxi arrives in Undercity.
  local _, cast = sim:click(taxi)
  T.eq(cast, "cast")
  T.eq(state(rider), "EN_ROUTE")
  sim:advance(11)
  T.eq(taxi.player.zone, "Undercity")
  T.eq(taxi.player.items[SCROLL], 8, "one scroll used")

  -- The taxi's addon opens the trade. Forever forbids addons to set trade gold (gate G2), so the rider's
  -- panel asks for it and the player types it.
  sim:advance(1)
  T.eq(state(taxi), "TRADING")
  T.ok(taxi.trade and rider.trade, "both trade windows are open")
  T.eq(rider.trade.mine, 0, "no automatic prefill on Forever")
  T.eq(#rider:callsTo("C_TradeInfo.SetTradeMoney"), 0)
  T.ok(table.concat(rider.ns.UI.RidePanel.view().notes, "|"):find("Put 3g into the trade window yourself.", 1, true),
    "the rider is told the amount")
  rider.env.C_TradeInfo.SetTradeMoney(PRICE) -- the player types 3g
  sim:advance(1)
  T.eq(taxi.trade.theirs, PRICE, "the taxi sees the offer")
  T.eq(button:GetAttribute("type"), nil, "still nothing armed before payment")

  -- Both players click Trade: the taxi's addon checks the gold and unlocks the portal.
  local taxiBefore, riderBefore = taxi.player.money, rider.player.money
  T.ok(sim:acceptTrade(taxi, rider))
  sim:advance(1)
  T.eq(taxi.player.money, taxiBefore + PRICE)
  T.eq(rider.player.money, riderBefore - PRICE)
  T.eq(state(taxi), "PAID")
  T.eq(state(rider), "PAID")
  T.eq({ button:GetAttribute("type"), button:GetAttribute("spell") }, { "spell", PORTAL_OG })

  -- The player clicks again: the portal opens, the rider steps through.
  local _, portal = sim:click(taxi)
  T.eq(portal, "cast")
  sim:advance(11)
  T.eq(state(taxi), "PORTAL_OPEN")
  T.eq(state(rider), "PORTAL_OPEN")
  sim:takePortal(rider, "OG")
  sim:advance(1)
  T.eq(rider.player.zone, "Orgrimmar")
  T.eq(taxi.ns.Ride.current(), nil)
  T.eq(rider.ns.Ride.current(), nil)
  T.eq(th, { "MATCHED", "GROUPED", "EN_ROUTE", "TRADING", "PAID", "PORTAL_OPEN", "DONE" })
  T.eq(rh, { "MATCHED", "GROUPED", "EN_ROUTE", "ARRIVED", "TRADING", "PAID", "PORTAL_OPEN", "DONE" })

  -- After the ride: button cleared, taxi at the back of the queue, group left, offering again.
  T.ok(not button:IsShown(), "the Portaxi button is hidden again")
  T.ok(taxi.env.time() - taxi.env.PortaxiCharDB.lastRideAt <= 2)
  sim:advance(4)
  T.eq(taxi.party, {}, "the taxi left the ride's group")
  T.eq(rider.party, {}, "the rider sees the group gone")
  T.eq(#rider.env.PortaxiCharDB.lateCancels, 0)
  T.eq(#sim.dropped, 0)
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("scenario 4, short payment: the portal stays locked and the taxi is warned", function()
  local sim, taxi, rider = world()
  local warned = {}
  taxi.ns.on("TRADE_MANUAL", function(what, offered, price) warned[#warned + 1] = { what, offered, price } end)
  T.ok(rider.ns.Dispatch.hail("OG", 40000))
  sim:advance(1)
  taxi.ns.Dispatch.take(rider.ns.Dispatch.status().hail.reqId)
  sim:advance(8)
  sim:click(taxi)
  sim:advance(12)
  T.eq(state(taxi), "TRADING")
  -- The rider lowers the gold before both click Trade.
  rider.env.C_TradeInfo.SetTradeMoney(10000)
  sim:advance(1)
  T.eq(warned[#warned], { "short", 10000, PRICE })
  T.ok(sim:acceptTrade(taxi, rider))
  sim:advance(2)
  T.eq(state(taxi), "TRADING", "no PAID for a short trade")
  T.ok(taxi.env.PortaxiNextButton:GetAttribute("spell") == nil, "the portal stays locked")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.done()
