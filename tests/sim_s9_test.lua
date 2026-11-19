-- Plan §9 scenario 9 on two simulated clients: the taxi logs out mid ride -> the rider's ride ends FAILED with a
-- reason that the panel shows. Fake Secure / Trade per playbook §2 (card I).
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

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

local function lastRide(wow)
  local box = {}
  wow.ns.on("RIDE_STATE", function(r) box.ride = r end)
  return box
end

local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll", zone = "Undercity", mapId = 1458 })
  fakes(taxi)
  fakes(rider)
  sim:advance(2)
  return sim, taxi, rider
end

local function startBoth(taxi, rider)
  local base = { reqId = "Velvet:1", svc = "COME", price = 30000, dest = "OG", eta = 25 }
  local r, t = {}, {}
  for k, v in pairs(base) do r[k], t[k] = v, v end
  r.role, r.peer = "rider", { key = "Thalindra", raw = "Thalindra Forever" }
  t.role, t.peer = "taxi", { key = "Velvet", raw = "Velvet Forever" }
  T.ok(rider.ns.Ride.start(r))
  T.ok(taxi.ns.Ride.start(t))
end

T.test("scenario 9: the taxi logs out during the scroll -> the rider's ride FAILED, the panel says why", function()
  local sim, taxi, rider = world()
  local rl = lastRide(rider)
  startBoth(taxi, rider)
  sim:advance(2)
  T.eq(select(2, sim:click(taxi)), "cast")
  sim:advance(3)
  T.eq(rider.ns.Ride.current().state, "EN_ROUTE")
  sim:logout(taxi)
  T.eq(rider.ns.Ride.current(), nil)
  T.eq(rl.ride.state, "FAILED")
  T.eq(rl.ride.reason, "peer_offline")
  T.eq(rider.env.PortaxiCharDB.lateCancels, {}, "not the rider's fault")
  local panel = rider.ns.UI.RidePanel
  T.ok(rider.env.PortaxiRidePanel:IsShown())
  T.eq(panel.view().status, "Ride failed: Thalindra went offline.")
  T.eq(panel.frame.status:GetText(), "Ride failed: Thalindra went offline.")
  T.eq(panel.view().cancel.shown, false)
  panel.updateCast()
  T.ok(not panel.frame.cast:IsShown(), "no cast bar after the end")
  sim:advance(10)
  T.ok(not rider.env.PortaxiRidePanel:IsShown(), "hidden a few seconds later")
  T.eq(#rider.errors, 0)
end)

T.test("scenario 9: the taxi logs out before the group formed -> the rider fails after T.INVITE", function()
  local sim, taxi, rider = world()
  local rl = lastRide(rider)
  startBoth(taxi, rider)
  sim:logout(taxi) -- before its invite timer ran
  sim:advance(59)
  T.eq(rider.ns.Ride.current().state, "MATCHED")
  sim:advance(1.5)
  T.eq(rider.ns.Ride.current(), nil)
  T.eq(rl.ride.state, "FAILED")
  T.eq(rl.ride.reason, "invite_timeout")
  T.eq(rider.ns.UI.RidePanel.view().status, "Ride failed: The group did not form in time.")
  T.eq(#rider.errors, 0)
end)

T.test("a rider that leaves the group mid ride fails the taxi's ride too", function()
  local sim, taxi, rider = world()
  local tl = lastRide(taxi)
  startBoth(taxi, rider)
  sim:advance(2)
  rider.env.C_PartyInfo.LeaveParty()
  T.eq(rider.ns.Ride.current(), nil)
  sim:advance(1)
  T.eq(tl.ride.state, "FAILED")
  T.ok(tl.ride.reason == "left_group" or tl.ride.reason == "peer_failed")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.done()
