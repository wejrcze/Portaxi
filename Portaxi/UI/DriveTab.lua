-- UI.DriveTab: the taxi page (shown only when services.canDrive). On-duty line with its toggle, the detection
-- card (portal spells with city emblems, runes, scrolls, resting, offered services, pauses in words), price
-- boxes per service and the open requests this taxi can serve (Dispatch.requests: bookings, then
-- market:openRequests) with Take buttons, then requests read from public chat (ChatReq, D16: blue stripe,
-- "(chat)", the start of the line, an Invite button). Layout follows the mock v0.8 driver view.
-- Contract: playbook §2 "UI" and "Dispatch". Card F built it in wave 1, card G extended it in wave 2, card J
-- polished it in wave 3. Redraws on MARKET_CHANGED, INCOMING_REQUEST, RIDE_STARTED and RIDE_STATE while visible.

local _, ns = ...

ns.UI = ns.UI or {}
local D = {}
ns.UI.DriveTab = D

local L = ns.L
local W = ns.UI.Widgets
local C = W.COLOR

local PAGE_W = 352 -- page width set by MainFrame
local REQUEST_ROWS, REQUEST_ROW_H = 3, 34
local SERVICES = { "COME", "PICK" }
local SERVICE_NAME = { COME = "Come-to-you portal", PICK = "Portal pickup" }
local SERVICE_SHORT = { COME = "Come-to-you", PICK = "Pickup" }
local PAUSE_TEXT = {
  NOT_MAGE = "Only mages can drive in this version.",
  NO_PORTAL = "No portal spell learned yet.",
  NO_RUNE = "No Rune of Portals in your bags: every portal is paused.",
  NO_SCROLL = "Come-to-you paused: no Scroll of Liminal Passage.",
  NOT_RESTING = "Come-to-you paused: you're not resting.",
}

-- Vertical layout of the page (y offsets from the top; the page is 352 x 516).
local Y = { card = -32, pricesHead = -228, prices = -250, priceNote = -350, requestsHead = -374, requests = -394 }

-- SavedVariables ------------------------------------------------------------------------

local function charDB()
  if type(PortaxiCharDB) ~= "table" then
    return nil
  end
  PortaxiCharDB.prices = PortaxiCharDB.prices or {}
  return PortaxiCharDB
end

-- Building ----------------------------------------------------------------------------

local function buildDuty(page, ui)
  ui.dot = W.dot(page, 12, C.OFF)
  ui.dot:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -7)
  ui.dutyText = W.label(page, "GameFontHighlight", C.TEXT)
  ui.dutyText:SetPoint("LEFT", ui.dot, "RIGHT", 6, 0)
  ui.duty = W.button(page, L["Go on duty"], 110, 24, "ghost")
  ui.duty:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -2)
  ui.duty:SetScript("OnClick", function() D.toggleDuty() end)
end

-- A portal row: a small city emblem, "Portal: Orgrimmar" and "known" / "not learned" on the right.
local function portalRow(card, y)
  local row = W.kv(card, "", y)
  row.key:ClearAllPoints()
  row.key:SetPoint("TOPLEFT", card, "TOPLEFT", 32, y)
  row.emblem = W.emblem(card, 16, "TOPLEFT", card, "TOPLEFT", 10, y + 2)
  return row
end

local function buildDetection(page, ui)
  local card = W.card(page)
  card:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.card)
  card:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.card)
  card:SetHeight(186)
  ui.card = card
  local head = W.caption(card, L["Read by the addon"])
  head:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -9)
  ui.portals = {}
  for i = 1, 3 do
    ui.portals[i] = portalRow(card, -10 - 18 * i)
  end
  W.hline(card, C.ROW_LINE, -84, 10, 10)
  ui.runes = W.kv(card, L["Rune of Portals"], -92)
  ui.scrolls = W.kv(card, L["Scroll of Liminal Passage"], -108)
  ui.resting = W.kv(card, L["Resting"], -124)
  ui.offering = W.kv(card, L["Offering now"], -140)
  ui.pauses = W.label(card, "GameFontHighlightSmall", C.WARN)
  ui.pauses:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -160)
  ui.pauses:SetWidth(PAGE_W - 20)
  ui.detectEmpty = W.label(card, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.detectEmpty:SetPoint("CENTER", card, "CENTER", 0, 0)
  ui.detectEmpty:SetText(L["Waiting for the addon to read your character."])
  ui.detection = { ui.portals[1], ui.portals[2], ui.portals[3], ui.runes, ui.scrolls, ui.resting, ui.offering }
end

local function buildPrices(page, ui)
  local head = W.section(page, L["Your prices"])
  head:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.pricesHead)
  head:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.pricesHead)
  ui.prices, ui.priceState = {}, {}
  local P = ns.Const.PRICE
  for i, svc in ipairs(SERVICES) do
    local box = W.priceBox(page, PAGE_W, L[SERVICE_NAME[svc]], { min = P.MIN, max = P.MAX, step = 1000,
      value = P.MIN, onChange = function(v) D.setPrice(svc, v) end })
    box:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.prices - (i - 1) * 50)
    ui.prices[svc], ui.priceState[svc] = box.stepper, box.sub
  end
  local note = W.label(page, "GameFontHighlightSmall", C.MUTED)
  note:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.priceNote)
  note:SetWidth(PAGE_W)
  note:SetText(L["Prices go out with your next heartbeat on the network."])
end

-- One request row: a gold stripe for bookings, the destination emblem, two text lines, the Take button.
local function requestRow(list, i)
  local row = CreateFrame("Frame", nil, list)
  row:SetSize(PAGE_W - 2, REQUEST_ROW_H)
  row:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1 - (i - 1) * REQUEST_ROW_H)
  if i > 1 then
    W.hline(row, C.ROW_LINE, 0)
  end
  row.stripe = W.texture(row, C.GOLD)
  row.stripe:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
  row.stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 1)
  row.stripe:SetWidth(3)
  row.emblem = W.emblem(row, 22, "LEFT", row, "LEFT", 9, 0)
  row.who = W.label(row, "GameFontHighlightSmall", C.TEXT)
  row.who:SetPoint("TOPLEFT", row, "TOPLEFT", 38, -5)
  row.who:SetWidth(220)
  row.what = W.label(row, "GameFontHighlightSmall", C.MUTED)
  row.what:SetPoint("TOPLEFT", row.who, "BOTTOMLEFT", 0, -2)
  row.what:SetWidth(220)
  row.take = W.button(row, L["Take"], 74, 22)
  row.take:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.take:SetScript("OnClick", function()
    if row.entry then
      D.take(row.entry.request.reqId)
    end
  end)
  return row
end

local function buildRequests(page, ui)
  local head = W.section(page, L["Open requests"])
  head:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.requestsHead)
  head:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.requestsHead)
  ui.requests = W.panel(page, C.PANEL, C.EDGE)
  ui.requests:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.requests)
  ui.requests:SetSize(PAGE_W, REQUEST_ROWS * REQUEST_ROW_H + 2)
  ui.requestsEmpty = W.label(ui.requests, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.requestsEmpty:SetPoint("CENTER")
  ui.requestsEmpty:SetText(L["No requests yet"])
  ui.requestRows = {}
  for i = 1, REQUEST_ROWS do
    ui.requestRows[i] = requestRow(ui.requests, i)
  end
  ui.requestsNote = W.label(page, "GameFontHighlightSmall", C.MUTED)
  ui.requestsNote:SetPoint("TOPLEFT", ui.requests, "BOTTOMLEFT", 0, -4)
  ui.requestsNote:SetWidth(PAGE_W)
end

function D.build(page)
  local ui = {}
  D.ui, D.page = ui, page
  buildDuty(page, ui)
  buildDetection(page, ui)
  buildPrices(page, ui)
  buildRequests(page, ui)
  return page
end

-- Refresh -----------------------------------------------------------------------------

local function count(n)
  n = tonumber(n) or 0
  return n > 0 and tostring(n) or L["none"], n > 0
end

local function refreshDuty(ui, p)
  local db = charDB()
  local on = db ~= nil and db.onDuty == true
  ui.dot:SetVertexColor(unpack(on and C.OK or C.OFF))
  ui.dutyText:SetText(on and L["On duty in the %s network"]:format(L[p and p.faction or "Portaxi"])
    or L["Off duty"])
  W.setColor(ui.dutyText, on and C.TEXT or C.MUTED)
  ui.duty:SetText(on and L["Go off duty"] or L["Go on duty"])
end

local function refreshPortals(ui, p)
  local keys = W.citiesOf(p.faction)
  for i, row in ipairs(ui.portals) do
    local key = keys[i]
    row:SetShown(key ~= nil)
    row.key:SetShown(key ~= nil)
    row.emblem.icon:SetShown(key ~= nil)
    row.emblem.ring:SetShown(key ~= nil)
    if key then
      local known = p.portals and p.portals[key] == true
      W.setEmblem(row.emblem, key)
      W.setEmblemState(row.emblem, known and "plain" or "off")
      row.key:SetText(L["Portal: %s"]:format(L[ns.Const.CITY[key].name]))
      W.setColor(row.key, known and C.TEXT or C.MUTED)
      row:SetText(known and L["known"] or L["not learned"])
      W.setColor(row, known and C.OK or C.WARN)
    end
  end
end

local function setCount(fs, n)
  local text, ok = count(n)
  fs:SetText(text)
  W.setColor(fs, ok and C.OK or C.WARN)
end

local function offeringText(services)
  local out = {}
  for _, svc in ipairs(SERVICES) do
    if services[svc] then
      out[#out + 1] = L[SERVICE_SHORT[svc]]
    end
  end
  return #out > 0 and table.concat(out, ", ") or L["nothing"]
end

local function pausesText(services)
  local out = {}
  for _, code in ipairs(services.pauses or {}) do
    out[#out + 1] = L[PAUSE_TEXT[code] or code]
  end
  return table.concat(out, "\n")
end

local function refreshDetection(ui, p, services)
  for _, row in ipairs(ui.detection) do
    row:SetShown(p ~= nil)
    row.key:SetShown(p ~= nil)
  end
  for _, row in ipairs(ui.portals) do
    row.emblem.icon:SetShown(p ~= nil)
    row.emblem.ring:SetShown(p ~= nil)
  end
  ui.pauses:SetShown(p ~= nil)
  ui.detectEmpty:SetShown(p == nil)
  if not p then
    return
  end
  refreshPortals(ui, p)
  setCount(ui.runes, p.runes)
  setCount(ui.scrolls, p.scrolls)
  ui.resting:SetText(p.resting and L["yes"] or L["no"])
  W.setColor(ui.resting, p.resting and C.OK or C.WARN)
  ui.offering:SetText(offeringText(services))
  W.setColor(ui.offering, (services.COME or services.PICK) and C.OK or C.WARN)
  ui.pauses:SetText(pausesText(services))
end

local function refreshPrices(ui, services)
  local db = charDB()
  for _, svc in ipairs(SERVICES) do
    local stored = db and db.prices[svc]
    local value = W.setStepper(ui.prices[svc], stored or ns.Const.PRICE.MIN)
    if db and stored and stored ~= value then
      db.prices[svc] = value -- keep saved prices within Const.PRICE
    end
    ui.priceState[svc]:SetText(services[svc] and L["active"] or L["paused right now"])
    W.setColor(ui.priceState[svc], services[svc] and C.OK or C.MUTED)
  end
end

-- Requests -------------------------------------------------------------------------------

local function dispatchFn(name)
  local d = ns.Dispatch
  return type(d) == "table" and type(d[name]) == "function" and d[name] or nil
end

local function activeRide()
  local ride = ns.Ride
  return type(ride) == "table" and type(ride.current) == "function" and ride.current() or nil
end

local function onDuty()
  local db = charDB()
  return db ~= nil and db.onDuty == true
end

local function chatReq(name)
  local c = ns.ChatReq
  return type(c) == "table" and type(c[name]) == "function" and c[name] or nil
end

-- Requests to list: only on duty. Dispatch.requests() (players with Portaxi) first, then the requests read
-- from public chat (ChatReq.list, D16).
function D.requests()
  if not onDuty() then
    return {}
  end
  local fn = dispatchFn("requests")
  local list = fn and fn() or {}
  local chat = chatReq("list")
  for _, entry in ipairs(chat and chat() or {}) do
    list[#list + 1] = entry
  end
  return list
end

local CHAT_QUOTE = 34 -- bytes of the chat line shown under a chat request

-- The start of a chat line, cut on a whole UTF-8 character.
local function quote(text)
  text = tostring(text or "")
  if #text <= CHAT_QUOTE then
    return '"' .. text .. '"'
  end
  local cut = text:sub(1, CHAT_QUOTE):gsub("[\192-\255][\128-\191]*$", "")
  return '"' .. cut .. '..."'
end

-- "Velvet to Orgrimmar" / "Come-to-you · 3g · 12 s ago" for a request entry; shared with the DutyBox.
-- A chat request shows "(chat)" and the start of what the player wrote.
function D.requestText(entry)
  local request = entry.request
  local city = ns.Const.CITY[request.dest]
  local who = L["%s to %s"]:format(request.key, city and L[city.name] or tostring(request.dest))
  if entry.booked then
    who = who .. " " .. L["(booked you)"]
  elseif entry.chat then
    who = who .. " " .. L["(chat)"]
  end
  local age = math.max(0, math.floor(ns.now() - (request.at or ns.now())))
  local what
  if entry.chat then
    what = ("%s · %s"):format(quote(entry.text), L["%d s ago"]:format(age))
  else
    what = ("%s · %s · %s"):format(L[SERVICE_SHORT[entry.svc] or tostring(entry.svc)], W.money(entry.price),
      L["%d s ago"]:format(age))
  end
  return who, what
end

-- Chat request: Invite (again after an invite), disabled off duty or during a ride.
local function inviteState(entry)
  if not chatReq("invite") or not onDuty() then
    return "duty", L["Invite"]
  elseif activeRide() then
    return "busy", L["Invite"]
  end
  return nil, entry.invited and L["Invite again"] or L["Invite"]
end

-- Why the Take button of an entry is disabled, or nil; and the button text.
function D.takeState(entry)
  if entry.chat then
    return inviteState(entry)
  end
  local st = dispatchFn("status") and ns.Dispatch.status() or {}
  if st.pendingTake == entry.request.reqId then
    return "pending", L["Sent"]
  elseif not dispatchFn("take") or not onDuty() then
    return "duty", L["Take"]
  elseif activeRide() then
    return "busy", L["Take"]
  elseif st.pendingTake then
    return "pending", L["Take"]
  end
  return nil, L["Take"]
end

local TAKE_ERRORS = {
  duty = "Go on duty to take requests.",
  busy = "You are on a ride.",
  pending = "Waiting for the rider to confirm your last answer.",
  request = "That request is gone.",
  invite = "Could not send the invite.",
}

local function drawRequest(row, entry)
  local who, what = D.requestText(entry)
  row.who:SetText(who)
  row.what:SetText(what)
  row.stripe:SetShown(entry.booked == true or entry.chat == true)
  row.stripe:SetVertexColor(unpack(entry.chat and C.CHAT or C.GOLD))
  W.setEmblem(row.emblem, entry.request.dest)
  W.setEmblemState(row.emblem, "plain")
  local blocker, text = D.takeState(entry)
  row.take:SetText(text)
  W.setEnabled(row.take, blocker == nil)
end

local function refreshRequests(ui)
  local list = D.requests()
  for i, row in ipairs(ui.requestRows) do
    local entry = list[i]
    row.entry = entry
    row:SetShown(entry ~= nil)
    if entry then
      drawRequest(row, entry)
    end
  end
  ui.requestsEmpty:SetShown(#list == 0)
  if D.error then
    ui.requestsNote:SetText(L[TAKE_ERRORS[D.error] or "The network is not ready. Try again in a moment."])
    W.setColor(ui.requestsNote, C.WARN)
  else
    local more = #list - #ui.requestRows
    ui.requestsNote:SetText(more > 0 and L["%d more requests"]:format(more) or "")
    W.setColor(ui.requestsNote, C.MUTED)
  end
end

function D.refresh(profile, services)
  if not D.ui then
    return
  end
  D.profile, D.services = profile, services or {}
  refreshDuty(D.ui, profile)
  refreshDetection(D.ui, profile, D.services)
  refreshPrices(D.ui, D.services)
  refreshRequests(D.ui)
end

function D.redraw()
  D.refresh(D.profile, D.services)
end

local function redrawIfVisible()
  if D.page and D.page:IsVisible() then
    D.redraw()
  end
end

for _, event in ipairs({ "MARKET_CHANGED", "CHAT_REQUESTS_CHANGED", "INCOMING_REQUEST", "RIDE_STARTED",
  "RIDE_STATE" }) do
  ns.on(event, redrawIfVisible)
end

-- Actions -----------------------------------------------------------------------------

-- Saves the duty flag and tells Dispatch when it exists (wave 2).
function D.setOnDuty(on)
  local db = charDB()
  if not db then
    return
  end
  db.onDuty = on and true or false
  local dispatch = ns.Dispatch
  if type(dispatch) == "table" and type(dispatch.setOnDuty) == "function" then
    dispatch.setOnDuty(db.onDuty)
  end
  D.redraw()
end

-- Taxi: answers a request (Dispatch.take), or invites a chat rider (ChatReq.invite, reqId "chat:..."); an
-- error is shown under the list until the next redraw.
function D.take(reqId)
  local take = dispatchFn("take")
  if type(reqId) == "string" and reqId:find("^chat:") then
    take = chatReq("invite")
  end
  if not take then
    return
  end
  local ok, err = take(reqId)
  D.error = (not ok) and err or nil
  D.redraw()
  D.error = nil
end

function D.toggleDuty()
  local db = charDB()
  D.setOnDuty(not (db and db.onDuty))
end

-- Saves a price for a service, clamped to Const.PRICE.
function D.setPrice(svc, copper)
  local db = charDB()
  if not db then
    return
  end
  local P = ns.Const.PRICE
  db.prices[svc] = math.max(P.MIN, math.min(P.MAX, math.floor(tonumber(copper) or P.MIN)))
end
