-- Core/Init.lua: event bus, API resolver, player key, SavedVariables defaults, /ptx.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local function loaded(opts)
  return Wow.new():load(opts)
end

T.test("whole addon loads without errors and fires READY once", function()
  local wow = Wow.new():load({ noLogin = true })
  local ready = 0
  wow.ns.on("READY", function() ready = ready + 1 end)
  wow:fire("ADDON_LOADED", "Portaxi")
  wow:fire("PLAYER_LOGIN")
  T.eq(ready, 1)
  T.eq(#wow.errors, 0)
  T.ok(wow.printed[#wow.printed]:find("loaded"), "login message")
end)

T.test("event bus calls listeners in order and passes all arguments, nil included", function()
  local ns = loaded().ns
  local got = {}
  ns.on("X", function(a, b, c) got[#got + 1] = { "first", a, b, c } end)
  ns.on("X", function(a, b, c) got[#got + 1] = { "second", a, b, c } end)
  ns.fire("X", 1, nil, 3)
  T.eq(got, { { "first", 1, nil, 3 }, { "second", 1, nil, 3 } })
end)

T.test("a failing listener is reported and does not stop the others", function()
  local wow = loaded()
  local ran = false
  wow.ns.on("X", function() error("boom") end)
  wow.ns.on("X", function() ran = true end)
  wow.ns.fire("X")
  T.ok(ran, "second listener ran")
  T.eq(#wow.errors, 1)
  T.ok(tostring(wow.errors[1]):find("boom"))
end)

T.test("off removes a listener, also while the event is being fired", function()
  local ns = loaded().ns
  local calls = 0
  local h2
  ns.on("X", function() ns.off(h2) end)
  h2 = ns.on("X", function() calls = calls + 1 end)
  ns.fire("X")
  ns.fire("X")
  T.eq(calls, 0)
  ns.off(nil) -- harmless
end)

-- Forever: first name + surname, unique only together (no realms); keys are "First Surname" (D5).
T.test("playerKey normalises the sender to 'First Surname'", function()
  local ns = loaded().ns
  T.eq(ns.playerKey("Thalindra Forever"), "Thalindra Forever")
  T.eq(ns.playerKey("Thalindra-Forever"), "Thalindra Forever")
  T.eq(ns.playerKey("  Varekhal   Stonefel "), "Varekhal Stonefel")
  T.eq(ns.playerKey("Thalindra Forever"), "Thalindra Forever")
  T.eq(ns.playerKey("Thalindra"), "Thalindra", "a first name alone stays a first-name key")
  T.eq(ns.playerKey(nil), nil)
end)

T.test("unitKey / selfKey build the key from UnitName's two parts", function()
  local wow = loaded()
  local ns = wow.ns
  T.eq(ns.selfKey(), "Thalindra Forever")
  wow.units.target = { name = "Aelric", realm = "Dawnmere", isPlayer = true }
  T.eq(ns.unitKey("target"), "Aelric Dawnmere")
  wow.units.target = { name = "Solo", isPlayer = true }
  T.eq(ns.unitKey("target"), "Solo")
  T.eq(ns.unitKey("focus"), nil)
end)

T.test("sameName: full keys exactly, a first-name-only side by first name", function()
  local ns = loaded().ns
  T.ok(ns.sameName("Varekhal Stonefel", "Varekhal Stonefel"))
  T.ok(not ns.sameName("Varekhal Stonefel", "Varekhal Other"), "same first name, other character")
  T.ok(ns.sameName("Varekhal", "Varekhal Stonefel"))
  T.ok(not ns.sameName("Zero", "Varekhal Stonefel"))
  T.ok(not ns.sameName(nil, "Varekhal"))
  T.eq(ns.firstName("Varekhal Stonefel"), "Varekhal")
end)

T.test("api returns the first existing function and skips missing ones", function()
  local ns = loaded().ns
  T.eq(ns.api("GetItemCount", "C_Item.GetItemCount")(17032), 7)
  T.eq(ns.api("Nope.Nothing", "AlsoMissing"), nil)
  T.ok(ns.hasApi("C_ChatInfo.SendAddonMessage"))
  T.ok(not ns.hasApi("SetTradeMoney"))
end)

T.test("SavedVariables get defaults and keep existing values", function()
  local wow = loaded({ saved = {
    PortaxiDB = { ui = { minimap = { angle = 45 } }, diag = { at = "x" } },
    PortaxiCharDB = { prices = { COME = 50000 } },
  } })
  local db, char = wow.env.PortaxiDB, wow.env.PortaxiCharDB
  T.eq(db.version, 1)
  T.eq(db.ui.minimap.angle, 45)
  T.eq(db.diag.at, "x")
  T.eq(db.caps, {})
  T.eq(char.prices, { COME = 50000, PICK = 15000 })
  T.eq(char.onDuty, false)
  T.eq(char.lastRideAt, 0)
end)

T.test("fresh SavedVariables do not share tables with the defaults", function()
  local a = loaded()
  local b = loaded()
  a.env.PortaxiCharDB.prices.COME = 1
  T.eq(b.env.PortaxiCharDB.prices.COME, 30000)
end)

T.test("/ptx lists commands; command word is case-insensitive, arguments keep case", function()
  local wow = loaded()
  local got
  wow.ns.commands.echo = { fn = function(args) got = args end, args = "<x>", help = "test" }
  wow:slash("")
  local help = table.concat(wow.printed, "\n")
  T.ok(help:find("/ptx diag", 1, true), "diag listed")
  T.ok(help:find("/ptx echo <x> · test", 1, true), "echo listed with args")
  wow:slash("  ECHO   Velvet Moon  ")
  T.eq(got, "Velvet Moon")
end)

T.test("every module from the TOC exists in the namespace", function()
  local ns = loaded().ns
  for _, name in ipairs({ "Const", "Protocol", "Market", "Detect", "Net", "Dispatch", "Ride", "Trade", "Secure" }) do
    T.ok(type(ns[name]) == "table", name)
  end
  for _, name in ipairs({ "Widgets", "MainFrame", "Minimap", "Alerts", "RideTab", "DriveTab", "RidePanel" }) do
    T.ok(type(ns.UI[name]) == "table", "UI." .. name)
  end
  T.eq(ns.L["Hail a taxi"], "Hail a taxi")
end)

T.done()
