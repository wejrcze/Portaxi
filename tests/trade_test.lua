-- Trade: opening, gold prefill, offer check and payment detection (Core/Trade.lua).
-- Ride is card H's module; a fake ns.Ride.current returns a ride in the playbook §2 shape.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local PRICE = 30000

-- A loaded client with a fake active ride with Velvet (party1) in the given role.
-- These tests cover the automatic prefill path (SetTradeMoney, then the money field). Forever forbids
-- SetTradeMoney (gate G2), so Const.TRADE turns both off; the "Forever default" tests below cover that.
local function client(role, forever)
  local wow = Wow.new():load()
  if not forever then
    wow.ns.Const.TRADE.SET_MONEY_API = true
    wow.ns.Const.TRADE.FILL_MONEY_FIELD = true
  end
  wow.ride = {
    reqId = "Velvet:1", role = role or "taxi", svc = "COME", price = PRICE, dest = "OG",
    peer = { key = "Velvet Forever", raw = "Velvet Forever" }, state = "TRADING", since = 1000, peerUnit = "party1",
  }
  wow.ns.Ride.current = function() return wow.ride end
  wow:joinParty("Velvet")
  return wow
end

-- Records internal events as { event, arg1, ... }.
local function record(wow, ...)
  local got = {}
  for _, event in ipairs({ ... }) do
    wow.ns.on(event, function(...) got[#got + 1] = { event, ... } end)
  end
  return got
end

local function caps(wow)
  return wow.env.PortaxiDB.caps
end

T.test("verify accepts the price or more and reports short payments", function()
  local wow = client()
  local verify = wow.ns.Trade.verify
  T.eq({ verify(30000, 30000) }, { true })
  T.eq({ verify(30000, 45000) }, { true })
  T.eq({ verify(30000, 29999) }, { false, "short" })
  T.eq({ verify(30000, 0) }, { false, "short" })
  T.eq({ verify(nil, 30000) }, { false, "invalid" })
end)

-- Opening ------------------------------------------------------------------------------------------

T.test("open() calls InitiateTrade from a timer and a TRADE_SHOW keeps caps on auto", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  T.eq(wow.ns.Trade.open("party1"), true)
  T.eq(#wow:callsTo("InitiateTrade"), 0, "not inside the caller")
  wow:advance(0.1)
  T.eq(wow:callsTo("InitiateTrade")[1].args, { "party1" })
  wow:advance(5)
  T.ok(wow.trade, "the window opened")
  T.eq(wow.ns.Trade.status().open, true)
  T.eq(#got, 0)
  T.eq(caps(wow).openTrade, nil)
end)

T.test("open() without a unit uses the ride's peerUnit", function()
  local wow = client("taxi")
  wow.ns.Trade.open()
  wow:advance(0.1)
  T.eq(wow:callsTo("InitiateTrade")[1].args, { "party1" })
end)

T.test("a blocked open switches caps.openTrade to manual and asks for the manual step", function()
  local wow = client("taxi")
  wow.blocked["InitiateTrade"] = true
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  wow.ns.Trade.open("party1")
  wow:advance(5)
  T.eq(caps(wow).openTrade, "manual")
  T.eq(#got, 2, "CAPS_CHANGED and TRADE_MANUAL once each")
  T.eq(got[1][1], "CAPS_CHANGED")
  T.eq(got[1][2].openTrade, "manual")
  T.eq(got[2], { "TRADE_MANUAL", "open" })
end)

T.test("no TRADE_SHOW within 3 s asks for the manual step but keeps caps.openTrade automatic", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_MANUAL")
  wow.ns.Trade.open("party2") -- nobody there: the window never opens
  wow:advance(3)
  T.eq(#got, 0, "not before the timeout")
  wow:advance(0.2)
  T.eq(got, { { "TRADE_MANUAL", "open" } })
  T.eq(caps(wow).openTrade, nil, "a timeout is not remembered (architect, G2)")
end)

T.test("with caps.openTrade manual, open() skips InitiateTrade and asks at once", function()
  local wow = client("taxi")
  caps(wow).openTrade = "manual"
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  T.eq({ wow.ns.Trade.open("party1") }, { false, "manual" })
  wow:advance(5)
  T.eq(#wow:callsTo("InitiateTrade"), 0)
  T.eq(got, { { "TRADE_MANUAL", "open" } })
end)

T.test("open() without an active ride does nothing", function()
  local wow = client("taxi")
  wow.ride = nil
  T.eq({ wow.ns.Trade.open("party1") }, { nil, "no_ride" })
  wow:advance(5)
  T.eq(#wow:callsTo("InitiateTrade"), 0)
  T.eq(caps(wow).openTrade, nil)
end)

-- Rider prefill ------------------------------------------------------------------------------------------

T.test("the rider's window is prefilled with the price after 0.3 s", function()
  local wow = client("rider")
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  wow:tradeOpenedBy("Velvet")
  wow:advance(0.2)
  T.eq(#wow:callsTo("C_TradeInfo.SetTradeMoney"), 0, "not before 0.3 s")
  wow:advance(0.1)
  T.eq(wow:callsTo("C_TradeInfo.SetTradeMoney")[1].args, { PRICE })
  wow:advance(1)
  local s = wow.ns.Trade.status()
  T.eq(s, { open = true, partner = "Velvet Forever", expected = PRICE, mine = PRICE, theirs = 0, prefilled = true })
  T.eq(#got, 0)
  T.eq(caps(wow).prefill, nil)
end)

T.test("a rider who cannot afford the price gets no prefill", function()
  local wow = client("rider")
  wow:setMoney(PRICE - 1)
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  wow:tradeOpenedBy("Velvet")
  wow:advance(2)
  T.eq(#wow:callsTo("C_TradeInfo.SetTradeMoney"), 0)
  T.eq(#got, 0)
  T.eq(wow.ns.Trade.status().prefilled, false)
end)

T.test("a blocked prefill falls back to MoneyInputFrame_SetCopper on the trade window", function()
  local wow = client("rider")
  wow.blocked["C_TradeInfo.SetTradeMoney"] = true
  wow.env.TradePlayerInputMoneyFrame = wow.env.CreateFrame("Frame", "TradePlayerInputMoneyFrame")
  local filled
  wow.env.MoneyInputFrame_SetCopper = function(frame, copper) filled = { frame, copper } end
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  wow:tradeOpenedBy("Velvet")
  wow:advance(2)
  T.ok(filled and filled[1] == wow.env.TradePlayerInputMoneyFrame)
  T.eq(filled[2], PRICE)
  T.eq(caps(wow).prefill, "manual")
  T.eq(#got, 1)
  T.eq(got[1][1], "CAPS_CHANGED")
end)

T.test("a blocked prefill without the trade money frame asks for the manual step", function()
  local wow = client("rider")
  wow.blocked["C_TradeInfo.SetTradeMoney"] = true
  local got = record(wow, "TRADE_MANUAL")
  wow:tradeOpenedBy("Velvet")
  wow:advance(2)
  T.eq(got, { { "TRADE_MANUAL", "prefill", PRICE } })
  T.eq(caps(wow).prefill, "manual")
  T.eq(#wow:callsTo("MoneyInputFrame_SetCopper"), 0)
end)

T.test("a prefill that does not take effect falls back too", function()
  local wow = client("rider")
  wow.env.C_TradeInfo.SetTradeMoney = function(copper) wow:record("C_TradeInfo.SetTradeMoney", copper) end
  local got = record(wow, "TRADE_MANUAL")
  wow:tradeOpenedBy("Velvet")
  wow:advance(0.3)
  T.eq(#wow:callsTo("C_TradeInfo.SetTradeMoney"), 1)
  T.eq(#got, 0, "checked only after a moment")
  wow:advance(1)
  T.eq(got, { { "TRADE_MANUAL", "prefill", PRICE } })
  T.eq(caps(wow).prefill, "manual")
end)

T.test("with caps.prefill manual the fallback runs at once, without SetTradeMoney", function()
  local wow = client("rider")
  caps(wow).prefill = "manual"
  local got = record(wow, "TRADE_MANUAL", "CAPS_CHANGED")
  wow:tradeOpenedBy("Velvet")
  T.eq(got, { { "TRADE_MANUAL", "prefill", PRICE } })
  wow:advance(2)
  T.eq(#wow:callsTo("C_TradeInfo.SetTradeMoney"), 0)
end)

T.test("a window closed before the prefill timer is left alone", function()
  local wow = client("rider")
  wow:tradeOpenedBy("Velvet")
  wow.env.CancelTrade()
  wow:advance(2)
  T.eq(#wow:callsTo("C_TradeInfo.SetTradeMoney"), 0)
end)

-- Taxi offer check and payment --------------------------------------------------------------------------

T.test("the taxi is warned once per amount when the rider offers less than the price", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_MANUAL")
  wow:tradeOpenedBy("Velvet")
  T.eq(#got, 0, "an empty offer at open is no warning")
  wow:tradeTheirMoney(20000)
  T.eq(got, { { "TRADE_MANUAL", "short", 20000, PRICE } })
  wow:fire("TRADE_MONEY_CHANGED")
  T.eq(#got, 1, "same amount, no repeat")
  wow:tradeTheirMoney(PRICE)
  T.eq(#got, 1)
  T.eq(wow.ns.Trade.status().theirs, PRICE)
  wow:tradeTheirMoney(0)
  wow:fire("TRADE_ACCEPT_UPDATE", 0, 1)
  T.eq(got[2], { "TRADE_MANUAL", "short", 0, PRICE }, "accepting with nothing offered")
end)

T.test("a completed trade with enough gold fires TRADE_PAID once on the taxi", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_PAID")
  local before = wow.player.money
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE)
  wow:tradeComplete()
  wow:advance(10)
  T.eq(got, { { "TRADE_PAID", "Velvet:1", PRICE } })
  T.eq(wow.player.money, before + PRICE)
  T.eq(wow.ns.Trade.status().open, false)
end)

T.test("more than the price is paid in full", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE + 5000)
  wow:tradeComplete()
  T.eq(got, { { "TRADE_PAID", "Velvet:1", PRICE + 5000 } })
end)

T.test("a completed trade with too little gold fires no TRADE_PAID", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE - 1)
  wow:tradeComplete()
  wow:advance(1)
  wow:setMoney(wow.player.money + 1) -- unrelated money later does not complete it
  wow:advance(10)
  T.eq(#got, 0)
end)

T.test("TRADE_CLOSED after both accepted completes the trade without the info message", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE)
  wow:fire("TRADE_ACCEPT_UPDATE", 1, 1)
  wow.player.money = wow.player.money + PRICE
  wow.trade = nil
  wow:fire("TRADE_CLOSED")
  T.eq(got, { { "TRADE_PAID", "Velvet:1", PRICE } })
end)

T.test("gold that arrives after the completion message is still counted", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE)
  wow:fire("UI_INFO_MESSAGE", 0, "Trade complete.")
  T.eq(#got, 0, "money not there yet")
  wow:advance(0.5)
  wow:setMoney(wow.player.money + PRICE)
  T.eq(got, { { "TRADE_PAID", "Velvet:1", PRICE } })
  wow:setMoney(wow.player.money + 1)
  T.eq(#got, 1, "once")
end)

T.test("a completion message shortly after TRADE_CLOSED still counts; a cancelled trade does not", function()
  local wow = client("taxi")
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE)
  wow.player.money = wow.player.money + PRICE
  wow.trade = nil
  wow:fire("TRADE_CLOSED")
  T.eq(#got, 0)
  wow:advance(0.5)
  wow:fire("UI_INFO_MESSAGE", 0, "Trade complete.")
  T.eq(got, { { "TRADE_PAID", "Velvet:1", PRICE } })

  local other = client("taxi")
  local none = record(other, "TRADE_PAID")
  other:tradeOpenedBy("Velvet")
  other:tradeTheirMoney(PRICE)
  other.env.CancelTrade()
  other:advance(3)
  other:fire("UI_INFO_MESSAGE", 0, "Trade complete.")
  T.eq(#none, 0)
end)

T.test("the localized ERR_TRADE_COMPLETE is recognised", function()
  local wow = client("taxi")
  wow.env.ERR_TRADE_COMPLETE = "Handel abgeschlossen."
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:tradeTheirMoney(PRICE)
  wow.player.money = wow.player.money + PRICE
  wow:fire("UI_INFO_MESSAGE", 0, "Handel abgeschlossen.")
  T.eq(got, { { "TRADE_PAID", "Velvet:1", PRICE } })
end)

T.test("the rider never fires TRADE_PAID", function()
  local wow = client("rider")
  local got = record(wow, "TRADE_PAID")
  wow:tradeOpenedBy("Velvet")
  wow:advance(1)
  wow:tradeComplete()
  wow:advance(10)
  T.eq(#got, 0)
end)

-- Not our trade ------------------------------------------------------------------------------------------

T.test("a trade with someone who is not the ride's peer is ignored", function()
  local rider = client("rider")
  local got = record(rider, "TRADE_MANUAL", "TRADE_PAID", "CAPS_CHANGED")
  rider:tradeOpenedBy("Stranger")
  rider:advance(2)
  T.eq(#rider:callsTo("C_TradeInfo.SetTradeMoney"), 0)
  T.eq(rider.ns.Trade.status().open, false)

  local taxi = client("taxi")
  local paid = record(taxi, "TRADE_MANUAL", "TRADE_PAID")
  taxi:tradeOpenedBy("Stranger")
  taxi:tradeTheirMoney(100)
  taxi:tradeTheirMoney(PRICE)
  taxi:tradeComplete()
  taxi:advance(10)
  T.eq(#got, 0)
  T.eq(#paid, 0)
end)

T.test("without an active ride trades are ignored", function()
  local rider = client("rider")
  rider.ride = nil
  rider:tradeOpenedBy("Velvet")
  rider:advance(2)
  T.eq(#rider:callsTo("C_TradeInfo.SetTradeMoney"), 0)

  local taxi = client("taxi")
  taxi.ride = nil
  local got = record(taxi, "TRADE_MANUAL", "TRADE_PAID")
  taxi:tradeOpenedBy("Velvet")
  taxi:tradeTheirMoney(PRICE)
  taxi:tradeComplete()
  T.eq(#got, 0)
end)

T.test("blocked calls of other addons do not switch caps", function()
  local wow = client("taxi")
  wow.ns.Trade.open("party1")
  wow:fire("ADDON_ACTION_BLOCKED", "OtherAddon", "InitiateTrade()")
  wow:advance(5)
  T.eq(caps(wow).openTrade, nil)
end)

-- Forever default (gate G2): SetTradeMoney is ADDON_ACTION_FORBIDDEN, so it is never called; the rider is
-- asked to type the gold, nothing is remembered in caps, and no blocked event is raised.
T.test("Forever default: no SetTradeMoney call, the rider is asked to type the price", function()
  local wow = client("rider", true)
  local got = record(wow, "TRADE_MANUAL")
  wow:tradeOpenedBy("Velvet")
  wow:advance(1)
  T.eq(#wow:callsTo("C_TradeInfo.SetTradeMoney"), 0)
  T.eq(#wow:callsTo("MoneyInputFrame_SetCopper"), 0, "the money field fill is unverified, off")
  T.eq(got, { { "TRADE_MANUAL", "prefill", PRICE } })
  T.eq(caps(wow).prefill, nil, "not a refusal, just off on this client")
  T.eq(#wow.errors, 0)
end)

T.test("a FORBIDDEN 'UNKNOWN()' during the prefill call is attributed to the prefill", function()
  local wow = client("rider")
  wow.env.TradePlayerInputMoneyFrame = nil
  wow.blocked["C_TradeInfo.SetTradeMoney"] = "forbidden"
  local got = record(wow, "TRADE_MANUAL")
  wow:tradeOpenedBy("Velvet")
  wow:advance(1)
  T.eq(caps(wow).prefill, "manual")
  T.eq(got, { { "TRADE_MANUAL", "prefill", PRICE } })
end)

T.test("a FORBIDDEN 'UNKNOWN()' during InitiateTrade is attributed to the open", function()
  local wow = client("taxi")
  wow.blocked.InitiateTrade = "forbidden"
  local got = record(wow, "TRADE_MANUAL")
  wow.ns.Trade.open("party1")
  wow:advance(1)
  T.eq(caps(wow).openTrade, "manual")
  T.eq(got, { { "TRADE_MANUAL", "open" } })
  wow:advance(5)
  T.eq(#got, 1, "no second request from the timeout")
end)

T.done()
