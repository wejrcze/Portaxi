-- Phase 0 tools. Owned by the architect.
--   /ptx diag   what the addon can read on this character -> PortaxiDB.diag
--   0.3 / 0.4   addon messages over the hidden channel (and whether factions share it)
--   0.5         party invite sent from a timer, not from a click
--   0.6         auto-accept of a party invite
--   0.7         opening trade from a timer
--   0.8 / 0.9   prefilling trade gold and reading the gold received
-- Each probe is armed by a slash command. Results go to PortaxiDB.probe.log (written on /reload).
-- Calls run from C_Timer callbacks on purpose: that is how the real addon will call them,
-- outside a hardware event. A blocked protected call shows up as ADDON_ACTION_BLOCKED.

local ADDON, ns = ...
local C = ns.Const
local say = ns.say

local MAX_LOG = 100
local TRADE_WATCH_SECONDS = 15

local itemCount = ns.api("C_Item.GetItemCount", "GetItemCount") or function() return 0 end
local spellKnown = ns.api("IsPlayerSpell", "IsSpellKnown", "C_SpellBook.IsSpellKnown") or function() return false end
local coinText = ns.api("C_CurrencyInfo.GetCoinTextureString", "GetCoinTextureString")
  or function(copper) return tostring(copper) .. "c" end

local function coins(copper)
  return coinText(copper or 0)
end

local function yesno(v)
  return v and "|cff5fd068yes|r" or "|cffff8a3dno|r"
end

-- Diagnostics -------------------------------------------------------------------

-- APIs the MVP depends on; both classic globals and C_ variants, to learn which exist.
local APIS = {
  "C_ChatInfo.RegisterAddonMessagePrefix",
  "C_ChatInfo.SendAddonMessage",
  "JoinTemporaryChannel",
  "C_PartyInfo.InviteUnit",
  "InviteUnit",
  "AcceptGroup",
  "InitiateTrade",
  "SetTradeMoney",
  "C_TradeInfo.SetTradeMoney",
  "GetTargetTradeMoney",
  "GetPlayerTradeMoney",
  "IsSpellKnown",
  "IsPlayerSpell",
  "C_SpellBook.IsSpellKnown",
  "IsResting",
  "GetItemCount",
  "C_Item.GetItemCount",
  "GetContainerNumSlots",
  "C_Container.GetContainerNumSlots",
  "C_Container.GetContainerItemLink",
  "GetCoinTextureString",
  "C_CurrencyInfo.GetCoinTextureString",
  "C_Map.GetBestMapForUnit",
  "C_Map.GetPlayerMapPosition",
  "C_Map.GetWorldPosFromMapPos",
  "UnitPosition",
  "GetPlayerFacing",
  "MoneyInputFrame_SetCopper",
  "C_Item.GetItemSpell",
  "SetPortraitTexture",
  "UnitIsConnected",
}

local function diag()
  local version, build, buildDate, interface = GetBuildInfo()
  local faction = UnitFactionGroup("player")
  local _, raceToken = UnitRace("player")
  local _, classToken = UnitClass("player")

  local d = {
    at = date("%Y-%m-%d %H:%M:%S"),
    addon = ns.VERSION,
    client = { version = version, build = build, buildDate = buildDate, interface = interface },
    player = {
      faction = faction,
      race = raceToken,
      class = classToken,
      level = UnitLevel("player"),
      resting = IsResting() and true or false,
      zone = GetZoneText(),
      subzone = GetSubZoneText(),
      money = GetMoney(),
    },
    portals = {},
    items = {},
    apis = {},
  }
  -- Stored first, so a later error still leaves the partial result in SavedVariables.
  PortaxiDB.diag = d

  local missing = {}
  for _, path in ipairs(APIS) do
    local ok = ns.hasApi(path)
    d.apis[path] = ok
    if not ok then
      missing[#missing + 1] = path
    end
  end

  local bestMap = ns.api("C_Map.GetBestMapForUnit")
  d.player.mapId = bestMap and bestMap("player")

  for _, key in ipairs(C.CITY_ORDER) do
    local city = C.CITY[key]
    if city.faction == faction then
      d.portals[city.name] = spellKnown(city.spell) and true or false
    end
  end
  d.ritualOfSummoning = spellKnown(C.SPELL.RITUAL_OF_SUMMONING) and true or false
  d.items.runeOfPortals = itemCount(C.ITEM.RUNE_OF_PORTALS)
  d.items.soulShard = itemCount(C.ITEM.SOUL_SHARD)
  d.items.scroll = itemCount(C.ITEM.LIMINAL_SCROLL)
  -- The spell the scroll casts, so Ride can recognise it in UNIT_SPELLCAST_* (Const.SPELL.LIMINAL_PASSAGE).
  local itemSpell = ns.api("C_Item.GetItemSpell", "GetItemSpell")
  if itemSpell then
    d.items.scrollSpellName, d.items.scrollSpellId = itemSpell(C.ITEM.LIMINAL_SCROLL)
  end

  say(("client %s (build %s), interface %s"):format(version, build, interface))
  say(("%s %s %s %d · %s%s · resting %s · %s"):format(
    faction or "?", raceToken or "?", classToken or "?", d.player.level,
    d.player.zone, d.player.subzone ~= "" and (" / " .. d.player.subzone) or "",
    yesno(d.player.resting), coins(d.player.money)))
  for _, key in ipairs(C.CITY_ORDER) do
    local city = C.CITY[key]
    if city.faction == faction then
      say(("Portal: %s %s"):format(city.name, yesno(d.portals[city.name])))
    end
  end
  say(("Ritual of Summoning %s · Rune of Portals %d · Soul Shard %d · Scroll of Liminal Passage %d"):format(
    yesno(d.ritualOfSummoning), d.items.runeOfPortals, d.items.soulShard, d.items.scroll))
  -- Forever has no realms; characters have a first name and a surname, unique only together. Record how
  -- each name API reports them for the player and the current target, to build the player key on facts.
  d.names = {}
  local fullName, getUnitName = ns.api("UnitFullName"), ns.api("GetUnitName")
  for _, unit in ipairs({ "player", "target" }) do
    if UnitExists(unit) then
      local n1, n2 = UnitName(unit)
      local f1, f2
      if fullName then
        f1, f2 = fullName(unit)
      end
      d.names[unit] = { unitName = n1, unitName2 = n2, fullName = f1, fullName2 = f2,
        getUnitName = getUnitName and getUnitName(unit, true) or nil }
      say(("Names %s: UnitName %s / %s · UnitFullName %s / %s · GetUnitName %s"):format(unit, tostring(n1),
        tostring(n2), tostring(f1), tostring(f2), tostring(d.names[unit].getUnitName)))
    end
  end
  local realm, normalized = ns.api("GetRealmName"), ns.api("GetNormalizedRealmName")
  d.names.realm = realm and realm() or nil
  d.names.normalizedRealm = normalized and normalized() or nil
  say(("Realm name %s · normalized %s"):format(tostring(d.names.realm), tostring(d.names.normalizedRealm)))
  say(("Scroll spell: %s (%s)"):format(tostring(d.items.scrollSpellName), tostring(d.items.scrollSpellId)))
  say(#missing == 0 and "All listed APIs exist." or ("Not on this client: " .. table.concat(missing, ", ")))
  say("Saved. Type /reload so the results reach the SavedVariables file.")
end

-- Probe log ---------------------------------------------------------------------

local armed = { accept = false, tradeCopper = nil }
local tradeSeenAt = -math.huge

local function log(kind, text)
  PortaxiDB.probe = PortaxiDB.probe or { log = {} }
  local entries = PortaxiDB.probe.log
  entries[#entries + 1] = { at = date("%H:%M:%S"), kind = kind, text = text }
  while #entries > MAX_LOG do
    table.remove(entries, 1)
  end
  say(("[%s] %s"):format(kind, text))
end

-- Runs fn(...) protected and logs the outcome, so one failing API never stops the probe.
local function try(kind, label, fn, ...)
  if type(fn) ~= "function" then
    log(kind, label .. ": API missing")
    return
  end
  local ok, a, b = pcall(fn, ...)
  if ok then
    log(kind, ("%s: ok, returned %s, %s"):format(label, tostring(a), tostring(b)))
  else
    log(kind, ("%s: error %s"):format(label, tostring(a)))
  end
  return ok, a, b
end

local function playerName()
  return (UnitName("player"))
end

-- Probes --------------------------------------------------------------------------

-- 0.3 / 0.4: join the channel and ping it. The server echoes our own channel message back.
-- (A whisper to our own short name is not delivered on Forever; whispers to the sender string work.)
local function netProbe()
  try("net", "RegisterAddonMessagePrefix", C_ChatInfo.RegisterAddonMessagePrefix, C.PREFIX)
  try("net", "JoinTemporaryChannel", JoinTemporaryChannel, C.CHANNEL)
  C_Timer.After(2, function()
    local id = GetChannelName(C.CHANNEL)
    if not id or id == 0 then
      log("net", C.CHANNEL .. " not joined after 2 s")
      return
    end
    local msg = ("PING|1|%s|%s"):format(playerName(), UnitFactionGroup("player") or "?")
    try("net", ("send CHANNEL %d"):format(id), C_ChatInfo.SendAddonMessage, C.PREFIX, msg, "CHANNEL", id)
  end)
end

-- 0.5: invite from a timer.
local function inviteProbe(name)
  if name == "" then
    say("Usage: /ptx invite <name>")
    return
  end
  log("invite", "inviting " .. name .. " in 1 s")
  C_Timer.After(1, function()
    try("invite", "C_PartyInfo.InviteUnit", C_PartyInfo.InviteUnit, name)
  end)
end

-- 0.6: accept the next party invite.
local function acceptProbe()
  armed.accept = true
  log("accept", "armed: the next party invite is accepted automatically")
end

-- 0.7: open trade with the target from a timer.
local function openTradeProbe()
  if not UnitExists("target") or not UnitIsPlayer("target") then
    say("Target the other player first.")
    return
  end
  log("trade", "opening trade with " .. (UnitName("target") or "?") .. " in 1 s")
  C_Timer.After(1, function()
    try("trade", "InitiateTrade", InitiateTrade, "target")
  end)
end

-- 0.8: prefill gold in the next trade window.
local function tradeProbe(args)
  local copper = tonumber(args)
  if not copper or copper <= 0 then
    say("Usage: /ptx trade <copper>   e.g. /ptx trade 100 = 1 silver")
    return
  end
  armed.tradeCopper = math.floor(copper)
  log("trade", "armed: the next trade window gets " .. coins(armed.tradeCopper) .. " prefilled")
end

-- 0.8 fallback: fill the trade window's own money field (MoneyInputFrame_SetCopper) in the next trade.
-- SetTradeMoney is forbidden on Forever (gate G2); this checks whether the Blizzard field path works.
local function tradeFieldProbe(args)
  local copper = tonumber(args)
  if not copper or copper <= 0 then
    say("Usage: /ptx tradefield <copper>   e.g. /ptx tradefield 1")
    return
  end
  armed.fieldCopper = math.floor(copper)
  log("trade", "armed: the next trade window's money field gets " .. coins(armed.fieldCopper))
end

local function showLog()
  local entries = PortaxiDB.probe and PortaxiDB.probe.log or {}
  if #entries == 0 then
    say("Probe log is empty.")
    return
  end
  for i = math.max(1, #entries - 9), #entries do
    local e = entries[i]
    say(("%s [%s] %s"):format(e.at, e.kind, e.text))
  end
end

local function probeCommand(args)
  if args == "clear" then
    PortaxiDB.probe = { log = {} }
    say("Probe log cleared.")
  else
    showLog()
  end
end

ns.commands.diag = { fn = diag, help = "check what the addon can read on this character" }
ns.commands.net = { fn = netProbe, help = "0.3/0.4 join " .. C.CHANNEL .. " and ping it" }
ns.commands.invite = { fn = inviteProbe, args = "<name>", help = "0.5 invite a player from a timer" }
ns.commands.accept = { fn = acceptProbe, help = "0.6 accept the next party invite automatically" }
ns.commands.opentrade = { fn = openTradeProbe, help = "0.7 open trade with your target from a timer" }
ns.commands.trade = { fn = tradeProbe, args = "<copper>",
  help = "0.8 try SetTradeMoney in the next trade (forbidden on Forever, raises a BugSack error)" }
ns.commands.tradefield = { fn = tradeFieldProbe, args = "<copper>",
  help = "0.8 fill the next trade window's money field (MoneyInputFrame_SetCopper)" }
ns.commands.probe = { fn = probeCommand, args = "[clear]", help = "show the last probe results, or clear them" }

-- Game events ------------------------------------------------------------------------

local handlers = {}

function handlers.PLAYER_LOGIN()
  C_ChatInfo.RegisterAddonMessagePrefix(C.PREFIX)
end

-- Only probe traffic (PING/PONG) is logged; protocol messages belong to Net.
function handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
  if prefix ~= C.PREFIX or not (text:find("^PING|") or text:find("^PONG|")) then
    return
  end
  log("net", ("received %s from %s: %s"):format(channel, tostring(sender), text))
  -- Answer pings from other players, so both sides see the round trip and the whisper path.
  if text:find("^PING|") and not ns.sameName(ns.playerKey(sender), ns.selfKey()) then
    local reply = ("PONG|1|%s|%s"):format(playerName(), UnitFactionGroup("player") or "?")
    try("net", "reply WHISPER " .. tostring(ns.playerKey(sender)),
      C_ChatInfo.SendAddonMessage, C.PREFIX, reply, "WHISPER", sender)
  end
end

function handlers.PARTY_INVITE_REQUEST(inviter)
  log("accept", "invite from " .. tostring(inviter))
  if armed.accept then
    armed.accept = false
    C_Timer.After(0.5, function()
      try("accept", "AcceptGroup", AcceptGroup)
      if StaticPopup_Hide then
        StaticPopup_Hide("PARTY_INVITE")
      end
    end)
  end
end

local lastGroupSize = -1
function handlers.GROUP_ROSTER_UPDATE()
  local size = GetNumGroupMembers()
  if size ~= lastGroupSize then
    lastGroupSize = size
    log("group", ("in group: %s, members: %d"):format(tostring(IsInGroup()), size))
  end
end

function handlers.TRADE_SHOW()
  tradeSeenAt = GetTime()
  log("trade", ("window open with %s, my money %s"):format(UnitName("NPC") or "?", coins(GetMoney())))
  local field = armed.fieldCopper
  if field then
    armed.fieldCopper = nil
    C_Timer.After(0.3, function()
      try("trade", "MoneyInputFrame_SetCopper " .. field, ns.api("MoneyInputFrame_SetCopper"),
        TradePlayerInputMoneyFrame, field)
      C_Timer.After(0.5, function()
        log("trade", "field: my offer after 0.5 s " .. coins(GetPlayerTradeMoney()))
      end)
      C_Timer.After(3, function()
        log("trade", "field: my offer after 3 s " .. coins(GetPlayerTradeMoney()))
      end)
    end)
  end
  local copper = armed.tradeCopper
  if copper then
    armed.tradeCopper = nil
    C_Timer.After(0.3, function()
      try("trade", "C_TradeInfo.SetTradeMoney " .. copper, C_TradeInfo and C_TradeInfo.SetTradeMoney, copper)
      C_Timer.After(0.5, function()
        log("trade", "my offer now " .. coins(GetPlayerTradeMoney()))
      end)
    end)
  end
end

function handlers.TRADE_MONEY_CHANGED()
  log("trade", ("money changed: mine %s, theirs %s"):format(
    coins(GetPlayerTradeMoney()), coins(GetTargetTradeMoney())))
end

function handlers.TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted)
  log("trade", ("accept update: me %s, them %s, theirs %s"):format(
    tostring(playerAccepted), tostring(targetAccepted), coins(GetTargetTradeMoney())))
end

function handlers.TRADE_CLOSED()
  log("trade", "window closed, my money " .. coins(GetMoney()))
end

function handlers.UI_INFO_MESSAGE(_, message)
  if GetTime() - tradeSeenAt < TRADE_WATCH_SECONDS then
    log("trade", "info: " .. tostring(message))
  end
end

function handlers.PLAYER_MONEY()
  if GetTime() - tradeSeenAt < TRADE_WATCH_SECONDS then
    log("trade", "money now " .. coins(GetMoney()))
  end
end

local function blocked(addon, func)
  if addon == ADDON then
    log("blocked", "protected call blocked: " .. tostring(func))
  end
end
handlers.ADDON_ACTION_BLOCKED = blocked
handlers.ADDON_ACTION_FORBIDDEN = blocked

local events = CreateFrame("Frame")
for event in pairs(handlers) do
  events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, ...)
  handlers[event](...)
end)
