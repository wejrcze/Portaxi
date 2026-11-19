-- Secure: the one secure action button ("next step") and its combat lockdown queue.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Trade a Secure" (Secure part), decisions D10, D14, D15.
-- Card I, wave 2.
--
--   Secure.button              SecureActionButtonTemplate, global Const.SECURE_BUTTON, created on READY
--   Secure.set(spec) -> true (applied) | false (queued in combat) | nil, "spec" (invalid spec)
--   Secure.current() -> spec|nil        the spec armed on the button
--   Secure.pending() -> spec|nil, bool  the newest spec queued for after combat; bool = something is queued
--   Secure.bindKey(key) -> true | nil, "combat" | "key"     nil or "" clears the key
--   /ptx key <KEY>
--
-- The addon only arms the button; the player clicks it (D10). Attributes, Show/Hide, position and
-- bindings of a secure frame cannot change in combat: set() queues the newest spec and applies it on
-- PLAYER_REGEN_ENABLED. Moving: Shift-drag out of combat; a Shift-click does not fire the action.

-- luacheck: read globals InCombatLockdown IsShiftKeyDown SetOverrideBindingClick ClearOverrideBindings
-- luacheck: read globals GameTooltip

local _, ns = ...
local C = ns.Const

local Secure = {}
ns.Secure = Secure

local SIZE = 40
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local DEFAULT_POS = { point = "CENTER", relPoint = "CENTER", x = 0, y = -180 }

local current          -- applied spec
local queued, hasQueued -- newest spec waiting for the end of combat (or for the button)
local bindAfterCombat  -- the saved key still has to be bound (READY came in combat)
local started = false  -- READY has fired
local ui = {}          -- icon, label

-- Spec ---------------------------------------------------------------------------------------

local function validSpec(spec)
  if spec == nil then
    return true
  end
  if type(spec) ~= "table" then
    return false
  end
  if spec.kind == "item" then
    return tonumber(spec.item) ~= nil
  elseif spec.kind == "spell" then
    return tonumber(spec.spell) ~= nil
  end
  return false
end

-- Calls an icon API protected; a missing or failing API gives the question mark.
local function iconFor(spec)
  local fn, id
  if spec.kind == "item" then
    fn, id = ns.api("C_Item.GetItemIconByID", "GetItemIcon"), spec.item
  else
    fn, id = ns.api("C_Spell.GetSpellTexture", "GetSpellTexture"), spec.spell
  end
  if fn then
    local ok, icon = pcall(fn, id)
    if ok and icon then
      return icon
    end
  end
  return QUESTION_MARK
end

-- The "type" attribute a spec arms, also used to restore it after a Shift-click.
local function typeOf(spec)
  return spec and spec.kind or nil
end

local function setAttributes(b, spec)
  local item = spec and spec.kind == "item"
  local spell = spec and spec.kind == "spell"
  b:SetAttribute("type", typeOf(spec))
  b:SetAttribute("item", item and ("item:" .. spec.item) or nil)
  b:SetAttribute("spell", spell and spec.spell or nil)
  b:SetAttribute("unit", item and spec.unit or nil)
end

-- Out of combat only: attributes, face and visibility, then SECURE_CHANGED.
local function apply(spec)
  local b = Secure.button
  setAttributes(b, spec)
  if spec then
    ui.icon:SetTexture(iconFor(spec))
    ui.label:SetText(spec.label or "")
    b:Show()
  else
    ui.icon:SetTexture(nil)
    ui.label:SetText("")
    b:Hide()
  end
  current = spec
  ns.fire("SECURE_CHANGED", spec)
end

local function canApply()
  return Secure.button ~= nil and not InCombatLockdown()
end

function Secure.set(spec)
  if not validSpec(spec) then
    return nil, "spec"
  end
  if not canApply() then
    queued, hasQueued = spec, true
    return false
  end
  queued, hasQueued = nil, false
  apply(spec)
  return true
end

function Secure.current()
  return current
end

function Secure.pending()
  return queued, hasQueued
end

-- Key binding (D14) -------------------------------------------------------------------------

local function applyBinding()
  local b = Secure.button
  if not b then
    return
  end
  ClearOverrideBindings(b)
  local key = PortaxiCharDB and PortaxiCharDB.nextKey
  if key then
    SetOverrideBindingClick(b, true, key, C.SECURE_BUTTON)
  end
end

-- "f" -> "F", "ctrl-1" -> "CTRL-1"; "" -> nil (clear); keys with spaces are invalid.
local function normalizeKey(key)
  if key == nil then
    return nil, true
  end
  key = tostring(key):gsub("^%s+", ""):gsub("%s+$", ""):upper()
  if key == "" then
    return nil, true
  end
  if key:find("%s") then
    return nil, false
  end
  return key, true
end

function Secure.bindKey(key)
  local norm, valid = normalizeKey(key)
  if not valid then
    return nil, "key"
  end
  if InCombatLockdown() then
    return nil, "combat"
  end
  PortaxiCharDB.nextKey = norm
  applyBinding()
  return true
end

ns.commands.key = {
  args = "<KEY>",
  help = "bind a key to the Portaxi button (no key clears it)",
  fn = function(args)
    local ok, err = Secure.bindKey(args)
    if ok then
      local key = PortaxiCharDB.nextKey
      ns.say(key and ("Key %s clicks the Portaxi button. Macro: /click %s"):format(key, C.SECURE_BUTTON)
        or "Portaxi button key cleared.")
    elseif err == "combat" then
      ns.say("Cannot change the key in combat.")
    else
      ns.say("Usage: /ptx key <KEY>, e.g. /ptx key F or /ptx key CTRL-1")
    end
  end,
}

-- Button ---------------------------------------------------------------------------------------

local function uiDB()
  return PortaxiDB and PortaxiDB.ui
end

local function restorePosition(b)
  local db = uiDB()
  local pos = db and type(db.secure) == "table" and db.secure.point and db.secure or DEFAULT_POS
  b:ClearAllPoints()
  b:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
end

local function savePosition(b)
  local db = uiDB()
  local point, _, relPoint, x, y = b:GetPoint()
  if db and point then
    db.secure = { point = point, relPoint = relPoint or point, x = math.floor((x or 0) + 0.5),
                  y = math.floor((y or 0) + 0.5) }
  end
end

local function onDragStart(b)
  if InCombatLockdown() or not IsShiftKeyDown() then
    return
  end
  b:StartMoving()
end

local function onDragStop(b)
  b:StopMovingOrSizing()
  b:SetUserPlaced(false) -- PortaxiDB.ui.secure is the only saved position
  savePosition(b)
end

-- A Shift-click (start of a move) must not cast: out of combat the action is disarmed for that click.
local disarmedClick = false
local function preClick(b)
  if IsShiftKeyDown() and not InCombatLockdown() and b:GetAttribute("type") then
    disarmedClick = true
    b:SetAttribute("type", nil)
  end
end

local function postClick(b)
  if disarmedClick then
    disarmedClick = false
    if not InCombatLockdown() then
      b:SetAttribute("type", typeOf(current))
    end
  end
end

local function onEnter(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  GameTooltip:SetText(current and current.label or "Portaxi")
  GameTooltip:AddLine("Shift-drag to move.", 1, 1, 1)
  GameTooltip:Show()
end

local function onLeave()
  GameTooltip:Hide()
end

local function createButton()
  local b = CreateFrame("Button", C.SECURE_BUTTON, UIParent, "SecureActionButtonTemplate")
  b:SetSize(SIZE, SIZE)
  b:SetFrameStrata("MEDIUM")
  b:SetClampedToScreen(true)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetMovable(true)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", onDragStart)
  b:SetScript("OnDragStop", onDragStop)
  b:SetScript("PreClick", preClick)
  b:SetScript("PostClick", postClick)
  b:SetScript("OnEnter", onEnter)
  b:SetScript("OnLeave", onLeave)

  ui.icon = b:CreateTexture(nil, "ARTWORK")
  ui.icon:SetAllPoints(b)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
  ui.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.label:SetPoint("TOP", b, "BOTTOM", 0, -2)

  restorePosition(b)
  b:Hide()
  Secure.button = b
  Secure.ui = ui
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- Creates the button (out of combat only), then applies what was queued meanwhile and the saved key.
local function setup()
  if InCombatLockdown() then
    bindAfterCombat = true
    return
  end
  if not Secure.button then
    createButton()
  end
  if hasQueued then
    local spec = queued
    queued, hasQueued = nil, false
    apply(spec)
  end
  if bindAfterCombat then
    bindAfterCombat = false
    applyBinding()
  end
end

function Secure.start()
  started = true
  bindAfterCombat = true
  setup()
end

ns.on("READY", Secure.start)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function()
  if started then
    setup()
  end
end)
