-- UI.WhatsNew: the "What's new" window (D17). Opens on WHATS_NEW (entries), sent by Version after an update
-- and by /ptx news. Global frame "PortaxiWhatsNewFrame" (D2), built lazily, movable, closes on Esc.
--   WhatsNew.show(entries)  entries = ns.Changelog items { version, date, items = { "..." } }, newest first
--   WhatsNew.hide()
--   WhatsNew.text(entry) -> the item list of one entry as one string ("• a\n• b")
-- luacheck: read globals UISpecialFrames

local _, ns = ...

ns.UI = ns.UI or {}
local N = {}
ns.UI.WhatsNew = N

local L = ns.L
local W = ns.UI.Widgets
local C = W.COLOR

local FRAME_NAME = "PortaxiWhatsNewFrame"
local WIDTH, HEIGHT = 380, 420
local PAD = 16
local TITLE_HEIGHT = 44
local FOOTER_HEIGHT = 44
local TEXT_WIDTH = WIDTH - 2 * PAD - 8 -- leaves room for the scroll bar's gap
local GAP = 12                         -- space between two entries
local WHEEL_STEP = 40

function N.text(entry)
  local lines = {}
  for i, item in ipairs(entry.items or {}) do
    lines[i] = "• " .. item
  end
  return table.concat(lines, "\n")
end

-- Frame ---------------------------------------------------------------------------------

local function registerEscape()
  if type(UISpecialFrames) ~= "table" then
    return
  end
  for _, name in ipairs(UISpecialFrames) do
    if name == FRAME_NAME then
      return
    end
  end
  table.insert(UISpecialFrames, FRAME_NAME)
end

local function buildTitle(frame)
  local title = W.label(frame, "GameFontNormalLarge", C.GOLD)
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -12)
  title:SetText(L["What's new"]:upper())
  N.title = title
  local sub = W.label(frame, "GameFontHighlightSmall", C.MUTED)
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  N.subtitle = sub
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() N.hide() end)
  W.hline(frame, C.TRIM, -TITLE_HEIGHT, 2, 2)
end

-- The scroll area: a plain ScrollFrame scrolled by the mouse wheel (no template, so nothing can be missing).
local function buildScroll(frame)
  local scroll = CreateFrame("ScrollFrame", nil, frame)
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(TITLE_HEIGHT + 10))
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOTER_HEIGHT)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    local y = (self:GetVerticalScroll() or 0) - delta * WHEEL_STEP
    self:SetVerticalScroll(math.max(0, math.min(range, y)))
  end)
  N.scroll = scroll
end

local function buildFooter(frame)
  local ok = W.button(frame, L["Got it"], 110, 26)
  ok:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 10)
  ok:SetScript("OnClick", function() N.hide() end)
  local hint = W.label(frame, "GameFontHighlightSmall", C.MUTED)
  hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 17)
  hint:SetText(L["/ptx news shows this again."])
end

local function build()
  local frame = W.panel(UIParent, C.PANEL, C.TRIM, 2, FRAME_NAME)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- opens centred every time; no position is saved
  end)
  N.frame = frame
  buildTitle(frame)
  buildScroll(frame)
  buildFooter(frame)
  registerEscape()
  return frame
end

-- Content ---------------------------------------------------------------------------------

-- A fresh scroll child for the given entries; the previous one is dropped (frames are never freed, but the
-- window opens a handful of times per session at most).
local function fill(entries)
  local child = CreateFrame("Frame", nil, N.scroll)
  child:SetWidth(TEXT_WIDTH)
  local y = 0
  for i, entry in ipairs(entries) do
    if i > 1 then
      y = y - GAP
    end
    local header = W.section(child, entry.date and L["Version %s · %s"]:format(entry.version, entry.date)
      or L["Version %s"]:format(entry.version))
    header:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
    header:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
    y = y - 14 - 8
    local body = W.label(child, "GameFontHighlight", C.TEXT)
    body:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
    body:SetWidth(TEXT_WIDTH)
    body:SetSpacing(4)
    body:SetText(N.text(entry))
    y = y - (body:GetStringHeight() or 0)
  end
  child:SetHeight(math.max(1, -y))
  if N.child then
    N.child:Hide()
  end
  N.child = child
  N.scroll:SetScrollChild(child)
  N.scroll:SetVerticalScroll(0)
end

function N.show(entries)
  if type(entries) ~= "table" or #entries == 0 then
    return
  end
  local frame = N.frame or build()
  N.subtitle:SetText(L["Portaxi %s"]:format(ns.VERSION))
  fill(entries)
  frame:Show()
  frame:Raise()
end

function N.hide()
  if N.frame then
    N.frame:Hide()
  end
end

ns.on("WHATS_NEW", N.show)
