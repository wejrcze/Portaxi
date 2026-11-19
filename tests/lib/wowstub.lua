-- Fake WoW Forever client for offline tests. Owned by the architect (playbook §3).
-- Agents: if you need an API that is missing here, define it in your own test file
-- (wow.env.SomeApi = function() ... end) and list it under "Requests for the architect".
--
--   local Wow = dofile("tests/lib/wowstub.lua")
--   local wow = Wow.new({ player = { level = 50 } })   -- overrides merge into the defaults
--   wow:load()                  -- loads Portaxi/Portaxi.toc, fires ADDON_LOADED + PLAYER_LOGIN
--   wow:slash("diag")           -- runs "/ptx diag"
--   wow:advance(2)              -- moves the clock, runs due C_Timer callbacks
--   wow:fire("PLAYER_UPDATE_RESTING")
--   wow.ns, wow.env, wow.player, wow.printed, wow.sent, wow.calls, wow.raidWarnings
--
-- Behaviour verified on Forever (2026-11-18) and reproduced here:
--   * Forever has no realms: a character has a first name and a surname, unique only together. The
--     stub keeps the surname in the field called `realm` (player.realm, units[...].realm).
--   * senders of addon messages arrive as "First Surname" (space); Ambiguate does not strip it
--   * a CHANNEL message is echoed back to the sender
--   * a WHISPER to your own short name is not delivered; to "Name Realm" it is
-- Unverified behaviour can be switched for tests of both branches (playbook D11):
--   wow.blocked["C_PartyInfo.InviteUnit"] = true  -> call is dropped, ADDON_ACTION_BLOCKED fires
-- Calls the addon must never make (playbook D10) raise an error: see FORBIDDEN.
-- Single-client defaults: wow.hooks.send / invite / initiateTrade are replaced by tests/lib/sim.lua.

local Wow = {}
Wow.__index = Wow

local ADDON = "Portaxi"
local ROOT = "Portaxi"

local FORBIDDEN = {
  "AcceptTrade", "CastSpell", "CastSpellByID", "CastSpellByName", "UseItemByName",
  "C_Container.UseContainerItem", "PickupContainerItem", "C_Container.PickupContainerItem",
}

local function merge(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function defaultPlayer()
  return {
    name = "Thalindra",
    realm = "Forever",
    faction = "Horde",
    race = "Orc",
    class = "MAGE",
    level = 40,
    resting = true,
    zone = "Orgrimmar",
    subzone = "",
    mapId = 1454,
    money = 455723,
    spells = { [11417] = true, [11418] = true },
    items = { [17032] = 7, [213548] = 9 },
  }
end

-- Fake widgets ------------------------------------------------------------------------

local function noop() end

local Widget = {}
local widgetMeta = {
  __index = function(_, key)
    if Widget[key] then
      return Widget[key]
    end
    if type(key) == "string" and key:sub(1, 2) == "__" then
      return nil -- internal state that was never set
    end
    return noop -- unknown widget methods are harmless no-ops
  end,
}

local function newWidget(wow, kind, name, parent, template)
  local w = setmetatable({
    __wow = wow, __kind = kind, __name = name, __parent = parent, __template = template or "",
    __shown = true, __scripts = {}, __events = {}, __attrs = {}, __text = nil,
  }, widgetMeta)
  if name then
    wow.env[name] = w
  end
  wow.frames[#wow.frames + 1] = w
  return w
end

function Widget:GetName() return self.__name end
function Widget:GetObjectType() return self.__kind end
function Widget:GetParent() return self.__parent end
function Widget:SetParent(p) self.__parent = p end
-- Events the Forever client does not know (verified in game); registering one raises, as in game.
local UNKNOWN_EVENTS = {
  LEARNED_SPELL_IN_TAB = true, -- BugGrabber 2026-11-18
}
local function checkEvent(e)
  if UNKNOWN_EVENTS[e] then
    error(('Frame:RegisterEvent(): Attempt to register unknown event "%s"'):format(e), 3)
  end
end
function Widget:RegisterEvent(e) checkEvent(e); self.__events[e] = true end
function Widget:RegisterUnitEvent(e) checkEvent(e); self.__events[e] = true end
function Widget:UnregisterEvent(e) self.__events[e] = nil end
function Widget:UnregisterAllEvents() self.__events = {} end
function Widget:IsEventRegistered(e) return self.__events[e] == true end
function Widget:SetScript(kind, fn) self.__scripts[kind] = fn end
function Widget:GetScript(kind) return self.__scripts[kind] end
function Widget:HookScript(kind, fn)
  local old = self.__scripts[kind]
  self.__scripts[kind] = function(...)
    if old then old(...) end
    fn(...)
  end
end
function Widget:Show()
  if not self.__shown then
    self.__shown = true
    if self.__scripts.OnShow then self.__scripts.OnShow(self) end
  end
end
function Widget:Hide()
  if self.__shown then
    self.__shown = false
    if self.__scripts.OnHide then self.__scripts.OnHide(self) end
  end
end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown() return self.__shown end
function Widget:IsVisible()
  local w = self
  while w do
    if not w.__shown then return false end
    w = w.__parent
  end
  return true
end
function Widget:SetText(t) self.__text = t end
function Widget:GetText() return self.__text end
function Widget:SetFormattedText(fmt, ...) self.__text = fmt:format(...) end
function Widget:SetAttribute(k, v)
  if self.__template:find("Secure") and self.__wow.combat then
    error("SetAttribute on a secure frame during combat lockdown", 2)
  end
  self.__attrs[k] = v
end
function Widget:GetAttribute(k) return self.__attrs[k] end
function Widget:SetDesaturated(v) self.__desaturated = v and true or false end
function Widget:IsDesaturated() return self.__desaturated == true end
function Widget:SetTexture(t) self.__texture = t end
function Widget:GetTexture() return self.__texture end
function Widget:Enable() self.__disabled = false end
function Widget:Disable() self.__disabled = true end
function Widget:SetEnabled(v) self.__disabled = not v end
function Widget:IsEnabled() return not self.__disabled end
function Widget:SetChecked(v) self.__checked = v and true or false end
function Widget:GetChecked() return self.__checked == true end
function Widget:CreateTexture(name) return newWidget(self.__wow, "Texture", name, self) end
function Widget:CreateFontString(name) return newWidget(self.__wow, "FontString", name, self) end
function Widget:CreateAnimationGroup() return newWidget(self.__wow, "AnimationGroup", nil, self) end
function Widget:GetWidth() return self.__w or 0 end
function Widget:GetHeight() return self.__h or 0 end
function Widget:SetSize(w, h) self.__w, self.__h = w, h end
function Widget:SetWidth(w) self.__w = w end
function Widget:SetHeight(h) self.__h = h end
function Widget:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Widget:GetCenter() return 0, 0 end
function Widget:GetEffectiveScale() return 1 end
function Widget:GetScale() return 1 end
-- Simulates the player's click. As in game: PreClick, then the secure action (recorded with the
-- attributes PreClick may have changed), then OnClick and PostClick.
function Widget:Click(button)
  button = button or "LeftButton"
  if self.__scripts.PreClick then self.__scripts.PreClick(self, button, false) end
  if self.__template:find("SecureActionButtonTemplate") then
    local a = self.__attrs
    local click = { type = a.type, spell = a.spell, item = a.item, unit = a.unit, macrotext = a.macrotext }
    self.__wow.secureClicks[#self.__wow.secureClicks + 1] = click
    self.__wow:record("SecureClick", click)
  end
  if self.__scripts.OnClick then self.__scripts.OnClick(self, button, false) end
  if self.__scripts.PostClick then self.__scripts.PostClick(self, button, false) end
end

-- Client --------------------------------------------------------------------------------

function Wow.new(opts)
  opts = opts or {}
  local wow = setmetatable({
    clock = opts.clock or 1000,
    player = merge(defaultPlayer(), opts.player),
    units = {},          -- unit token -> { name, realm, faction, class, level, isPlayer }
    party = {},          -- names of the other party members
    frames = {},
    timers = {},
    timerSeq = 0,
    printed = {},
    sent = {},           -- every SendAddonMessage { prefix, msg, kind, target }
    calls = {},          -- side-effect API calls { fn, args }
    errors = {},
    raidWarnings = {},
    secureClicks = {},
    prefixes = {},
    channels = {},
    nextChannelId = 6,
    combat = false,
    trade = nil,         -- { with, mine, theirs }
    pendingInviter = nil,
    blocked = opts.blocked or {},
    hooks = {},
  }, Wow)
  wow.units.player = wow.player
  wow:buildEnv()
  return wow
end

function Wow:fullName()
  return self.player.name .. " " .. self.player.realm
end

function Wow:record(fn, ...)
  self.calls[#self.calls + 1] = { fn = fn, args = { ... } }
end

function Wow:callsTo(fn)
  local out = {}
  for _, c in ipairs(self.calls) do
    if c.fn == fn then out[#out + 1] = c end
  end
  return out
end

-- Events and time ------------------------------------------------------------------------

-- Fires a game event on every frame registered for it, in creation order. Errors propagate.
function Wow:fire(event, ...)
  local snapshot = { unpack(self.frames) }
  for _, f in ipairs(snapshot) do
    if f.__events[event] and f.__scripts.OnEvent then
      f.__scripts.OnEvent(f, event, ...)
    end
  end
end

function Wow:later(seconds, fn)
  self.timerSeq = self.timerSeq + 1
  local t = { due = self.clock + (seconds or 0), seq = self.timerSeq, fn = fn }
  self.timers[#self.timers + 1] = t
  return t
end

-- Advances the clock, running due timers in order (timers scheduled meanwhile run too).
function Wow:advance(seconds)
  local target = self.clock + (seconds or 0)
  while true do
    local nextIndex
    for i, t in ipairs(self.timers) do
      if not t.cancelled and t.due <= target then
        local n = nextIndex and self.timers[nextIndex]
        if not n or t.due < n.due or (t.due == n.due and t.seq < n.seq) then
          nextIndex = i
        end
      end
    end
    if not nextIndex then break end
    local t = table.remove(self.timers, nextIndex)
    if t.due > self.clock then self.clock = t.due end
    t.fn()
  end
  self.clock = target
  for i = #self.timers, 1, -1 do
    if self.timers[i].cancelled then table.remove(self.timers, i) end
  end
end

-- Player-side helpers ----------------------------------------------------------------------

function Wow:slash(text)
  self.env.SlashCmdList.PORTAXI(text or "")
end

function Wow:setCombat(on)
  self.combat = on and true or false
  self:fire(on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

function Wow:setResting(on)
  self.player.resting = on and true or false
  self:fire("PLAYER_UPDATE_RESTING")
end

function Wow:setItem(id, count)
  self.player.items[id] = count
  self:fire("BAG_UPDATE_DELAYED")
end

function Wow:setMoney(copper)
  self.player.money = copper
  self:fire("PLAYER_MONEY")
end

-- Delivers an addon message to this client (only when the prefix is registered, as in game).
function Wow:receive(prefix, text, kind, sender)
  if self.prefixes[prefix] then
    self:fire("CHAT_MSG_ADDON", prefix, text, kind, sender)
  end
end

-- Someone invites this player.
function Wow:inviteFrom(name)
  self.pendingInviter = name
  self:fire("PARTY_INVITE_REQUEST", name)
end

-- unit (optional): the member's unit record, e.g. { faction, race, class, level }.
function Wow:joinParty(name, unit)
  self.party[#self.party + 1] = name
  local u = unit or {}
  u.name, u.realm, u.isPlayer = name, u.realm or self.player.realm, true
  self.units["party" .. #self.party] = u
  self:fire("GROUP_ROSTER_UPDATE")
end

-- Trade helpers: the other side opens / sets money / both accept.
function Wow:tradeOpenedBy(name)
  self.trade = { with = name, mine = 0, theirs = 0 }
  self.units.NPC = { name = name, realm = self.player.realm, isPlayer = true }
  self:fire("TRADE_SHOW")
end

function Wow:tradeTheirMoney(copper)
  self.trade.theirs = copper
  self:fire("TRADE_MONEY_CHANGED")
end

function Wow:tradeComplete()
  local t = self.trade
  self.player.money = self.player.money - t.mine + t.theirs
  self.trade = nil
  self:fire("UI_INFO_MESSAGE", 0, "Trade complete.")
  self:fire("TRADE_CLOSED")
  self:fire("PLAYER_MONEY")
end

-- Loading the addon -------------------------------------------------------------------------

function Wow:tocFiles(root)
  local files = {}
  for line in io.lines((root or ROOT) .. "/Portaxi.toc") do
    line = line:gsub("%s+$", "")
    if line ~= "" and not line:find("^#") then
      files[#files + 1] = line
    end
  end
  return files
end

-- Loads every TOC file into this client's environment; opts.saved preloads SavedVariables.
function Wow:load(opts)
  opts = opts or {}
  self.ns = {}
  for k, v in pairs(opts.saved or {}) do
    self.env[k] = v
  end
  for _, file in ipairs(self:tocFiles(opts.root)) do
    local chunk = assert(loadfile((opts.root or ROOT) .. "/" .. file))
    setfenv(chunk, self.env)
    chunk(ADDON, self.ns)
  end
  if not opts.noLogin then
    self:fire("ADDON_LOADED", ADDON)
    self:fire("PLAYER_LOGIN")
    self:fire("PLAYER_ENTERING_WORLD", true, false)
  end
  return self
end

-- Environment ---------------------------------------------------------------------------------

local STD = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset", "select",
  "setmetatable", "getmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "loadstring",
  "string", "table", "math", "coroutine",
}

function Wow:buildEnv()
  local wow = self
  local base = {}
  for _, name in ipairs(STD) do
    base[name] = _G[name]
  end
  -- WoW's Lua aliases.
  base.format, base.strlen, base.strsub, base.strfind, base.strmatch, base.gsub, base.strlower, base.strupper =
    string.format, string.len, string.sub, string.find, string.match, string.gsub, string.lower, string.upper
  base.tinsert, base.tremove, base.sort = table.insert, table.remove, table.sort
  base.floor, base.ceil, base.abs, base.max, base.min, base.random =
    math.floor, math.ceil, math.abs, math.max, math.min, math.random
  base.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  base.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  base.strsplit = function(sep, s, limit)
    local out, start = {}, 1
    while true do
      if limit and #out == limit - 1 then break end
      local i = s:find(sep, start, true)
      if not i then break end
      out[#out + 1] = s:sub(start, i - 1)
      start = i + #sep
    end
    out[#out + 1] = s:sub(start)
    return unpack(out)
  end
  base.strjoin = function(sep, ...) return table.concat({ ... }, sep) end

  local env = setmetatable({}, { __index = base })
  env._G = env
  self.env = env

  -- wow.blocked[name] = true -> ADDON_ACTION_BLOCKED naming the function; = "forbidden" -> as seen on
  -- Forever at G2: ADDON_ACTION_FORBIDDEN with the function reported as "UNKNOWN()".
  local function protected(name, fn)
    return function(...)
      local mode = wow.blocked[name]
      if mode then
        wow:record(name .. ":blocked", ...)
        if mode == "forbidden" then
          wow:fire("ADDON_ACTION_FORBIDDEN", ADDON, "UNKNOWN()")
        else
          wow:fire("ADDON_ACTION_BLOCKED", ADDON, name .. "()")
        end
        return nil
      end
      return fn(...)
    end
  end

  local function unit(token)
    return wow.units[token]
  end

  -- Output and errors
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    wow.printed[#wow.printed + 1] = table.concat(parts, " ")
  end
  env.geterrorhandler = function()
    return function(err) wow.errors[#wow.errors + 1] = err end
  end
  env.date = os.date
  env.time = function() return 1795000000 + math.floor(wow.clock) end
  env.GetTime = function() return wow.clock end
  env.GetBuildInfo = function() return "1.60.1", "70959", "Nov 13 2026", 16001 end
  env.hooksecurefunc = function(...) wow:record("hooksecurefunc", ...) end

  -- Frames
  env.CreateFrame = function(kind, name, parent, template)
    return newWidget(wow, kind or "Frame", name, parent, template)
  end
  env.UIParent = newWidget(wow, "Frame", "UIParent")
  env.Minimap = newWidget(wow, "Minimap", "Minimap", env.UIParent)
  env.GameTooltip = newWidget(wow, "GameTooltip", "GameTooltip", env.UIParent)
  env.RaidWarningFrame = newWidget(wow, "Frame", "RaidWarningFrame", env.UIParent)
  env.GetCursorPosition = function() return 0, 0 end
  env.GetScreenWidth = function() return 1920 end
  env.GetScreenHeight = function() return 1080 end
  env.InCombatLockdown = function() return wow.combat end
  env.UISpecialFrames = {}
  env.IsShiftKeyDown = function() return wow.shift == true end
  env.IsControlKeyDown = function() return wow.ctrl == true end
  env.ChatTypeInfo = { RAID_WARNING = { r = 1, g = 0.28, b = 0 } }
  env.SOUNDKIT = { RAID_WARNING = 8959, IG_MAINMENU_OPEN = 850, IG_MAINMENU_CLOSE = 851 }
  env.PlaySound = function(id) wow:record("PlaySound", id) end
  env.RaidNotice_AddMessage = function(_, text)
    wow.raidWarnings[#wow.raidWarnings + 1] = text
  end
  env.StaticPopup_Hide = function(which) wow:record("StaticPopup_Hide", which) end
  env.SetOverrideBindingClick = function(...) wow:record("SetOverrideBindingClick", ...) end
  env.ClearOverrideBindings = function(...) wow:record("ClearOverrideBindings", ...) end
  env.SlashCmdList = {}

  -- Units
  -- As on Forever (/ptx diag 2026-11-18): first name and surname as two values.
  env.UnitName = function(token)
    local u = unit(token)
    if u then return u.name, u.realm end
  end
  env.GetUnitName = function(token)
    local u = unit(token)
    if u then return u.realm and (u.name .. " " .. u.realm) or u.name end
  end
  env.UnitFullName = function(token)
    local u = unit(token)
    if u then return u.name, u.realm end
  end
  env.UnitExists = function(token) return unit(token) ~= nil end
  env.UnitIsPlayer = function(token)
    local u = unit(token)
    return u ~= nil and (u == wow.player or u.isPlayer == true)
  end
  env.UnitFactionGroup = function(token)
    local u = unit(token)
    return u and u.faction
  end
  env.UnitRace = function(token)
    local u = unit(token)
    return u and u.race, u and u.race
  end
  env.UnitClass = function(token)
    local u = unit(token)
    return u and u.class, u and u.class
  end
  env.UnitLevel = function(token)
    local u = unit(token)
    return u and u.level or 0
  end
  env.UnitCastingInfo = function(token)
    local u = unit(token)
    if u and u.casting then
      local c = u.casting
      return c.name, c.name, c.icon, c.startMs, c.endMs, false, c.castId, false, c.spellId
    end
  end
  env.UnitIsConnected = function(token)
    local u = unit(token)
    return u ~= nil and not u.offline
  end
  env.Ambiguate = function(name) return name end -- Forever: "Name Realm" stays as is
  env.CheckInteractDistance = function(token)
    local u = unit(token)
    return u ~= nil and u.near == true
  end

  -- Character state
  env.IsResting = function() return wow.player.resting end
  env.GetZoneText = function() return wow.player.zone end
  env.GetRealZoneText = function() return wow.player.zone end
  env.GetSubZoneText = function() return wow.player.subzone end
  env.GetMoney = function() return wow.player.money end
  env.IsSpellKnown = function(id) return wow.player.spells[id] == true end
  env.IsPlayerSpell = env.IsSpellKnown
  env.C_SpellBook = { IsSpellKnown = env.IsSpellKnown }
  env.C_Spell = {
    GetSpellTexture = function(id) return 100000 + id end,
    GetSpellInfo = function(id) return { spellID = id, name = "Spell " .. id, iconID = 100000 + id } end,
  }
  env.C_Item = {
    GetItemCount = function(id) return wow.player.items[id] or 0 end,
    -- wow.itemSpells[itemId] = { name, spellId } (the scroll's spell ID is not known yet)
    GetItemSpell = function(id)
      local s = wow.itemSpells and wow.itemSpells[id]
      if s then return s[1], s[2] end
    end,
  }
  env.C_Container = {
    GetContainerNumSlots = function() return 0 end,
    GetContainerItemLink = function() return nil end,
  }
  env.C_Map = {
    GetBestMapForUnit = function() return wow.player.mapId end,
    GetPlayerMapPosition = function() return nil end,
  }
  env.C_CurrencyInfo = {
    GetCoinTextureString = function(copper)
      copper = math.floor(copper or 0)
      return ("%dg %ds %dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
    end,
  }

  -- Addon messages and channels
  env.C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix)
      if wow.prefixes[prefix] then return 1 end -- duplicate, as seen in game
      wow.prefixes[prefix] = true
      return 0
    end,
    IsAddonMessagePrefixRegistered = function(prefix) return wow.prefixes[prefix] == true end,
    SendAddonMessage = function(prefix, msg, kind, target)
      if #prefix > 16 then error("addon prefix longer than 16 bytes", 2) end
      if #msg > 255 then error("addon message longer than 255 bytes", 2) end
      local entry = { prefix = prefix, msg = msg, kind = kind, target = target }
      wow.sent[#wow.sent + 1] = entry
      if wow.hooks.send then
        wow.hooks.send(wow, entry)
      elseif kind == "CHANNEL" then
        wow:later(0.1, function() wow:receive(prefix, msg, "CHANNEL", wow:fullName()) end)
      elseif kind == "WHISPER" and target == wow:fullName() then
        wow:later(0.1, function() wow:receive(prefix, msg, "WHISPER", wow:fullName()) end)
      end
      return 0
    end,
  }
  env.JoinTemporaryChannel = function(name)
    wow:record("JoinTemporaryChannel", name)
    if not wow.channels[name] then
      wow.channels[name] = wow.nextChannelId
      wow.nextChannelId = wow.nextChannelId + 1
      wow:later(0.5, function()
        wow:fire("CHAT_MSG_CHANNEL_NOTICE", "YOU_CHANGED", "", "", wow.channels[name] .. ". " .. name, "", "", 0,
          wow.channels[name], name)
      end)
    end
    return 0
  end
  env.JoinChannelByName = env.JoinTemporaryChannel
  env.LeaveChannelByName = function(name)
    wow:record("LeaveChannelByName", name)
    wow.channels[name] = nil
  end
  env.GetChannelName = function(name)
    local id = wow.channels[name]
    if id then return id, name end
    return 0, nil
  end
  env.ChatFrame_RemoveChannel = function(frame, name) wow:record("ChatFrame_RemoveChannel", frame, name) end
  env.DEFAULT_CHAT_FRAME = newWidget(wow, "ScrollingMessageFrame", "ChatFrame1", env.UIParent)
  env.NUM_CHAT_WINDOWS = 1

  -- Party
  env.C_PartyInfo = {
    InviteUnit = protected("C_PartyInfo.InviteUnit", function(name)
      wow:record("C_PartyInfo.InviteUnit", name)
      if wow.hooks.invite then wow.hooks.invite(wow, name) end
    end),
    LeaveParty = function()
      wow:record("C_PartyInfo.LeaveParty")
      wow.party = {}
      for i = 1, 4 do wow.units["party" .. i] = nil end
      wow:fire("GROUP_ROSTER_UPDATE")
    end,
  }
  env.AcceptGroup = protected("AcceptGroup", function()
    wow:record("AcceptGroup")
    local inviter = wow.pendingInviter
    wow.pendingInviter = nil
    if inviter then
      if wow.hooks.accept then
        wow.hooks.accept(wow, inviter)
      else
        wow:joinParty(inviter)
      end
    end
  end)
  env.DeclineGroup = function()
    wow:record("DeclineGroup")
    wow.pendingInviter = nil
  end
  env.IsInGroup = function() return #wow.party > 0 end
  env.GetNumGroupMembers = function() return #wow.party > 0 and #wow.party + 1 or 0 end
  env.UnitInParty = function(token) return unit(token) ~= nil end

  -- Trade
  env.InitiateTrade = protected("InitiateTrade", function(token)
    wow:record("InitiateTrade", token)
    local u = unit(token)
    if not u then return end
    if wow.hooks.initiateTrade then
      wow.hooks.initiateTrade(wow, u.name)
    else
      wow:later(0.2, function() wow:tradeOpenedBy(u.name) end)
    end
  end)
  env.C_TradeInfo = {
    SetTradeMoney = protected("C_TradeInfo.SetTradeMoney", function(copper)
      wow:record("C_TradeInfo.SetTradeMoney", copper)
      if wow.trade then
        wow.trade.mine = copper
        if wow.hooks.tradeMoney then wow.hooks.tradeMoney(wow, copper) end
        wow:fire("TRADE_MONEY_CHANGED")
      end
    end),
  }
  env.GetPlayerTradeMoney = function() return wow.trade and wow.trade.mine or 0 end
  env.GetTargetTradeMoney = function() return wow.trade and wow.trade.theirs or 0 end
  env.CancelTrade = function()
    wow:record("CancelTrade")
    if wow.trade then
      wow.trade = nil
      wow:fire("TRADE_CLOSED")
    end
  end
  env.MoneyInputFrame_SetCopper = function(_, copper) wow:record("MoneyInputFrame_SetCopper", copper) end
  -- TradePlayerInputMoneyFrame is left out on purpose: trade tests cover both branches by defining it.
  env.ERR_TRADE_COMPLETE = "Trade complete."
  env.StaticPopup_FindVisible = function() return nil end

  -- Timers
  local function handle(t)
    return {
      Cancel = function() t.cancelled = true end,
      IsCancelled = function() return t.cancelled == true end,
    }
  end
  env.C_Timer = {
    After = function(seconds, fn) wow:later(seconds, fn) end,
    NewTimer = function(seconds, fn)
      local h
      local t = wow:later(seconds, function() fn(h) end)
      h = handle(t)
      return h
    end,
    NewTicker = function(seconds, fn, iterations)
      local h, current = nil, nil
      local count = 0
      h = {
        Cancel = function() h.cancelled = true; if current then current.cancelled = true end end,
        IsCancelled = function() return h.cancelled == true end,
      }
      local function tick()
        if h.cancelled then return end
        count = count + 1
        fn(h)
        if not h.cancelled and (not iterations or count < iterations) then
          current = wow:later(seconds, tick)
        end
      end
      current = wow:later(seconds, tick)
      return h
    end,
  }

  -- Calls the addon must never make (D10).
  for _, path in ipairs(FORBIDDEN) do
    local fn = function() error("forbidden call " .. path .. " (playbook D10)", 2) end
    local ns, field = path:match("^(.-)%.(.+)$")
    if ns then
      env[ns] = env[ns] or {}
      env[ns][field] = fn
    else
      env[path] = fn
    end
  end
end

return Wow
