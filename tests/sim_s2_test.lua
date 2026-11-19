-- Scenario 2 (plan §9): a rider with 50s cannot hail with a maximum of 3g. Dispatch refuses with
-- "money", nothing goes on the network, and the Ride tab says why.
local T = dofile("tests/lib/t.lua")
local Sim = dofile("tests/lib/sim.lua")

local function world()
  local sim = Sim.new()
  local taxi = sim:client("Thalindra")
  local rider = sim:client("Velvet", { class = "WARRIOR", race = "Orc", money = 5000, zone = "Durotar" })
  sim:advance(2)
  taxi.ns.Dispatch.setOnDuty(true)
  sim:advance(2)
  return sim, taxi, rider
end

local function hails(c)
  local n = 0
  for _, e in ipairs(c.sent) do
    if e.msg:find("^HAIL|") then
      n = n + 1
    end
  end
  return n
end

T.test("Dispatch.hail refuses with money and broadcasts nothing", function()
  local sim, taxi, rider = world()
  local incoming = {}
  taxi.ns.on("INCOMING_REQUEST", function(e) incoming[#incoming + 1] = e end)
  T.eq({ rider.ns.Dispatch.hail("OG", 30000) }, { nil, "money" })
  sim:advance(5)
  T.eq(hails(rider), 0)
  T.eq(rider.ns.Dispatch.status().hail, nil)
  T.eq(#incoming, 0, "no taxi hears of it")
  T.eq(#taxi.ns.Dispatch.requests(), 0)
  -- A maximum the rider can pay goes out.
  T.ok(rider.ns.Dispatch.hail("OG", 5000))
  sim:advance(1)
  T.eq(hails(rider), 1)
end)

T.test("the Ride tab keeps the Hail button grey and says why", function()
  local sim, _, rider = world()
  rider:slash("show")
  local R = rider.ns.UI.RideTab
  local ui = R.ui
  ui.tiles[1]:Click()
  T.eq(R.max, 30000, "default maximum 3g")
  T.ok(ui.warning:IsShown())
  T.eq(ui.warning:GetText(), "You carry only 50s. Portaxi won't send an offer for more gold than you have.")
  T.ok(not ui.hail:IsEnabled())
  T.eq(ui.hint:GetText(), "Lower your maximum to what you carry.")
  ui.hail:Click()
  R.hail()
  sim:advance(2)
  T.eq(hails(rider), 0, "nothing broadcast from the UI either")
  -- Even if the button were clicked, Dispatch's answer is shown in words.
  R.error = "money"
  R.redraw()
  T.eq(ui.status:GetText(), "You don't carry enough gold for that.")
  T.eq(#rider.errors, 0)
end)

T.done()
