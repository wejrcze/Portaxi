-- UI.Arrow: a small floating arrow that points from you to the other side of the ride (taxi or rider), with
-- their name and the distance, so the two do not have to look for each other on the map (user request after
-- 0.1.0). Both roles see it. Reads only game positions of the peer's party unit; no protocol message.
--
--   Global frame "PortaxiArrow", drag to move, position in PortaxiDB.ui.arrow, right-click hides it for the
--   rest of the ride, /ptx arrow turns it off or on for good (PortaxiDB.ui.arrowOff).
--   Shown while Arrow.wanted(ride): the peer is in the group and the ride is between GROUPED and PORTAL_OPEN;
--   a Come-to-you ride only from ARRIVED (before that the taxi teleports, nobody walks).
--   Arrow.refresh() (on ride events; starts/stops the 20 Hz update) ; Arrow.update() ; Arrow.frame ;
--   Arrow.running ; Arrow.view() -> table of what is shown
--
-- Pure helpers (no game API)
--   Arrow.vector(fromN, fromW, toN, toW) -> bearing, yards
--       Positions are world coordinates: N grows to the north, W to the west (UnitPosition's first two
--       returns, and C_Map.GetWorldPosFromMapPos's vector x / y). bearing is counter-clockwise from north in
--       [0, 2pi), the same convention as GetPlayerFacing().
--   Arrow.turn(bearing, facing) -> angle in (-pi, pi]; the arrow texture (pointing up) is rotated by it
--   Arrow.wanted(ride) -> bool
--
-- Positions: UnitPosition first; when it gives nothing for either unit, C_Map (best map of the unit, map
-- position, world position). Both units are always read from the same source, so their instance/continent
-- IDs compare. Unverified on Forever: /ptx diag lists both APIs and GetPlayerFacing.

local _, ns = ...

ns.UI = ns.UI or {}
local A = {}
ns.UI.Arrow = A

local L = ns.L
local W = ns.UI.Widgets
local COL = W.COLOR

local FRAME_NAME = "PortaxiArrow"
local SIZE = 56             -- arrow texture side
local THROTTLE = 0.05       -- seconds between updates while shown
local CLOSE = 8             -- yards: the arrow turns green ("here")
local FALLBACK_TEXTURE = "Interface\\Minimap\\MinimapArrow"
local TWO_PI = 2 * math.pi

local SHOWN_STATES = { GROUPED = true, EN_ROUTE = true, ARRIVED = true, TRADING = true, PAID = true,
                       PORTAL_OPEN = true }
local COME_STATES = { ARRIVED = true, TRADING = true, PAID = true, PORTAL_OPEN = true }

A.ride = nil       -- last ride seen
A.hiddenFor = nil  -- reqId the player right-clicked the arrow away for
A.last = nil       -- last computed view

-- Pure ----------------------------------------------------------------------------------------

function A.vector(fromN, fromW, toN, toW)
  local dn, dw = toN - fromN, toW - fromW
  local bearing = math.atan2(dw, dn) % TWO_PI
  return bearing, math.sqrt(dn * dn + dw * dw)
end

function A.turn(bearing, facing)
  local a = (bearing - facing) % TWO_PI
  if a > math.pi then
    a = a - TWO_PI
  end
  return a
end

function A.wanted(ride)
  if type(ride) ~= "table" or not ride.peerUnit or not SHOWN_STATES[ride.state] then
    return false
  end
  if ride.svc == "COME" then
    return COME_STATES[ride.state] == true
  end
  return true
end

-- Game readers ---------------------------------------------------------------------------------

local function call(fn, ...)
  if not fn then
    return nil
  end
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then
    return a, b, c, d
  end
end

local function fromUnitPosition(unit)
  local n, w, _, instance = call(ns.api("UnitPosition"), unit)
  if type(n) == "number" and type(w) == "number" then
    return n, w, instance
  end
end

local function fromMap(unit)
  local mapId = call(ns.api("C_Map.GetBestMapForUnit"), unit)
  local pos = mapId and call(ns.api("C_Map.GetPlayerMapPosition"), mapId, unit)
  if not pos then
    return nil
  end
  local continent, world = call(ns.api("C_Map.GetWorldPosFromMapPos"), mapId, pos)
  if type(world) ~= "table" then
    return nil
  end
  local n, w = world.x, world.y
  if type(world.GetXY) == "function" then
    n, w = world:GetXY()
  end
  if type(n) == "number" and type(w) == "number" then
    return n, w, continent
  end
end

-- Own and peer position from one source: pn, pw, tn, tw, sameArea; nil when neither source knows both.
function A.positions(unit)
  for _, read in ipairs({ fromUnitPosition, fromMap }) do
    local pn, pw, pArea = read("player")
    local tn, tw, tArea = read(unit)
    if pn and tn then
      return pn, pw, tn, tw, pArea == tArea
    end
  end
end

local function facing()
  local f = call(ns.api("GetPlayerFacing"))
  return type(f) == "number" and f or nil
end

-- View model -----------------------------------------------------------------------------------

local function uiDB()
  if type(PortaxiDB) ~= "table" then
    return nil
  end
  PortaxiDB.ui = PortaxiDB.ui or {}
  return PortaxiDB.ui
end

local function currentRide()
  local Ride = ns.Ride
  local r = type(Ride) == "table" and type(Ride.current) == "function" and Ride.current() or nil
  return r or A.ride
end

local function isOver(r)
  local Ride = ns.Ride
  if type(Ride) == "table" and type(Ride.isOver) == "function" then
    return Ride.isOver(r)
  end
  return r == nil
end

-- What the arrow shows right now: { shown, name, yards, angle, close, far, text } (angle nil: no arrow).
function A.view()
  local r = currentRide()
  local db = uiDB() or {}
  local v = { shown = false }
  if not r or isOver(r) or db.arrowOff or A.hiddenFor == r.reqId or not A.wanted(r) then
    return v
  end
  local pn, pw, tn, tw, sameArea = A.positions(r.peerUnit)
  if not pn then
    return v -- no position API on this client: nothing useful to show
  end
  v.shown = true
  v.name = ns.firstName(r.peer.key)
  if not sameArea then
    v.far = true
    v.text = L["Not on your continent"]
    return v
  end
  local bearing, yards = A.vector(pn, pw, tn, tw)
  v.yards = math.floor(yards + 0.5)
  v.close = yards <= CLOSE
  v.text = v.close and L["Here"] or L["%d yd"]:format(v.yards)
  local f = facing()
  if f then
    v.angle = A.turn(bearing, f)
  end
  return v
end

-- Frame ----------------------------------------------------------------------------------------

local function savePosition(frame)
  local db = uiDB()
  local point, _, relPoint, x, y = frame:GetPoint()
  if db and point then
    db.arrow = { point = point, relPoint = relPoint or point, x = math.floor((x or 0) + 0.5),
                 y = math.floor((y or 0) + 0.5) }
  end
end

local function restorePosition(frame)
  local db = uiDB()
  local pos = db and db.arrow
  frame:ClearAllPoints()
  if type(pos) == "table" and pos.point then
    frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
  else
    frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
  end
end

local function draw(v)
  local f = A.frame
  A.last = v
  f.name:SetText(v.name or "")
  f.dist:SetText(v.text or "")
  W.setColor(f.dist, v.close and COL.OK or (v.far and COL.MUTED or COL.TEXT))
  if v.angle then
    f.arrow:SetRotation(v.angle)
    local c = v.close and COL.OK or COL.GOLD
    f.arrow:SetVertexColor(c[1], c[2], c[3], 1)
    f.arrow:Show()
  else
    f.arrow:Hide()
  end
end

local function build()
  local f = CreateFrame("Frame", FRAME_NAME, UIParent)
  f:SetSize(96, SIZE + 34)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- PortaxiDB.ui.arrow is the only saved position
    savePosition(self)
  end)
  f:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then
      A.hideForRide()
    end
  end)
  restorePosition(f)
  f.arrow = f:CreateTexture(nil, "ARTWORK")
  f.arrow:SetSize(SIZE, SIZE)
  f.arrow:SetPoint("TOP", f, "TOP", 0, 0)
  if not W.trySetTexture(f.arrow, W.MEDIA .. "arrow") then
    f.arrow:SetTexture(FALLBACK_TEXTURE)
  end
  f.name = W.label(f, "GameFontNormalSmall", COL.GOLD)
  f.name:SetPoint("TOP", f.arrow, "BOTTOM", 0, -1)
  f.dist = W.label(f, "GameFontHighlightSmall", COL.TEXT)
  f.dist:SetPoint("TOP", f.name, "BOTTOM", 0, -2)
  f:Hide()
  A.frame = f
  return f
end

-- Recomputes the view; shows, draws or hides the frame.
function A.update()
  local v = A.view()
  if not v.shown then
    if A.frame then
      A.frame:Hide()
    end
    A.last = v
    return v
  end
  local f = A.frame or build()
  draw(v)
  f:Show()
  return v
end

-- The driver updates the arrow while the ride wants one, also while the frame is hidden (the peer's position
-- may be unknown for a moment, e.g. while loading).
local driver = CreateFrame("Frame")
local elapsed = 0
local function onUpdate(_, dt)
  elapsed = elapsed + (dt or 0)
  if elapsed >= THROTTLE then
    elapsed = 0
    A.update()
  end
end

function A.refresh()
  local r = currentRide()
  local on = r ~= nil and not isOver(r) and A.wanted(r)
  driver:SetScript("OnUpdate", on and onUpdate or nil)
  A.running = on
  return A.update()
end

function A.hideForRide()
  local r = currentRide()
  A.hiddenFor = r and r.reqId or nil
  A.refresh()
  ns.say(L["Arrow hidden for this ride. /ptx arrow turns it off for good."])
end

function A.isShown()
  return A.frame ~= nil and A.frame:IsShown() == true
end

ns.on("RIDE_STARTED", function(r)
  A.ride, A.hiddenFor = r, nil
  A.refresh()
end)

ns.on("RIDE_STATE", function(r)
  A.ride = r
  A.refresh()
end)

local function arrowCommand()
  local db = uiDB()
  if not db then
    return
  end
  db.arrowOff = not db.arrowOff or nil
  A.hiddenFor = nil
  A.refresh()
  ns.say(db.arrowOff and L["Ride arrow off."] or L["Ride arrow on."])
end

ns.commands.arrow = { fn = arrowCommand, help = "turn the arrow to the other player of a ride off or on" }
