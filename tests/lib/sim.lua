-- Simulator of N WoW Forever clients on one fake server, for offline multi-player tests.
-- Owned by agent E (playbook §3). Built on tests/lib/wowstub.lua without changing it: every client
-- is one Wow.new(), the server is a set of wow.hooks, and all clients share one clock.
--
--   local Sim = dofile("tests/lib/sim.lua")
--   local sim = Sim.new()                                         -- options below
--   local pok = sim:client("Thalindra")                           -- wowstub defaults: Horde mage in Orgrimmar
--   local vel = sim:client("Velvet", { class = "WARRIOR", zone = "Undercity" })
--   pok:slash("net"); vel:slash("net")                            -- clients are plain wowstub clients
--   sim:advance(3)                                                -- every client's timers, in global time order
--   sim:target(pok, vel) ; sim:click(pok) ; sim:acceptTrade(pok, vel) ; sim:takePortal(vel, "OG")
--
-- Sim.new(opts)
--   opts.factionSplit  false: one channel for both factions (phase 0.4 is unverified);
--                      true: CHANNEL messages only reach clients of the sender's faction
--   opts.castTime      { scroll = 10, portal = 10 } seconds (unverified, adjustable)
--   opts.latency       server delay of messages, invites, party joins, trade money (0.1 s)
--   opts.clock         start clock of every client (1000, as wowstub)
--   opts.scrollSpell   spellID reported for the scroll's cast (default Const.SPELL.LIMINAL_PASSAGE or 0:
--                      the real ID is not known yet)
--
-- Clients
--   sim:client(name, player, loadOpts) -> wow
--       Wow.new with player.name = name, realm "Forever" (player overrides merge into wowstub defaults),
--       server hooks installed, then wow:load(loadOpts). loadOpts.noLoad = true skips loading the addon.
--   sim:clients() -> list in creation order ; sim:byName("Name" or "Name Realm") -> wow|nil
--   sim.Const      Portaxi/Core/Const.lua, loaded once outside any client
--
-- Time
--   sim:advance(seconds)  runs the earliest due timer of any client (ties: scheduling order across
--                         clients), with every client's clock set to that timer's time; repeats; ends with
--                         all clocks at the target. Do not call wow:advance on a single sim client.
--   sim:now() -> the shared clock
--
-- Server (installed through wow.hooks; nothing here is sent before the addon calls the game API)
--   CHANNEL   -> every online client that joined the channel (sender's channel id mapped to its name),
--               the sender included (echo), only the sender's faction when factionSplit; after latency,
--               sender "Name Realm", through wow:receive (unregistered prefixes are not delivered)
--   WHISPER   -> only the client whose "Name Realm" equals the target (a short name is not delivered)
--   other kinds (PARTY, RAID, ...) are not simulated
--   InviteUnit("Name" or "Name Realm") -> target gets wow:inviteFrom(inviterShortName) after latency;
--       not delivered to an unknown/offline player, oneself, another faction or someone already grouped.
--       A blocked invite (wow.blocked) never reaches the hook: wowstub drops it.
--   AcceptGroup -> after latency the accepter and every member of the inviter's group join each other
--       (party list, partyN unit with name/realm/faction/race/class/level, GROUP_ROSTER_UPDATE)
--   C_PartyInfo.LeaveParty -> the others drop the leaver after latency (a group of one disbands)
--   InitiateTrade(unit) -> after 0.2 s both clients get wow:tradeOpenedBy(other) (TRADE_SHOW);
--       not opened with an unknown/offline player, oneself, another faction or a busy trader
--   C_TradeInfo.SetTradeMoney -> after latency the other side's trade.theirs is set, TRADE_MONEY_CHANGED there
--   CancelTrade -> after latency the other side's window closes too (TRADE_CLOSED)
--   Anything not delivered is appended to sim.dropped = { { from, kind, target, msg, reason }, ... }.
--
-- Player actions (what the player does by hand; the addon never does these, D10)
--   sim:target(a, b)              a targets b: a.units.target = b's unit, PLAYER_TARGET_CHANGED
--   sim:acceptTrade(a, b) -> bool both accept the open trade between a and b: each side's offer moves
--                                 exactly (trade.mine of one = trade.theirs of the other),
--                                 TRADE_ACCEPT_UPDATE (a first), then wowstub tradeComplete on both
--   sim:click(c, buttonName) -> click, result
--       Clicks the button (default Const.SECURE_BUTTON) in c's env with :Click(). If it recorded a secure
--       click, the game's response is simulated; result is "cast" or why nothing happened ("ignored",
--       "busy", "no partner", "partner not resting", "no scroll", "spell not known", "no rune", ...):
--       * type "item", item Const.ITEM.LIMINAL_SCROLL, unit "party1": the scroll. UNIT_SPELLCAST_START on
--         the caster ("player") and on every party member (as "partyN"), UnitCastingInfo set meanwhile;
--         after castTime.scroll UNIT_SPELLCAST_SUCCEEDED on the same, one scroll used (BAG_UPDATE_DELAYED),
--         the caster takes party1's zone/subzone/mapId/resting, both see each other as near
--         (CheckInteractDistance), ZONE_CHANGED_NEW_AREA on the caster (ZONE_CHANGED if the zone is the same)
--       * type "spell", spell = a portal of Const.CITY: the same cast events with castTime.portal, one rune
--         used, then a portal to that city is open for Const.T.PORTAL s where the caster stands
--       * anything else: recorded in sim.clicks, nothing happens
--       Event args follow WoW: UNIT_SPELLCAST_*(unitTarget, castGUID, spellID).
--   sim:interrupt(c) -> bool      breaks c's cast: UNIT_SPELLCAST_INTERRUPTED instead of SUCCEEDED
--   sim:takePortal(c, cityKey)    c walks into an open portal (error if none): c must be the caster or in
--                                 the caster's group and in the portal's zone. Zone becomes the city,
--                                 resting, near flags cleared, ZONE_CHANGED_NEW_AREA
--   sim:logout(c)                 c goes silent: timers cancelled, nothing delivered to it, its cast and
--                                 trade end; group members keep it as offline (UnitIsConnected false,
--                                 UNIT_CONNECTION, GROUP_ROSTER_UPDATE), as the game keeps offline members
--
-- Unverified game behaviour reproduced here (fix at G-final): cast times, the scroll's spellID and its
-- "partner must be resting" rule, TRADE_ACCEPT_UPDATE order, portal use limited to the group,
-- uiMapIDs of the capitals, latency values.

local Wow = dofile("tests/lib/wowstub.lua")

local Sim = {}
Sim.__index = Sim

local REALM = "Forever"
local TRADE_OPEN_DELAY = 0.2
-- Timers due within this of the target run too, so 0.05 + 0.05 reaches a timer due in 0.1 s.
local EPSILON = 1e-6

-- uiMapIDs of the capitals (modern client numbering, unverified on Forever except Orgrimmar 1454).
local CITY_MAP = { OG = 1454, UC = 1458, TB = 1456, SW = 1453, IF = 1455, DN = 1457 }

local function loadConst()
  local chunk = assert(loadfile("Portaxi/Core/Const.lua"))
  local ns = {}
  chunk("Portaxi", ns)
  return ns.Const
end

function Sim.new(opts)
  opts = opts or {}
  local castTime = opts.castTime or {}
  local self = setmetatable({
    Const = loadConst(),
    factionSplit = opts.factionSplit == true,
    castTime = { scroll = castTime.scroll or 10, portal = castTime.portal or 10 },
    latency = opts.latency or 0.1,
    clock = opts.clock or 1000,
    list = {},       -- clients in creation order
    named = {},      -- "Name" -> client
    full = {},       -- "Name Realm" -> client
    online = {},     -- client -> true
    seq = 0,         -- global timer sequence, tie-break across clients
    castSeq = 0,
    casts = {},      -- client -> current cast
    portals = {},    -- { caster, city, zone, expires }
    dropped = {},
    clicks = {},
  }, Sim)
  self.scrollSpell = opts.scrollSpell or self.Const.SPELL.LIMINAL_PASSAGE or 0
  return self
end

function Sim:now()
  return self.clock
end

function Sim:clients()
  local out = {}
  for i, c in ipairs(self.list) do out[i] = c end
  return out
end

function Sim:byName(name)
  if type(name) ~= "string" then return nil end
  return self.named[name] or self.full[name]
end

local function drop(sim, from, kind, target, msg, reason)
  sim.dropped[#sim.dropped + 1] = {
    from = from.player.name, kind = kind, target = target, msg = msg, reason = reason,
  }
end

-- Units and the group ---------------------------------------------------------------

local function unitOf(c)
  local p = c.player
  return {
    name = p.name, realm = p.realm, faction = p.faction, race = p.race, class = p.class, level = p.level,
    isPlayer = true,
  }
end

-- The unit token under which viewer sees subject: "player", "partyN" or nil.
local function tokenOf(viewer, subject)
  if viewer == subject then return "player" end
  for i, name in ipairs(viewer.party) do
    if name == subject.player.name then return "party" .. i end
  end
end

local function addMember(c, other)
  if tokenOf(c, other) then return end
  c.party[#c.party + 1] = other.player.name
  c.units["party" .. #c.party] = unitOf(other)
  c:fire("GROUP_ROSTER_UPDATE")
end

local function removeMember(c, name)
  local names, units = {}, {}
  for i, n in ipairs(c.party) do
    if n ~= name then
      names[#names + 1] = n
      units[#units + 1] = c.units["party" .. i]
    end
  end
  if #names == #c.party then return end
  c.party = names
  for i = 1, 4 do c.units["party" .. i] = units[i] end
  c:fire("GROUP_ROSTER_UPDATE")
end

-- The online clients of c's group, c excluded.
local function members(sim, c)
  local out = {}
  for _, name in ipairs(c.party) do
    local m = sim.named[name]
    if m and sim.online[m] then out[#out + 1] = m end
  end
  return out
end

local function setNear(a, b, near)
  local ta, tb = tokenOf(a, b), tokenOf(b, a)
  if ta and ta ~= "player" then a.units[ta].near = near end
  if tb and tb ~= "player" then b.units[tb].near = near end
end

local function clearNear(sim, c)
  for _, m in ipairs(members(sim, c)) do setNear(c, m, false) end
end

-- Server hooks ------------------------------------------------------------------------

local function later(sim, c, delay, fn)
  c:later(delay, function()
    if sim.online[c] then fn() end
  end)
end

local function route(sim, from, entry)
  local sender = from:fullName()
  local function deliver(to)
    later(sim, to, sim.latency, function() to:receive(entry.prefix, entry.msg, entry.kind, sender) end)
  end
  if entry.kind == "CHANNEL" then
    local channel
    for name, id in pairs(from.channels) do
      if tostring(id) == tostring(entry.target) then channel = name end
    end
    if not channel then
      return drop(sim, from, entry.kind, entry.target, entry.msg, "sender is not in that channel")
    end
    for _, to in ipairs(sim.list) do
      if sim.online[to] and to.channels[channel]
        and (not sim.factionSplit or to.player.faction == from.player.faction) then
        deliver(to)
      end
    end
  elseif entry.kind == "WHISPER" then
    local to = sim.full[entry.target]
    if to and sim.online[to] then
      deliver(to)
    else
      drop(sim, from, entry.kind, entry.target, entry.msg, "no online player with that \"Name Realm\"")
    end
  else
    drop(sim, from, entry.kind, entry.target, entry.msg, "kind not simulated")
  end
end

local function invite(sim, from, name)
  local to = sim:byName(name)
  local why
  if not to or not sim.online[to] then
    why = "no online player"
  elseif to == from then
    why = "cannot invite oneself"
  elseif to.player.faction ~= from.player.faction then
    why = "other faction"
  elseif #to.party > 0 then
    why = "already in a group"
  end
  if why then return drop(sim, from, "INVITE", name, nil, why) end
  later(sim, to, sim.latency, function() to:inviteFrom(from.player.name) end)
end

local function accept(sim, accepter, inviterName)
  local inviter = sim:byName(inviterName)
  if not inviter or not sim.online[inviter] then
    return drop(sim, accepter, "ACCEPT", inviterName, nil, "inviter is offline")
  end
  later(sim, accepter, sim.latency, function()
    local group = members(sim, inviter)
    table.insert(group, 1, inviter)
    for _, m in ipairs(group) do
      addMember(accepter, m)
      addMember(m, accepter)
    end
  end)
end

local function openTrade(sim, from, name)
  local to = sim:byName(name)
  local why
  if not to or not sim.online[to] then
    why = "no online player"
  elseif to == from then
    why = "cannot trade with oneself"
  elseif to.player.faction ~= from.player.faction then
    why = "other faction"
  elseif to.trade or from.trade then
    why = "busy"
  end
  if why then return drop(sim, from, "TRADE", name, nil, why) end
  later(sim, from, TRADE_OPEN_DELAY, function()
    if not sim.online[to] or to.trade or from.trade then return end
    from:tradeOpenedBy(to.player.name)
    to:tradeOpenedBy(from.player.name)
  end)
end

local function tradeMoney(sim, from, copper)
  local other = from.trade and sim.named[from.trade.with]
  if not other then return end
  later(sim, other, sim.latency, function()
    if other.trade and other.trade.with == from.player.name then other:tradeTheirMoney(copper) end
  end)
end

-- Per-client additions: the server side of leaving a group or closing a trade, and UnitIsConnected.
local function wrapEnv(sim, c)
  local env = c.env
  local leave = env.C_PartyInfo.LeaveParty
  env.C_PartyInfo.LeaveParty = function(...)
    local group = members(sim, c)
    leave(...)
    for _, m in ipairs(group) do
      later(sim, m, sim.latency, function() removeMember(m, c.player.name) end)
    end
  end
  local cancel = env.CancelTrade
  env.CancelTrade = function(...)
    local other = c.trade and sim.named[c.trade.with]
    cancel(...)
    if other then
      later(sim, other, sim.latency, function()
        if other.trade and other.trade.with == c.player.name then
          other.trade = nil
          other:fire("TRADE_CLOSED")
        end
      end)
    end
  end
  -- Missing in wowstub (request for the architect); party members of a logged-out client are offline.
  env.UnitIsConnected = function(token)
    local u = c.units[token]
    return u ~= nil and not u.offline
  end
end

function Sim:client(name, player, loadOpts)
  assert(type(name) == "string" and not name:find("[%s%-]"), "client name must be a short name")
  local p = {}
  for k, v in pairs(player or {}) do p[k] = v end
  p.name = name
  p.realm = p.realm or REALM
  local c = Wow.new({ player = p, clock = self.clock })
  local key = c:fullName()
  assert(not self.named[name] and not self.full[key], "duplicate client " .. key)

  local sim = self
  -- Every timer gets a global sequence number, so equal due times run in scheduling order across clients.
  local baseLater = c.later
  c.later = function(wow, seconds, fn)
    local t = baseLater(wow, seconds, fn)
    sim.seq = sim.seq + 1
    t.gseq = sim.seq
    return t
  end
  c.hooks.send = function(from, entry) route(sim, from, entry) end
  c.hooks.invite = function(from, target) invite(sim, from, target) end
  c.hooks.accept = function(from, inviterName) accept(sim, from, inviterName) end
  c.hooks.initiateTrade = function(from, target) openTrade(sim, from, target) end
  c.hooks.tradeMoney = function(from, copper) tradeMoney(sim, from, copper) end
  wrapEnv(sim, c)

  self.list[#self.list + 1] = c
  self.named[name] = c
  self.full[key] = c
  self.online[c] = true
  if not (loadOpts and loadOpts.noLoad) then
    c:load(loadOpts)
  end
  return c
end

-- Time ----------------------------------------------------------------------------------

function Sim:advance(seconds)
  local target = self.clock + (seconds or 0)
  while true do
    local owner, index, best
    for _, c in ipairs(self.list) do
      if self.online[c] then
        for i, t in ipairs(c.timers) do
          if not t.cancelled and t.due <= target + EPSILON
            and (not best or t.due < best.due or (t.due == best.due and (t.gseq or 0) < (best.gseq or 0))) then
            owner, index, best = c, i, t
          end
        end
      end
    end
    if not best then break end
    table.remove(owner.timers, index)
    if best.due > self.clock then self.clock = best.due end
    for _, c in ipairs(self.list) do
      if self.online[c] then c.clock = self.clock end
    end
    best.fn()
  end
  self.clock = target
  for _, c in ipairs(self.list) do
    if self.online[c] then
      c.clock = target
      for i = #c.timers, 1, -1 do
        if c.timers[i].cancelled then table.remove(c.timers, i) end
      end
    end
  end
end

-- Player actions ------------------------------------------------------------------------

function Sim:target(a, b)
  a.units.target = unitOf(b)
  a:fire("PLAYER_TARGET_CHANGED")
end

function Sim:acceptTrade(a, b)
  local ta, tb = a.trade, b.trade
  if not (ta and tb and ta.with == b.player.name and tb.with == a.player.name) then
    error(("no open trade between %s and %s"):format(a.player.name, b.player.name), 2)
  end
  if ta.mine > a.player.money or tb.mine > b.player.money then
    error("a trade offer exceeds the player's money", 2)
  end
  ta.theirs, tb.theirs = tb.mine, ta.mine
  a:fire("TRADE_ACCEPT_UPDATE", 1, 0)
  b:fire("TRADE_ACCEPT_UPDATE", 0, 1)
  if a.trade ~= ta or b.trade ~= tb then return false end -- a handler closed the window
  a:tradeComplete()
  b:tradeComplete()
  return true
end

-- Casting --------------------------------------------------------------------------------

-- Fires event on the caster and on every online group member, each with its own unit token.
local function castEvent(sim, caster, event, cast)
  local seen = { { caster, "player" } }
  for _, m in ipairs(members(sim, caster)) do
    local token = tokenOf(m, caster)
    if token then seen[#seen + 1] = { m, token } end
  end
  for _, s in ipairs(seen) do
    local c, token = s[1], s[2]
    local u = c.units[token]
    if event == "UNIT_SPELLCAST_START" then
      u.casting = cast.info
    elseif u.casting == cast.info then
      u.casting = nil
    end
    c:fire(event, token, cast.guid, cast.spellId)
  end
end

local function finishCast(sim, caster, event)
  local cast = sim.casts[caster]
  if not cast then return nil end
  sim.casts[caster] = nil
  cast.timer.cancelled = true
  castEvent(sim, caster, event, cast)
  -- Units that saw the start but are no longer in the group still drop the cast bar.
  for _, c in ipairs(sim.list) do
    for _, u in pairs(c.units) do
      if u.casting == cast.info then u.casting = nil end
    end
  end
  return cast
end

local function startCast(sim, caster, spellId, name, duration, onSuccess)
  sim.castSeq = sim.castSeq + 1
  local now = sim.clock
  local guid = ("Cast-3-0-0-0-%d-%010d"):format(spellId, sim.castSeq)
  local cast = {
    guid = guid, spellId = spellId,
    info = {
      name = name, icon = 100000 + spellId, startMs = now * 1000, endMs = (now + duration) * 1000,
      castId = guid, spellId = spellId,
    },
  }
  sim.casts[caster] = cast
  cast.timer = caster:later(duration, function()
    if sim.casts[caster] ~= cast then return end
    finishCast(sim, caster, "UNIT_SPELLCAST_SUCCEEDED")
    onSuccess()
  end)
  castEvent(sim, caster, "UNIT_SPELLCAST_START", cast)
end

local function useItem(c, id)
  c:setItem(id, (c.player.items[id] or 0) - 1)
end

local function moveTo(c, zone, subzone, mapId, resting)
  local p = c.player
  local changed = p.zone ~= zone
  p.zone, p.subzone, p.mapId = zone, subzone or "", mapId or p.mapId
  c:fire(changed and "ZONE_CHANGED_NEW_AREA" or "ZONE_CHANGED")
  if resting ~= nil and p.resting ~= resting then
    p.resting = resting
    c:fire("PLAYER_UPDATE_RESTING")
  end
end

local function scroll(sim, c, id)
  local u = c.units.party1
  local partner = u and sim.named[u.name]
  if not partner or not sim.online[partner] then return "no partner" end
  if not partner.player.resting then return "partner not resting" end
  if (c.player.items[id] or 0) < 1 then return "no scroll" end
  startCast(sim, c, sim.scrollSpell, "Scroll of Liminal Passage", sim.castTime.scroll, function()
    useItem(c, id)
    if not sim.online[partner] then return end
    clearNear(sim, c)
    local q = partner.player
    moveTo(c, q.zone, q.subzone, q.mapId, q.resting)
    setNear(c, partner, true)
  end)
  return "cast"
end

local function portal(sim, c, key, spellId)
  local C = sim.Const
  if not c.player.spells[spellId] then return "spell not known" end
  if (c.player.items[C.ITEM.RUNE_OF_PORTALS] or 0) < 1 then return "no rune" end
  startCast(sim, c, spellId, "Portal: " .. C.CITY[key].name, sim.castTime.portal, function()
    useItem(c, C.ITEM.RUNE_OF_PORTALS)
    sim.portals[#sim.portals + 1] = { caster = c, city = key, zone = c.player.zone, expires = sim.clock + C.T.PORTAL }
  end)
  return "cast"
end

local function perform(sim, c, click)
  local C = sim.Const
  if sim.casts[c] then return "busy" end
  if click.type == "item" then
    local id = tonumber(click.item) or tonumber(tostring(click.item):match("item:(%d+)"))
    if id == C.ITEM.LIMINAL_SCROLL and click.unit == "party1" then
      return scroll(sim, c, id)
    end
  elseif click.type == "spell" then
    local id = tonumber(click.spell)
    for _, key in ipairs(C.CITY_ORDER) do
      if C.CITY[key].spell == id then return portal(sim, c, key, id) end
    end
  end
  return "ignored"
end

function Sim:click(c, buttonName)
  local name = buttonName or self.Const.SECURE_BUTTON
  local button = c.env[name]
  if not button then
    error(("%s has no button %s"):format(c.player.name, name), 2)
  end
  local before = #c.secureClicks
  button:Click("LeftButton")
  local click = c.secureClicks[before + 1]
  if not click then return nil, "not a secure action button" end
  local result = perform(self, c, click)
  self.clicks[#self.clicks + 1] = { client = c.player.name, click = click, result = result }
  return click, result
end

function Sim:interrupt(c)
  return finishCast(self, c, "UNIT_SPELLCAST_INTERRUPTED") ~= nil
end

local function inGroupWith(c, other)
  return c == other or tokenOf(c, other) ~= nil
end

function Sim:takePortal(c, key)
  local city = self.Const.CITY[key]
  local found
  for _, p in ipairs(self.portals) do
    if p.city == key and self.clock < p.expires and inGroupWith(c, p.caster) and c.player.zone == p.zone then
      found = p
    end
  end
  if not city or not found then
    error(("%s: no open portal to %s here"):format(c.player.name, tostring(key)), 2)
  end
  clearNear(self, c)
  moveTo(c, city.name, "", CITY_MAP[key], true)
end

function Sim:logout(c)
  if not self.online[c] then return end
  local cast = self.casts[c]
  if cast then
    self.casts[c] = nil
    for _, other in ipairs(self.list) do
      for _, u in pairs(other.units) do
        if u.casting == cast.info then u.casting = nil end
      end
    end
  end
  self.online[c] = nil
  for _, t in ipairs(c.timers) do t.cancelled = true end
  c.timers = {}
  for _, other in ipairs(self.list) do
    if self.online[other] then
      if other.trade and other.trade.with == c.player.name then
        other.trade = nil
        other:fire("TRADE_CLOSED")
      end
      local token = tokenOf(other, c)
      if token then
        other.units[token].offline = true
        other.units[token].near = false
        other:fire("UNIT_CONNECTION", token, false)
        other:fire("GROUP_ROSTER_UPDATE")
      end
    end
  end
end

return Sim
