-- UI.DutyBox: small movable box shown while the taxi is on duty and can drive (user request at gate G1).
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "UI" (DutyBox). Card G, wave 2.
--   Global frame "PortaxiDutyBox" (D2), built on first need. Lines: status dot + "On duty" (click opens the
--   window on Drive), services with prices or the pause reason, open request count, the best request with
--   a Take button (Dispatch.take); small Off and hide (x) buttons. Drag to move unless locked; position,
--   lock and the hidden flag live in PortaxiDB.ui.dutyBox. Pulses on INCOMING_REQUEST.
--   DutyBox.refresh() ; /ptx box toggles the lock, or shows the box again after the user hid it.
-- Look (card J, wave 3): the main window's style in small: title strip with a round status dot, trim line,
-- the destination emblem next to the best request.

local _, ns = ...

ns.UI = ns.UI or {}
local B = { pulses = 0 }
ns.UI.DutyBox = B

local L = ns.L
local W = ns.UI.Widgets
local C = W.COLOR

local FRAME_NAME = "PortaxiDutyBox"
local WIDTH, HEIGHT = 224, 94
local TITLE_H = 20
local PULSE_TIME, PULSE_STEP = 2, 0.25
local SERVICE_TINY = { COME = "Come", PICK = "Pickup" }
local PAUSE_SHORT = {
  NOT_MAGE = "Only mages can drive.",
  NO_PORTAL = "Paused: no portal learned.",
  NO_RUNE = "Paused: no Rune of Portals.",
  NO_SCROLL = "Come-to-you paused: no scroll.",
  NOT_RESTING = "Come-to-you paused: not resting.",
}

-- SavedVariables --------------------------------------------------------------------------

local function boxDB()
  if type(PortaxiDB) ~= "table" then
    return nil
  end
  PortaxiDB.ui = PortaxiDB.ui or {}
  PortaxiDB.ui.dutyBox = PortaxiDB.ui.dutyBox or {}
  return PortaxiDB.ui.dutyBox
end

local function onDuty()
  return type(PortaxiCharDB) == "table" and PortaxiCharDB.onDuty == true
end

local function savePosition(frame)
  local db = boxDB()
  local point, _, relPoint, x, y = frame:GetPoint()
  if db and point then
    db.point, db.relPoint = point, relPoint or point
    db.x, db.y = math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5)
  end
end

local function restorePosition(frame)
  local db = boxDB()
  frame:ClearAllPoints()
  if db and db.point then
    frame:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
  else
    frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -240, -220)
  end
end

-- Building --------------------------------------------------------------------------------

local function buildTitle(box)
  local strip = box:CreateTexture(nil, "BACKGROUND", nil, 1)
  strip:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
  strip:SetPoint("TOPRIGHT", box, "TOPRIGHT", -1, -1)
  strip:SetHeight(TITLE_H)
  W.gradient(strip, C.TITLE_TOP, C.TITLE_BOTTOM)
  B.line = W.hline(box, C.TRIM, -(TITLE_H + 1), 1, 1)
  local title = CreateFrame("Button", nil, box)
  title:SetSize(140, 16)
  title:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -3)
  title:SetScript("OnClick", function() ns.UI.show("drive") end)
  B.dot = W.dot(title, 12, C.OK)
  B.dot:SetPoint("LEFT", title, "LEFT", 0, 0)
  B.titleText = W.label(title, "GameFontNormalSmall", C.GOLD)
  B.titleText:SetPoint("LEFT", B.dot, "RIGHT", 4, 0)
  local hl = W.texture(title, { 1, 0.82, 0, 0.08 }, "HIGHLIGHT")
  hl:SetAllPoints()
  B.title = title
  B.hide = W.button(box, "x", 16, 16, "ghost")
  B.hide:SetPoint("TOPRIGHT", box, "TOPRIGHT", -3, -3)
  B.hide:SetScript("OnClick", function() B.hideByUser() end)
  B.off = W.button(box, L["Off"], 34, 16, "ghost")
  B.off:SetPoint("RIGHT", B.hide, "LEFT", -3, 0)
  B.off:SetScript("OnClick", function() B.goOff() end)
end

local function line(box, y, color)
  local fs = W.label(box, "GameFontHighlightSmall", color)
  fs:SetPoint("TOPLEFT", box, "TOPLEFT", 8, y)
  fs:SetWidth(WIDTH - 16)
  return fs
end

-- The best request: destination emblem, two text lines, the Take button.
local function buildBest(box)
  B.emblem = W.emblem(box, 24, "TOPLEFT", box, "TOPLEFT", 8, -62)
  B.best = W.label(box, "GameFontHighlightSmall", C.TEXT)
  B.best:SetPoint("TOPLEFT", box, "TOPLEFT", 38, -62)
  B.best:SetWidth(WIDTH - 100)
  B.take = W.button(box, L["Take"], 52, 22)
  B.take:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -6, 7)
  B.take:SetScript("OnClick", function()
    if B.entry then
      ns.UI.DriveTab.take(B.entry.request.reqId)
      B.refresh()
    end
  end)
end

local function build()
  local box = W.panel(UIParent, C.PANEL, C.TRIM, 1, FRAME_NAME)
  box:SetSize(WIDTH, HEIGHT)
  box:SetFrameStrata("MEDIUM")
  box:SetClampedToScreen(true)
  box:EnableMouse(true)
  box:SetMovable(true)
  box:RegisterForDrag("LeftButton")
  box:SetScript("OnDragStart", function(self)
    local db = boxDB()
    if not (db and db.locked) then
      self:StartMoving()
    end
  end)
  box:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- PortaxiDB.ui.dutyBox is the only saved position
    savePosition(self)
  end)
  restorePosition(box)
  B.frame = box
  buildTitle(box)
  B.services = line(box, -28, C.TEXT)
  B.count = line(box, -44, C.MUTED)
  buildBest(box)
  box:Hide()
  return box
end

-- Content ---------------------------------------------------------------------------------

local function activeRide()
  local ride = ns.Ride
  return type(ride) == "table" and type(ride.current) == "function" and ride.current() or nil
end

-- "Come 3g · Pickup 1g 50s", or the first pause reason when nothing is offered.
function B.servicesText(services)
  if activeRide() then
    return L["On a ride"], C.TEXT
  end
  local prices = type(PortaxiCharDB) == "table" and PortaxiCharDB.prices or {}
  local out = {}
  for _, svc in ipairs({ "COME", "PICK" }) do
    if services[svc] and prices[svc] then
      out[#out + 1] = ("%s %s"):format(L[SERVICE_TINY[svc]], W.money(prices[svc]))
    end
  end
  if #out > 0 then
    return table.concat(out, " · "), C.TEXT
  end
  local reason = (services.pauses or {})[1]
  return L[PAUSE_SHORT[reason] or "Paused."], C.WARN
end

local function countText(n)
  if n == 0 then
    return L["No open requests"]
  elseif n == 1 then
    return L["1 open request"]
  end
  return L["%d open requests"]:format(n)
end

local function refreshContent(services)
  local db = boxDB() or {}
  local ride = activeRide()
  B.titleText:SetText(db.locked and L["On duty (locked)"] or L["On duty"])
  B.dot:SetVertexColor(unpack((services.COME or services.PICK) and not ride and C.OK or C.WARN))
  local text, color = B.servicesText(services)
  B.services:SetText(text)
  W.setColor(B.services, color)
  local D = ns.UI.DriveTab
  local list = D.requests()
  B.count:SetText(countText(#list))
  local entry = list[1]
  B.entry = entry
  B.best:SetShown(entry ~= nil)
  B.take:SetShown(entry ~= nil)
  B.emblem.icon:SetShown(entry ~= nil)
  B.emblem.ring:SetShown(entry ~= nil)
  if entry then
    W.setEmblem(B.emblem, entry.request.dest)
    W.setEmblemState(B.emblem, "plain")
    local who, what = D.requestText(entry)
    B.best:SetText(who .. "\n" .. what)
    local blocker, label = D.takeState(entry)
    B.take:SetText(label)
    W.setEnabled(B.take, blocker == nil)
  end
end

-- Visible while on duty, able to drive and not hidden by the user.
function B.shouldShow()
  local _, services = W.current()
  local db = boxDB()
  return onDuty() and services.canDrive == true and not (db and db.hidden), services
end

function B.refresh()
  local show, services = B.shouldShow()
  if not show then
    if B.frame then
      B.frame:Hide()
    end
    return
  end
  local box = B.frame or build()
  refreshContent(services)
  box:Show()
end

function B.isShown()
  return B.frame ~= nil and B.frame:IsShown() == true
end

-- Pulse -----------------------------------------------------------------------------------

local function stopPulse()
  B.frame:SetScript("OnUpdate", nil)
  W.setBorder(B.frame, C.TRIM)
  B.pulsing = false
end

-- Flashes the border for PULSE_TIME seconds.
function B.pulse()
  if not B.isShown() then
    return
  end
  B.pulses = B.pulses + 1
  B.pulsing = true
  local elapsed, step, bright = 0, 0, true
  W.setBorder(B.frame, C.GOLD)
  B.frame:SetScript("OnUpdate", function(_, dt)
    elapsed, step = elapsed + dt, step + dt
    if elapsed >= PULSE_TIME then
      stopPulse()
    elseif step >= PULSE_STEP then
      step, bright = 0, not bright
      W.setBorder(B.frame, bright and C.GOLD or C.TRIM)
    end
  end)
end

-- Actions ---------------------------------------------------------------------------------

function B.goOff()
  ns.UI.DriveTab.setOnDuty(false)
  B.refresh()
end

function B.hideByUser()
  local db = boxDB()
  if db then
    db.hidden = true
  end
  B.refresh()
  ns.say(L["Duty box hidden. /ptx box shows it again."])
end

-- /ptx box: shows the box again after the user hid it, otherwise toggles the lock.
function B.command()
  local db = boxDB()
  if not db then
    return
  end
  if db.hidden then
    db.hidden = false
    ns.say(L["Duty box shown."])
  else
    db.locked = not db.locked
    ns.say(db.locked and L["Duty box locked."] or L["Duty box unlocked: drag it to move it."])
  end
  B.refresh()
  if not B.isShown() then
    ns.say(L["The duty box shows while you are on duty as a taxi."])
  end
end

ns.commands.box = { fn = B.command, help = "duty box: lock or unlock it, or show it again after hiding" }

for _, event in ipairs({ "READY", "PROFILE_CHANGED", "MARKET_CHANGED", "RIDE_STARTED", "RIDE_STATE" }) do
  ns.on(event, B.refresh)
end
ns.on("INCOMING_REQUEST", function()
  B.refresh()
  B.pulse()
end)
