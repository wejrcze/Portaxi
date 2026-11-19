-- UI.DutyBox (card G, look by card J): visibility, content, emblem, Take / Off buttons, lock, position, /ptx box,
-- pulse.
-- One client with a fake Detect profile and the real Dispatch; Ride is the empty table of wave 2 unless
-- a test installs a fake. Other players' messages are injected with say().
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local function mage()
  return {
    faction = "Horde", race = "Orc", class = "MAGE", level = 40, resting = true,
    zone = "Orgrimmar", subzone = "", mapId = 1454, money = 455723,
    portals = { OG = true, UC = true }, runes = 7, scrolls = 9, shards = 0,
  }, { canDrive = true, COME = true, PICK = true, dests = { "OG", "UC" }, pauses = {} }
end

local function warrior()
  return {
    faction = "Horde", race = "Orc", class = "WARRIOR", level = 40, resting = false,
    zone = "Durotar", subzone = "", mapId = 1411, money = 455723,
    portals = {}, runes = 0, scrolls = 0, shards = 0,
  }, { canDrive = false, COME = false, PICK = false, dests = {}, pauses = { "NOT_MAGE" } }
end

local function client(saved)
  local wow = Wow.new()
  wow:load({ saved = saved })
  local state = {}
  state.profile, state.services = mage()
  wow.ns.Detect.current = function() return state.profile, state.services end
  wow:advance(2)
  return wow, wow.ns, state
end

local function say(wow, msg, from, via)
  wow:receive("PTX", assert(wow.ns.Protocol.encode(msg)), via or "CHANNEL", from .. " Forever")
end

local function hail(wow, from, dest, svcs)
  say(wow, { type = "HAIL", reqId = from .. ":1", fac = "Horde", dest = dest or "OG", svcs = svcs or { "COME", "PICK" },
    max = 40000, rest = true }, from)
end

local function noErrors(wow)
  T.eq(#wow.errors, 0, "errors: " .. tostring(wow.errors[1]))
end

local function box(wow)
  return wow.env.PortaxiDutyBox
end

T.test("the box shows only while on duty and able to drive", function()
  local wow, ns, state = client()
  local B = ns.UI.DutyBox
  T.eq(box(wow), nil, "built on first need")
  T.ok(not B.isShown())
  ns.Dispatch.setOnDuty(true)
  T.ok(box(wow) and box(wow):IsShown(), "on duty")
  state.profile, state.services = warrior()
  ns.fire("PROFILE_CHANGED", state.profile, state.services)
  T.ok(not box(wow):IsShown(), "cannot drive")
  state.profile, state.services = mage()
  ns.fire("PROFILE_CHANGED", state.profile, state.services)
  T.ok(box(wow):IsShown())
  ns.Dispatch.setOnDuty(false)
  T.ok(not box(wow):IsShown(), "off duty")
  noErrors(wow)
end)

T.test("a taxi that was on duty gets the box right after login", function()
  local wow = Wow.new()
  wow:load({ saved = { PortaxiCharDB = { onDuty = true } } })
  T.ok(box(wow) and box(wow):IsShown())
  noErrors(wow)
end)

T.test("content: services with prices, request count, the best request", function()
  local wow, ns = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  T.eq(B.titleText:GetText(), "On duty")
  T.eq(B.services:GetText(), "Come 3g · Pickup 1g 50s")
  T.eq(B.count:GetText(), "No open requests")
  T.ok(not B.take:IsShown() and not B.best:IsShown())
  T.ok(not B.emblem.icon:IsShown(), "no emblem without a request")
  hail(wow, "Velvet", "UC")
  wow:advance(5)
  hail(wow, "Kira", "OG", { "PICK" })
  T.eq(B.count:GetText(), "2 open requests")
  T.eq(B.best:GetText(), "Velvet Forever to Undercity\nCome-to-you · 3g · 5 s ago", "oldest first")
  T.eq(B.emblem.icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\emblem_UC", "destination emblem")
  T.ok(B.emblem.icon:IsShown())
  T.ok(B.take:IsShown() and B.take:IsEnabled())
  wow.env.PortaxiCharDB.prices.PICK = 22000
  ns.fire("PROFILE_CHANGED")
  T.eq(B.services:GetText(), "Come 3g · Pickup 2g 20s")
  noErrors(wow)
end)

T.test("content: the pause reason when nothing is offered", function()
  local wow, ns, state = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  state.services = { canDrive = true, COME = false, PICK = false, dests = { "OG" }, pauses = { "NO_RUNE", "NO_SCROLL" } }
  ns.fire("PROFILE_CHANGED", state.profile, state.services)
  T.eq(B.services:GetText(), "Paused: no Rune of Portals.")
  state.services = { canDrive = true, COME = false, PICK = true, dests = { "OG" }, pauses = { "NOT_RESTING" } }
  ns.fire("PROFILE_CHANGED", state.profile, state.services)
  T.eq(B.services:GetText(), "Pickup 1g 50s")
  noErrors(wow)
end)

T.test("Take sends a TAKE for the best request; Off ends the duty", function()
  local wow, ns = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  hail(wow, "Velvet")
  B.take:Click()
  T.eq(ns.Dispatch.status().pendingTake, "Velvet:1")
  T.eq(B.take:GetText(), "Sent")
  T.ok(not B.take:IsEnabled())
  wow:advance(1)
  local takes = 0
  for _, e in ipairs(wow.sent) do
    if e.msg:find("^TAKE|") then
      takes = takes + 1
      T.eq(e.target, "Velvet Forever")
    end
  end
  T.eq(takes, 1)
  B.off:Click()
  T.eq(wow.env.PortaxiCharDB.onDuty, false)
  T.ok(not box(wow):IsShown())
  noErrors(wow)
end)

T.test("clicking the title opens the window on Drive", function()
  local wow, ns = client()
  ns.Dispatch.setOnDuty(true)
  ns.UI.DutyBox.title:Click()
  T.ok(wow.env.PortaxiMainFrame:IsShown())
  T.eq(ns.UI.MainFrame.tab, "drive")
  noErrors(wow)
end)

T.test("dragging saves the position in PortaxiDB.ui.dutyBox; it is restored on the next login", function()
  local wow, ns = client()
  ns.Dispatch.setOnDuty(true)
  local f = box(wow)
  local moved = 0
  f.StartMoving = function() moved = moved + 1 end
  f.GetPoint = function() return "TOPLEFT", wow.env.UIParent, "TOPLEFT", 300.4, -120.6 end
  f:GetScript("OnDragStart")(f)
  f:GetScript("OnDragStop")(f)
  T.eq(moved, 1)
  local db = wow.env.PortaxiDB.ui.dutyBox
  T.eq({ db.point, db.relPoint, db.x, db.y }, { "TOPLEFT", "TOPLEFT", 300, -121 })

  local points = {}
  local wow2 = Wow.new()
  local create = wow2.env.CreateFrame
  wow2.env.CreateFrame = function(kind, name, parent, template)
    local frame = create(kind, name, parent, template)
    if name == "PortaxiDutyBox" then
      frame.SetPoint = function(_, ...) points[#points + 1] = { ... } end
    end
    return frame
  end
  wow2:load({ saved = { PortaxiCharDB = { onDuty = true },
    PortaxiDB = { ui = { dutyBox = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 300, y = -121 } } } } })
  T.eq(points[1][1], "TOPLEFT")
  T.eq(points[1][4], 300)
  T.eq(points[1][5], -121)
  noErrors(wow)
  noErrors(wow2)
end)

T.test("/ptx box toggles the lock; a locked box does not move", function()
  local wow, ns = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  T.ok(ns.commands.box and ns.commands.box.help)
  wow:slash("box")
  T.eq(wow.env.PortaxiDB.ui.dutyBox.locked, true)
  T.eq(B.titleText:GetText(), "On duty (locked)")
  local f = box(wow)
  local moved = 0
  f.StartMoving = function() moved = moved + 1 end
  f:GetScript("OnDragStart")(f)
  T.eq(moved, 0, "locked")
  wow:slash("box")
  T.eq(wow.env.PortaxiDB.ui.dutyBox.locked, false)
  f:GetScript("OnDragStart")(f)
  T.eq(moved, 1)
  noErrors(wow)
end)

T.test("the x hides the box until /ptx box shows it again", function()
  local wow, ns = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  B.hide:Click()
  T.ok(not box(wow):IsShown())
  T.eq(wow.env.PortaxiDB.ui.dutyBox.hidden, true)
  hail(wow, "Velvet")
  T.ok(not box(wow):IsShown(), "stays hidden on new requests")
  wow:slash("box")
  T.ok(box(wow):IsShown())
  T.eq(wow.env.PortaxiDB.ui.dutyBox.locked, nil, "showing again does not lock")
  ns.Dispatch.setOnDuty(false)
  wow:slash("box")
  T.ok(wow.printed[#wow.printed]:find("on duty", 1, true), "tells why nothing shows")
  noErrors(wow)
end)

T.test("the box pulses on INCOMING_REQUEST next to the raid warning", function()
  local wow, ns = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  local f = box(wow)
  T.eq(f:GetScript("OnUpdate"), nil)
  hail(wow, "Velvet")
  T.eq(B.pulses, 1)
  T.eq(#wow.raidWarnings, 1)
  local onUpdate = T.ok(f:GetScript("OnUpdate"), "pulsing")
  for _ = 1, 10 do
    onUpdate(f, 0.25)
  end
  T.eq(f:GetScript("OnUpdate"), nil, "pulse ends after 2 s")
  T.eq(B.pulsing, false)
  noErrors(wow)
end)

T.test("no errors without Ride; with a fake ride the box says so and Take is off", function()
  local wow, ns = client()
  local B = ns.UI.DutyBox
  ns.Dispatch.setOnDuty(true)
  hail(wow, "Velvet")
  T.ok(B.take:IsEnabled())
  -- A ride with the full §2 shape: the real RidePanel listens to RIDE_STARTED too.
  local ride = { reqId = "Velvet:1", role = "taxi", svc = "COME", price = 30000, dest = "OG",
    peer = { key = "Velvet", raw = "Velvet Forever" }, state = "MATCHED" }
  ns.Ride.current = function() return ride end
  ns.fire("RIDE_STARTED", ride)
  T.eq(B.services:GetText(), "On a ride")
  T.ok(not B.take:IsEnabled())
  ride.state = "DONE"
  ns.Ride.current = function() return nil end
  ns.fire("RIDE_STATE", ride)
  T.eq(B.services:GetText(), "Come 3g · Pickup 1g 50s")
  noErrors(wow)
end)

T.done()
