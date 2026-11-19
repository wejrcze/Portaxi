-- Plan §9 scenario 8 on the simulator: combat during a ride -> the secure button changes only after combat.
-- Plus the trade between two clients (open, prefill, offer check, TRADE_PAID) and its D11 fallbacks.
-- Ride is card H's module: both clients get a fake ns.Ride.current in the playbook §2 shape.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local PRICE = 30000
local SCROLL = 213548
local RUNE = 17032
local PORTAL_UC = 11418

local function fakeRide(c, role, peer)
  c.ride = {
    reqId = "Velvet:1", role = role, svc = "COME", price = PRICE, dest = "UC",
    peer = { key = peer .. " Forever", raw = peer .. " Forever" }, state = "TRADING", since = 1000, peerUnit = "party1",
  }
  c.ns.Ride.current = function() return c.ride end
end

-- Taxi Thalindra (mage) and rider Velvet in one party, each with the fake ride.
local function setup()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll" })
  rider:slash("accept")
  taxi:slash("invite Velvet")
  sim:advance(2)
  assert(taxi.units.party1 and taxi.units.party1.name == "Velvet", "party formed")
  fakeRide(taxi, "taxi", "Velvet")
  fakeRide(rider, "rider", "Thalindra")
  -- These scenarios cover the automatic prefill path; Forever forbids it (gate G2, see trade_test).
  for _, c in ipairs({ taxi, rider }) do
    c.ns.Const.TRADE.SET_MONEY_API = true
    c.ns.Const.TRADE.FILL_MONEY_FIELD = true
  end
  return sim, taxi, rider
end

local function record(c, ...)
  local got = {}
  for _, event in ipairs({ ... }) do
    c.ns.on(event, function(...) got[#got + 1] = { event, ... } end)
  end
  return got
end

local function portalSpec()
  return { kind = "spell", spell = PORTAL_UC, label = "Portal: Undercity" }
end

local function attrs(b)
  return { type = b:GetAttribute("type"), item = b:GetAttribute("item"), spell = b:GetAttribute("spell"),
           unit = b:GetAttribute("unit") }
end

T.test("scenario 8: the portal asked for in combat is armed only after combat, then the click casts it", function()
  local sim, taxi, rider = setup()
  local S = taxi.ns.Secure
  local got = record(taxi, "SECURE_CHANGED")
  S.set({ kind = "item", item = SCROLL, unit = "party1", label = "Teleport to Velvet" })
  local button = taxi.env.PortaxiNextButton

  taxi:setCombat(true)
  local portal = portalSpec()
  T.eq(S.set(portal), false, "queued, no error from SetAttribute in combat")
  T.ok(S.pending() == portal, "pending reported")
  T.eq(attrs(button), { type = "item", item = "item:213548", unit = "party1" }, "nothing changes in combat")
  T.eq(#got, 1)
  sim:advance(5)
  T.eq(attrs(button), { type = "item", item = "item:213548", unit = "party1" }, "still nothing while in combat")

  taxi:setCombat(false)
  T.eq(attrs(button), { type = "spell", spell = PORTAL_UC })
  T.ok(button:IsShown())
  T.eq(S.pending(), nil)
  T.eq(#got, 2)
  T.ok(got[2][2] == portal)

  local click, result = sim:click(taxi)
  T.eq(click.type, "spell")
  T.eq(result, "cast")
  sim:advance(10)
  T.eq(taxi.player.items[RUNE], 6, "one rune used")
  T.eq(sim.portals[1].city, "UC")
  sim:takePortal(rider, "UC")
  T.eq(rider.player.zone, "Undercity")
  T.eq(#taxi.errors, 0)
end)

T.test("scenario 8: only the newest spec queued in combat is applied; the rider's button is untouched", function()
  local sim, taxi, rider = setup()
  local S = taxi.ns.Secure
  taxi:setCombat(true)
  S.set({ kind = "item", item = SCROLL, unit = "party1", label = "Teleport to Velvet" })
  S.set(portalSpec())
  S.set(nil)
  local spec, queued = S.pending()
  T.ok(spec == nil and queued, "the nil spec is queued")
  taxi:setCombat(false)
  T.ok(not taxi.env.PortaxiNextButton:IsShown())
  T.eq(attrs(taxi.env.PortaxiNextButton), {})
  local _, result = sim:click(taxi)
  T.eq(result, "ignored", "nothing armed, nothing cast")
  T.ok(not rider.env.PortaxiNextButton:IsShown())
end)

T.test("full trade: the taxi opens it, the rider's gold is prefilled, both accept, the taxi gets TRADE_PAID", function()
  local sim, taxi, rider = setup()
  local taxiGot = record(taxi, "TRADE_PAID", "TRADE_MANUAL", "CAPS_CHANGED")
  local riderGot = record(rider, "TRADE_PAID", "TRADE_MANUAL", "CAPS_CHANGED")
  local taxiMoney, riderMoney = taxi.player.money, rider.player.money

  T.eq(taxi.ns.Trade.open("party1"), true)
  sim:advance(2)
  T.eq(taxi:callsTo("InitiateTrade")[1].args, { "party1" })
  T.eq(rider:callsTo("C_TradeInfo.SetTradeMoney")[1].args, { PRICE })
  T.eq(rider.ns.Trade.status(),
    { open = true, partner = "Thalindra Forever", expected = PRICE, mine = PRICE, theirs = 0, prefilled = true })
  local s = taxi.ns.Trade.status()
  T.eq(s.theirs, PRICE, "the taxi sees the price offered")
  T.eq(s.partner, "Velvet Forever")

  T.eq(sim:acceptTrade(taxi, rider), true)
  sim:advance(5)
  T.eq(taxiGot, { { "TRADE_PAID", "Velvet:1", PRICE } })
  T.eq(riderGot, {})
  T.eq(taxi.player.money, taxiMoney + PRICE)
  T.eq(rider.player.money, riderMoney - PRICE)
  T.eq(taxi.env.PortaxiDB.caps, {})
  T.eq(rider.env.PortaxiDB.caps, {})
end)

T.test("D11: a blocked InitiateTrade falls back to the manual open; the trade then works as usual", function()
  local sim, taxi, rider = setup()
  taxi.blocked["InitiateTrade"] = true
  local got = record(taxi, "TRADE_PAID", "TRADE_MANUAL")
  taxi.ns.Trade.open("party1")
  sim:advance(1)
  T.eq(got, { { "TRADE_MANUAL", "open" } })
  T.eq(taxi.env.PortaxiDB.caps.openTrade, "manual")
  T.eq(rider.trade, nil)

  -- The player clicks RidePanel's "Open trade" (a hardware event: the call goes through).
  taxi.blocked["InitiateTrade"] = nil
  taxi.env.InitiateTrade("party1")
  sim:advance(2)
  T.eq(taxi.ns.Trade.status().theirs, PRICE, "prefilled on the rider side")
  sim:acceptTrade(taxi, rider)
  T.eq(got[2], { "TRADE_PAID", "Velvet:1", PRICE })
end)

T.test("D11: a blocked prefill asks the rider to type the gold; a short amount warns the taxi", function()
  local sim, taxi, rider = setup()
  rider.blocked["C_TradeInfo.SetTradeMoney"] = true
  local riderGot = record(rider, "TRADE_MANUAL")
  local taxiGot = record(taxi, "TRADE_MANUAL", "TRADE_PAID")
  taxi.ns.Trade.open("party1")
  sim:advance(2)
  T.eq(riderGot, { { "TRADE_MANUAL", "prefill", PRICE } })
  T.eq(rider.env.PortaxiDB.caps.prefill, "manual")
  T.eq(taxi.ns.Trade.status().theirs, 0)

  -- The rider types the gold by hand (simulated as the game's own money call): too little first.
  rider.blocked["C_TradeInfo.SetTradeMoney"] = nil
  rider.env.C_TradeInfo.SetTradeMoney(20000)
  sim:advance(0.5)
  T.eq(taxiGot, { { "TRADE_MANUAL", "short", 20000, PRICE } })
  rider.env.C_TradeInfo.SetTradeMoney(PRICE)
  sim:advance(0.5)
  sim:acceptTrade(taxi, rider)
  T.eq(taxiGot[2], { "TRADE_PAID", "Velvet:1", PRICE })
end)

T.test("a short trade accepted anyway pays nothing", function()
  local sim, taxi, rider = setup()
  local got = record(taxi, "TRADE_PAID")
  taxi.ns.Trade.open("party1")
  sim:advance(2)
  -- The rider lowers the prefilled amount by hand.
  rider.env.C_TradeInfo.SetTradeMoney(PRICE - 100)
  sim:advance(0.5)
  sim:acceptTrade(taxi, rider)
  sim:advance(10)
  T.eq(got, {})
end)

T.done()
