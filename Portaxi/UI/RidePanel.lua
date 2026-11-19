-- UI.RidePanel: the active ride in a small movable panel: destination emblem and name, peer, service and price,
-- a steps bar and the step list, a cast bar, the armed Portaxi button, notes, Cancel and the manual fallback
-- buttons (D11). Look of the mock v0.8 ride view (.ridehead, .steps, .check, .cast).
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "UI" and "Ride". Card H, wave 2; polished by card J, wave 3.
--   Global frame "PortaxiRidePanel", position in PortaxiDB.ui.ridePanel, built on the first RIDE_STARTED.
--   Shown on RIDE_STARTED; refreshed on RIDE_STATE, SECURE_CHANGED, TRADE_MANUAL, CAPS_CHANGED; hidden HIDE_DELAY
--   seconds after the ride ended. Reads Ride.current() / the last RIDE_STATE ride; acts only through Ride.*.
--   RidePanel.refresh() ; RidePanel.updateCast() ; RidePanel.frame ; RidePanel.view() -> table of what is shown
-- luacheck: read globals UnitCastingInfo

local _, ns = ...

ns.UI = ns.UI or {}
local P = {}
ns.UI.RidePanel = P

local L = ns.L
local W = ns.UI.Widgets
local COL = W.COLOR
local K = ns.Const

local FRAME_NAME = "PortaxiRidePanel"
local WIDTH, HEIGHT = 280, 396
local INNER = WIDTH - 24
local HIDE_DELAY = 8      -- seconds the panel stays after the ride ended
local CAST_THROTTLE = 0.05

local STEPS = { "Match", "Group", "TRAVEL", "Trade", "Portal", "Done" }
-- Index of the current step per state (steps before it are done).
local CURRENT_STEP = { MATCHED = 2, GROUPED = 3, EN_ROUTE = 3, ARRIVED = 4, TRADING = 4, PAID = 5, PORTAL_OPEN = 5,
                       DONE = 7 }

local STATUS = {
  MATCHED = "Forming the group",
  GROUPED = "In a group",
  EN_ROUTE = "On the way",
  ARRIVED = "Together",
  TRADING = "Trade the price",
  PAID = "Paid, waiting for the portal",
  PORTAL_OPEN = "The portal is open",
  DONE = "Arrived. Have a good trip!",
}

local REASON = {
  invite_timeout = "The group did not form in time.",
  peer_offline = "%s went offline.",
  left_group = "%s is no longer in the group.",
  peer_failed = "The ride failed on %s's side.",
  peer_cancelled = "%s cancelled the ride.",
  trade_timeout = "Nobody paid in time.",
  cancelled = "You cancelled the ride.",
}

P.ride = nil       -- last ride seen (kept after the end until the panel hides)
P.spec = nil       -- last SECURE_CHANGED spec
P.trade = {}       -- TRADE_MANUAL notes of this ride: open, short = { offered, price }, prefill = price
P.confirm = false  -- a late cancel waits for a second click
local hideGen = 0

-- Position ----------------------------------------------------------------------------------

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
    db.ridePanel = { point = point, relPoint = relPoint or point, x = math.floor((x or 0) + 0.5),
                     y = math.floor((y or 0) + 0.5) }
  end
end

local function restorePosition(frame)
  local db = uiDB()
  local pos = db and db.ridePanel
  frame:ClearAllPoints()
  if type(pos) == "table" and pos.point then
    frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
  else
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -120, 60)
  end
end

-- Building ----------------------------------------------------------------------------------

-- Header (the mock's .ridehead): the destination emblem with a gold ring, the title and the role under it.
local function buildHeader(f)
  local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
  bg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
  bg:SetHeight(64)
  W.gradient(bg, COL.TITLE_TOP, COL.PANEL)
  f.emblem = W.emblem(f, 40, "TOPLEFT", f, "TOPLEFT", 14, -12)
  f.icon = f.emblem.icon
  f.title = W.label(f, "GameFontNormal", COL.GOLD)
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 64, -17)
  f.title:SetWidth(INNER - 70)
  f.sub = W.label(f, "GameFontHighlightSmall", COL.MUTED)
  f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
  close:SetScript("OnClick", function() f:Hide() end)
  f.close = close
end

local function buildInfo(f)
  f.bar = W.steps(f, #STEPS, INNER)
  f.bar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -62)
  local card = W.card(f)
  card:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -74)
  card:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -74)
  card:SetHeight(56)
  f.peer = W.kv(card, L["Taxi"], -7)
  f.service = W.kv(card, L["Service"], -22)
  f.price = W.kv(card, L["Price"], -37)
  W.setColor(f.price, COL.GOLD)
end

-- The step list (the mock's .check): a marker and a line per step.
local function buildSteps(f)
  f.steps, f.marks = {}, {}
  for i = 1, #STEPS do
    local y = -140 - (i - 1) * 16
    local mark = W.texture(f, COL.OFF)
    mark:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y - 4)
    f.marks[i] = mark
    local fs = W.label(f, "GameFontHighlightSmall", COL.MUTED)
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 34, y)
    fs:SetWidth(INNER - 24)
    f.steps[i] = fs
  end
  f.status = W.label(f, "GameFontHighlight", COL.TEXT)
  f.status:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -242)
  f.status:SetWidth(INNER)
end

-- Cast bar of the mock (.cast): trimmed track, gold gradient fill, spell name and time left on it.
local function buildCastBar(f)
  local bar = W.panel(f, COL.DARK, COL.TRIM)
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -266)
  bar:SetSize(INNER, 16)
  bar.fill = bar:CreateTexture(nil, "ARTWORK")
  bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
  bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
  bar.fill:SetWidth(1)
  W.gradient(bar.fill, COL.CAST_TOP, COL.CAST_BOTTOM)
  bar.text = W.label(bar, "GameFontHighlightSmall", COL.TEXT, "CENTER")
  bar.text:SetPoint("CENTER")
  -- OnUpdate sits on the panel itself: a hidden frame gets no OnUpdate, and the bar starts hidden.
  local acc = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc >= CAST_THROTTLE then
      acc = 0
      P.updateCast()
    end
  end)
  bar:Hide()
  f.cast = bar
end

local function buildLines(f)
  f.secure = W.label(f, "GameFontHighlightSmall", COL.GOLD)
  f.secure:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -290)
  f.secure:SetWidth(INNER)
  f.notes = W.label(f, "GameFontHighlightSmall", COL.WARN)
  f.notes:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -316)
  f.notes:SetWidth(INNER)
end

local function buildButtons(f)
  W.hline(f, COL.ROW_LINE, -(HEIGHT - 44), 12, 12)
  f.cancel = W.button(f, L["Cancel"], 124, 26, "ghost")
  f.cancel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
  f.cancel:SetScript("OnClick", function() P.onCancel() end)
  f.manual = {}
  for _, what in ipairs({ "invite", "accept", "trade" }) do
    local text = (what == "invite" and L["Invite"]) or (what == "accept" and L["Accept"]) or L["Open trade"]
    local b = W.button(f, text, 124, 26)
    b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
    b:SetScript("OnClick", function() P.onManual(what) end)
    b:Hide()
    f.manual[what] = b
  end
end

local function build()
  local f = W.panel(UIParent, COL.PANEL, COL.TRIM, 2, FRAME_NAME)
  f:SetSize(WIDTH, HEIGHT)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- PortaxiDB.ui.ridePanel is the only saved position
    savePosition(self)
  end)
  restorePosition(f)
  buildHeader(f)
  buildInfo(f)
  buildSteps(f)
  buildCastBar(f)
  buildLines(f)
  buildButtons(f)
  f:Hide()
  P.frame = f
  return f
end

-- View model (pure-ish: reads the ride, caps and saved key; no frames) ----------------------------

local function ride()
  local Ride = ns.Ride
  local current = type(Ride) == "table" and type(Ride.current) == "function" and Ride.current() or nil
  return current or P.ride
end

local function isOver(r)
  return r.state == "DONE" or r.state == "CANCELLED" or r.state == "FAILED"
end

local function caps()
  return type(PortaxiDB) == "table" and type(PortaxiDB.caps) == "table" and PortaxiDB.caps or {}
end

local function cityName(r)
  local city = K.CITY[r.dest]
  return city and L[city.name] or tostring(r.dest)
end

local function serviceName(svc)
  return svc == "COME" and L["Come to you"] or L["Pickup"]
end

local function stepLabel(r, name)
  if name == "TRAVEL" then
    if r.svc == "COME" then
      return r.role == "taxi" and L["Teleport to the rider"] or L["The taxi teleports to you"]
    end
    return r.role == "taxi" and L["The rider walks to you"] or L["Walk to the taxi"]
  end
  return L[name]
end

local function statusText(r)
  if r.state == "CANCELLED" or r.state == "FAILED" then
    local head = r.state == "CANCELLED" and L["Ride cancelled"] or L["Ride failed"]
    local why = REASON[r.reason] and L[REASON[r.reason]]:format(r.peer.key) or tostring(r.reason or "")
    if r.state == "CANCELLED" and r.late then
      why = why .. " " .. L["Late cancel."]
    end
    return head .. ": " .. why
  end
  return L[STATUS[r.state] or r.state]
end

local function secureText(r)
  local spec = P.spec
  if r.role ~= "taxi" or not spec or isOver(r) then
    return ""
  end
  local text = L["Ready: %s. Click the Portaxi button"]:format(spec.label or "?")
  local key = type(PortaxiCharDB) == "table" and PortaxiCharDB.nextKey
  if key and key ~= "" then
    text = text .. " " .. L["(key %s)"]:format(key)
  end
  return text .. "."
end

local function notes(r)
  local out = {}
  if isOver(r) then
    return out
  end
  local rank = CURRENT_STEP[r.state] or 0
  if r.svc == "COME" and rank <= 3 and r.state ~= "EN_ROUTE" and r.riderResting == false then
    out[#out + 1] = r.role == "taxi"
      and L["The rider is not resting: the scroll is off. You can cancel for free."]
      or L["You are not resting: the scroll cannot reach you. Go back to an inn or a city."]
  end
  if r.svc == "COME" and r.role == "taxi" and r.state == "GROUPED" and r.scrollError then
    out[#out + 1] = r.scrollError == "unconfirmed"
      and L["The scroll did not take you to the rider. Try again."]
      or L["The scroll failed (%s): both of you must be resting. Try again."]:format(r.scrollError)
  end
  local c = caps()
  if r.svc == "COME" and r.role == "taxi" and rank <= 3 and r.state ~= "EN_ROUTE" and r.selfResting == false then
    out[#out + 1] = L["You are not resting: the scroll needs both of you in an inn or a city."]
  end
  if r.state == "MATCHED" then
    if r.role == "taxi" and (c.invite == "manual" or r.inviteManual) then
      out[#out + 1] = L["Automatic invite is off: click Invite."]
    elseif r.role == "rider" and (c.accept == "manual" or r.acceptManual) and r.invited then
      out[#out + 1] = L["Automatic accept is off: click Accept."]
    end
  end
  if P.trade.open and (r.state == "ARRIVED" or r.state == "TRADING") then
    out[#out + 1] = L["The trade did not open: click Open trade."]
  end
  local trading = r.state == "ARRIVED" or r.state == "TRADING"
  if P.trade.prefill and trading then
    out[#out + 1] = L["Put %s into the trade window yourself."]:format(W.money(P.trade.prefill))
  end
  if P.trade.short and trading then
    out[#out + 1] = L["The rider offers %s of %s. Do not accept yet."]:format(W.money(P.trade.short[1]),
      W.money(P.trade.short[2]))
  end
  return out
end

-- Which manual buttons apply now.
local function manualButtons(r)
  local c = caps()
  local out = {}
  if isOver(r) then
    return out
  end
  out.invite = r.role == "taxi" and r.state == "MATCHED" and (c.invite == "manual" or r.inviteManual == true)
  out.accept = r.role == "rider" and r.state == "MATCHED" and (c.accept == "manual" or r.acceptManual == true)
    and r.invited == true
  out.trade = r.role == "taxi" and (r.state == "ARRIVED" or r.state == "TRADING")
    and (c.openTrade == "manual" or P.trade.open == true)
  return out
end

-- Cancel button: shown only when Ride.canCancel allows it; a late cancel asks for a second click.
local function cancelButton(r)
  local Ride = ns.Ride
  local can, late = nil, false
  if type(Ride) == "table" and type(Ride.canCancel) == "function" and not isOver(r) then
    can, late = Ride.canCancel(r)
  end
  if not can then
    return { shown = false }
  end
  if late then
    return { shown = true, late = true, text = P.confirm and L["Confirm late cancel"] or L["Cancel (late)"] }
  end
  return { shown = true, late = false, text = L["Cancel (free)"] }
end

-- Everything the panel shows, as plain data (tests read this).
function P.view()
  local r = ride()
  if not r then
    return nil
  end
  local current = CURRENT_STEP[r.state] or P.lastStep or 2
  local steps = {}
  for i, name in ipairs(STEPS) do
    steps[i] = { text = stepLabel(r, name), done = i < current, current = i == current }
  end
  return {
    title = L["Ride to %s"]:format(cityName(r)),
    sub = r.role == "taxi" and L["You drive"] or L["You ride"],
    peerKey = r.role == "taxi" and L["Rider"] or L["Taxi"],
    peer = r.peer.key,
    service = serviceName(r.svc),
    price = W.money(r.price),
    steps = steps,
    status = statusText(r),
    secure = secureText(r),
    notes = notes(r),
    manual = manualButtons(r),
    cancel = cancelButton(r),
    over = isOver(r),
  }
end

-- Drawing -------------------------------------------------------------------------------------

-- Done steps: green mark, muted text; the current one: bigger gold mark, gold text; later ones: dim.
local function drawSteps(f, steps)
  local lit = 0
  for i, s in ipairs(steps) do
    local fs, mark = f.steps[i], f.marks[i]
    fs:SetText(s.text)
    W.setColor(fs, s.done and COL.TEXT or (s.current and COL.GOLD or COL.MUTED))
    local color = s.done and COL.OK or (s.current and COL.GOLD or COL.OFF)
    mark:SetVertexColor(color[1], color[2], color[3], 1)
    mark:SetSize(s.current and 8 or 6, s.current and 8 or 6)
    if s.done or s.current then
      lit = i
    end
  end
  W.setSteps(f.bar, lit)
end

local function drawButtons(f, v)
  for what, b in pairs(f.manual) do
    b:SetShown(v.manual[what] == true)
  end
  f.cancel:SetShown(v.cancel.shown)
  if v.cancel.shown then
    f.cancel:SetText(v.cancel.text)
  end
end

function P.refresh()
  local f = P.frame
  local v = P.view()
  if not (f and v) then
    return
  end
  local r = ride()
  if not isOver(r) then
    P.lastStep = CURRENT_STEP[r.state]
  end
  W.setEmblem(f.emblem, r.dest)
  W.setEmblemState(f.emblem, "plain")
  local profile = W.current()
  W.setBorder(f, W.trimFor(profile and profile.faction))
  f.title:SetText(v.title)
  f.sub:SetText(v.sub)
  f.peer.key:SetText(v.peerKey)
  f.peer:SetText(v.peer)
  f.service:SetText(v.service)
  f.price:SetText(v.price)
  drawSteps(f, v.steps)
  f.status:SetText(v.status)
  W.setColor(f.status, (r.state == "FAILED" or r.state == "CANCELLED") and COL.WARN
    or (r.state == "DONE" and COL.OK or COL.TEXT))
  f.secure:SetText(v.secure)
  f.notes:SetText(table.concat(v.notes, "\n"))
  drawButtons(f, v)
  P.updateCast()
end

-- Cast bar: the scroll or portal being cast by the taxi ("player" on the taxi side, peerUnit on the rider side).
local function castUnit(r)
  if r.role == "taxi" then
    return "player"
  end
  return r.peerUnit
end

local function rideSpell(r, spellId)
  if spellId == nil then
    return false
  end
  local city = K.CITY[r.dest]
  return spellId == K.SPELL.LIMINAL_PASSAGE or (city ~= nil and spellId == city.spell)
end

function P.updateCast()
  local f = P.frame
  local r = ride()
  if not (f and r) then
    return
  end
  local unit = not isOver(r) and castUnit(r)
  local name, startMs, endMs, spellId
  if unit then
    local n, _, _, s, e, _, _, _, id = UnitCastingInfo(unit)
    name, startMs, endMs, spellId = n, s, e, tonumber(id)
  end
  if not (name and startMs and endMs and endMs > startMs and rideSpell(r, spellId)) then
    f.cast:Hide()
    return
  end
  local nowMs = GetTime() * 1000
  local progress = math.max(0, math.min(1, (nowMs - startMs) / (endMs - startMs)))
  f.cast.fill:SetWidth(math.max(1, (INNER - 2) * progress))
  f.cast.text:SetText(("%s %.1f s"):format(name, math.max(0, (endMs - nowMs) / 1000)))
  f.cast.progress = progress
  f.cast:Show()
end

-- Buttons ---------------------------------------------------------------------------------------

function P.onCancel()
  local Ride = ns.Ride
  local r = ride()
  if not (r and type(Ride) == "table" and type(Ride.cancel) == "function") then
    return
  end
  local v = cancelButton(r)
  if v.late and not P.confirm then
    P.confirm = true
    P.refresh()
    return
  end
  P.confirm = false
  Ride.cancel("cancelled")
  P.refresh()
end

function P.onManual(what)
  local Ride = ns.Ride
  if type(Ride) == "table" and type(Ride.manual) == "function" then
    Ride.manual(what)
  end
  if what == "trade" then
    P.trade.open = false
  end
  P.refresh()
end

-- Events ------------------------------------------------------------------------------------------

local function scheduleHide()
  hideGen = hideGen + 1
  local gen = hideGen
  C_Timer.After(HIDE_DELAY, function()
    if gen == hideGen and P.frame then
      P.frame:Hide()
    end
  end)
end

ns.on("RIDE_STARTED", function(r)
  hideGen = hideGen + 1 -- a pending hide of the previous ride is void
  P.ride, P.spec, P.trade, P.confirm, P.lastStep = r, nil, {}, false, nil
  local f = P.frame or build()
  f:Show()
  P.refresh()
end)

ns.on("RIDE_STATE", function(r)
  local stateChanged = not P.ride or P.ride.state ~= r.state
  P.ride = r
  if stateChanged then
    P.confirm = false
  end
  if isOver(r) then
    P.spec = nil
    scheduleHide()
  end
  P.refresh()
end)

ns.on("SECURE_CHANGED", function(spec)
  P.spec = spec
  P.refresh()
end)

ns.on("TRADE_MANUAL", function(what, a, b)
  if what == "open" then
    P.trade.open = true
  elseif what == "prefill" then
    P.trade.prefill = a
  elseif what == "short" then
    P.trade.short = { a, b }
  end
  P.refresh()
end)

ns.on("CAPS_CHANGED", function()
  P.refresh()
end)
