-- UI.Minimap: own minimap button (no LibDBIcon, playbook D1). Left click toggles the window; dragging
-- moves it around the minimap and saves the angle in PortaxiDB.ui.minimap.angle. Created on READY (D15).
-- Card F, wave 1; card J (wave 3) gave it the mock's portal icon.
-- luacheck: read globals Minimap GameTooltip GetCursorPosition

local _, ns = ...

ns.UI = ns.UI or {}
local MM = {}
ns.UI.Minimap = MM

local L = ns.L
local W = ns.UI.Widgets

local DEFAULT_ANGLE = 200
local SIZE = 31

local function minimapDB()
  if type(PortaxiDB) ~= "table" then
    return nil
  end
  PortaxiDB.ui = PortaxiDB.ui or {}
  PortaxiDB.ui.minimap = PortaxiDB.ui.minimap or {}
  return PortaxiDB.ui.minimap
end

-- Position ----------------------------------------------------------------------------

function MM.angle()
  local db = minimapDB()
  return tonumber(db and db.angle) or DEFAULT_ANGLE
end

-- Places the button on the minimap's rim at the given angle (degrees, 0 = east, counter-clockwise).
function MM.place(angle)
  local b = MM.button
  local width = tonumber((Minimap:GetWidth())) or 0
  local radius = (width > 0 and width / 2 or 70) + 10
  local rad = math.rad(angle)
  b:ClearAllPoints()
  b:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
end

-- Angle from the minimap centre to the cursor, in degrees 0..360.
local function cursorAngle()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = tonumber((Minimap:GetEffectiveScale())) or 1
  if not (mx and my and cx and cy) then
    return nil
  end
  local deg = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
  return math.floor(deg % 360 + 0.5)
end

local function onDragUpdate()
  local a = cursorAngle()
  if a then
    MM.dragAngle = a
    MM.place(a)
  end
end

local function onDragStart(self)
  MM.dragAngle = nil
  self:SetScript("OnUpdate", onDragUpdate)
end

local function onDragStop(self)
  self:SetScript("OnUpdate", nil)
  onDragUpdate()
  local db = minimapDB()
  if db and MM.dragAngle then
    db.angle = MM.dragAngle
  end
end

-- Tooltip -----------------------------------------------------------------------------

-- One status line: who you are for Portaxi right now.
function MM.statusLine()
  local profile, services = W.current()
  if not profile then
    return L["Waiting for character data"]
  end
  local who = ("%s %s %s"):format(profile.race or "", W.className(profile.class), tostring(profile.level or ""))
  if not services.canDrive then
    return L["You: rider (%s)"]:format(who)
  end
  local onDuty = type(PortaxiCharDB) == "table" and PortaxiCharDB.onDuty == true
  return L["You: taxi, %s (%s)"]:format(onDuty and L["on duty"] or L["off duty"], who)
end

local function onEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(L["Portaxi"], 1, 0.82, 0)
  GameTooltip:AddLine(MM.statusLine(), 0.92, 0.89, 0.82)
  GameTooltip:AddLine(L["Click: open or close the window. Drag: move this button."], 0.37, 0.82, 0.41)
  GameTooltip:Show()
end

local function onLeave()
  GameTooltip:Hide()
end

-- Building ----------------------------------------------------------------------------

-- Icon: the arcane portal disc of the mock (Media/portal); when the client refuses the file, a portal spell
-- of the own faction (D13), Orgrimmar until Detect knows the faction.
local function setIcon(icon)
  if W.trySetTexture(icon, W.MEDIA .. "portal") then
    icon:SetTexCoord(0, 1, 0, 1)
    return
  end
  local profile = W.current()
  local key = profile and W.citiesOf(profile.faction)[1] or "OG"
  icon:SetTexture(W.spellIcon(ns.Const.CITY[key].spell))
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

local function build()
  local b = CreateFrame("Button", nil, Minimap)
  b:SetSize(SIZE, SIZE)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER")
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", b, "CENTER", 0, 1)
  b.icon = icon
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  b:SetScript("OnClick", function(_, button)
    if button == nil or button == "LeftButton" then
      ns.UI.toggle()
    end
  end)
  b:SetScript("OnDragStart", onDragStart)
  b:SetScript("OnDragStop", onDragStop)
  b:SetScript("OnEnter", onEnter)
  b:SetScript("OnLeave", onLeave)
  return b
end

function MM.refresh()
  if MM.button then
    setIcon(MM.button.icon)
  end
end

function MM.start()
  if MM.button or not Minimap then
    return
  end
  MM.button = build()
  MM.place(MM.angle())
  MM.refresh()
end

ns.on("READY", MM.start)
ns.on("PROFILE_CHANGED", MM.refresh)
