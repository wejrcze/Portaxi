-- UI.MapPins: taxis on the map (D19, docs/FIELD_TAXI_PLAN.md) as pins on the world map. A pin is a soft ring of
-- one grid cell (the taxi is somewhere in there; its client rounds the position before sending it) with a portal
-- icon in the middle. Hover: name, level, price, distance and the walk; click books the ride to the city chosen
-- in the Ride tab (UI.RideTab.book, the same path as Browse). A busy taxi (fighting, on a ride) is grey and
-- cannot be booked.
--
--   Shown only when Field.nearby(RideTab.dest) has entries: the rider chose a city, is not resting, not on a
--   ride, not in an instance. The pins redraw every REFRESH s while the world map is open; the driver frame is a
--   child of WorldMapFrame, so nothing runs while the map is closed.
--   MapPins.view(mapId) -> { { entry, x, y, r } } map positions (0..1) of the pins on that map, r = ring radius
--   as a share of the map height ; MapPins.refresh() ; MapPins.attach() -> bool ; MapPins.pins
--   MapPins.level, MapPins.levelSource: the frame level the pins got and where from ("manager" | "canvas").
--
-- Frame level: the map draws its layers (explored areas, POIs, the player arrow) on frame levels handed out by
-- WorldMapFrame:GetPinFrameLevelsManager(). A pin a few levels above the canvas is hidden under the explored
-- area tiles while the mouse still finds it (in game 2026-11-19: tooltip, no pin). Pins take the level of
-- area POIs, above the map, below the player arrow; without the manager, far above the canvas.
--
-- Needs WorldMapFrame.ScrollContainer.Child (the map canvas) and C_Map.GetMapPosFromWorldPos; without them there
-- are no pins and Browse still lists the taxis. Unverified on Forever (plan §5 F2, F4).
-- luacheck: read globals WorldMapFrame GameTooltip CreateVector2D

local _, ns = ...

ns.UI = ns.UI or {}
local P = { pins = {} }
ns.UI.MapPins = P

local L = ns.L
local W = ns.UI.Widgets
local COL = W.COLOR

local REFRESH = 0.5
local ICON = 18
local RING_MIN = 14
local SERVICE = "Pickup"
local LEVEL_TYPE = "PIN_FRAME_LEVEL_AREA_POI"
local LEVEL_FALLBACK = 1000 -- above the canvas when the map has no frame level manager

-- Map positions ----------------------------------------------------------------------------------

local function call(fn, ...)
  if not fn then
    return nil
  end
  local ok, a, b = pcall(fn, ...)
  if ok then
    return a, b
  end
end

local function vector(n, w)
  local make = ns.api("CreateVector2D")
  return make and make(n, w) or { x = n, y = w }
end

local function xy(pos)
  if type(pos) ~= "table" then
    return nil
  end
  if type(pos.GetXY) == "function" then
    return pos:GetXY()
  end
  return pos.x, pos.y
end

-- Where a world position lies on the map mapId: x, y (0..1) or nil when it is off that map.
local function mapPos(inst, n, w, mapId)
  local _, pos = call(ns.api("C_Map.GetMapPosFromWorldPos"), inst, vector(n, w), mapId)
  local x, y = xy(pos)
  if type(x) == "number" and type(y) == "number" and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
    return x, y
  end
end

local function riderDest()
  local R = ns.UI.RideTab
  return type(R) == "table" and R.dest or nil
end

function P.view(mapId)
  local F = ns.Field
  if not (mapId and type(F) == "table" and type(F.nearby) == "function") then
    return {}
  end
  local out = {}
  local grid = ns.Const.FIELD.GRID
  for _, entry in ipairs((F.nearby(riderDest()))) do
    local spot = entry.spot
    local x, y = mapPos(spot.inst, spot.n, spot.w, mapId)
    if x then
      local _, ny = mapPos(spot.inst, spot.n + grid, spot.w, mapId)
      out[#out + 1] = { entry = entry, x = x, y = y, r = ny and math.abs(ny - y) or 0 }
    end
  end
  return out
end

-- Pins -------------------------------------------------------------------------------------------

local function canvas()
  local wm = WorldMapFrame
  return type(wm) == "table" and type(wm.ScrollContainer) == "table" and wm.ScrollContainer.Child or nil
end

local function canvasScale()
  local sc = WorldMapFrame.ScrollContainer
  local s = type(sc.GetCanvasScale) == "function" and sc:GetCanvasScale() or 1
  return (type(s) == "number" and s > 0) and s or 1
end

local function showTooltip(pin)
  local e = pin.entry
  if not e then
    return
  end
  local city = W.cityName(riderDest())
  GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
  GameTooltip:SetText(e.key)
  GameTooltip:AddLine(("%s %s · %s %s"):format(W.className(e.offer.cls), tostring(e.offer.lvl or ""), L[SERVICE],
    W.money(e.price)), 1, 1, 1)
  GameTooltip:AddLine(L["~%d yd · ~%d s on foot"]:format(math.floor(e.yards + 0.5), e.walk), 1, 1, 1)
  if e.self then
    GameTooltip:AddLine(L["This is you (test view)."], unpack(COL.MUTED))
  elseif e.busy then
    GameTooltip:AddLine(L["Busy: fighting or on a ride."], unpack(COL.WARN))
  else
    GameTooltip:AddLine(L["Click: ride to %s"]:format(city), unpack(COL.GOLD))
  end
  GameTooltip:Show()
end

local function onClick(pin)
  local e = pin.entry
  local R = ns.UI.RideTab
  if e and e.self then
    ns.say(L["This is you (test view)."])
    return
  end
  if not (e and not e.busy and type(R) == "table" and type(R.book) == "function") then
    return
  end
  R.book(e)
  if R.error then
    ns.say(L[R.ERRORS[R.error] or "The network is not ready. Try again in a moment."])
  else
    ns.say(L["Asked %s for a ride to %s."]:format(e.key, W.cityName(riderDest())))
  end
end

-- The area: a soft green fill with a clear edge, so it shows on the orange and brown of the map.
local function newPin(parent)
  local ring = CreateFrame("Frame", nil, parent)
  ring.tex = ring:CreateTexture(nil, "ARTWORK")
  ring.tex:SetAllPoints()
  W.trySetTexture(ring.tex, W.MEDIA .. "glow")
  ring.edge = ring:CreateTexture(nil, "OVERLAY")
  ring.edge:SetAllPoints()
  W.trySetTexture(ring.edge, W.MEDIA .. "ring")
  local pin = CreateFrame("Button", nil, parent)
  pin:SetSize(ICON, ICON)
  pin.icon = pin:CreateTexture(nil, "OVERLAY")
  pin.icon:SetAllPoints()
  W.trySetTexture(pin.icon, W.MEDIA .. "portal")
  pin.ring = ring
  pin:SetScript("OnEnter", showTooltip)
  pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
  pin:SetScript("OnClick", onClick)
  return pin
end

local function hideFrom(i)
  for j = i, #P.pins do
    P.pins[j]:Hide()
    P.pins[j].ring:Hide()
    P.pins[j].entry = nil
  end
end

local function pinLevel(child)
  local wm = WorldMapFrame
  local manager = type(wm.GetPinFrameLevelsManager) == "function" and call(wm.GetPinFrameLevelsManager, wm)
  if type(manager) == "table" and type(manager.GetValidFrameLevel) == "function" then
    local level = call(manager.GetValidFrameLevel, manager, LEVEL_TYPE)
    if type(level) == "number" then
      return level, "manager"
    end
  end
  return (child:GetFrameLevel() or 0) + LEVEL_FALLBACK, "canvas"
end

function P.refresh()
  local child = canvas()
  if not (child and WorldMapFrame:IsShown()) then
    hideFrom(1)
    return
  end
  local mapId = call(WorldMapFrame.GetMapID, WorldMapFrame)
  local list = P.view(mapId)
  local w, h = child:GetWidth() or 0, child:GetHeight() or 0
  local inv = 1 / canvasScale() -- the icon keeps its size when the map zooms; the ring is map area and zooms
  local level, source = pinLevel(child)
  P.level, P.levelSource = level, source
  for i, v in ipairs(list) do
    local pin = P.pins[i] or newPin(child)
    P.pins[i] = pin
    pin.entry = v.entry
    local size = math.max(RING_MIN, 2 * v.r * h)
    pin.ring:SetSize(size, size)
    pin.ring:ClearAllPoints()
    pin.ring:SetPoint("CENTER", child, "TOPLEFT", v.x * w, -v.y * h)
    pin.ring:SetFrameLevel(level)
    pin.ring:Show()
    pin:SetScale(inv)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", child, "TOPLEFT", v.x * w / inv, -v.y * h / inv)
    pin:SetFrameLevel(level + 1)
    local color = v.entry.busy and COL.MUTED or COL.OK
    pin.icon:SetDesaturated(v.entry.busy == true)
    pin.ring.tex:SetVertexColor(color[1], color[2], color[3], v.entry.busy and 0.35 or 0.7)
    pin.ring.edge:SetVertexColor(color[1], color[2], color[3], v.entry.busy and 0.6 or 1)
    pin:Show()
  end
  hideFrom(#list + 1)
end

-- Lifecycle --------------------------------------------------------------------------------------

local driver = nil

function P.attach()
  if driver then
    return true
  end
  if not canvas() then
    return false
  end
  driver = CreateFrame("Frame", nil, WorldMapFrame)
  local elapsed = REFRESH
  driver:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= REFRESH then
      elapsed = 0
      P.refresh()
    end
  end)
  driver:SetScript("OnHide", function() hideFrom(1) end)
  return true
end

ns.on("READY", function()
  if not P.attach() then
    -- The world map may load later (Blizzard_WorldMap on demand).
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self)
      if P.attach() then
        self:UnregisterEvent("ADDON_LOADED")
      end
    end)
  end
end)
