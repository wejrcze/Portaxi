-- UI.MainFrame: the Portaxi window with bottom tabs Ride / Drive / Hop (Drive only when services.canDrive; Hop,
-- Inn hop D20, only for a mage with scrolls: HopTab.wanted).
-- Global frame "PortaxiMainFrame" (D2), built lazily on first show; movable, position in PortaxiDB.ui.pos,
-- closes on Esc. Refreshes on PROFILE_CHANGED; the "taxis online" line on MARKET_CHANGED.
-- Look of the mock v0.8: gold trim (red-brown for the Horde), title bar with the round player portrait over
-- the corner, "PORTAXI" in gold, a subtitle line, tabs hanging under the frame.
-- Contract: playbook §2 "UI". Card F built it in wave 1; card J polished it in wave 3.
-- luacheck: read globals UISpecialFrames

local _, ns = ...

ns.UI = ns.UI or {}
local M = {}
ns.UI.MainFrame = M

local L = ns.L
local W = ns.UI.Widgets
local C = W.COLOR

local FRAME_NAME = "PortaxiMainFrame"
local WIDTH, HEIGHT = 380, 584
local TITLE_HEIGHT = 44
local PORTRAIT = 46
local TAB_W, TAB_H = 92, 26
local TABS = { "ride", "drive", "hop" }
local TAB_TEXT = { ride = "Ride", drive = "Drive", hop = "Hop" }

M.tab = "ride" -- last selected tab

-- Position ----------------------------------------------------------------------------

local function uiDB()
  if type(PortaxiDB) ~= "table" then
    return nil
  end
  PortaxiDB.ui = PortaxiDB.ui or {}
  return PortaxiDB.ui
end

local function savePosition(frame)
  local db = uiDB()
  local point, _, relPoint, x, y = frame:GetPoint()
  if db and point then
    db.pos = { point = point, relPoint = relPoint or point, x = math.floor((x or 0) + 0.5),
               y = math.floor((y or 0) + 0.5) }
  end
end

local function restorePosition(frame)
  local db = uiDB()
  local pos = db and db.pos
  frame:ClearAllPoints()
  if type(pos) == "table" and pos.point then
    frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  end
end

-- Building ----------------------------------------------------------------------------

-- Round player portrait over the top-left corner, with a ring in the trim colour.
local function buildPortrait(frame)
  local holder = CreateFrame("Frame", nil, frame)
  holder:SetSize(PORTRAIT, PORTRAIT)
  holder:SetPoint("CENTER", frame, "TOPLEFT", 22, -20)
  holder:SetFrameLevel((frame:GetFrameLevel() or 1) + 5)
  M.portrait = holder:CreateTexture(nil, "ARTWORK")
  M.portrait:SetSize(PORTRAIT - 6, PORTRAIT - 6)
  M.portrait:SetPoint("CENTER")
  M.portraitRing = holder:CreateTexture(nil, "OVERLAY")
  M.portraitRing:SetSize(PORTRAIT, PORTRAIT)
  M.portraitRing:SetPoint("CENTER")
  if not W.trySetTexture(M.portraitRing, W.MEDIA .. "ring") then
    M.portraitRing:Hide()
  end
end

local function buildTitle(frame)
  local bar = CreateFrame("Frame", nil, frame)
  bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
  bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  bar:SetHeight(TITLE_HEIGHT)
  local fill = bar:CreateTexture(nil, "BACKGROUND")
  fill:SetAllPoints()
  W.gradient(fill, C.TITLE_TOP, C.TITLE_BOTTOM)
  M.titleLine = W.texture(bar, C.TRIM, "BORDER")
  M.titleLine:SetHeight(1)
  M.titleLine:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
  M.titleLine:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
  buildPortrait(frame)
  local title = W.label(bar, "GameFontNormalLarge", C.GOLD)
  title:SetPoint("TOPLEFT", bar, "TOPLEFT", 52, -7)
  title:SetText(L["Portaxi"]:upper())
  M.title = title
  local sub = W.label(bar, "GameFontHighlightSmall", C.MUTED)
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  M.subtitle = sub
  local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
  close:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
  close:SetScript("OnClick", function() M.hide() end)
  M.closeButton = close
  local online = W.label(bar, "GameFontHighlightSmall", C.MUTED, "RIGHT")
  online:SetPoint("RIGHT", close, "LEFT", -2, 0)
  M.online = online
end

-- A soft lighter band under the title bar (the mock's radial glow at the top of the body).
local function buildGlow(frame)
  local glow = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  glow:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -(TITLE_HEIGHT + 2))
  glow:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -(TITLE_HEIGHT + 2))
  glow:SetHeight(140)
  W.gradient(glow, C.GLOW, C.PANEL)
end

local function buildTabs(frame)
  M.tabButtons = {}
  for _, name in ipairs(TABS) do
    local b = W.button(frame, L[TAB_TEXT[name]], TAB_W, TAB_H, "ghost")
    b:SetScript("OnClick", function() M.select(name) end)
    M.tabButtons[name] = b
  end
end

local function buildContent(frame)
  M.pages = {}
  for name, module in pairs({ ride = ns.UI.RideTab, drive = ns.UI.DriveTab, hop = ns.UI.HopTab }) do
    local page = CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(TITLE_HEIGHT + 12))
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
    page:SetSize(WIDTH - 28, HEIGHT - TITLE_HEIGHT - 24)
    if module and module.build then
      module.build(page)
    end
    page:Hide()
    M.pages[name] = page
  end
end

local function registerEscape()
  if type(UISpecialFrames) == "table" then
    for _, name in ipairs(UISpecialFrames) do
      if name == FRAME_NAME then
        return
      end
    end
    table.insert(UISpecialFrames, FRAME_NAME)
  end
end

local function build()
  local frame = W.panel(UIParent, C.PANEL, C.TRIM, 2, FRAME_NAME)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- PortaxiDB.ui.pos is the only saved position, not the layout cache
    savePosition(self)
  end)
  restorePosition(frame)
  M.frame = frame
  buildGlow(frame)
  buildTitle(frame)
  buildTabs(frame)
  buildContent(frame)
  registerEscape()
  return frame
end

-- Refresh -----------------------------------------------------------------------------

local function canDrive(services)
  return services and services.canDrive == true
end

local function subtitle(profile, services)
  if not profile then
    return L["Waiting for character data"]
  end
  local role = (M.tab == "drive" and canDrive(services)) and L["Taxi"] or (M.tab == "hop" and L["Inn hop"])
    or L["Rider"]
  return ("%s · %s · %s %s"):format(L[profile.faction or "?"], role, W.className(profile.class),
    tostring(profile.level or ""))
end

-- Selected tab: panel fill, trim edge, gold text, a little taller so it joins the frame.
local function placeTab(b, x, on, trim)
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", M.frame, "BOTTOMLEFT", x, on and 3 or 1)
  b:SetHeight(on and TAB_H + 4 or TAB_H)
  W.setToggle(b, on, trim)
  W.setFill(b, on and C.PANEL or C.DARK)
end

local function canHop(profile)
  local H = ns.UI.HopTab
  return type(H) == "table" and type(H.wanted) == "function" and H.wanted(profile) == true
end

local function updateTabs(profile, services, trim)
  local shown = { ride = true, drive = canDrive(services), hop = canHop(profile) }
  if not shown[M.tab] then
    M.tab = "ride"
  end
  local x = 24
  for _, name in ipairs(TABS) do
    local on = name == M.tab
    M.tabButtons[name]:SetShown(shown[name])
    if shown[name] then
      placeTab(M.tabButtons[name], x, on, trim)
      x = x + TAB_W + 4
    end
    M.pages[name]:SetShown(on)
  end
end

-- "3 taxis online" for the own faction, or nothing while there is no market.
function M.onlineText(profile)
  local n = profile and W.taxisOnline(profile.faction)
  if not n then
    return ""
  end
  return n == 1 and L["1 taxi online"] or L["%d taxis online"]:format(n)
end

local function updateTrim(trim)
  W.setBorder(M.frame, trim)
  M.titleLine:SetVertexColor(trim[1], trim[2], trim[3], 1)
  M.portraitRing:SetVertexColor(trim[1], trim[2], trim[3], 1)
end

-- Redraws the window from (profile, services); without arguments it asks Detect.current().
function M.refresh(profile, services)
  if not M.frame then
    return
  end
  if not profile then
    profile, services = W.current()
  end
  services = services or {}
  local trim = W.trimFor(profile and profile.faction)
  updateTrim(trim)
  updateTabs(profile, services, trim)
  M.subtitle:SetText(subtitle(profile, services))
  M.online:SetText(M.onlineText(profile))
  local setPortrait = ns.api("SetPortraitTexture")
  if setPortrait then
    setPortrait(M.portrait, "player")
  end
  local page = ({ drive = ns.UI.DriveTab, hop = ns.UI.HopTab })[M.tab] or ns.UI.RideTab
  if page and page.refresh then
    page.refresh(profile, services)
  end
end

-- Public API (playbook §2 "UI") ------------------------------------------------------------

local function tabName(tab)
  return (tab == "drive" or tab == "hop") and tab or "ride"
end

function M.select(tab)
  M.tab = tabName(tab)
  M.refresh()
end

-- Opens the window on a tab ("ride" | "drive" | "hop"); nil keeps the last one. A tab the character cannot use
-- falls back to Ride.
function M.show(tab)
  local frame = M.frame or build()
  if tab then
    M.tab = tabName(tab)
  end
  frame:Show()
  M.refresh()
end

function M.hide()
  if M.frame then
    M.frame:Hide()
  end
end

function M.isShown()
  return M.frame ~= nil and M.frame:IsShown() == true
end

function M.toggle()
  if M.isShown() then
    M.hide()
  else
    M.show()
  end
end

ns.UI.toggle = M.toggle
ns.UI.show = M.show
ns.UI.hide = M.hide

ns.commands.show = { fn = ns.UI.toggle, help = "open or close the Portaxi window" }

ns.on("PROFILE_CHANGED", function(profile, services)
  if M.isShown() then
    M.refresh(profile, services)
  end
end)

ns.on("MARKET_CHANGED", function()
  if M.isShown() then
    M.online:SetText(M.onlineText((W.current())))
  end
end)
