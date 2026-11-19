-- UI.HopTab: Inn hop (D20). The Hop tab (shown only to a mage with scrolls, R5): scroll and resting status, the
-- places where hosts with Portaxi rest now with a "Hop here" button, the state of the open request, and the /who
-- fallback (zone box, Search, players with an Ask button). Also the host's request popup ("PortaxiHopRequest":
-- raid warning, sound, Accept / Decline with a countdown) and the host toggle that the Ride tab shows.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Inn hop (D20)". Data: Detect.hop, Hop.places / status, Who.results;
-- actions: Hop.request / answer / setHosting, Who.search / ask. Every click is the player's (hardware event).
-- luacheck: read globals RaidNotice_AddMessage RaidWarningFrame ChatTypeInfo PlaySound SOUNDKIT

local _, ns = ...

ns.UI = ns.UI or {}
local H = ns.UI.HopTab or {}
ns.UI.HopTab = H

local L = ns.L
local W = ns.UI.Widgets
local C = W.COLOR

local PAGE_W = 352
local ROWS, ROW_H = 5, 34
local WHO_ROWS = 6
local POPUP_NAME = "PortaxiHopRequest"

local Y = { status = 0, pauses = -18, placesHead = -48, places = -68, request = -244, whoHead = -276,
            whoBox = -298, who = -328 }

local PAUSE_TEXT = {
  NOT_MAGE = "Only mages can hop.",
  NO_SCROLL = "No Scroll of Liminal Passage in your bags.",
  NOT_RESTING = "Rest in an inn or a city first: the scroll needs both of you resting.",
  IN_GROUP = "Leave your group first: the hop forms a group of two.",
}

local RESULT_TEXT = {
  declined = "%s declined.",
  busy = "%s is busy right now.",
  timeout = "No answer from %s.",
  cancelled = "Request withdrawn.",
}

local ERROR_TEXT = {
  state = "You cannot hop right now.",
  busy = "A request or a ride is already running.",
  retry = "You asked this host a moment ago. Try another one or wait a minute.",
  host = "That host is gone or busy.",
  zone = "Type a zone first.",
  cooldown = "Wait a few seconds between searches.",
  who = "That player is not in the last search.",
}

-- Helpers -----------------------------------------------------------------------------------------

local function module(name, fn)
  local m = ns[name]
  return type(m) == "table" and type(m[fn]) == "function" and m[fn] or nil
end

local function hopOf(profile)
  local D = ns.Detect
  if profile and type(D) == "table" and type(D.hop) == "function" then
    return D.hop(profile)
  end
end

-- The Hop tab is for a mage who has scrolls at all (R5); resting and group only pause it.
function H.wanted(profile)
  return profile ~= nil and profile.class == "MAGE" and (tonumber(profile.scrolls) or 0) > 0
end

local function activeRide()
  local f = module("Ride", "current")
  return f and f() or nil
end

-- Building ----------------------------------------------------------------------------------------

local function placeRow(list, i)
  local row = CreateFrame("Frame", nil, list)
  row:SetSize(PAGE_W - 2, ROW_H)
  row:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1 - (i - 1) * ROW_H)
  if i > 1 then
    W.hline(row, C.ROW_LINE, 0)
  end
  row.emblem = W.emblem(row, 22, "LEFT", row, "LEFT", 9, 0)
  row.place = W.label(row, "GameFontHighlightSmall", C.TEXT)
  row.place:SetPoint("TOPLEFT", row, "TOPLEFT", 38, -5)
  row.place:SetWidth(220)
  row.hosts = W.label(row, "GameFontHighlightSmall", C.MUTED)
  row.hosts:SetPoint("TOPLEFT", row.place, "BOTTOMLEFT", 0, -2)
  row.hosts:SetWidth(220)
  row.go = W.button(row, L["Hop here"], 74, 22)
  row.go:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.go:SetScript("OnClick", function()
    if row.entry then
      H.hop(row.entry.hosts[1].key)
    end
  end)
  return row
end

local function whoRow(list, i)
  local row = CreateFrame("Frame", nil, list)
  row:SetSize(PAGE_W - 2, 26)
  row:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1 - (i - 1) * 26)
  row.text = W.label(row, "GameFontHighlightSmall", C.TEXT)
  row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
  row.text:SetWidth(250)
  row.ask = W.button(row, L["Ask"], 60, 20, "ghost")
  row.ask:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.ask:SetScript("OnClick", function()
    if row.entry then
      H.ask(row.entry.key)
    end
  end)
  return row
end

function H.build(page)
  local ui = {}
  H.ui, H.page = ui, page
  ui.status = W.label(page, "GameFontHighlight", C.TEXT)
  ui.status:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.status)
  ui.status:SetWidth(PAGE_W)
  ui.pauses = W.label(page, "GameFontHighlightSmall", C.WARN)
  ui.pauses:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.pauses)
  ui.pauses:SetWidth(PAGE_W)

  local head = W.section(page, L["Hosts resting now"])
  head:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.placesHead)
  head:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.placesHead)
  ui.places = W.panel(page, C.PANEL, C.EDGE)
  ui.places:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.places)
  ui.places:SetSize(PAGE_W, ROWS * ROW_H + 2)
  ui.placesEmpty = W.label(ui.places, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.placesEmpty:SetPoint("CENTER")
  ui.placesEmpty:SetWidth(PAGE_W - 20)
  ui.rows = {}
  for i = 1, ROWS do
    ui.rows[i] = placeRow(ui.places, i)
  end
  ui.request = W.label(page, "GameFontHighlightSmall", C.MUTED)
  ui.request:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.request)
  ui.request:SetWidth(PAGE_W)

  local whoHead = W.section(page, L["No host there? Ask players by /who"])
  whoHead:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.whoHead)
  whoHead:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.whoHead)
  ui.zone = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  ui.zone:SetSize(250, 22)
  ui.zone:SetPoint("TOPLEFT", page, "TOPLEFT", 6, Y.whoBox)
  ui.zone:SetAutoFocus(false)
  ui.zone:SetMaxLetters(48)
  ui.zone:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    H.search()
  end)
  ui.search = W.button(page, L["Search"], 84, 22, "ghost")
  ui.search:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.whoBox)
  ui.search:SetScript("OnClick", function() H.search() end)
  ui.who = W.panel(page, C.PANEL, C.EDGE)
  ui.who:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.who)
  ui.who:SetSize(PAGE_W, WHO_ROWS * 26 + 2)
  ui.whoEmpty = W.label(ui.who, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.whoEmpty:SetPoint("CENTER")
  ui.whoEmpty:SetWidth(PAGE_W - 20)
  ui.whoRows = {}
  for i = 1, WHO_ROWS do
    ui.whoRows[i] = whoRow(ui.who, i)
  end
  ui.whoNote = W.label(page, "GameFontHighlightSmall", C.MUTED)
  ui.whoNote:SetPoint("TOPLEFT", ui.who, "BOTTOMLEFT", 0, -4)
  ui.whoNote:SetWidth(PAGE_W - 110)
  ui.whoNext = W.button(page, ">", 24, 18, "ghost")
  ui.whoNext:SetPoint("TOPRIGHT", ui.who, "BOTTOMRIGHT", 0, -3)
  ui.whoNext:SetScript("OnClick", function() H.whoPage(1) end)
  ui.whoPrev = W.button(page, "<", 24, 18, "ghost")
  ui.whoPrev:SetPoint("RIGHT", ui.whoNext, "LEFT", -2, 0)
  ui.whoPrev:SetScript("OnClick", function() H.whoPage(-1) end)
  ui.whoPos = W.label(page, "GameFontHighlightSmall", C.MUTED, "RIGHT")
  ui.whoPos:SetPoint("RIGHT", ui.whoPrev, "LEFT", -6, 0)
  return page
end

-- View (plain data, tests read it) ----------------------------------------------------------------

local function hostsText(place)
  local names = {}
  for i, h in ipairs(place.hosts) do
    if i > 2 then
      names[#names + 1] = "..."
      break
    end
    names[#names + 1] = ("%s (%s)"):format(h.key, tostring(h.lvl or "?"))
  end
  local n = #place.hosts
  return (n == 1 and L["1 host"] or L["%d hosts"]:format(n)) .. " · " .. table.concat(names, ", ")
end

local function requestText(st)
  if H.error then
    return L[ERROR_TEXT[H.error] or "The network is not ready. Try again in a moment."], true
  end
  local r = activeRide()
  if r and r.svc == "HOP" then
    return L["Hop to %s is on: follow the ride panel."]:format(r.peer.key), false
  end
  if st.request then
    local left = math.max(0, math.floor(ns.Const.T.HOP_ANSWER - (ns.now() - st.request.since)))
    return L["Asking %s... (%d s)"]:format(st.request.key, left), false
  end
  local last = st.last
  if last and not last.ok then
    return L[RESULT_TEXT[last.why] or "%s did not take it."]:format(last.key), true
  end
  return "", false
end

-- "Zorg Axehand · 22 Warrior · The Crossroads (inn)": players in a town with an inn are marked (Who.isInn).
local function whoText(entry)
  local area = tostring(entry.area or "")
  if entry.inn then
    area = area .. " " .. L["(inn)"]
  end
  return ("%s · %s %s · %s"):format(entry.key, tostring(entry.level or "?"), tostring(entry.class or ""), area)
end

H.whoFirst = 1 -- index of the first /who result shown (pages of WHO_ROWS)

function H.view(profile)
  local hop = hopOf(profile) or { hopPauses = {}, HOP = false }
  local places = module("Hop", "places") and ns.Hop.places() or {}
  local st = module("Hop", "status") and ns.Hop.status() or {}
  local busy = st.request ~= nil or activeRide() ~= nil
  local pauses = {}
  for _, code in ipairs(hop.hopPauses or {}) do
    pauses[#pauses + 1] = L[PAUSE_TEXT[code] or code]
  end
  local list = {}
  for i, place in ipairs(places) do
    list[i] = { label = place.label, city = place.city, hosts = hostsText(place), entry = place,
                enabled = hop.HOP == true and not busy }
  end
  local whoList, whoZone, whoTown = {}, nil, nil
  if module("Who", "results") then
    whoList, whoZone, whoTown = ns.Who.results()
  end
  whoList = whoList or {}
  if H.whoFirst > #whoList then
    H.whoFirst = 1
  end
  local asked = module("Who", "awaiting") and ns.Who.awaiting() or {}
  -- Asking takes a while (whisper, then their invite), so it is fine on the way to the inn: only resting may be
  -- missing. The scroll itself still waits for both of you resting.
  local canAsk = true
  for _, code in ipairs(hop.hopPauses or {}) do
    if code ~= "NOT_RESTING" then
      canAsk = false
    end
  end
  local who, inns = {}, 0
  for i, entry in ipairs(whoList) do
    who[i] = { text = whoText(entry), entry = entry, asked = asked[entry.key] ~= nil,
               enabled = profile ~= nil and canAsk and not busy }
    if entry.inn then
      inns = inns + 1
    end
  end
  local last = math.min(#who, H.whoFirst + WHO_ROWS - 1)
  local request, warn = requestText(st)
  return {
    status = L["Scrolls: %d · resting: %s"]:format(tonumber(profile and profile.scrolls) or 0,
      (profile and profile.resting) and L["yes"] or L["no"]),
    pauses = table.concat(pauses, "\n"),
    places = list,
    empty = #list == 0 and L["Nobody hosts right now. Hosts appear here while they rest in an inn or a city."]
      or nil,
    request = request,
    requestWarn = warn,
    who = who,
    whoFirst = H.whoFirst,
    whoPos = #who > 0 and L["%d-%d of %d"]:format(H.whoFirst, last, #who) or "",
    whoPrev = H.whoFirst > 1,
    whoNext = last < #who,
    whoEmpty = #who == 0 and (whoZone and L["Nobody found in %s."]:format(whoTown or whoZone)
      or L["Type a town with an inn or a zone, e.g. The Crossroads, and click Search."]) or nil,
    whoNote = next(asked) and L["Asked players invite you; accept the invite yourself, then click the Portaxi button."]
      or (#who > 0 and L["%d in a town with an inn, listed first."]:format(inns) or ""),
  }
end

-- Refresh -----------------------------------------------------------------------------------------

function H.refresh(profile)
  local ui = H.ui
  if not ui then
    return
  end
  H.profile = profile
  local v = H.view(profile)
  ui.status:SetText(v.status)
  ui.pauses:SetText(v.pauses)
  for i, row in ipairs(ui.rows) do
    local p = v.places[i]
    row.entry = p and p.entry
    row:SetShown(p ~= nil)
    if p then
      row.place:SetText(p.label)
      row.hosts:SetText(p.hosts)
      W.setEmblem(row.emblem, p.city)
      W.setEmblemState(row.emblem, "plain")
      W.setEnabled(row.go, p.enabled)
    end
  end
  ui.placesEmpty:SetShown(v.empty ~= nil)
  ui.placesEmpty:SetText(v.empty or "")
  ui.request:SetText(v.request)
  W.setColor(ui.request, v.requestWarn and C.WARN or C.MUTED)
  for i, row in ipairs(ui.whoRows) do
    local w = v.who[v.whoFirst + i - 1]
    row.entry = w and w.entry
    row:SetShown(w ~= nil)
    if w then
      row.text:SetText(w.text)
      row.ask:SetText(w.asked and L["Asked"] or L["Ask"])
      W.setEnabled(row.ask, w.enabled)
    end
  end
  ui.whoEmpty:SetShown(v.whoEmpty ~= nil)
  ui.whoEmpty:SetText(v.whoEmpty or "")
  ui.whoNote:SetText(v.whoNote)
  ui.whoPos:SetText(v.whoPos)
  ui.whoPrev:SetShown(v.whoPrev or v.whoNext)
  ui.whoNext:SetShown(v.whoPrev or v.whoNext)
  W.setEnabled(ui.whoPrev, v.whoPrev)
  W.setEnabled(ui.whoNext, v.whoNext)
end

-- Pages through the /who results by WHO_ROWS.
function H.whoPage(dir)
  local list = module("Who", "results") and ns.Who.results() or {}
  local first = H.whoFirst + dir * WHO_ROWS
  if first >= 1 and first <= #list then
    H.whoFirst = first
  end
  H.redraw()
end

function H.redraw()
  H.refresh(H.profile or (W.current()))
end

-- Actions (from clicks) ---------------------------------------------------------------------------

local function result(ok, err)
  H.error = (not ok) and err or nil
  H.redraw()
  H.error = nil
end

function H.hop(hostKey)
  local f = module("Hop", "request")
  if f then
    result(f(hostKey))
  end
end

function H.search()
  local f = module("Who", "search")
  if f and H.ui then
    result(f(H.ui.zone:GetText() or ""))
  end
end

function H.ask(key)
  local f = module("Who", "ask")
  if f then
    result(f(key))
  end
end

local function redrawIfVisible()
  if H.page and H.page:IsVisible() then
    H.redraw()
  end
end

ns.on("WHO_RESULTS", function()
  H.whoFirst = 1 -- a new search starts on its first page
end)

for _, event in ipairs({ "HOSTS_CHANGED", "HOP_CHANGED", "HOP_RESULT", "WHO_RESULTS", "WHO_CHANGED", "RIDE_STARTED",
  "RIDE_STATE" }) do
  ns.on(event, redrawIfVisible)
end

-- Host toggle (shown on the Ride tab) --------------------------------------------------------------

-- Text of the host toggle and whether hosting is on.
function H.hostToggle()
  local on = module("Hop", "hosting") and ns.Hop.hosting() or false
  return on and L["Hosting: on"] or L["Hosting: off"], on
end

function H.toggleHosting()
  local f = module("Hop", "setHosting")
  if f then
    f(not ns.Hop.hosting())
  end
end

-- Host: request popup ---------------------------------------------------------------------------

local popupTicker = nil

local function buildPopup()
  local f = W.panel(UIParent, C.PANEL, C.TRIM, 2, POPUP_NAME)
  f:SetSize(280, 104)
  f:SetFrameStrata("DIALOG")
  f:SetPoint("TOP", UIParent, "TOP", 0, -180)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f.title = W.label(f, "GameFontNormal", C.GOLD)
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
  f.title:SetText(L["Inn hop request"])
  f.text = W.label(f, "GameFontHighlightSmall", C.TEXT)
  f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
  f.text:SetWidth(256)
  f.left = W.label(f, "GameFontHighlightSmall", C.MUTED)
  f.left:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -4)
  f.accept = W.button(f, L["Accept"], 100, 22)
  f.accept:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
  f.accept:SetScript("OnClick", function() H.answer(true) end)
  f.decline = W.button(f, L["Decline"], 100, 22, "ghost")
  f.decline:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
  f.decline:SetScript("OnClick", function() H.answer(false) end)
  f:Hide()
  return f
end

local function stopTicker()
  if popupTicker then
    popupTicker:Cancel()
    popupTicker = nil
  end
end

local function popupLeft(req)
  return math.max(0, math.floor(ns.Const.T.HOP_ANSWER - (ns.now() - req.at)))
end

function H.popupText(req)
  return L["%s (mage, level %d) wants to teleport to you with a scroll. Stay rested until they arrive."]:format(
    req.key, tonumber(req.lvl) or 0)
end

function H.updatePopup()
  local f = H.popup
  if not f then
    return
  end
  local st = module("Hop", "status") and ns.Hop.status() or {}
  local req = st.incoming
  if not req then
    f:Hide()
    stopTicker()
    return
  end
  f.req = req
  f.text:SetText(H.popupText(req))
  f.left:SetText(L["Answer within %d s."]:format(popupLeft(req)))
  f:Show()
end

local function alert(req)
  local text = L["Portaxi: %s wants to hop to you"]:format(req.key)
  if RaidNotice_AddMessage and RaidWarningFrame then
    local color = ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.1 }
    pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color)
  end
  if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
    pcall(PlaySound, SOUNDKIT.RAID_WARNING)
  end
end

function H.answer(ok)
  local f = H.popup
  local req = f and f.req
  local answer = module("Hop", "answer")
  if req and answer then
    answer(req.reqId, ok)
  end
  H.updatePopup()
end

ns.on("HOP_REQUEST", function(req)
  H.popup = H.popup or buildPopup()
  alert(req)
  H.updatePopup()
  stopTicker()
  popupTicker = C_Timer.NewTicker(1, H.updatePopup)
end)
ns.on("HOP_CHANGED", function()
  if H.popup then
    H.updatePopup()
  end
end)

-- /ptx hop opens the window on the Hop tab.
ns.commands.hop = {
  fn = function()
    if ns.UI.show then
      ns.UI.show("hop")
    end
  end,
  help = "Inn hop: open the Hop tab (mages with a Scroll of Liminal Passage)",
}
