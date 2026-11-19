-- UI skeleton (card F): main window, tabs, Ride and Drive pages, minimap button. Wave 2 (card G): the real
-- Dispatch behind the pages. Wave 3 (card J): emblems and their fallback, pills, online count, ride panel texts.
-- Detect and Dispatch are faked per test, following playbook §2.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local function mage()
  return {
    faction = "Horde", race = "Orc", class = "MAGE", level = 40, resting = true,
    zone = "Orgrimmar", subzone = "Valley of Strength", mapId = 1454, money = 455723,
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

local function both(fn)
  local p, s = fn()
  return { p, s }
end

-- A loaded client with a fake Detect.current returning state.profile/state.services (nil = no data)
-- and no Dispatch functions. opts.saved preloads SavedVariables; opts.setup(wow) runs before load.
local function client(profile, services, opts)
  opts = opts or {}
  if type(profile) == "table" and profile[1] then -- client(both(mage), nil, opts)
    profile, services = profile[1], profile[2]
  end
  local wow = Wow.new()
  wow.env.UISpecialFrames = {}
  if opts.setup then
    opts.setup(wow)
  end
  wow:load({ saved = opts.saved })
  local state = { profile = profile, services = services }
  wow.ns.Detect.current = function() return state.profile, state.services end
  wow.ns.Dispatch.hail = nil
  wow.ns.Dispatch.setOnDuty = nil
  return wow, wow.ns, state
end

local function changed(ns, state)
  ns.fire("PROFILE_CHANGED", state.profile, state.services)
end

local function noErrors(wow)
  T.eq(#wow.errors, 0, "errors: " .. tostring(wow.errors[1]))
end

-- Main window ---------------------------------------------------------------------------------

T.test("/ptx show opens and closes PortaxiMainFrame and registers it for Esc once", function()
  local wow, ns = client(mage())
  T.eq(wow.env.PortaxiMainFrame, nil, "built lazily")
  T.eq(ns.commands.show.help, "open or close the Portaxi window")
  wow:slash("show")
  local frame = T.ok(wow.env.PortaxiMainFrame, "frame exists")
  T.ok(frame:IsShown(), "opened")
  T.eq(wow.env.UISpecialFrames, { "PortaxiMainFrame" })
  wow:slash("show")
  T.ok(not frame:IsShown(), "closed")
  ns.UI.toggle()
  T.ok(frame:IsShown(), "toggle opens again")
  ns.UI.hide()
  T.ok(not frame:IsShown(), "hide")
  ns.UI.show()
  T.eq(#wow.env.UISpecialFrames, 1, "no duplicate Esc entry")
  noErrors(wow)
end)

T.test("window works without UISpecialFrames", function()
  local wow = Wow.new():load()
  wow:slash("show")
  T.ok(wow.env.PortaxiMainFrame:IsShown())
  noErrors(wow)
end)

T.test("position is saved after a drag stop and restored on the next build", function()
  local wow, ns = client(mage())
  ns.UI.show()
  local frame = wow.env.PortaxiMainFrame
  frame.GetPoint = function() return "TOPLEFT", wow.env.UIParent, "TOPLEFT", 100.4, -50.6 end
  frame:GetScript("OnDragStop")(frame)
  T.eq(wow.env.PortaxiDB.ui.pos, { point = "TOPLEFT", relPoint = "TOPLEFT", x = 100, y = -51 })

  local points = {}
  local wow2 = client(both(mage), nil, {
    saved = { PortaxiDB = { ui = { pos = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 100, y = -51 } } } },
    setup = function(w)
      local create = w.env.CreateFrame
      w.env.CreateFrame = function(kind, name, parent, template)
        local f = create(kind, name, parent, template)
        if name == "PortaxiMainFrame" then
          f.SetPoint = function(_, ...) points[#points + 1] = { ... } end
        end
        return f
      end
    end,
  })
  wow2:slash("show")
  T.eq(points[1][1], "TOPLEFT")
  T.eq(points[1][3], "TOPLEFT")
  T.eq(points[1][4], 100)
  T.eq(points[1][5], -51)
end)

T.test("a mage gets Ride and Drive; switching tabs shows the right page", function()
  local wow, ns = client(mage())
  ns.UI.show()
  local M = ns.UI.MainFrame
  T.ok(M.tabButtons.ride:IsShown() and M.tabButtons.drive:IsShown(), "both tabs")
  T.ok(M.pages.ride:IsShown() and not M.pages.drive:IsShown(), "ride first")
  M.tabButtons.drive:Click()
  T.ok(M.pages.drive:IsShown() and not M.pages.ride:IsShown(), "drive page")
  T.ok(M.subtitle:GetText():find("Taxi", 1, true), "subtitle says taxi")
  ns.UI.show("ride")
  T.ok(M.pages.ride:IsShown() and not M.pages.drive:IsShown(), "show('ride')")
  ns.UI.hide()
  ns.UI.show()
  T.ok(M.pages.ride:IsShown(), "remembers the last tab")
  noErrors(wow)
end)

T.test("a warrior gets only Ride, also when Drive is asked for", function()
  local wow, ns = client(warrior())
  ns.UI.show("drive")
  local M = ns.UI.MainFrame
  T.ok(not M.tabButtons.drive:IsShown(), "no drive tab")
  T.ok(M.pages.ride:IsShown() and not M.pages.drive:IsShown(), "ride page")
  T.ok(ns.UI.RideTab.ui.riderNote:IsShown(), "rider note")
  T.ok(M.subtitle:GetText():find("Rider", 1, true), "subtitle says rider")
  noErrors(wow)
end)

T.test("the Drive tab goes away when the profile loses canDrive", function()
  local wow, ns, state = client(mage())
  ns.UI.show("drive")
  state.profile, state.services = warrior()
  changed(ns, state)
  local M = ns.UI.MainFrame
  T.eq(M.tab, "ride")
  T.ok(not M.tabButtons.drive:IsShown() and not M.pages.drive:IsShown())
  T.ok(M.pages.ride:IsShown())
  noErrors(wow)
end)

T.test("without Detect the window opens in an empty state and nothing fails", function()
  local wow, ns = client(nil, nil)
  ns.Detect.current = nil
  ns.UI.show("drive")
  local M, ui = ns.UI.MainFrame, ns.UI.RideTab.ui
  T.ok(M.frame:IsShown())
  T.ok(M.pages.ride:IsShown() and not M.tabButtons.drive:IsShown(), "only ride")
  T.ok(ui.readoutEmpty:IsShown() and not ui.resting:IsShown(), "readout empty")
  T.ok(ui.tilesEmpty:IsShown(), "no tiles message")
  for _, tile in ipairs(ui.tiles) do
    T.ok(not tile:IsShown(), "tile hidden")
  end
  T.ok(not ui.hail:IsEnabled(), "hail disabled")
  ui.hail:Click()
  ns.fire("PROFILE_CHANGED")
  T.eq(ns.UI.Minimap.statusLine(), "Waiting for character data")
  ns.UI.Minimap.button:GetScript("OnEnter")(ns.UI.Minimap.button)
  -- Detect.current exists but has no data yet.
  ns.Detect.current = function() return nil end
  ns.UI.MainFrame.refresh()
  T.ok(ui.readoutEmpty:IsShown())
  noErrors(wow)
end)

-- Ride page -------------------------------------------------------------------------------------

T.test("Ride shows what the addon read and refreshes on PROFILE_CHANGED", function()
  local wow, ns, state = client(mage())
  ns.UI.show()
  local ui = ns.UI.RideTab.ui
  T.ok(not ui.readoutEmpty:IsShown())
  T.eq(ui.name:GetText(), "Thalindra")
  T.eq(ui.faction:GetText(), "Horde")
  T.eq(ui.character:GetText(), "Orc Mage 40")
  T.eq(ui.place:GetText(), "Valley of Strength, Orgrimmar")
  T.eq(ui.resting:GetText(), "Resting")
  T.eq(ui.gold:GetText(), "45g 57s in bags")
  for _, pill in ipairs(ui.pills) do
    T.ok(pill:IsShown(), "pill shown")
  end
  state.profile.resting = false
  state.profile.subzone = ""
  changed(ns, state)
  T.eq(ui.resting:GetText(), "Not resting")
  T.eq(ui.place:GetText(), "Orgrimmar")
  noErrors(wow)
end)

T.test("pills wrap onto a second row when they do not fit the page width", function()
  local wow, ns = client(mage())
  ns.UI.show()
  local W, ui = ns.UI.Widgets, ns.UI.RideTab.ui
  local page = ns.UI.MainFrame.pages.ride
  local points = {}
  for i, pill in ipairs(ui.pills) do
    pill:SetWidth(100)
    pill.SetPoint = function(_, ...) points[i] = { ... } end
  end
  T.eq(W.flow(ui.pills, page, 0, -20, 352), 2, "4 x 100 px do not fit 352 px")
  T.eq({ points[1][4], points[1][5] }, { 0, -20 })
  T.eq({ points[3][4], points[3][5] }, { 208, -20 })
  T.eq({ points[4][4], points[4][5] }, { 0, -42 }, "the fourth pill wraps")
  noErrors(wow)
end)

T.test("city tiles show the own faction's three cities; selecting one greys the others", function()
  local wow, ns, state = client(mage())
  ns.UI.show()
  local tiles = ns.UI.RideTab.ui.tiles
  local function keys()
    return { tiles[1].cityKey, tiles[2].cityKey, tiles[3].cityKey }
  end
  T.eq(keys(), { "OG", "UC", "TB" })
  T.eq(tiles[1].icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\emblem_OG", "city emblem (wave 3)")
  T.eq(tiles[1].name:GetText(), "ORGRIMMAR")
  for _, tile in ipairs(tiles) do
    T.ok(tile.icon:IsDesaturated(), "grey before a choice")
  end
  tiles[2]:Click()
  T.eq(ns.UI.RideTab.dest, "UC")
  T.ok(not tiles[2].icon:IsDesaturated() and tiles[1].icon:IsDesaturated() and tiles[3].icon:IsDesaturated())
  tiles[1]:Click()
  T.ok(not tiles[1].icon:IsDesaturated() and tiles[2].icon:IsDesaturated())
  state.profile.faction = "Alliance"
  changed(ns, state)
  T.eq(keys(), { "SW", "IF", "DN" })
  T.eq(ns.UI.RideTab.dest, nil, "a city of the other faction is dropped")
  noErrors(wow)
end)

T.test("the hail stepper clamps to Const.PRICE and moves in 10s steps", function()
  local wow, ns = client(mage())
  ns.UI.show()
  local W, R = ns.UI.Widgets, ns.UI.RideTab
  local s = R.ui.max
  local P = ns.Const.PRICE
  T.eq(s.value, 30000)
  s.plus:Click()
  T.eq(R.max, 31000)
  s.minus:Click()
  s.minus:Click()
  T.eq(R.max, 29000)
  T.eq(s.text:GetText(), "2g 90s")
  T.eq(W.setStepper(s, 10 ^ 9), P.MAX)
  T.ok(not s.plus:IsEnabled(), "plus disabled at max")
  s.plus:Click()
  T.eq(s.value, P.MAX)
  T.eq(W.setStepper(s, 0), P.MIN)
  T.ok(not s.minus:IsEnabled(), "minus disabled at min")
  s.minus:Click()
  T.eq(s.value, P.MIN)
  wow.env.IsShiftKeyDown = function() return true end
  s.plus:Click()
  T.eq(s.value, P.MIN + 10000, "shift = 10 steps")
  noErrors(wow)
end)

T.test("Hail needs Dispatch.hail, a destination and enough gold", function()
  local wow, ns, state = client(mage())
  state.profile.zone = "Durotar" -- not in Orgrimmar, so hailing there is allowed (G2 review: "here")
  ns.UI.show()
  local R = ns.UI.RideTab
  local ui = R.ui
  ui.tiles[1]:Click()
  T.ok(not ui.hail:IsEnabled(), "disabled without Dispatch.hail")
  T.eq(ui.hint:GetText(), "Network not ready yet.")
  local hails = {}
  ns.Dispatch.hail = function(dest, max) hails[#hails + 1] = { dest, max } end
  changed(ns, state)
  T.ok(ui.hail:IsEnabled(), "enabled with a fake")
  T.eq(ui.hail:GetText(), "Hail a taxi to Orgrimmar")
  T.ok(not ui.warning:IsShown(), "no warning")
  ui.hail:Click()
  T.eq(hails, { { "OG", 30000 } })
  -- More than the player carries.
  wow.player.money = 20000
  changed(ns, state)
  T.ok(ui.warning:IsShown(), "warning above GetMoney()")
  T.ok(ui.warning:GetText():find("2g", 1, true), "warning names the gold carried")
  T.ok(not ui.hail:IsEnabled(), "disabled when poor")
  ui.hail:Click()
  T.eq(#hails, 1, "no hail when poor")
  noErrors(wow)
end)

-- Drive page ------------------------------------------------------------------------------------

T.test("Drive shows the detection block with pauses in words", function()
  local profile, services = mage()
  profile.scrolls = 0
  services.COME = false
  services.pauses = { "NO_SCROLL" }
  local wow, ns = client(profile, services)
  ns.UI.show("drive")
  local ui = ns.UI.DriveTab.ui
  T.eq(ui.portals[1].key:GetText(), "Portal: Orgrimmar")
  T.eq(ui.portals[1]:GetText(), "known")
  T.eq(ui.portals[3].key:GetText(), "Portal: Thunder Bluff")
  T.eq(ui.portals[3]:GetText(), "not learned")
  T.eq(ui.runes:GetText(), "7")
  T.eq(ui.scrolls:GetText(), "none")
  T.eq(ui.resting:GetText(), "yes")
  T.eq(ui.offering:GetText(), "Pickup")
  T.eq(ui.pauses:GetText(), "Come-to-you paused: no Scroll of Liminal Passage.")
  T.eq(ui.priceState.COME:GetText(), "paused right now")
  T.eq(ui.priceState.PICK:GetText(), "active")
  T.ok(ui.requestsEmpty:IsShown())
  T.eq(ui.requestsEmpty:GetText(), "No requests yet")
  noErrors(wow)
end)

T.test("the duty toggle writes PortaxiCharDB.onDuty and calls Dispatch.setOnDuty", function()
  local wow, ns = client(mage())
  ns.UI.show("drive")
  local ui = ns.UI.DriveTab.ui
  T.eq(ui.duty:GetText(), "Go on duty")
  ui.duty:Click() -- no Dispatch yet
  T.eq(wow.env.PortaxiCharDB.onDuty, true)
  T.eq(ui.duty:GetText(), "Go off duty")
  T.eq(ui.dutyText:GetText(), "On duty in the Horde network")
  local calls = {}
  ns.Dispatch.setOnDuty = function(on) calls[#calls + 1] = on end
  ui.duty:Click()
  ui.duty:Click()
  T.eq(calls, { false, true })
  T.eq(wow.env.PortaxiCharDB.onDuty, true)
  noErrors(wow)
end)

T.test("price steppers write PortaxiCharDB.prices within Const.PRICE", function()
  local wow, ns = client(both(mage), nil, { saved = { PortaxiCharDB = { prices = { COME = 999999, PICK = 15000 } } } })
  ns.UI.show("drive")
  local D, W = ns.UI.DriveTab, ns.UI.Widgets
  local prices = wow.env.PortaxiCharDB.prices
  T.eq(prices.COME, 500000, "saved price clamped on display")
  D.ui.prices.PICK.plus:Click()
  T.eq(prices.PICK, 16000)
  W.setStepper(D.ui.prices.PICK, 1000)
  D.ui.prices.PICK.minus:Click()
  T.eq(prices.PICK, 16000, "no change at the bound")
  D.setPrice("PICK", 10)
  T.eq(prices.PICK, 1000)
  D.setPrice("PICK", 10 ^ 7)
  T.eq(prices.PICK, 500000)
  noErrors(wow)
end)

-- Minimap button ------------------------------------------------------------------------------

T.test("minimap button: created on READY, click toggles the window", function()
  local wow, ns = client(mage())
  local b = T.ok(ns.UI.Minimap.button, "button exists after READY")
  b:Click()
  T.ok(wow.env.PortaxiMainFrame:IsShown(), "opened")
  b:Click()
  T.ok(not wow.env.PortaxiMainFrame:IsShown(), "closed")
  noErrors(wow)
end)

T.test("minimap button: dragging changes and saves the angle", function()
  local wow, ns = client(both(mage), nil, { saved = { PortaxiDB = { ui = { minimap = { angle = 45 } } } } })
  local MM = ns.UI.Minimap
  T.eq(MM.angle(), 45)
  local b = MM.button
  wow.env.GetCursorPosition = function() return 100, 0 end
  b:GetScript("OnDragStart")(b)
  b:GetScript("OnUpdate")(b, 0.02)
  T.eq(MM.dragAngle, 0)
  wow.env.GetCursorPosition = function() return 0, 100 end
  b:GetScript("OnDragStop")(b)
  T.eq(wow.env.PortaxiDB.ui.minimap.angle, 90)
  T.eq(b:GetScript("OnUpdate"), nil, "drag updates stop")
  noErrors(wow)
end)

T.test("minimap tooltip status line follows the role", function()
  local wow, ns, state = client(mage())
  T.eq(ns.UI.Minimap.statusLine(), "You: taxi, off duty (Orc Mage 40)")
  wow.env.PortaxiCharDB.onDuty = true
  T.eq(ns.UI.Minimap.statusLine(), "You: taxi, on duty (Orc Mage 40)")
  state.profile, state.services = warrior()
  T.eq(ns.UI.Minimap.statusLine(), "You: rider (Orc Warrior 40)")
  local b = ns.UI.Minimap.button
  b:GetScript("OnEnter")(b)
  b:GetScript("OnLeave")(b)
  noErrors(wow)
end)

-- Wave 2 (card G): the real Dispatch behind the Ride and Drive pages, alerts ------------------------

-- A loaded client with a fake Detect profile and the real Dispatch; the channel is joined.
-- The player is "Thalindra" (wowstub default); other players' messages are injected with say().
local function realClient(profile, services)
  local wow = Wow.new()
  wow:load()
  local state = { profile = profile, services = services }
  wow.ns.Detect.current = function() return state.profile, state.services end
  wow:advance(2)
  return wow, wow.ns, state
end

local function say(wow, msg, from, via)
  wow:receive("PTX", assert(wow.ns.Protocol.encode(msg)), via or "CHANNEL", from .. " Forever")
end

local function sentOf(wow, msgType)
  local out = {}
  for _, e in ipairs(wow.sent) do
    local m = wow.ns.Protocol.decode(e.msg)
    if m and m.type == msgType then
      m.target = e.target
      out[#out + 1] = m
    end
  end
  return out
end

local function hello(fac, dests, ask, place)
  return { type = "HELLO", fac = fac, cls = "MAGE", lvl = 40, place = place or "Orgrimmar",
    dests = dests, ask = ask, resp = 20, wait = 100 }
end

T.test("Ride tiles show the cheapest offer and the number of taxis of the own faction", function()
  local wow, ns = realClient(warrior())
  ns.UI.show("ride")
  local tiles = ns.UI.RideTab.ui.tiles
  T.eq(tiles[1].sub:GetText(), "no taxis")
  say(wow, hello("Horde", { "OG" }, { COME = 30000, PICK = 20000 }), "Aaron")
  say(wow, hello("Horde", { "OG", "UC" }, { PICK = 15000 }), "Bert")
  say(wow, hello("Alliance", { "SW" }, { PICK = 1000 }), "Ally")
  T.eq(tiles[1].sub:GetText(), "from 1g 50s · 2 taxis", "redrawn on MARKET_CHANGED")
  T.eq(tiles[2].sub:GetText(), "from 1g 50s · 1 taxi")
  T.eq(tiles[3].sub:GetText(), "no taxis")
  noErrors(wow)
end)

T.test("Browse lists the offers for the city with Book buttons, grey when not affordable", function()
  local profile, services = warrior()
  profile.resting = false
  local wow, ns = realClient(profile, services)
  ns.UI.show("ride")
  local R = ns.UI.RideTab
  local ui = R.ui
  ui.modes.browse:Click()
  T.eq(R.mode, "browse")
  T.ok(ui.browseBlock:IsShown() and not ui.hailBlock:IsShown())
  T.eq(ui.browseEmpty:GetText(), "Choose a destination.")
  ui.tiles[1]:Click()
  T.eq(ui.browseEmpty:GetText(), "No taxi offers Orgrimmar right now.")
  say(wow, hello("Horde", { "OG" }, { COME = 30000, PICK = 20000 }, "Undercity"), "Aaron")
  say(wow, hello("Horde", { "OG" }, { PICK = 500000 }), "Bert")
  T.ok(not ui.browseEmpty:IsShown())
  local rows = ui.rows
  T.eq(rows[1].who:GetText(), "Aaron Forever · Pickup")
  T.eq(rows[1].place:GetText(), "Undercity")
  T.eq(rows[1].price:GetText(), "2g")
  T.ok(rows[1].book:IsEnabled())
  T.eq(rows[2].who:GetText(), "Aaron Forever · Come-to-you")
  T.ok(not rows[2].book:IsEnabled(), "Come-to-you needs resting")
  T.eq(rows[3].price:GetText(), "50g")
  T.ok(not rows[3].book:IsEnabled(), "more than the player carries")
  T.eq(rows[3].book:GetText(), "Too dear")
  T.ok(not rows[4]:IsShown())
  rows[1].book:Click()
  wow:advance(1)
  local book = sentOf(wow, "BOOK")
  T.eq(#book, 1)
  T.eq({ book[1].target, book[1].svc, book[1].price, book[1].dest }, { "Aaron Forever", "PICK", 20000, "OG" })
  T.eq(ui.status:GetText(), "Waiting for Aaron Forever to accept...")
  T.ok(ui.cancel:IsShown())
  T.ok(not rows[1].book:IsEnabled(), "one booking at a time")
  ui.cancel:Click()
  wow:advance(1)
  T.eq(#sentOf(wow, "GONE"), 1)
  T.eq(ui.status:GetText(), "Request cancelled.")
  T.ok(not ui.cancel:IsShown())
  ui.modes.hail:Click()
  T.ok(ui.hailBlock:IsShown() and not ui.browseBlock:IsShown())
  noErrors(wow)
end)

T.test("the Hail button shows its status: searching, answers, matched, no taxi", function()
  local wow, ns = realClient(warrior())
  ns.UI.show("ride")
  local ui = ns.UI.RideTab.ui
  ui.tiles[1]:Click()
  ui.hail:Click()
  wow:advance(1)
  local reqId = sentOf(wow, "HAIL")[1].reqId
  T.eq(ui.status:GetText(), "Searching for a taxi to Orgrimmar...")
  T.ok(ui.cancel:IsShown(), "Cancel while the hail is open")
  T.ok(not ui.hail:IsEnabled(), "one hail at a time")
  T.eq(ui.hint:GetText(), "Your request is open.")
  say(wow, { type = "TAKE", reqId = reqId, svc = "PICK", price = 25000, eta = 40, wait = 10 }, "Aaron", "WHISPER")
  T.eq(ui.status:GetText(), "Searching for a taxi to Orgrimmar... 1 answered")
  wow:advance(3)
  T.eq(ui.status:GetText(), "Matched with Aaron Forever, here in about 40 s.")
  T.ok(not ui.cancel:IsShown())
  -- With the real Ride merged the match started a ride; end it (free before the scroll) so the next
  -- hail is not refused as busy.
  T.ok(ns.Ride.current(), "the match started a ride")
  ns.Ride.cancel("test")
  -- The next hail finds nobody.
  wow:advance(10)
  ui.hail:Click()
  wow:advance(121)
  T.eq(ui.status:GetText(), "No taxi answered. Try a higher maximum or Browse.")
  T.ok(ui.hail:IsEnabled())
  noErrors(wow)
end)

T.test("Dispatch errors are shown in words on the Ride page", function()
  local wow, ns, state = client(warrior())
  ns.UI.show("ride")
  local R = ns.UI.RideTab
  ns.Dispatch.hail = function() return nil, "cooldown" end
  changed(ns, state)
  R.ui.tiles[2]:Click()
  R.ui.hail:Click()
  T.eq(R.ui.status:GetText(), "Wait a few seconds before you hail again.")
  ns.Dispatch.hail = function() return nil, "queue_full" end
  R.ui.hail:Click()
  T.eq(R.ui.status:GetText(), "The network is not ready. Try again in a moment.")
  R.ui.tiles[1]:Click()
  T.eq(R.ui.status:GetText(), "", "a new choice clears the error")
  noErrors(wow)
end)

T.test("Drive lists open requests on duty with Take buttons; Take whispers TAKE", function()
  local wow, ns = realClient(mage())
  ns.UI.show("drive")
  local ui = ns.UI.DriveTab.ui
  say(wow, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" }, max = 40000,
    rest = true }, "Velvet")
  T.ok(ui.requestsEmpty:IsShown(), "off duty: nothing listed")
  ui.duty:Click()
  T.ok(wow.env.PortaxiCharDB.onDuty)
  T.ok(not ui.requestsEmpty:IsShown())
  local row = ui.requestRows[1]
  T.eq(row.who:GetText(), "Velvet Forever to Orgrimmar")
  T.eq(row.what:GetText(), "Come-to-you · 3g · 0 s ago")
  wow:advance(4)
  say(wow, { type = "HAIL", reqId = "Kira:1", fac = "Horde", dest = "UC", svcs = { "PICK" }, max = 40000,
    rest = false }, "Kira")
  T.eq(row.what:GetText(), "Come-to-you · 3g · 4 s ago", "redrawn on MARKET_CHANGED")
  T.eq(ui.requestRows[2].who:GetText(), "Kira Forever to Undercity")
  T.ok(row.take:IsEnabled())
  row.take:Click()
  wow:advance(1)
  local take = sentOf(wow, "TAKE")
  T.eq({ take[1].target, take[1].reqId, take[1].svc }, { "Velvet Forever", "Velvet:1", "COME" })
  T.eq(row.take:GetText(), "Sent")
  T.ok(not row.take:IsEnabled())
  T.ok(not ui.requestRows[2].take:IsEnabled(), "one pending TAKE")
  ns.UI.DriveTab.take("Kira:1")
  T.eq(#sentOf(wow, "TAKE"), 1)
  T.eq(ui.requestsNote:GetText(), "Waiting for the rider to confirm your last answer.")
  wow:advance(10)
  T.ok(ui.requestRows[2].take:IsEnabled(), "free again after T.CONFIRM")
  say(wow, { type = "GONE", reqId = "Kira:1" }, "Kira")
  T.ok(not ui.requestRows[2]:IsShown(), "GONE removes the row")
  ui.duty:Click()
  T.ok(ui.requestsEmpty:IsShown(), "off duty again")
  noErrors(wow)
end)

T.test("Alerts: raid warning and sound for INCOMING_REQUEST", function()
  local wow, ns = realClient(mage())
  ns.Dispatch.setOnDuty(true)
  say(wow, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" }, max = 40000,
    rest = true }, "Velvet")
  T.eq(wow.raidWarnings, { "Portaxi: Velvet Forever wants Orgrimmar (Come-to-you, 3g)" })
  T.eq(wow:callsTo("PlaySound")[1].args[1], 8959)
  say(wow, { type = "BOOK", reqId = "Kira:7", dest = "UC", svc = "PICK", price = 15000 }, "Kira", "WHISPER")
  T.eq(wow.raidWarnings[2], "Portaxi: Kira Forever booked you to Undercity (Pickup, 1g 50s)")
  wow:advance(12)
  say(wow, { type = "HAIL", reqId = "Velvet:1", fac = "Horde", dest = "OG", svcs = { "COME", "PICK" }, max = 40000,
    rest = true }, "Velvet")
  T.eq(#wow.raidWarnings, 2, "once per reqId")
  noErrors(wow)
end)

-- Wave 3 (card J): emblems, fallbacks, the online line, the ride panel ------------------------------

-- Makes a texture refuse files from Portaxi/Media, as the game does for a missing file.
local function refuseMedia(tex)
  tex.SetTexture = function(self, path)
    if type(path) == "string" and path:find("Portaxi\\Media\\", 1, true) then
      return false
    end
    self.__texture = path
    return true
  end
end

T.test("a tile falls back to the portal spell icon when the emblem texture is refused", function()
  local wow, ns, state = client(mage())
  ns.UI.show()
  local tile = ns.UI.RideTab.ui.tiles[1]
  T.ok(tile.emblem.ring:IsShown(), "ring around the emblem")
  refuseMedia(tile.icon)
  changed(ns, state)
  T.eq(tile.icon:GetTexture(), 100000 + 11417, "portal spell icon (D13)")
  T.ok(tile.emblem.fallback)
  T.ok(not tile.emblem.ring:IsShown(), "no ring around a square icon")
  T.ok(tile.icon:IsDesaturated(), "still grey when not selected")
  tile:Click()
  T.ok(not tile.icon:IsDesaturated())
  noErrors(wow)
end)

T.test("Drive shows the city emblems next to the portal spells and in the request rows", function()
  local wow, ns = realClient(mage())
  ns.UI.show("drive")
  local ui = ns.UI.DriveTab.ui
  T.eq(ui.portals[1].emblem.icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\emblem_OG")
  T.ok(not ui.portals[1].emblem.icon:IsDesaturated(), "known portal in colour")
  T.ok(ui.portals[3].emblem.icon:IsDesaturated(), "unknown portal grey")
  ui.duty:Click()
  say(wow, { type = "BOOK", reqId = "Kira:7", dest = "UC", svc = "PICK", price = 15000 }, "Kira", "WHISPER")
  local row = ui.requestRows[1]
  T.eq(row.emblem.icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\emblem_UC")
  T.ok(row.stripe:IsShown(), "gold stripe for a booking")
  noErrors(wow)
end)

T.test("the title bar counts the taxis online of the own faction", function()
  local wow, ns = realClient(warrior())
  ns.UI.show()
  local M = ns.UI.MainFrame
  T.eq(M.title:GetText(), "PORTAXI")
  T.eq(M.online:GetText(), "0 taxis online")
  say(wow, hello("Horde", { "OG" }, { PICK = 20000 }), "Aaron")
  T.eq(M.online:GetText(), "1 taxi online", "updated on MARKET_CHANGED")
  say(wow, hello("Horde", { "OG", "UC" }, { COME = 30000, PICK = 15000 }), "Bert")
  say(wow, hello("Alliance", { "SW" }, { PICK = 1000 }), "Ally")
  T.eq(M.online:GetText(), "2 taxis online")
  noErrors(wow)
end)

T.test("minimap button: the portal icon, or the portal spell when the file is refused", function()
  local wow, ns = client(mage())
  local MM = ns.UI.Minimap
  T.eq(MM.button.icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\portal")
  refuseMedia(MM.button.icon)
  MM.refresh()
  T.eq(MM.button.icon:GetTexture(), 100000 + 11417)
  noErrors(wow)
end)

T.test("ride panel: destination emblem, steps bar and a text for every fail reason of Ride", function()
  local wow, ns = client(mage())
  local ride = { reqId = "Velvet:1", role = "rider", svc = "PICK", price = 15000, dest = "UC",
    peer = { key = "Velvet", raw = "Velvet Forever" }, state = "TRADING" }
  ns.fire("RIDE_STARTED", ride)
  local P = ns.UI.RidePanel
  T.eq(P.frame.icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\emblem_UC")
  T.eq(P.frame.steps[4]:GetText(), "Trade")
  local reasons = {
    invite_timeout = "The group did not form in time.",
    peer_offline = "Velvet went offline.",
    left_group = "Velvet is no longer in the group.",
    peer_failed = "The ride failed on Velvet's side.",
    trade_timeout = "Nobody paid in time.",
  }
  for reason, text in pairs(reasons) do
    ride.state, ride.reason = "FAILED", reason
    ns.fire("RIDE_STATE", ride)
    T.eq(P.view().status, "Ride failed: " .. text, reason)
  end
  ride.state, ride.reason = "CANCELLED", "peer_cancelled"
  ns.fire("RIDE_STATE", ride)
  T.eq(P.view().status, "Ride cancelled: Velvet cancelled the ride.")
  ride.reason = "cancelled"
  ns.fire("RIDE_STATE", ride)
  T.eq(P.view().status, "Ride cancelled: You cancelled the ride.")
  noErrors(wow)
end)

T.test("every fail reason Core/Ride.lua can set has a text in the ride panel", function()
  local f = assert(io.open("Portaxi/Core/Ride.lua", "r"))
  local src = f:read("*a")
  f:close()
  local found = {}
  for reason in src:gmatch('fail%(r, acts, "([%w_]+)"') do
    found[reason] = true
  end
  for reason in src:gmatch('r%.reason = "([%w_]+)"') do
    found[reason] = true
  end
  for reason in src:gmatch('Ride%.cancel%("([%w_]+)"%)') do
    found[reason] = true
  end
  local wow, ns = client(mage())
  local n = 0
  for reason in pairs(found) do
    n = n + 1
    local ride = { reqId = "Velvet:1", role = "taxi", svc = "COME", price = 30000, dest = "OG",
      peer = { key = "Velvet", raw = "Velvet Forever" }, state = "FAILED", reason = reason }
    ns.fire("RIDE_STATE", ride)
    T.ok(ns.UI.RidePanel.view().status ~= "Ride failed: " .. reason, "no text for reason " .. reason)
  end
  T.ok(n >= 7, "found the reasons in Ride.lua: " .. n)
  noErrors(wow)
end)

T.done()
