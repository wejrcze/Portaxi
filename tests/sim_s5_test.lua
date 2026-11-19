-- Plan §9 scenario 5 on two simulated clients: the rider leaves the inn before the scroll, so the taxi's scroll
-- button is disarmed; back in the inn it is armed again and the ride goes on. Also a full Come-to-you ride to DONE
-- with fake Secure / Trade (card I) as a reference for the full-stack scenario 4.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local SCROLL_ITEM = 213548
local PORTAL_OG = 11417

-- Fake Secure.set / Trade.open per playbook §2 (card I writes the real ones).
local function fakes(wow)
  local env, ns = wow.env, wow.ns
  local f = { specs = {}, trades = {} }
  ns.Secure.set = function(spec)
    local b = env.PortaxiNextButton
      or env.CreateFrame("Button", "PortaxiNextButton", env.UIParent, "SecureActionButtonTemplate")
    for _, k in ipairs({ "type", "item", "unit", "spell" }) do b:SetAttribute(k, nil) end
    if spec then
      b:SetAttribute("type", spec.kind)
      if spec.kind == "item" then
        b:SetAttribute("item", "item:" .. spec.item)
        b:SetAttribute("unit", spec.unit)
      else
        b:SetAttribute("spell", spec.spell)
      end
    end
    f.current = spec
    f.specs[#f.specs + 1] = spec or false
    ns.fire("SECURE_CHANGED", spec)
  end
  ns.Trade.open = function(unit)
    f.trades[#f.trades + 1] = unit
    env.InitiateTrade(unit)
  end
  return f
end

-- Every distinct state a client's ride went through, in order.
local function history(wow)
  local seen = {}
  wow.ns.on("RIDE_STATE", function(r)
    if seen[#seen] ~= r.state then seen[#seen + 1] = r.state end
  end)
  return seen
end

local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll", zone = "Undercity",
    subzone = "Trade Quarter", mapId = 1458, money = 100000 })
  local tf, rf = fakes(taxi), fakes(rider)
  sim:advance(2)
  return sim, taxi, rider, tf, rf
end

local function startRide(sim, taxi, rider)
  local base = { reqId = "Velvet:1", svc = "COME", price = 30000, dest = "OG", eta = 25 }
  local r, t = {}, {}
  for k, v in pairs(base) do r[k], t[k] = v, v end
  r.role, r.peer = "rider", { key = "Thalindra", raw = "Thalindra Forever" }
  t.role, t.peer = "taxi", { key = "Velvet", raw = "Velvet Forever" }
  local th, rh = history(taxi), history(rider)
  T.ok(rider.ns.Ride.start(r))
  T.ok(taxi.ns.Ride.start(t))
  sim:advance(2)
  return th, rh
end

local function state(wow)
  local r = wow.ns.Ride.current()
  return r and r.state
end

T.test("scenario 5: the rider leaves the inn before the scroll -> disarmed; back -> armed; scroll -> ARRIVED", function()
  local sim, taxi, rider, tf = world()
  local th, rh = startRide(sim, taxi, rider)
  T.eq(state(taxi), "GROUPED")
  T.eq(state(rider), "GROUPED")
  T.eq(tf.current.kind, "item")
  T.eq(taxi.env.PortaxiNextButton:GetAttribute("item"), "item:" .. SCROLL_ITEM)
  T.eq(taxi.env.PortaxiNextButton:GetAttribute("unit"), "party1")
  T.eq(taxi.ns.UI.RidePanel.view().secure, "Ready: Teleport to Velvet. Click the Portaxi button.")

  rider:setResting(false)
  sim:advance(1)
  T.eq(taxi.ns.Ride.current().riderResting, false)
  T.eq(tf.current, nil, "scroll button disarmed")
  T.eq(taxi.env.PortaxiNextButton:GetAttribute("type"), nil)
  T.eq(taxi.ns.UI.RidePanel.view().secure, "")
  T.eq(taxi.ns.UI.RidePanel.view().notes[1], "The rider is not resting: the scroll is off. You can cancel for free.")
  T.eq(rider.ns.UI.RidePanel.view().notes[1],
    "You are not resting: the scroll cannot reach you. Go back to an inn or a city.")
  T.eq(taxi.ns.UI.RidePanel.view().cancel.text, "Cancel (free)")
  local _, result = sim:click(taxi)
  T.ok(result ~= "cast", "a click does nothing while disarmed")
  T.eq(state(taxi), "GROUPED")

  rider:setResting(true)
  sim:advance(1)
  T.eq(tf.current.kind, "item", "armed again")
  T.eq(taxi.ns.UI.RidePanel.view().notes, {})

  local click, cast = sim:click(taxi)
  T.eq(cast, "cast")
  T.eq(click.unit, "party1")
  T.eq(state(taxi), "EN_ROUTE")
  T.eq(state(rider), "EN_ROUTE")
  T.eq(tf.current, nil, "no second scroll during the cast")
  sim:advance(4)
  local panel = rider.ns.UI.RidePanel
  panel.updateCast()
  T.ok(panel.frame.cast:IsShown(), "the rider sees the taxi's cast bar")
  T.ok(panel.frame.cast.progress > 0.35 and panel.frame.cast.progress < 0.45)
  sim:advance(7)
  T.eq(taxi.player.zone, "Undercity", "the taxi came to the rider")
  T.eq(th, { "MATCHED", "GROUPED", "EN_ROUTE", "TRADING" }, "ARRIVED is passed in the same step on the taxi")
  T.eq(rh, { "MATCHED", "GROUPED", "EN_ROUTE", "ARRIVED", "TRADING" })
  T.eq(state(taxi), "TRADING")
  T.eq(taxi.trade and taxi.trade.with, "Velvet", "the trade window opened")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("full Come-to-you ride to DONE with fake Secure / Trade (reference for scenario 4)", function()
  local sim, taxi, rider, tf, rf = world()
  local th, rh = startRide(sim, taxi, rider)
  local _, cast = sim:click(taxi)
  T.eq(cast, "cast")
  sim:advance(11)
  T.eq(state(taxi), "TRADING")
  T.eq(state(rider), "TRADING")
  T.eq(tf.trades, { "party1" })
  T.eq(rf.trades, {}, "only the taxi opens the trade")

  -- The rider puts in the price (card I prefills it), both click Trade, card I's Trade fires TRADE_PAID.
  rider.env.C_TradeInfo.SetTradeMoney(30000)
  sim:advance(0.5)
  local before = taxi.player.money
  T.ok(sim:acceptTrade(taxi, rider))
  T.eq(taxi.player.money, before + 30000)
  taxi.ns.fire("TRADE_PAID", "Velvet:1", 30000)
  T.eq(state(taxi), "PAID")
  T.eq(tf.current.spell, PORTAL_OG)
  T.eq(taxi.env.PortaxiNextButton:GetAttribute("type"), "spell")
  sim:advance(1)
  T.eq(state(rider), "PAID")

  local _, portal = sim:click(taxi)
  T.eq(portal, "cast")
  T.eq(state(taxi), "PAID", "the portal is open only when the cast succeeds")
  sim:advance(10.5)
  T.eq(state(taxi), "PORTAL_OPEN")
  T.eq(state(rider), "PORTAL_OPEN")
  T.eq(tf.current, nil)

  sim:takePortal(rider, "OG")
  T.eq(rider.player.zone, "Orgrimmar")
  T.eq(rider.ns.Ride.current(), nil)
  sim:advance(1)
  T.eq(taxi.ns.Ride.current(), nil)
  T.eq(th, { "MATCHED", "GROUPED", "EN_ROUTE", "TRADING", "PAID", "PORTAL_OPEN", "DONE" })
  T.eq(rh, { "MATCHED", "GROUPED", "EN_ROUTE", "ARRIVED", "TRADING", "PAID", "PORTAL_OPEN", "DONE" })
  T.ok(taxi.env.time() - taxi.env.PortaxiCharDB.lastRideAt <= 1, "lastRideAt = time() at DONE")
  T.eq(rider.env.PortaxiCharDB.lastRideAt, 0, "only the taxi moves to the back of the queue")
  T.eq(tf.specs[#tf.specs], false, "Secure cleared at the end")
  T.eq(taxi.env.PortaxiNextButton:GetAttribute("type"), nil)
  T.eq(rf.current, nil)
  T.eq(taxi.ns.UI.RidePanel.view().status, "Arrived. Have a good trip!")
  T.eq(rider.env.PortaxiCharDB.lateCancels, {})
  sim:advance(9)
  T.ok(not taxi.env.PortaxiRidePanel:IsShown())
  T.ok(not rider.env.PortaxiRidePanel:IsShown())
  T.eq(#sim.dropped, 0)
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.done()
