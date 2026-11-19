-- Trade: opening the trade window, gold prefill and the payment check.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Trade a Secure" (Trade part), decisions D3, D10, D11.
-- Card I, wave 2.
--
--   Trade.verify(expected, received) -> ok, reason   pure; reason "short" when received < expected
--   Trade.open(unit) -> true | false, "manual" | nil, "no_ride"
--       taxi: InitiateTrade(unit) from a timer; blocked -> caps.openTrade = "manual", CAPS_CHANGED and
--       TRADE_MANUAL("open"); no TRADE_SHOW within OPEN_TIMEOUT -> only TRADE_MANUAL("open") for this
--       ride (a timeout is often just distance, not a client restriction). With caps.openTrade already
--       "manual" the attempt is skipped and TRADE_MANUAL("open") fires at once.
--   Trade.status() -> { open, partner, expected, mine, theirs, prefilled }   (a copy)
--
-- Trade acts only for the active ride (ns.Ride.current()) and only when the window is open with its
-- peer (ns.sameName(ns.unitKey("NPC"), ride.peer.key)). Anything else is ignored.
--   rider: GetMoney() >= price -> C_TradeInfo.SetTradeMoney(price) after PREFILL_DELAY, only when
--     Const.TRADE.SET_MONEY_API (false on Forever: the call is ADDON_ACTION_FORBIDDEN, gate G2); blocked,
--     an error or GetPlayerTradeMoney() ~= price PREFILL_CHECK later -> caps.prefill = "manual". Fallback:
--     MoneyInputFrame_SetCopper(TradePlayerInputMoneyFrame, price) only when Const.TRADE.FILL_MONEY_FIELD,
--     else TRADE_MANUAL("prefill", price) (the panel asks the rider to type the gold).
-- A blocked call is attributed to the call in progress (`calling`): Forever reports the function as
-- "UNKNOWN()", so its name cannot be matched.
--   taxi: GetTargetTradeMoney() on TRADE_MONEY_CHANGED / TRADE_ACCEPT_UPDATE; an offer below the price
--     (non-zero, or zero while someone has accepted) -> TRADE_MANUAL("short", offered, price), once per amount.
--   completion: UI_INFO_MESSAGE "Trade complete." (or ERR_TRADE_COMPLETE), or TRADE_CLOSED after both sides
--     accepted (TRADE_ACCEPT_UPDATE 1, 1). A TRADE_CLOSED without that keeps the session CLOSE_GRACE s for
--     a late completion message. The taxi then checks the GetMoney() delta since TRADE_SHOW with verify();
--     ok -> TRADE_PAID(reqId, delta) once. When the last offer seen covered the price but the money has
--     not arrived yet, it is re-checked on PLAYER_MONEY for PAY_WAIT s.
-- Trade never calls AcceptTrade (D10): the player clicks Trade.

-- luacheck: read globals ERR_TRADE_COMPLETE TradePlayerInputMoneyFrame MoneyInputFrame_SetCopper

local ADDON, ns = ...

local Trade = {}
ns.Trade = Trade

local OPEN_DELAY = 0.1      -- InitiateTrade runs from a timer, never inside the caller's stack
local OPEN_TIMEOUT = 3      -- TRADE_SHOW must follow InitiateTrade within this
local PREFILL_DELAY = 0.3   -- after TRADE_SHOW, before SetTradeMoney
local PREFILL_CHECK = 0.5   -- after SetTradeMoney, before reading GetPlayerTradeMoney back
local CLOSE_GRACE = 2       -- a closed window still accepts a late "Trade complete."
local PAY_WAIT = 5          -- after completion, PLAYER_MONEY may still bring the gold
local COMPLETE_TEXT = "Trade complete."

local session   -- the trade with the active ride's peer, see newSession
local opening   -- token of the pending Trade.open, nil when none
local calling   -- "open" | "prefill" while that protected call runs (blocked-event attribution)

-- Pure -----------------------------------------------------------------------------------------

function Trade.verify(expected, received)
  if type(expected) ~= "number" or type(received) ~= "number" then
    return false, "invalid"
  end
  if received < expected then
    return false, "short"
  end
  return true
end

-- Helpers ----------------------------------------------------------------------------------------

local function activeRide()
  local current = ns.Ride and ns.Ride.current
  local ride = type(current) == "function" and current() or nil
  if type(ride) == "table" and type(ride.peer) == "table" and ride.peer.key and ride.price then
    return ride
  end
end

local function setManual(cap)
  ns.setCap(cap, "manual")
end

local function capIsManual(cap)
  return ns.cap(cap) == "manual"
end

local function after(seconds, fn)
  C_Timer.After(seconds, fn)
end

-- Opening (taxi) -----------------------------------------------------------------------------------

-- remember = true only when the client refused the call (blocked, error, missing API). A timeout (e.g. the
-- peer is out of range) asks for the manual step for this ride but does not switch caps.openTrade for good.
local function openFailed(token, remember)
  if opening ~= token then
    return
  end
  opening = nil
  if remember then
    setManual("openTrade")
  end
  ns.fire("TRADE_MANUAL", "open")
end

function Trade.open(unit)
  local ride = activeRide()
  if not ride then
    return nil, "no_ride"
  end
  unit = unit or ride.peerUnit
  if capIsManual("openTrade") then
    ns.fire("TRADE_MANUAL", "open")
    return false, "manual"
  end
  local token = {}
  opening = token
  after(OPEN_DELAY, function()
    if opening ~= token then
      return
    end
    local initiate = ns.api("InitiateTrade")
    calling = "open"
    local ok = initiate and pcall(initiate, unit)
    calling = nil
    if not ok then
      return openFailed(token, true)
    end
    if opening ~= token then
      return -- blocked during the call
    end
    after(OPEN_TIMEOUT, function() openFailed(token, false) end)
  end)
  return true
end

-- Session ------------------------------------------------------------------------------------------

local function newSession(ride, partner)
  return {
    role = ride.role, reqId = ride.reqId, price = ride.price, partner = partner,
    open = true, before = GetMoney(), mine = GetPlayerTradeMoney() or 0, theirs = GetTargetTradeMoney() or 0,
    prefilled = false, accepted = false,
  }
end

local function endSession(s)
  if session == s then
    session = nil
  end
end

function Trade.status()
  local s = session
  if not s then
    return { open = false, prefilled = false }
  end
  return { open = s.open, partner = s.partner, expected = s.price, mine = s.mine, theirs = s.theirs,
           prefilled = s.prefilled }
end

-- Prefill (rider) -----------------------------------------------------------------------------------

-- remember = false when the automatic prefill is simply off on this client (Const), not refused now.
local function prefillManual(s, remember)
  if s.manual then
    return
  end
  s.manual, s.prefilling = true, false
  if remember ~= false then
    setManual("prefill")
  end
  local setCopper = ns.api("MoneyInputFrame_SetCopper")
  local frame = TradePlayerInputMoneyFrame
  if ns.Const.TRADE.FILL_MONEY_FIELD and setCopper and frame and pcall(setCopper, frame, s.price) then
    return
  end
  ns.fire("TRADE_MANUAL", "prefill", s.price)
end

local function checkPrefill(s)
  if session ~= s or not s.prefilling then
    return
  end
  s.prefilling = false
  s.mine = GetPlayerTradeMoney() or 0
  if s.mine == s.price then
    s.prefilled = true
  else
    prefillManual(s)
  end
end

local function prefillNow(s)
  if session ~= s or not s.open then
    return
  end
  local setMoney = ns.api("C_TradeInfo.SetTradeMoney", "SetTradeMoney")
  if not setMoney then
    return prefillManual(s)
  end
  s.prefilling = true
  calling = "prefill"
  local ok = pcall(setMoney, s.price)
  calling = nil
  if not ok then
    return prefillManual(s)
  end
  if s.prefilling then -- not blocked meanwhile
    after(PREFILL_CHECK, function() checkPrefill(s) end)
  end
end

local function startPrefill(s)
  if GetMoney() < s.price then
    return -- cannot afford it: the player sees the price in RidePanel
  end
  if not ns.Const.TRADE.SET_MONEY_API then
    return prefillManual(s, false)
  end
  if capIsManual("prefill") then
    return prefillManual(s)
  end
  after(PREFILL_DELAY, function() prefillNow(s) end)
end

-- Offer check (taxi) ---------------------------------------------------------------------------------

local function checkOffer(s, someoneAccepted)
  s.theirs = GetTargetTradeMoney() or 0
  if s.theirs >= s.price then
    s.shortWarned = nil
    return
  end
  if (s.theirs > 0 or someoneAccepted) and s.shortWarned ~= s.theirs then
    s.shortWarned = s.theirs
    ns.fire("TRADE_MANUAL", "short", s.theirs, s.price)
  end
end

-- Completion ------------------------------------------------------------------------------------------

-- Taxi: the money delta since TRADE_SHOW is the payment. True once TRADE_PAID has fired.
local function checkPaid(s)
  if s.paid then
    return true
  end
  local received = GetMoney() - s.before
  if Trade.verify(s.price, received) then
    s.paid = true
    endSession(s)
    ns.fire("TRADE_PAID", s.reqId, received)
    return true
  end
  return false
end

local function complete(s)
  if s.completed then
    return
  end
  s.completed, s.open, s.prefilling = true, false, false
  -- Late money is waited for only when the last offer seen covered the price, so unrelated gold
  -- after a short trade never turns it into a payment.
  if s.role ~= "taxi" or checkPaid(s) or s.theirs < s.price then
    return endSession(s)
  end
  s.waitUntil = GetTime() + PAY_WAIT
  after(PAY_WAIT, function() endSession(s) end)
end

local function closed(s)
  if s.accepted then
    return complete(s)
  end
  s.open, s.prefilling = false, false
  after(CLOSE_GRACE, function()
    if not s.completed then
      endSession(s)
    end
  end)
end

-- Events ------------------------------------------------------------------------------------------------

local handlers = {}

function handlers.TRADE_SHOW()
  local ride = activeRide()
  local partner = ns.unitKey("NPC")
  if not ride or not ns.sameName(partner, ride.peer.key) then
    session = nil
    return
  end
  opening = nil
  session = newSession(ride, partner)
  if session.role == "rider" then
    startPrefill(session)
  end
end

function handlers.TRADE_MONEY_CHANGED()
  local s = session
  if not s or not s.open then
    return
  end
  s.mine = GetPlayerTradeMoney() or 0
  if s.role == "taxi" then
    checkOffer(s, false)
  else
    s.theirs = GetTargetTradeMoney() or 0
  end
end

function handlers.TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted)
  local s = session
  if not s or not s.open then
    return
  end
  local me, them = playerAccepted == 1 or playerAccepted == true, targetAccepted == 1 or targetAccepted == true
  s.accepted = me and them
  if s.role == "taxi" then
    checkOffer(s, me or them)
  end
end

function handlers.TRADE_CLOSED()
  local s = session
  if s and s.open then
    closed(s)
  end
end

function handlers.UI_INFO_MESSAGE(arg1, arg2)
  local s = session
  if not s or s.completed then
    return
  end
  local done = ERR_TRADE_COMPLETE or COMPLETE_TEXT
  if arg1 == done or arg2 == done or arg1 == COMPLETE_TEXT or arg2 == COMPLETE_TEXT then
    complete(s)
  end
end

function handlers.PLAYER_MONEY()
  local s = session
  if s and s.completed and s.waitUntil and GetTime() <= s.waitUntil then
    checkPaid(s)
  end
end

function handlers.ADDON_ACTION_BLOCKED(addon, func)
  if addon ~= ADDON then
    return
  end
  func = tostring(func)
  if calling == "open" or (not calling and opening and func:find("InitiateTrade", 1, true)) then
    if opening then
      openFailed(opening, true)
    end
  elseif calling == "prefill" or (session and session.prefilling and func:find("SetTradeMoney", 1, true)) then
    if session then
      prefillManual(session)
    end
  end
end
handlers.ADDON_ACTION_FORBIDDEN = handlers.ADDON_ACTION_BLOCKED

function Trade.start()
  local frame = CreateFrame("Frame")
  for event in pairs(handlers) do
    frame:RegisterEvent(event)
  end
  frame:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
  end)
end

ns.on("READY", Trade.start)
