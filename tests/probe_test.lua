-- Phase 0 probes (Core/Probe.lua).
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local function client()
  local wow = Wow.new():load()
  wow.units.target = { name = "Velvet", realm = "Forever", isPlayer = true }
  return wow
end

local function lastLog(wow)
  local l = wow.env.PortaxiDB.probe.log
  return l[#l].text
end

local function logHas(wow, text)
  for _, e in ipairs(wow.env.PortaxiDB.probe.log) do
    if e.text:find(text, 1, true) then return true end
  end
  return false
end

T.test("net joins the channel, pings it and logs the echo without replying to itself", function()
  local wow = client()
  wow:slash("net")
  wow:advance(3)
  T.eq(wow.sent[1], { prefix = "PTX", msg = "PING|1|Thalindra|Horde", kind = "CHANNEL", target = 6 })
  T.eq(#wow.sent, 1, "no PONG to own echo")
  T.ok(logHas(wow, "received CHANNEL from Thalindra Forever: PING|1|Thalindra|Horde"))
end)

T.test("a ping from another player gets a PONG whisper to the raw sender", function()
  local wow = client()
  wow:receive("PTX", "PING|1|Velvet|Horde", "CHANNEL", "Velvet Forever")
  T.eq(wow.sent[1].kind, "WHISPER")
  T.eq(wow.sent[1].target, "Velvet Forever")
  T.ok(wow.sent[1].msg:find("^PONG|1|Thalindra|"))
end)

T.test("a player whose name starts with ours is someone else", function()
  local wow = client()
  wow:receive("PTX", "PING|1|Thalindrak|Horde", "CHANNEL", "Thalindrak Forever")
  T.eq(#wow.sent, 1)
end)

T.test("protocol traffic and other prefixes are not logged", function()
  local wow = client()
  wow:receive("PTX", "HELLO|1|Horde|MAGE", "CHANNEL", "Velvet Forever")
  wow:receive("OTHER", "PING|1|x", "CHANNEL", "Velvet Forever")
  T.eq(wow.env.PortaxiDB.probe, nil)
end)

T.test("invite runs from a timer and keeps the name's case", function()
  local wow = client()
  wow:slash("invite Velvet")
  T.eq(#wow:callsTo("C_PartyInfo.InviteUnit"), 0, "not before the timer")
  wow:advance(1)
  T.eq(wow:callsTo("C_PartyInfo.InviteUnit")[1].args, { "Velvet" })
end)

T.test("a blocked invite is logged", function()
  local wow = client()
  wow.blocked["C_PartyInfo.InviteUnit"] = true
  wow:slash("invite Velvet")
  wow:advance(1)
  T.ok(logHas(wow, "protected call blocked: C_PartyInfo.InviteUnit()"))
end)

T.test("accept is armed once and joins the party", function()
  local wow = client()
  wow:inviteFrom("Velvet")
  wow:advance(1)
  T.eq(#wow:callsTo("AcceptGroup"), 0, "not armed")
  wow:slash("accept")
  wow:inviteFrom("Velvet")
  wow:advance(1)
  T.eq(#wow:callsTo("AcceptGroup"), 1)
  T.eq(wow.party, { "Velvet" })
  T.ok(logHas(wow, "in group: true, members: 2"))
  wow:inviteFrom("Velvet")
  wow:advance(1)
  T.eq(#wow:callsTo("AcceptGroup"), 1, "disarmed after one use")
end)

T.test("opentrade needs a player target and opens trade from a timer", function()
  local wow = client()
  wow.units.target = nil
  wow:slash("opentrade")
  T.ok(wow.printed[#wow.printed]:find("Target the other player"))
  wow.units.target = { name = "Velvet", realm = "Forever", isPlayer = true }
  wow:slash("opentrade")
  wow:advance(2)
  T.eq(wow:callsTo("InitiateTrade")[1].args, { "target" })
  T.ok(logHas(wow, "window open with Velvet"))
end)

T.test("trade prefills the armed amount once and logs the result", function()
  local wow = client()
  wow:slash("trade abc")
  T.ok(wow.printed[#wow.printed]:find("Usage"))
  wow:slash("trade 150")
  wow:tradeOpenedBy("Velvet")
  wow:advance(1)
  T.eq(wow.trade.mine, 150)
  T.ok(logHas(wow, "my offer now 0g 1s 50c"))
  wow:tradeTheirMoney(20000)
  wow:tradeComplete()
  T.ok(logHas(wow, "info: Trade complete."))
  T.ok(logHas(wow, "money now"))
  wow:tradeOpenedBy("Velvet")
  wow:advance(1)
  T.eq(wow.trade.mine, 0, "disarmed after one use")
end)

T.test("trade messages are ignored long after a trade", function()
  local wow = client()
  wow:tradeOpenedBy("Velvet")
  wow:advance(60)
  wow:fire("UI_INFO_MESSAGE", 0, "Something else")
  T.ok(not logHas(wow, "Something else"))
end)

T.test("blocked calls of other addons are ignored", function()
  local wow = client()
  wow:fire("ADDON_ACTION_BLOCKED", "OtherAddon", "Foo()")
  T.eq(wow.env.PortaxiDB.probe, nil)
end)

T.test("a missing API is logged, not thrown", function()
  local wow = client()
  wow.env.C_PartyInfo.InviteUnit = nil
  wow:slash("invite Velvet")
  wow:advance(1)
  T.eq(lastLog(wow), "C_PartyInfo.InviteUnit: API missing")
end)

T.test("the log is capped at 100 entries and can be cleared", function()
  local wow = client()
  for _ = 1, 150 do wow:fire("TRADE_CLOSED") end
  T.eq(#wow.env.PortaxiDB.probe.log, 100)
  wow:slash("probe clear")
  T.eq(#wow.env.PortaxiDB.probe.log, 0)
end)

T.done()
