-- Ride (card H): the pure state machine (Ride.new / Ride.step), its glue on one fake client, and the RidePanel.
-- Secure and Trade belong to card I; the glue tests install fakes that follow playbook §2.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local SCROLL_SPELL = 434752
local PORTAL_OG = 11417
local SCROLL_ITEM = 213548

local RIDER = { name = "Velvet", class = "WARRIOR", race = "Troll", zone = "Undercity", spells = {}, items = {} }

local function client(player)
  local wow = Wow.new({ player = player })
  wow:load()
  return wow
end

local base = client()
local R = base.ns.Ride

local function match(role, svc)
  local peer = role == "taxi" and { key = "Velvet", raw = "Velvet Forever" }
    or { key = "Thalindra", raw = "Thalindra Forever" }
  return { reqId = "Velvet:1", role = role, svc = svc or "COME", price = 30000, dest = "OG", peer = peer, eta = 25 }
end

-- Runs { event, now } pairs; returns the last ride and all actions.
local function run(ride, list)
  local all = {}
  for _, item in ipairs(list) do
    local acts
    ride, acts = R.step(ride, item[1], item[2])
    for _, a in ipairs(acts) do all[#all + 1] = a end
  end
  return ride, all
end

-- Actions as short strings: "SEND:EN_ROUTE", "SECURE:item:party1", "SECURE:nil", "CAPS:invite", "END", ...
local function names(acts)
  local out = {}
  for _, a in ipairs(acts) do
    local s = a.type
    if a.type == "SEND" then
      s = s .. ":" .. a.state
    elseif a.type == "SECURE" then
      s = s .. ":" .. (a.spec and (a.spec.kind .. ":" .. tostring(a.spec.unit or a.spec.spell)) or "nil")
    elseif a.type == "CAPS" then
      s = s .. ":" .. a.what
    elseif a.type == "CANCEL_MSG" then
      s = s .. ":" .. tostring(a.late)
    end
    out[#out + 1] = s
  end
  return out
end

local function has(acts, name)
  for _, n in ipairs(names(acts)) do
    if n == name then return true end
  end
  return false
end

local function ev(t, fields)
  local e = { type = t }
  for k, v in pairs(fields or {}) do e[k] = v end
  return e
end

local ROSTER = ev("ROSTER", { unit = "party1", connected = true })
local function cast(who, spell, phase, guid)
  return ev("CAST", { who = who, spell = spell, phase = phase, guid = guid })
end

-- A ride moved to `state` the normal way (taxi or rider, COME unless svc given).
local function rideAt(role, state, svc)
  local ride = R.new(match(role, svc), 100)
  local taxi = role == "taxi"
  local path = {
    { ev("RESTING", { resting = true }), 100 },
    { ev("PEER_STATE", { state = "RESTING" }), 100 },
    { ROSTER, 101 },
  }
  local come = (svc or "COME") == "COME"
  if state ~= "GROUPED" and state ~= "MATCHED" then
    if come then
      path[#path + 1] = { cast(taxi and "self" or "peer", "SCROLL", "START", "g1"), 102 }
    end
    if state ~= "EN_ROUTE" then
      path[#path + 1] = come and { cast(taxi and "self" or "peer", "SCROLL", "SUCCEEDED", "g1"), 112 }
        or { ev("NEAR"), 112 }
      if come then
        path[#path + 1] = taxi and { ev("LANDED"), 112.5 } or { ev("PEER_STATE", { state = "ARRIVED" }), 112.5 }
      end
      if not taxi and state ~= "ARRIVED" then
        path[#path + 1] = { ev("PEER_STATE", { state = "TRADING" }), 113 }
      end
      if state == "PAID" or state == "PORTAL_OPEN" then
        path[#path + 1] = taxi and { ev("PAID", { copper = 30000 }), 120 } or { ev("PEER_STATE", { state = "PAID" }), 120 }
      end
      if state == "PORTAL_OPEN" then
        path[#path + 1] = { cast(taxi and "self" or "peer", "PORTAL", "SUCCEEDED", "p1"), 130 }
      end
    end
  end
  if state == "MATCHED" then path = {} end
  ride = run(ride, path)
  T.eq(ride.state, state, "rideAt " .. role .. " " .. state)
  return ride
end

-- Pure state machine ------------------------------------------------------------------------------

T.test("new: MATCHED with the match fields; the taxi invites; a bad match is refused", function()
  local ride, acts = R.new(match("taxi"), 50)
  T.eq(ride.state, "MATCHED")
  T.eq(ride.since, 50)
  T.eq(ride.reqId, "Velvet:1")
  T.eq(ride.peer, { key = "Velvet", raw = "Velvet Forever" })
  T.eq(ride.late, false)
  T.eq(names(acts), { "INVITE" })
  local rider, racts = R.new(match("rider"), 50)
  T.eq(rider.role, "rider")
  T.eq(racts, {})
  T.eq({ R.new({ role = "taxi" }, 1) }, { nil, "match" })
  local bad = match("taxi")
  bad.dest = "XX"
  T.eq(select(2, R.new(bad, 1)), "match")
end)

T.test("step never changes the ride it gets", function()
  local ride = R.new(match("taxi"), 0)
  local after = R.step(ride, ROSTER, 1)
  T.eq(ride.state, "MATCHED")
  T.eq(ride.peerUnit, nil)
  T.eq(after.state, "GROUPED")
  T.ok(after ~= ride)
end)

T.test("taxi COME: group, rider rests -> scroll armed, cast, trade, paid -> portal, portal, DONE from the rider", function()
  local ride, acts = R.new(match("taxi"), 0)
  ride, acts = R.step(ride, ROSTER, 2)
  T.eq(ride.state, "GROUPED")
  T.eq(ride.peerUnit, "party1")
  T.eq(names(acts), {}, "nothing armed while the rider's resting state is unknown")
  ride, acts = R.step(ride, ev("PEER_STATE", { state = "RESTING" }), 3)
  T.eq(ride.riderResting, true)
  T.eq(names(acts), { "SECURE:item:party1" })
  T.eq(acts[1].spec.item, SCROLL_ITEM)
  T.eq(acts[1].spec.label, "Teleport to Velvet")
  ride, acts = R.step(ride, cast("self", "SCROLL", "START", "g1"), 5)
  T.eq(ride.state, "EN_ROUTE")
  T.eq(names(acts), { "SEND:EN_ROUTE", "SECURE:nil" })
  ride, acts = R.step(ride, cast("self", "SCROLL", "SUCCEEDED", "g1"), 15)
  T.eq(ride.state, "EN_ROUTE", "SUCCEEDED alone is no proof (it also fires on Invalid target)")
  T.eq(ride.landing, 15)
  T.eq(names(acts), {})
  ride, acts = R.step(ride, ev("LANDED"), 15.5)
  T.eq(ride.state, "TRADING", "ARRIVED -> TRADING at once on the taxi")
  T.eq(ride.landing, nil)
  T.eq(names(acts), { "SEND:ARRIVED", "SEND:TRADING", "TRADE_OPEN" })
  ride, acts = R.step(ride, ev("PAID", { copper = 30000 }), 20)
  T.eq(ride.state, "PAID")
  T.eq(ride.paid, 30000)
  T.eq(names(acts), { "SEND:PAID", "SECURE:spell:" .. PORTAL_OG })
  T.eq(acts[2].spec.label, "Portal: Orgrimmar")
  ride, acts = R.step(ride, cast("self", "PORTAL", "SUCCEEDED", "p1"), 30)
  T.eq(ride.state, "PORTAL_OPEN")
  T.eq(names(acts), { "SEND:PORTAL_OPEN", "SECURE:nil" })
  ride, acts = R.step(ride, ev("PEER_STATE", { state = "DONE" }), 40)
  T.eq(ride.state, "DONE")
  T.eq(names(acts), { "SECURE:nil", "LAST_RIDE", "END" })
  T.ok(R.isOver(ride))
end)

T.test("rider COME: accepts the peer's invite, follows the taxi, leads DONE on reaching the city", function()
  local ride, acts = R.new(match("rider"), 0)
  ride, acts = R.step(ride, ev("RESTING", { resting = true }), 0)
  T.eq(names(acts), { "SEND:RESTING" })
  ride, acts = R.step(ride, ev("INVITE", { from = "Thalindra" }), 1)
  T.eq(ride.invited, true)
  T.eq(names(acts), { "ACCEPT" })
  ride, acts = R.step(ride, ROSTER, 2)
  T.eq(ride.state, "GROUPED")
  T.eq(names(acts), { "SEND:RESTING" }, "resent once grouped")
  ride, acts = R.step(ride, cast("peer", "SCROLL", "START", "g1"), 3)
  T.eq(ride.state, "EN_ROUTE")
  T.eq(names(acts), {}, "the rider does not lead EN_ROUTE")
  ride = R.step(ride, ev("PEER_STATE", { state = "EN_ROUTE" }), 3.1)
  T.eq(ride.state, "EN_ROUTE", "the taxi's EN_ROUTE is a no-op")
  ride, acts = R.step(ride, cast("peer", "SCROLL", "SUCCEEDED", "g1"), 13)
  T.eq(ride.state, "EN_ROUTE", "the rider waits for the taxi's proof")
  T.eq(names(acts), {})
  ride, acts = R.step(ride, ev("PEER_STATE", { state = "ARRIVED" }), 13.5)
  T.eq(ride.state, "ARRIVED")
  T.eq(names(acts), {}, "no trade from the rider")
  ride = R.step(ride, ev("PEER_STATE", { state = "TRADING" }), 14)
  T.eq(ride.state, "TRADING")
  ride, acts = R.step(ride, ev("PAID", { copper = 30000 }), 15)
  T.eq(ride.state, "TRADING", "TRADE_PAID is the taxi's")
  ride = R.step(ride, ev("PEER_STATE", { state = "PAID" }), 20)
  T.eq(ride.state, "PAID")
  ride, acts = R.step(ride, cast("peer", "PORTAL", "SUCCEEDED", "p1"), 30)
  T.eq(ride.state, "PORTAL_OPEN")
  T.eq(names(acts), {})
  ride, acts = R.step(ride, ev("ZONE", { zone = "Undercity" }), 31)
  T.eq(ride.state, "PORTAL_OPEN")
  ride, acts = R.step(ride, ev("ZONE", { zone = "Orgrimmar" }), 35)
  T.eq(ride.state, "DONE")
  T.eq(names(acts), { "SEND:DONE", "SECURE:nil", "END" })
end)

T.test("rider: the zone counts only after payment; casts of the rider's own are ignored", function()
  local ride = rideAt("rider", "GROUPED")
  ride = R.step(ride, ev("ZONE", { zone = "Orgrimmar" }), 5)
  T.eq(ride.state, "GROUPED")
  ride = R.step(ride, cast("self", "SCROLL", "START", "x"), 6)
  T.eq(ride.state, "GROUPED", "only the peer's scroll moves the rider")
  local taxi = rideAt("taxi", "GROUPED")
  taxi = R.step(taxi, cast("peer", "SCROLL", "START", "x"), 6)
  T.eq(taxi.state, "GROUPED", "only the taxi's own scroll moves the taxi")
end)

T.test("taxi PICK: GROUPED -> EN_ROUTE at once, proximity -> trade; nothing armed before PAID", function()
  local ride, acts = R.new(match("taxi", "PICK"), 0)
  ride, acts = R.step(ride, ev("PEER_STATE", { state = "RESTING" }), 1)
  ride, acts = R.step(ride, ROSTER, 2)
  T.eq(ride.state, "EN_ROUTE")
  T.eq(names(acts), { "SEND:EN_ROUTE" })
  ride, acts = R.step(ride, cast("self", "SCROLL", "START", "g"), 3)
  T.eq(ride.state, "EN_ROUTE", "no scroll in a pickup")
  ride, acts = R.step(ride, ev("NEAR"), 60)
  T.eq(ride.state, "TRADING")
  T.eq(names(acts), { "SEND:ARRIVED", "SEND:TRADING", "TRADE_OPEN" })
  ride, acts = R.step(ride, ev("PAID", { copper = 15000 }), 70)
  T.eq(names(acts), { "SEND:PAID", "SECURE:spell:" .. PORTAL_OG })
end)

T.test("rider PICK: EN_ROUTE at once, ARRIVED on proximity or the taxi's STATE", function()
  local ride = R.new(match("rider", "PICK"), 0)
  ride = R.step(ride, ROSTER, 1)
  T.eq(ride.state, "EN_ROUTE")
  local near = R.step(ride, ev("NEAR"), 30)
  T.eq(near.state, "ARRIVED")
  local told = R.step(ride, ev("PEER_STATE", { state = "ARRIVED" }), 30)
  T.eq(told.state, "ARRIVED")
end)

T.test("T.INVITE without a group -> FAILED invite_timeout; FAILED goes to the peer", function()
  local ride = R.new(match("taxi"), 100)
  local still = R.step(ride, ev("TICK"), 159.9)
  T.eq(still.state, "MATCHED")
  local failed, acts = R.step(ride, ev("TICK"), 160)
  T.eq(failed.state, "FAILED")
  T.eq(failed.reason, "invite_timeout")
  T.eq(names(acts), { "SEND:FAILED", "SECURE:nil", "END" })
  local grouped = R.step(ride, ROSTER, 120)
  T.eq(R.step(grouped, ev("TICK"), 500).state, "GROUPED", "no invite timeout once grouped")
end)

T.test("T.PORTAL in PORTAL_OPEN without DONE -> back to PAID; the taxi re-arms the portal", function()
  local taxi = rideAt("taxi", "PORTAL_OPEN")
  T.eq(R.step(taxi, ev("TICK"), 189).state, "PORTAL_OPEN")
  local back, acts = R.step(taxi, ev("TICK"), 190)
  T.eq(back.state, "PAID")
  T.eq(names(acts), { "SEND:PAID", "SECURE:spell:" .. PORTAL_OG })
  local again = R.step(back, cast("self", "PORTAL", "SUCCEEDED", "p2"), 200)
  T.eq(again.state, "PORTAL_OPEN", "a second portal")
  local rider = rideAt("rider", "PORTAL_OPEN")
  local rback, racts = R.step(rider, ev("TICK"), 190)
  T.eq(rback.state, "PAID")
  T.eq(names(racts), {})
  T.eq(R.step(rider, ev("PEER_STATE", { state = "PAID" }), 150).state, "PAID", "the rider follows the revert")
  T.eq(R.step(rback, ev("ZONE", { zone = "Orgrimmar" }), 195).state, "DONE", "late arrival through the old portal")
end)

-- G2 review: a timeout (AFK rider, slow roster) shows the manual step for this ride only; it never
-- stores caps "manual" for good. Only a call the client refused does (BLOCKED, next test).
T.test("auto invite / accept without a group -> manual step for this ride, caps untouched", function()
  local ride = R.new(match("taxi"), 0)
  ride = R.step(ride, ev("INVITE_SENT"), 1)
  local early = R.step(ride, ev("TICK"), 15.9)
  T.eq(early.inviteManual, nil)
  local switched, acts = R.step(ride, ev("TICK"), 16)
  T.eq(names(acts), {}, "no CAPS on a timeout")
  T.eq(switched.inviteManual, true)

  local rider = R.new(match("rider"), 0)
  rider = R.step(rider, ev("ACCEPT_SENT"), 2)
  T.eq(R.step(rider, ev("TICK"), 6.9).acceptManual, nil)
  local late, racts = R.step(rider, ev("TICK"), 7)
  T.eq(names(racts), {})
  T.eq(late.acceptManual, true)
end)

T.test("ADDON_ACTION_BLOCKED for invite / accept -> caps manual once", function()
  local ride, acts = R.step(R.new(match("taxi"), 0), ev("BLOCKED", { what = "invite" }), 1)
  T.eq(names(acts), { "CAPS:invite" })
  T.eq(names(select(2, R.step(ride, ev("BLOCKED", { what = "invite" }), 2))), {})
  T.eq(names(select(2, R.step(ride, ev("BLOCKED", { what = "accept" }), 2))), { "CAPS:accept" })
  T.eq(names(select(2, R.step(ride, ev("BLOCKED", { what = "trade" }), 2))), {}, "trade caps belong to Trade")
end)

T.test("the rider accepts only the peer's invite", function()
  local ride, acts = R.step(R.new(match("rider"), 0), ev("INVITE", { from = "Stranger" }), 1)
  T.eq(names(acts), {})
  T.eq(ride.invited, nil)
  local taxi, tacts = R.step(R.new(match("taxi"), 0), ev("INVITE", { from = "Velvet" }), 1)
  T.eq(names(tacts), {}, "a taxi never accepts")
  T.eq(taxi.invited, nil)
  local grouped = rideAt("rider", "GROUPED")
  T.eq(names(select(2, R.step(grouped, ev("INVITE", { from = "Thalindra" }), 5))), {}, "not after grouping")
end)

T.test("scroll cast failed or interrupted -> back to GROUPED and re-armed; another attempt's failure is ignored", function()
  local ride = rideAt("taxi", "EN_ROUTE")
  local other = R.step(ride, cast("self", "SCROLL", "FAILED", "g2"), 103)
  T.eq(other.state, "EN_ROUTE", "a second click failing does not stop the running cast")
  for _, phase in ipairs({ "FAILED", "INTERRUPTED" }) do
    local back, acts = R.step(ride, cast("self", "SCROLL", phase, "g1"), 104)
    T.eq(back.state, "GROUPED", phase)
    T.eq(names(acts), { "SEND:GROUPED", "SECURE:item:party1" })
  end
  local rider = rideAt("rider", "EN_ROUTE")
  T.eq(R.step(rider, ev("PEER_STATE", { state = "GROUPED" }), 104).state, "GROUPED", "rider follows the revert")
  local fromTaxi = R.step(rideAt("rider", "GROUPED"), ev("PEER_STATE", { state = "EN_ROUTE" }), 104)
  T.eq(fromTaxi.state, "EN_ROUTE", "rider follows EN_ROUTE when it cannot see the cast")
  T.eq(R.step(fromTaxi, cast("peer", "SCROLL", "SUCCEEDED", "zz"), 114).state, "EN_ROUTE", "waits for the taxi")
  T.eq(R.step(fromTaxi, ev("PEER_STATE", { state = "ARRIVED" }), 114).state, "ARRIVED")
end)

-- In-game probe 2026-11-19: a scroll on a rider who is not resting still fires UNIT_SPELLCAST_SUCCEEDED, then the
-- UI error "Invalid target"; nothing moves and no scroll is used.
T.test("scroll SUCCEEDED then Invalid target -> back to GROUPED, re-armed, the rider follows; no trade", function()
  local ride = R.step(rideAt("taxi", "EN_ROUTE"), cast("self", "SCROLL", "SUCCEEDED", "g1"), 103)
  T.eq(ride.state, "EN_ROUTE")
  local back, acts = R.step(ride, ev("SCROLL_ERROR", { message = "Invalid target" }), 103.2)
  T.eq(back.state, "GROUPED")
  T.eq(back.scrollError, "Invalid target")
  T.eq(back.landing, nil)
  T.eq(names(acts), { "SEND:GROUPED", "SECURE:item:party1" }, "no TRADE_OPEN")
  T.eq(R.step(back, ev("LANDED"), 104).state, "GROUPED", "a late LANDED after the revert is ignored")
  T.ok(R.canCancel(back), "the taxi may cancel again")
  local again = R.step(R.step(back, cast("self", "SCROLL", "START", "g2"), 110), cast("self", "SCROLL", "SUCCEEDED", "g2"), 111)
  again = R.step(again, ev("LANDED"), 111.5)
  T.eq(again.state, "TRADING", "the next attempt works")
  T.eq(again.scrollError, nil)
end)

T.test("scroll SUCCEEDED without proof for T.LANDING -> back to GROUPED as unconfirmed", function()
  local ride = R.step(rideAt("taxi", "EN_ROUTE"), cast("self", "SCROLL", "SUCCEEDED", "g1"), 103)
  T.eq(R.step(ride, ev("TICK"), 103 + 11.9).state, "EN_ROUTE")
  local back, acts = R.step(ride, ev("TICK"), 103 + 12)
  T.eq(back.state, "GROUPED")
  T.eq(back.scrollError, "unconfirmed")
  T.eq(names(acts), { "SEND:GROUPED", "SECURE:item:party1" })
end)

T.test("SCROLL_ERROR and LANDED mean nothing outside a taxi's Come-to-you landing", function()
  local before = rideAt("taxi", "EN_ROUTE") -- cast started, not succeeded
  T.eq(R.step(before, ev("SCROLL_ERROR", { message = "x" }), 104).state, "EN_ROUTE", "an error before SUCCEEDED")
  T.eq(R.step(before, ev("LANDED"), 104).state, "EN_ROUTE", "proof before SUCCEEDED")
  local rider = R.step(rideAt("rider", "EN_ROUTE"), cast("peer", "SCROLL", "SUCCEEDED", "g1"), 103)
  T.eq(R.step(rider, ev("LANDED"), 104).state, "EN_ROUTE", "the rider waits for STATE")
  local pick = rideAt("taxi", "EN_ROUTE", "PICK")
  T.eq(R.step(pick, ev("SCROLL_ERROR", { message = "x" }), 104).state, "EN_ROUTE")
end)

T.test("taxi: the rider leaving the inn disarms the scroll, coming back arms it again", function()
  local ride = rideAt("taxi", "GROUPED")
  local off, acts = R.step(ride, ev("PEER_STATE", { state = "NOT_RESTING" }), 5)
  T.eq(off.riderResting, false)
  T.eq(names(acts), { "SECURE:nil" })
  local on, acts2 = R.step(off, ev("PEER_STATE", { state = "RESTING" }), 6)
  T.eq(names(acts2), { "SECURE:item:party1" })
  T.eq(on.riderResting, true)
  local rider = rideAt("rider", "GROUPED")
  local _, racts = R.step(rider, ev("RESTING", { resting = false }), 5)
  T.eq(names(racts), { "SEND:NOT_RESTING" })
  T.eq(names(select(2, R.step(rider, ev("RESTING", { resting = true }), 5))), {}, "no change, no message")
end)

-- G2 review: the taxi may walk away from a rider who does not pay (ARRIVED/TRADING) or does not come (PICK
-- EN_ROUTE); a pickup cancel is never late for the rider.
T.test("canCancel: rider COME late from the scroll until PAID; taxi free while waiting for the rider", function()
  local expect = {
    rider = { MATCHED = { true, false }, GROUPED = { true, false }, EN_ROUTE = { true, true }, ARRIVED = { true, true },
              TRADING = { true, true }, PAID = { true, false }, PORTAL_OPEN = { true, false } },
    taxi = { MATCHED = { true, false }, GROUPED = { true, false }, EN_ROUTE = { nil, "too_late" },
             TRADING = { true, false }, PAID = { nil, "too_late" }, PORTAL_OPEN = { nil, "too_late" } },
  }
  for role, states in pairs(expect) do
    for state, want in pairs(states) do
      T.eq({ R.canCancel(rideAt(role, state)) }, want, role .. " " .. state)
    end
  end
  local pick = function(role, state)
    local r = rideAt(role, state)
    r.svc = "PICK"
    return r
  end
  T.eq({ R.canCancel(pick("rider", "EN_ROUTE")) }, { true, false }, "a pickup cancel is never late")
  T.eq({ R.canCancel(pick("rider", "TRADING")) }, { true, false })
  T.eq({ R.canCancel(pick("taxi", "EN_ROUTE")) }, { true, false }, "the taxi stops waiting for a walker")
  local arrived = rideAt("taxi", "TRADING") -- the taxi passes ARRIVED in one step; check the state itself
  arrived.state = "ARRIVED"
  T.eq({ R.canCancel(arrived) }, { true, false })
  T.eq({ R.canCancel(nil) }, { nil, "no_ride" })
  local done = R.step(rideAt("taxi", "PORTAL_OPEN"), ev("PEER_STATE", { state = "DONE" }), 140)
  T.eq({ R.canCancel(done) }, { nil, "no_ride" })
end)

T.test("CANCEL: a late rider cancel is recorded; a free one is not; a late taxi cancel is ignored", function()
  local late, acts = R.step(rideAt("rider", "EN_ROUTE"), ev("CANCEL", { reason = "changed my mind" }), 105)
  T.eq(late.state, "CANCELLED")
  T.eq(late.late, true)
  T.eq(late.cancelledBy, "rider")
  T.eq(late.reason, "changed my mind")
  T.eq(names(acts), { "CANCEL_MSG:true", "RECORD_LATE", "SECURE:nil", "END" })
  local free, facts = R.step(rideAt("rider", "GROUPED"), ev("CANCEL"), 105)
  T.eq(free.late, false)
  T.eq(free.reason, "cancelled")
  T.eq(names(facts), { "CANCEL_MSG:false", "SECURE:nil", "END" })
  local paid, pacts = R.step(rideAt("rider", "PAID"), ev("CANCEL"), 125)
  T.eq(paid.late, false, "paid already")
  T.ok(not has(pacts, "RECORD_LATE"))
  local taxiFree, tacts = R.step(rideAt("taxi", "GROUPED"), ev("CANCEL"), 105)
  T.eq(taxiFree.state, "CANCELLED")
  T.eq(names(tacts), { "CANCEL_MSG:false", "SECURE:nil", "END" })
  local taxi = rideAt("taxi", "EN_ROUTE")
  local same, none = R.step(taxi, ev("CANCEL"), 105)
  T.eq(same.state, "EN_ROUTE")
  T.eq(names(none), {})
end)

T.test("PEER_CANCEL ends the ride in any active state with the peer's late flag; nothing is sent back", function()
  for _, state in ipairs({ "MATCHED", "GROUPED", "EN_ROUTE", "TRADING", "PAID" }) do
    local ride, acts = R.step(rideAt("taxi", state), ev("PEER_CANCEL", { by = "rider", late = true }), 150)
    T.eq(ride.state, "CANCELLED", state)
    T.eq(ride.late, true)
    T.eq(ride.reason, "peer_cancelled")
    T.eq(ride.cancelledBy, "rider")
    T.eq(names(acts), { "SECURE:nil", "END" }, state)
  end
end)

T.test("peer offline or out of the group -> FAILED; before grouping a missing peer is normal", function()
  local offline, acts = R.step(rideAt("rider", "EN_ROUTE"), ev("ROSTER", { unit = "party1", connected = false }), 110)
  T.eq(offline.state, "FAILED")
  T.eq(offline.reason, "peer_offline")
  T.eq(names(acts), { "SECURE:nil", "END" }, "no STATE to an offline peer")
  local left, lacts = R.step(rideAt("taxi", "TRADING"), ev("ROSTER"), 120)
  T.eq(left.state, "FAILED")
  T.eq(left.reason, "left_group")
  T.eq(names(lacts), { "SEND:FAILED", "SECURE:nil", "END" })
  local waiting = R.step(R.new(match("rider"), 0), ev("ROSTER"), 1)
  T.eq(waiting.state, "MATCHED")
  local followed, facts = R.step(rideAt("rider", "TRADING"), ev("PEER_STATE", { state = "FAILED" }), 120)
  T.eq(followed.reason, "peer_failed")
  T.eq(names(facts), { "SECURE:nil", "END" })
end)

T.test("followers ignore states the peer does not lead and backward moves", function()
  local rider = rideAt("rider", "TRADING")
  T.eq(R.step(rider, ev("PEER_STATE", { state = "DONE" }), 120).state, "TRADING", "the rider leads DONE")
  T.eq(R.step(rider, ev("PEER_STATE", { state = "EN_ROUTE" }), 120).state, "TRADING", "no backward move")
  T.eq(R.step(rider, ev("PEER_STATE", { state = "BOGUS" }), 120).state, "TRADING")
  local taxi = rideAt("taxi", "GROUPED")
  T.eq(R.step(taxi, ev("PEER_STATE", { state = "TRADING" }), 120).state, "GROUPED", "the taxi leads TRADING")
  T.eq(R.step(taxi, ev("PEER_STATE", { state = "RESTING" }), 120).riderResting, true)
end)

T.test("a finished ride ignores every event", function()
  local done = R.step(rideAt("taxi", "PORTAL_OPEN"), ev("PEER_STATE", { state = "DONE" }), 140)
  for _, e in ipairs({ ev("TICK"), ROSTER, ev("CANCEL"), ev("PEER_CANCEL", { late = true }), ev("PAID") }) do
    local same, acts = R.step(done, e, 999)
    T.ok(same == done)
    T.eq(acts, {})
  end
  T.eq(select(2, R.step(rideAt("taxi", "GROUPED"), ev("NOPE"), 1)), {})
end)

-- Glue on one fake client ----------------------------------------------------------------------------------

-- Fake Secure.set / Trade.open (card I) per playbook §2.
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

local function events(wow, name)
  local got = {}
  wow.ns.on(name, function(...) got[#got + 1] = { ... } end)
  return got
end

-- Decoded whispers this client sent to target.
local function whispers(wow, target)
  local out = {}
  for _, s in ipairs(wow.sent) do
    if s.kind == "WHISPER" and s.target == target then
      out[#out + 1] = wow.ns.Protocol.decode(s.msg)
    end
  end
  return out
end

local function lastWhisper(wow, target)
  local all = whispers(wow, target)
  return all[#all]
end

local function stateMsgs(wow, target)
  local out = {}
  for _, m in ipairs(whispers(wow, target)) do
    if m.type == "STATE" then out[#out + 1] = m.state end
  end
  return out
end

local function peerSays(wow, key, msg)
  msg.reqId = msg.reqId or "Velvet:1"
  wow.ns.fire("NET_MSG", msg, key, key .. " Forever", "WHISPER")
end

local function noErrors(wow)
  T.eq(wow.errors, {}, "no Lua errors")
end

T.test("glue: a second Ride.start while a ride is active is refused; a bad match too", function()
  local wow = client()
  fakes(wow)
  T.eq({ wow.ns.Ride.start({}) }, { nil, "match" })
  local started = events(wow, "RIDE_STARTED")
  local ride = wow.ns.Ride.start(match("taxi"))
  T.eq(ride.state, "MATCHED")
  T.eq(#started, 1)
  T.ok(wow.ns.Ride.current() == ride)
  T.eq({ wow.ns.Ride.start(match("taxi")) }, { nil, "busy" })
  T.eq(#started, 1)
  noErrors(wow)
end)

T.test("glue taxi COME to DONE: invite from a timer, armed scroll, trade, portal, lastRideAt, Secure cleared", function()
  local wow = client()
  local f = fakes(wow)
  local states = events(wow, "RIDE_STATE")
  wow.ns.Ride.start(match("taxi"))
  T.eq(#wow:callsTo("C_PartyInfo.InviteUnit"), 0, "not synchronously")
  wow:advance(0.5)
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args, { "Velvet Forever" })
  wow:joinParty("Velvet", { faction = "Horde" })
  T.eq(wow.ns.Ride.current().state, "GROUPED")
  T.eq(wow.ns.Ride.current().peerUnit, "party1")
  T.eq(f.current, nil)
  peerSays(wow, "Stranger", { type = "STATE", state = "RESTING" })
  peerSays(wow, "Velvet", { type = "STATE", state = "RESTING", reqId = "Velvet:9" })
  T.eq(f.current, nil, "STATE from another player or another ride is ignored")
  peerSays(wow, "Velvet", { type = "STATE", state = "RESTING" })
  T.eq(f.current.kind, "item")
  T.eq(wow.env.PortaxiNextButton:GetAttribute("unit"), "party1")

  wow:fire("UNIT_SPELLCAST_START", "player", "g1", 999)
  T.eq(wow.ns.Ride.current().state, "GROUPED", "another spell")
  wow:fire("UNIT_SPELLCAST_START", "player", "g1", SCROLL_SPELL)
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE")
  T.eq(f.current, nil)
  wow:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g1", SCROLL_SPELL)
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE", "no proof yet: the scroll count is unchanged")
  wow:setItem(SCROLL_ITEM, 8) -- the scroll was used: BAG_UPDATE_DELAYED
  T.eq(wow.ns.Ride.current().state, "TRADING")
  T.eq(f.trades, { "party1" })
  wow.ns.fire("TRADE_PAID", "Velvet:7", 30000)
  T.eq(wow.ns.Ride.current().state, "TRADING", "another ride's payment")
  wow.ns.fire("TRADE_PAID", "Velvet:1", 30000)
  T.eq(wow.ns.Ride.current().state, "PAID")
  T.eq(f.current.spell, PORTAL_OG)
  wow:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "p1", PORTAL_OG)
  T.eq(wow.ns.Ride.current().state, "PORTAL_OPEN")
  peerSays(wow, "Velvet", { type = "STATE", state = "DONE" })
  T.eq(wow.ns.Ride.current(), nil)
  T.eq(states[#states][1].state, "DONE")
  T.eq(wow.env.PortaxiCharDB.lastRideAt, wow.env.time())
  T.eq(f.current, nil)
  T.eq(f.specs[#f.specs], false, "Secure.set(nil) at the end")
  wow:advance(3)
  T.eq(stateMsgs(wow, "Velvet Forever"), { "EN_ROUTE", "ARRIVED", "TRADING", "PAID", "PORTAL_OPEN" })
  local seen = {}
  for _, s in ipairs(states) do
    if seen[#seen] ~= s[1].state then seen[#seen + 1] = s[1].state end
  end
  -- MATCHED shows up first since the taxi tracks its own resting (selfResting, G2 review).
  T.eq(seen, { "MATCHED", "GROUPED", "EN_ROUTE", "TRADING", "PAID", "PORTAL_OPEN", "DONE" })
  noErrors(wow)
end)

-- Forever has no realms: "Varekhal Stonefel" is first name + surname, and only the pair is unique.
-- Gate G2: InviteUnit("Varekhal Stonefel") worked, so the full name is always used.
T.test("glue: the peer is always invited by the full 'First Surname'", function()
  local wow = client()
  fakes(wow)
  local m = match("taxi")
  m.peer = { key = "Varekhal", raw = "Varekhal Stonefel" }
  wow.ns.Ride.start(m)
  wow:advance(1)
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args, { "Varekhal Stonefel" })
  wow.ns.Ride.cancel("test")
  wow:advance(1)
  wow.ns.Ride.start(match("taxi")) -- Velvet Forever: the same surname as the stub player changes nothing
  wow:advance(1)
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[2].args, { "Velvet Forever" })
  noErrors(wow)
end)

T.test("glue: a FORBIDDEN 'UNKNOWN()' during the invite is attributed to the invite", function()
  local wow = client()
  fakes(wow)
  wow.blocked["C_PartyInfo.InviteUnit"] = "forbidden"
  wow.ns.Ride.start(match("taxi"))
  wow:advance(1)
  T.eq(wow.env.PortaxiDB.caps.invite, "manual")
  T.eq(wow.ns.UI.RidePanel.view().manual.invite, true)
  noErrors(wow)
end)

T.test("glue: a blocked invite switches caps.invite to manual; Ride.manual('invite') invites", function()
  local wow = client()
  fakes(wow)
  local capsEv = events(wow, "CAPS_CHANGED")
  wow.blocked["C_PartyInfo.InviteUnit"] = true
  wow.ns.Ride.start(match("taxi"))
  wow:advance(1)
  T.eq(wow.env.PortaxiDB.caps.invite, "manual")
  T.eq(#capsEv, 1)
  T.eq(wow.ns.UI.RidePanel.view().manual.invite, true, "the panel offers Invite")
  T.ok(wow.env.PortaxiRidePanel and wow.ns.UI.RidePanel.frame.manual.invite:IsShown())
  T.eq({ wow.ns.Ride.manual("invite") }, { nil, "blocked" })
  wow.blocked["C_PartyInfo.InviteUnit"] = nil
  T.eq(wow.ns.Ride.manual("invite"), true)
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args, { "Velvet Forever" })
  T.eq({ wow.ns.Ride.manual("accept") }, { nil, "state" }, "a taxi does not accept")
  T.eq({ wow.ns.Ride.manual("dance") }, { nil, "what" })
  noErrors(wow)
end)

T.test("glue: with caps.invite manual there is no automatic invite; the panel click invites", function()
  local wow = client()
  fakes(wow)
  wow.env.PortaxiDB.caps.invite = "manual"
  wow.ns.Ride.start(match("taxi"))
  wow:advance(2)
  T.eq(#wow:callsTo("C_PartyInfo.InviteUnit"), 0)
  wow.ns.UI.RidePanel.frame.manual.invite:Click()
  T.eq(#wow:callsTo("C_PartyInfo.InviteUnit"), 1)
  noErrors(wow)
end)

T.test("glue: no group after the auto invite -> Invite button for this ride, then T.INVITE -> FAILED", function()
  local wow = client()
  fakes(wow)
  local states = events(wow, "RIDE_STATE")
  wow.ns.Ride.start(match("taxi"))
  wow:advance(15)
  T.eq(wow.ns.UI.RidePanel.view().manual.invite, false)
  wow:advance(1)
  T.eq(wow.ns.UI.RidePanel.view().manual.invite, true, "the panel offers Invite")
  T.eq(wow.env.PortaxiDB.caps.invite, nil, "a timeout is not remembered (G2 review)")
  wow:advance(44)
  T.eq(wow.ns.Ride.current(), nil)
  T.eq(states[#states][1].state, "FAILED")
  T.eq(states[#states][1].reason, "invite_timeout")
  wow:advance(1)
  T.eq(lastWhisper(wow, "Velvet Forever").state, "FAILED")
  noErrors(wow)
end)

T.test("glue rider: resting sent, invites from others ignored, the peer's accepted and the popup hidden", function()
  local wow = client(RIDER)
  fakes(wow)
  wow.ns.Ride.start(match("rider"))
  wow:inviteFrom("Stranger")
  T.eq(#wow:callsTo("AcceptGroup"), 0)
  T.eq(wow.pendingInviter, "Stranger", "the stranger's invite is left alone")
  wow:inviteFrom("Thalindra")
  T.eq(#wow:callsTo("AcceptGroup"), 1)
  T.eq(wow:callsTo("StaticPopup_Hide")[1].args, { "PARTY_INVITE" })
  T.eq(wow.ns.Ride.current().state, "GROUPED")
  wow:setResting(false)
  wow:advance(2)
  T.eq(stateMsgs(wow, "Thalindra Forever"), { "RESTING", "RESTING", "NOT_RESTING" })
  T.eq(wow.ns.UI.RidePanel.view().notes[1],
    "You are not resting: the scroll cannot reach you. Go back to an inn or a city.")
  noErrors(wow)
end)

T.test("glue rider: a blocked accept -> caps.accept manual, popup kept, Accept button works", function()
  local wow = client(RIDER)
  fakes(wow)
  wow.blocked.AcceptGroup = true
  wow.ns.Ride.start(match("rider"))
  T.eq(wow.ns.UI.RidePanel.view().manual.accept, false, "no Accept before an invite")
  wow:inviteFrom("Thalindra")
  T.eq(wow.env.PortaxiDB.caps.accept, "manual")
  T.eq(#wow:callsTo("StaticPopup_Hide"), 0)
  T.eq(wow.ns.UI.RidePanel.view().manual.accept, true)
  wow.blocked.AcceptGroup = nil
  wow.ns.UI.RidePanel.frame.manual.accept:Click()
  T.eq(wow.ns.Ride.current().state, "GROUPED")
  T.eq(wow.ns.UI.RidePanel.view().manual.accept, false)
  noErrors(wow)
end)

T.test("glue rider: an accept that silently does nothing -> Accept button for this ride after the wait", function()
  local wow = client(RIDER)
  fakes(wow)
  wow.hooks.accept = function() end -- the call goes through, no group forms
  wow.ns.Ride.start(match("rider"))
  wow:inviteFrom("Thalindra")
  wow:advance(4)
  T.eq(wow.ns.UI.RidePanel.view().manual.accept, false)
  wow:advance(2)
  T.eq(wow.ns.UI.RidePanel.view().manual.accept, true)
  T.eq(wow.env.PortaxiDB.caps.accept, nil, "a timeout is not remembered (G2 review)")
  noErrors(wow)
end)

T.test("G2 review: ARRIVED / TRADING without payment for T.TRADE -> FAILED trade_timeout on both sides", function()
  for _, role in ipairs({ "taxi", "rider" }) do
    local r = rideAt(role, "TRADING")
    T.eq(R.step(r, ev("TICK"), r.since + 179).state, "TRADING", role)
    local failed = R.step(r, ev("TICK"), r.since + 180)
    T.eq({ failed.state, failed.reason }, { "FAILED", "trade_timeout" }, role)
  end
end)

T.test("G2 review: the scroll is armed only while the taxi rests too", function()
  local ride = rideAt("taxi", "GROUPED")
  T.eq(ride.armedKey, "item:" .. SCROLL_ITEM .. ":party1")
  local away, acts = R.step(ride, ev("RESTING", { resting = false }), 5)
  T.eq(away.selfResting, false)
  T.eq(names(acts), { "SECURE:nil" }, "disarmed when the taxi leaves the inn")
  local back, acts2 = R.step(away, ev("RESTING", { resting = true }), 6)
  T.eq(names(acts2), { "SECURE:item:party1" })
  T.eq(back.selfResting, true)
end)

T.test("glue: peer offline -> FAILED peer_offline; leaving the group -> FAILED left_group", function()
  local wow = client(RIDER)
  fakes(wow)
  wow.ns.Ride.start(match("rider"))
  wow:joinParty("Thalindra")
  wow.units.party1.offline = true
  wow:fire("UNIT_CONNECTION", "party1", false)
  T.eq(wow.ns.Ride.current(), nil)
  T.eq(wow.ns.UI.RidePanel.view().status, "Ride failed: Thalindra went offline.")

  local taxi = client()
  fakes(taxi)
  taxi.ns.Ride.start(match("taxi"))
  taxi:joinParty("Velvet")
  local states = events(taxi, "RIDE_STATE")
  taxi.env.C_PartyInfo.LeaveParty()
  T.eq(states[1][1].state, "FAILED")
  T.eq(states[1][1].reason, "left_group")
  noErrors(wow)
  noErrors(taxi)
end)

T.test("glue PICK: proximity polled every second -> ARRIVED -> trade opened", function()
  local wow = client()
  local f = fakes(wow)
  wow.ns.Ride.start(match("taxi", "PICK"))
  wow:joinParty("Velvet")
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE")
  wow:advance(3)
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE")
  wow.units.party1.near = true
  wow:advance(1)
  T.eq(wow.ns.Ride.current().state, "TRADING")
  T.eq(f.trades, { "party1" })
  T.eq(wow.ns.Ride.manual("trade"), true)
  T.eq(#wow:callsTo("InitiateTrade"), 2)
  noErrors(wow)
end)

-- Taxi COME glue around the scroll's SUCCEEDED (in-game probe 2026-11-19).
local function landingTaxi()
  local wow = client()
  local f = fakes(wow)
  wow.ns.Ride.start(match("taxi"))
  wow:joinParty("Velvet", { faction = "Horde" })
  peerSays(wow, "Velvet", { type = "STATE", state = "RESTING" })
  wow:fire("UNIT_SPELLCAST_START", "player", "g1", SCROLL_SPELL)
  wow:advance(1)
  wow:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g1", SCROLL_SPELL)
  return wow, f
end

T.test("glue: Invalid target right after the scroll's SUCCEEDED -> GROUPED, scroll re-armed, no trade", function()
  local wow, f = landingTaxi()
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE")
  wow:fire("UI_ERROR_MESSAGE", 50, "Invalid target")
  local r = wow.ns.Ride.current()
  T.eq(r.state, "GROUPED")
  T.eq(r.scrollError, "Invalid target")
  T.eq(wow.ns.UI.RidePanel.view().notes[1], "The scroll failed (Invalid target): both of you must be resting. Try again.")
  T.eq(f.current and f.current.kind, "item", "the scroll is armed again")
  T.eq(f.trades, {})
  wow:advance(1) -- the whisper queue
  T.eq(stateMsgs(wow, "Velvet Forever"), { "EN_ROUTE", "GROUPED" })
  noErrors(wow)
end)

T.test("glue: a UI error long after SUCCEEDED is not the scroll's; proximity after 1 s proves the move", function()
  local wow, f = landingTaxi()
  wow.units.party1.near = true
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE", "near at once does not count: an error may still come")
  wow:advance(3)
  T.eq(wow.ns.Ride.current().state, "TRADING", "the tick saw the rider next to us")
  T.eq(f.trades, { "party1" })
  wow:fire("UI_ERROR_MESSAGE", 50, "Out of range")
  T.eq(wow.ns.Ride.current().state, "TRADING")
  noErrors(wow)
end)

T.test("glue: no proof within T.LANDING -> GROUPED unconfirmed", function()
  local wow = landingTaxi()
  wow:advance(13)
  T.eq(wow.ns.Ride.current().state, "GROUPED")
  T.eq(wow.ns.Ride.current().scrollError, "unconfirmed")
  noErrors(wow)
end)

T.test("glue cancel: late rider cancel recorded and sent; taxi refused after EN_ROUTE", function()
  local wow = client(RIDER)
  fakes(wow)
  wow.ns.Ride.start(match("rider"))
  wow:joinParty("Thalindra")
  T.eq(wow.ns.UI.RidePanel.view().cancel.text, "Cancel (free)")
  wow:fire("UNIT_SPELLCAST_START", "party1", "g1", SCROLL_SPELL)
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE")
  T.eq(wow.ns.UI.RidePanel.view().cancel.text, "Cancel (late)")
  local panel = wow.ns.UI.RidePanel.frame
  panel.cancel:Click()
  T.eq(wow.ns.Ride.current().state, "EN_ROUTE", "the first click asks to confirm")
  T.eq(panel.cancel:GetText(), "Confirm late cancel")
  panel.cancel:Click()
  T.eq(wow.ns.Ride.current(), nil)
  T.eq(wow.env.PortaxiCharDB.lateCancels, {
    { reqId = "Velvet:1", at = wow.env.time(), peer = "Thalindra", price = 30000 },
  })
  wow:advance(2)
  local msg = lastWhisper(wow, "Thalindra Forever")
  T.eq({ msg.type, msg.reqId, msg.by, msg.late }, { "CANCEL", "Velvet:1", "rider", true })
  T.eq({ wow.ns.Ride.cancel() }, { nil, "no_ride" })

  local taxi = client()
  fakes(taxi)
  taxi.ns.Ride.start(match("taxi"))
  taxi:joinParty("Velvet")
  taxi:fire("UNIT_SPELLCAST_START", "player", "g1", SCROLL_SPELL)
  T.eq({ taxi.ns.Ride.cancel() }, { nil, "too_late" })
  T.eq(taxi.ns.UI.RidePanel.view().cancel.shown, false)
  T.eq(taxi.ns.Ride.current().state, "EN_ROUTE")
  noErrors(wow)
  noErrors(taxi)
end)

-- RidePanel ------------------------------------------------------------------------------------------------

T.test("panel: shown on start, steps follow the state, secure label with key, hidden after the end", function()
  local wow = client()
  local f = fakes(wow)
  wow.env.PortaxiCharDB.nextKey = "F"
  wow.ns.Ride.start(match("taxi"))
  local frame = wow.env.PortaxiRidePanel
  T.ok(frame and frame:IsShown())
  local P = wow.ns.UI.RidePanel
  local v = P.view()
  T.eq(v.title, "Ride to Orgrimmar")
  T.eq(v.peer, "Velvet")
  T.eq(v.peerKey, "Rider")
  T.eq(v.service, "Come to you")
  T.eq(v.price, "3g")
  T.eq(v.steps[1].done, true)
  T.eq(v.steps[2].current, true)
  T.eq(v.steps[3].text, "Teleport to the rider")
  wow:joinParty("Velvet")
  peerSays(wow, "Velvet", { type = "STATE", state = "RESTING" })
  v = P.view()
  T.eq(v.steps[3].current, true)
  T.eq(v.secure, "Ready: Teleport to Velvet. Click the Portaxi button (key F).")
  T.eq(P.frame.secure:GetText(), v.secure)
  peerSays(wow, "Velvet", { type = "STATE", state = "NOT_RESTING" })
  T.eq(P.view().secure, "", "disarmed")
  T.eq(P.view().notes[1], "The rider is not resting: the scroll is off. You can cancel for free.")
  peerSays(wow, "Velvet", { type = "STATE", state = "RESTING" })

  -- cast bar while the scroll is cast
  wow.player.casting = { name = "Liminal Passage", startMs = wow.clock * 1000, endMs = (wow.clock + 10) * 1000,
                         spellId = SCROLL_SPELL }
  wow:fire("UNIT_SPELLCAST_START", "player", "g1", SCROLL_SPELL)
  wow:advance(5)
  P.updateCast()
  T.ok(P.frame.cast:IsShown())
  T.eq(P.frame.cast.progress, 0.5)
  P.frame:GetScript("OnUpdate")(P.frame, 0.1)
  wow.player.casting = nil
  wow:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g1", SCROLL_SPELL)
  wow:setItem(SCROLL_ITEM, 8) -- the scroll was used: proof of the move
  T.ok(not P.frame.cast:IsShown())
  T.eq(P.view().steps[4].current, true)

  wow.ns.fire("TRADE_MANUAL", "open")
  T.eq(P.view().manual.trade, true)
  T.ok(P.frame.manual.trade:IsShown())
  wow.ns.fire("TRADE_MANUAL", "short", 20000, 30000)
  T.eq(P.view().notes[#P.view().notes], "The rider offers 2g of 3g. Do not accept yet.")
  P.frame.manual.trade:Click()
  T.eq(#wow:callsTo("InitiateTrade"), 2, "Trade.open fake + the manual click")

  wow.ns.fire("TRADE_PAID", "Velvet:1", 30000)
  T.eq(P.view().secure, "Ready: Portal: Orgrimmar. Click the Portaxi button (key F).")
  T.eq(f.current.spell, PORTAL_OG)
  peerSays(wow, "Velvet", { type = "STATE", state = "DONE" })
  v = P.view()
  T.eq(v.over, true)
  T.eq(v.status, "Arrived. Have a good trip!")
  T.eq(v.steps[6].done, true)
  T.eq(v.secure, "")
  T.eq(v.cancel.shown, false)
  wow:advance(7.9)
  T.ok(frame:IsShown(), "stays a few seconds")
  wow:advance(0.2)
  T.ok(not frame:IsShown())
  noErrors(wow)
end)

T.test("panel: a new ride cancels the pending hide; position is saved on drag", function()
  local wow = client(RIDER)
  fakes(wow)
  wow.ns.Ride.start(match("rider"))
  wow.ns.Ride.cancel()
  wow:advance(5)
  local m = match("rider")
  m.reqId = "Velvet:2"
  T.ok(wow.ns.Ride.start(m))
  local frame = wow.env.PortaxiRidePanel
  T.eq(wow.ns.UI.RidePanel.view().status, "Forming the group")
  wow:advance(5)
  T.ok(frame:IsShown(), "the old hide timer is void")
  frame:GetScript("OnDragStop")(frame)
  T.eq(wow.env.PortaxiDB.ui.ridePanel, { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 })
  frame.close:Click()
  T.ok(not frame:IsShown())
  T.ok(wow.ns.Ride.current(), "closing the panel does not cancel")
  noErrors(wow)
end)

T.test("/ptx ride prints the ride and cancels", function()
  local wow = client()
  fakes(wow)
  wow:slash("ride")
  T.ok(wow.printed[#wow.printed]:find("no active ride", 1, true))
  wow.ns.Ride.start(match("taxi"))
  wow:slash("ride")
  T.ok(wow.printed[#wow.printed]:find("Velvet:1 · taxi COME to OG · MATCHED with Velvet", 1, true))
  wow:slash("ride cancel")
  T.eq(wow.ns.Ride.current(), nil)
  noErrors(wow)
end)

-- Inn hop (D20): svc HOP ------------------------------------------------------------------------------

local function hopMatch(role, extra)
  local m = { reqId = "Thalindra:h1", role = role, svc = "HOP", price = 0, dest = nil,
              peer = { key = role == "taxi" and "Velvet" or "Thalindra",
                       raw = role == "taxi" and "Velvet Forever" or "Thalindra Forever" }, eta = 1 }
  for k, v in pairs(extra or {}) do
    m[k] = v
  end
  return m
end

T.test("HOP: dest may be nil or a city; COME and PICK still need a city", function()
  T.ok(R.new(hopMatch("taxi"), 0))
  T.ok(R.new(hopMatch("taxi", { dest = "OG" }), 0))
  T.eq({ R.new(hopMatch("taxi", { dest = "XX" }), 0) }, { nil, "match" })
  local m = match("taxi")
  m.dest = nil
  T.eq({ R.new(m, 0) }, { nil, "match" })
end)

T.test("taxi HOP: scroll armed when both rest, cast, LANDED -> DONE led by the taxi; no trade, no LAST_RIDE", function()
  local ride, acts = R.new(hopMatch("taxi"), 0)
  T.eq(names(acts), { "INVITE" })
  ride = R.step(ride, ev("RESTING", { resting = true }), 1)
  ride, acts = R.step(ride, ROSTER, 2)
  T.eq(ride.state, "GROUPED")
  ride, acts = R.step(ride, ev("PEER_STATE", { state = "RESTING" }), 3)
  T.eq(names(acts), { "SECURE:item:party1" })
  ride, acts = R.step(ride, cast("self", "SCROLL", "START", "g1"), 4)
  T.eq(ride.state, "EN_ROUTE")
  ride, acts = R.step(ride, cast("self", "SCROLL", "SUCCEEDED", "g1"), 5)
  T.eq(ride.state, "EN_ROUTE")
  ride, acts = R.step(ride, ev("LANDED"), 5.2)
  T.eq(ride.state, "DONE")
  T.eq(names(acts), { "SEND:ARRIVED", "SEND:DONE", "SECURE:nil", "END" })
  T.ok(not has(acts, "TRADE_OPEN") and not has(acts, "LAST_RIDE"))
end)

T.test("taxi HOP: Invalid target goes back to GROUPED like Come-to-you", function()
  local ride = R.new(hopMatch("taxi"), 0)
  ride = run(ride, { { ev("RESTING", { resting = true }), 1 }, { ROSTER, 2 },
    { ev("PEER_STATE", { state = "RESTING" }), 3 }, { cast("self", "SCROLL", "START", "g1"), 4 },
    { cast("self", "SCROLL", "SUCCEEDED", "g1"), 5 } })
  local back = R.step(ride, ev("SCROLL_ERROR", { message = "Invalid target" }), 5.1)
  T.eq(back.state, "GROUPED")
end)

T.test("rider HOP (the host): accepts only the mage's invite, follows ARRIVED and DONE; a cancel is never late", function()
  local ride, acts = R.new(hopMatch("rider"), 0)
  T.eq(names(select(2, R.step(ride, ev("INVITE", { from = "Stranger" }), 1))), {})
  ride, acts = R.step(ride, ev("INVITE", { from = "Thalindra" }), 1)
  T.eq(names(acts), { "ACCEPT" })
  ride = R.step(R.step(ride, ev("RESTING", { resting = true }), 1), ROSTER, 2)
  ride = R.step(ride, cast("peer", "SCROLL", "START", "g1"), 3)
  T.eq(ride.state, "EN_ROUTE")
  local ok, late = R.canCancel(ride)
  T.eq({ ok, late }, { true, false }, "no scroll cost for the host")
  ride = R.step(ride, ev("PEER_STATE", { state = "ARRIVED" }), 4)
  T.eq(ride.state, "ARRIVED")
  ride, acts = R.step(ride, ev("PEER_STATE", { state = "DONE" }), 4.1)
  T.eq(ride.state, "DONE")
  T.eq(names(acts), { "SECURE:nil", "END" }, "the host sends nothing back")
end)

T.test("HOP with a host without Portaxi: counted as resting, scroll armed once grouped; glue sends no STATE", function()
  local ride = R.new(hopMatch("taxi", { peer = { key = "Velvet", raw = "Velvet Forever", noAddon = true } }), 0)
  T.eq(ride.riderResting, true)
  T.eq(ride.peer.noAddon, true)
  ride = R.step(ride, ev("RESTING", { resting = true }), 1)
  local _, acts = R.step(ride, ROSTER, 2)
  T.ok(has(acts, "SECURE:item:party1"), "armed without the host's STATE")

  local wow = client()
  wow.ns.Ride.start(hopMatch("taxi", { peer = { key = "Velvet", raw = "Velvet Forever", noAddon = true } }))
  wow:joinParty("Velvet", { faction = "Horde" })
  wow:advance(2)
  T.eq(wow.ns.Ride.current().state, "GROUPED")
  T.eq(#stateMsgs(wow, "Velvet Forever"), 0, "no addon message to a player without Portaxi")
  noErrors(wow)
end)

T.done()
