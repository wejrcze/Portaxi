-- Plan §9 scenario 6 on two simulated clients: the rider cancels after the scroll cast started -> a late cancel
-- recorded on the rider; before the scroll the cancel is free. Fake Secure / Trade per playbook §2 (card I).
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

-- The last RIDE_STATE ride of a client (survives the end of the ride).
local function lastRide(wow)
  local box = {}
  wow.ns.on("RIDE_STATE", function(r) box.ride = r end)
  return box
end

local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Troll", zone = "Undercity", mapId = 1458 })
  local tf, rf = fakes(taxi), fakes(rider)
  sim:advance(2)
  local base = { reqId = "Velvet:1", svc = "COME", price = 30000, dest = "OG", eta = 25 }
  local r, t = {}, {}
  for k, v in pairs(base) do r[k], t[k] = v, v end
  r.role, r.peer = "rider", { key = "Thalindra", raw = "Thalindra Forever" }
  t.role, t.peer = "taxi", { key = "Velvet", raw = "Velvet Forever" }
  local tl, rl = lastRide(taxi), lastRide(rider)
  T.ok(rider.ns.Ride.start(r))
  T.ok(taxi.ns.Ride.start(t))
  sim:advance(2)
  T.eq(taxi.ns.Ride.current().state, "GROUPED")
  T.eq(tf.current.kind, "item")
  return sim, taxi, rider, tf, rf, tl, rl
end

T.test("scenario 6: the rider cancels after the scroll started -> late, recorded, taxi told, both CANCELLED", function()
  local sim, taxi, rider, tf, rf, tl, rl = world()
  T.eq(select(2, sim:click(taxi)), "cast")
  sim:advance(3)
  T.eq(rider.ns.Ride.current().state, "EN_ROUTE")
  T.eq(rider.ns.UI.RidePanel.view().cancel.text, "Cancel (late)")
  T.eq({ rider.ns.Ride.cancel("rider changed plans") }, { true, true })
  T.eq(rider.ns.Ride.current(), nil)
  T.eq(rl.ride.state, "CANCELLED")
  T.eq(rl.ride.late, true)
  local records = rider.env.PortaxiCharDB.lateCancels
  T.eq(#records, 1)
  T.eq(records[1].reqId, "Velvet:1")
  T.eq(records[1].peer, "Thalindra")
  T.eq(records[1].price, 30000)
  T.eq(records[1].at, rider.env.time())

  sim:advance(1)
  T.eq(taxi.ns.Ride.current(), nil)
  T.eq(tl.ride.state, "CANCELLED")
  T.eq(tl.ride.late, true, "the taxi got CANCEL with late = true")
  T.eq(tl.ride.cancelledBy, "rider")
  T.eq(tl.ride.reason, "peer_cancelled")
  T.eq(taxi.env.PortaxiCharDB.lateCancels, {}, "recorded on the rider only")
  T.eq(tf.current, nil)
  T.eq(tf.specs[#tf.specs], false, "Secure cleared on the taxi")
  T.eq(rf.specs[#rf.specs], false, "and on the rider")
  T.eq(taxi.ns.UI.RidePanel.view().status, "Ride cancelled: Velvet cancelled the ride. Late cancel.")

  sim:advance(10) -- the scroll cast still finishes; nothing happens to the finished rides
  T.eq(taxi.ns.Ride.current(), nil)
  T.eq(taxi.player.zone, "Undercity")
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("scenario 6: a cancel before the scroll is free and leaves no record", function()
  local sim, taxi, rider, tf, _, tl, rl = world()
  T.eq(rider.ns.UI.RidePanel.view().cancel.text, "Cancel (free)")
  T.eq({ rider.ns.Ride.cancel() }, { true, false })
  T.eq(rl.ride.late, false)
  T.eq(rider.env.PortaxiCharDB.lateCancels, {})
  sim:advance(1)
  T.eq(tl.ride.state, "CANCELLED")
  T.eq(tl.ride.late, false)
  T.eq(tf.current, nil, "the armed scroll is gone")
  T.eq(taxi.env.PortaxiNextButton:GetAttribute("type"), nil)
  T.eq(#taxi.errors + #rider.errors, 0)
end)

T.test("the taxi cancels free before the scroll, but not after it started", function()
  local sim, taxi, rider, _, _, _, rl = world()
  T.eq({ taxi.ns.Ride.cancel() }, { true, false })
  sim:advance(1)
  T.eq(rl.ride.state, "CANCELLED")
  T.eq(rl.ride.cancelledBy, "taxi")
  T.eq(rider.ns.UI.RidePanel.view().status, "Ride cancelled: Thalindra cancelled the ride.")

  local sim2, taxi2, rider2 = world()
  sim2:click(taxi2)
  T.eq({ taxi2.ns.Ride.cancel() }, { nil, "too_late" })
  sim2:advance(1)
  T.eq(rider2.ns.Ride.current().state, "EN_ROUTE")
  T.eq(#taxi.errors + #rider.errors + #taxi2.errors + #rider2.errors, 0)
end)

T.done()
