-- UI.RideTab: the rider page. Who you are (name in the class colour and pills read by the addon), city tiles
-- of the own faction with their emblems, the cheapest offer and the number of taxis, a Hail / Browse switch,
-- the hail max price box with the Hail button and its live status, and the Browse list of offers with Book
-- buttons. Layout follows the mock v0.8 rider view.
-- Contract: playbook §2 "UI" and "Dispatch". Card F built it in wave 1, card G extended it in wave 2, card J
-- polished it in wave 3. Data: Detect.current() (through MainFrame), Dispatch.market / status(); actions:
-- Dispatch.hail / book / cancel, each only when it exists. Redraws on MARKET_CHANGED, HAIL_RESULT, RIDE_STARTED,
-- RIDE_STATE and CHAT_OFFERS_CHANGED.
-- Browse lists mages' ads from public chat (ChatOffers, D18) after the Portaxi taxis: a blue stripe, "(chat)",
-- where the mage stands (or the start of the ad), the price they named, an Invite button, and a Where? button
-- that asks /who while the place is unknown.
-- Taxis on the map (D19) come first in Browse while the rider may see them (Field.nearby): a green stripe, the
-- distance and the walk instead of the zone, nearest first. Their Book sends the rider's own ETA along. While
-- such rows are shown, the page redraws every NEAR_REFRESH s so the distance follows the walking rider.
-- Inn hop (D20, R5): a small "Hosting: on/off" toggle at the top right (HopTab.hostToggle / toggleHosting); any
-- class can host mage travellers while resting.

local _, ns = ...

ns.UI = ns.UI or {}
local R = {
  dest = nil,    -- selected city key
  max = 30000,   -- hail maximum in copper (session only)
  mode = "hail", -- "hail" | "browse"
  error = nil,   -- error code of the last hail/book call
}
ns.UI.RideTab = R

local L = ns.L
local W = ns.UI.Widgets
local C = W.COLOR

local PAGE_W = 352 -- page width set by MainFrame
local TILE_W, TILE_H, TILE_GAP = 112, 110, 8
local ROWS, ROW_H = 5, 32
local SERVICE_SHORT = { COME = "Come-to-you", PICK = "Pickup" }
local NEAR_REFRESH = 2 -- seconds between redraws while Browse lists taxis on the map

-- Vertical layout of the page (y offsets from the top; the page is 352 x 516).
local Y = {
  pills = -20, tilesHead = -68, tiles = -88, howHead = -208, switch = -228,
  body = -264, warning = -320, hail = -362, list = -264, status = -436, note = -470,
}

-- Dispatch error codes in words.
R.ERRORS = {
  money = "You don't carry enough gold for that.",
  cooldown = "Wait a few seconds before you hail again.",
  busy = "You already have an open request or a ride.",
  dest = "Choose a destination of your faction.",
  profile = "Waiting for character data.",
  offer = "That taxi no longer offers this.",
  resting = "Come-to-you needs you to be resting.",
  range = "That price is out of range.",
  here = "You are already in that city.",
  group = "Leave your group first: the taxi has to invite you.",
  invite = "Could not send the invite.",
  who = "This client can't ask /who from an addon.",
  off = "Reading chat is off. /ptx chat turns it on.",
}

-- Building ----------------------------------------------------------------------------

local function buildReadout(page, ui)
  ui.name = W.label(page, "GameFontNormal", C.TEXT)
  ui.name:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  ui.host = W.button(page, L["Hosting: off"], 96, 18, "ghost")
  ui.host:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 2)
  ui.host:SetScript("OnClick", function()
    local H = ns.UI.HopTab
    if H and H.toggleHosting then
      H.toggleHosting()
    end
    R.redraw()
  end)
  ui.pills = {}
  for _, field in ipairs({ "faction", "character", "place", "resting", "gold" }) do
    local p = W.pill(page)
    ui.pills[#ui.pills + 1] = p
    ui[field] = p.text
    p.text.pill = p
  end
  ui.readoutEmpty = W.label(page, "GameFontHighlightSmall", C.MUTED)
  ui.readoutEmpty:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.pills - 3)
  ui.readoutEmpty:SetText(L["Waiting for the addon to read your character."])
end

local function buildTiles(page, ui)
  local head = W.section(page, L["Choose your destination"])
  head:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.tilesHead)
  head:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.tilesHead)
  ui.tiles = {}
  for i = 1, 3 do
    local tile = W.cityTile(page, TILE_W, TILE_H, function(key) R.selectCity(key) end)
    tile:SetPoint("TOPLEFT", page, "TOPLEFT", (i - 1) * (TILE_W + TILE_GAP), Y.tiles)
    ui.tiles[i] = tile
  end
  ui.tilesEmpty = W.label(page, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.tilesEmpty:SetPoint("TOP", page, "TOP", 0, Y.tiles - 40)
  ui.tilesEmpty:SetText(L["Destinations appear once the addon knows your faction."])
end

-- Segmented switch of the mock (.seg): two halves in one bordered box.
local function buildSwitch(page, ui)
  local head = W.section(page, L["How to ride"])
  head:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.howHead)
  head:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.howHead)
  ui.modes = {}
  for i, mode in ipairs({ "hail", "browse" }) do
    local b = W.button(page, mode == "hail" and L["Hail"] or L["Browse"], PAGE_W / 2, 26, "ghost")
    b:SetPoint("TOPLEFT", page, "TOPLEFT", (i - 1) * PAGE_W / 2, Y.switch)
    b:SetScript("OnClick", function() R.setMode(mode) end)
    ui.modes[mode] = b
  end
end

local function buildHail(page, ui)
  local block = CreateFrame("Frame", nil, page)
  block:SetAllPoints(page)
  ui.hailBlock = block
  local P = ns.Const.PRICE
  local box = W.priceBox(block, PAGE_W, L["Your maximum"], { min = P.MIN, max = P.MAX, step = 1000, value = R.max,
    onChange = function(v)
      R.max = v
      R.redraw()
    end })
  box:SetHeight(52)
  box:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.body)
  ui.max, ui.maxNote = box.stepper, box.sub
  ui.warningBox = W.warnBox(block, PAGE_W, 36)
  ui.warningBox:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.warning)
  ui.warning = ui.warningBox.text
  ui.hail = W.button(block, L["Hail a taxi"], PAGE_W, 32)
  ui.hail:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.hail)
  ui.hail:SetScript("OnClick", function() R.hail() end)
  ui.hint = W.label(block, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.hint:SetPoint("TOP", ui.hail, "BOTTOM", 0, -6)
  ui.hint:SetWidth(PAGE_W)
end

local function buildRow(list, i)
  local row = CreateFrame("Frame", nil, list)
  row:SetSize(PAGE_W - 2, ROW_H)
  row:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1 - (i - 1) * ROW_H)
  if i > 1 then
    W.hline(row, C.ROW_LINE, 0)
  end
  row.stripe = W.texture(row, C.CHAT)
  row.stripe:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
  row.stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 1)
  row.stripe:SetWidth(3)
  row.who = W.label(row, "GameFontHighlightSmall", C.TEXT)
  row.who:SetPoint("TOPLEFT", row, "TOPLEFT", 9, -4)
  row.who:SetWidth(200)
  row.place = W.label(row, "GameFontHighlightSmall", C.MUTED)
  row.place:SetPoint("TOPLEFT", row.who, "BOTTOMLEFT", 0, -2)
  row.place:SetWidth(200)
  row.price = W.label(row, "GameFontHighlightSmall", C.GOLD, "RIGHT")
  row.price:SetPoint("RIGHT", row, "RIGHT", -82, 0)
  row.book = W.button(row, L["Book"], 70, 22)
  row.book:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.book:SetScript("OnClick", function()
    if row.offer then
      R.book(row.offer)
    end
  end)
  row.where = W.button(row, L["Where?"], 52, 20, "ghost")
  row.where:SetPoint("RIGHT", row, "RIGHT", -136, 0)
  row.where:SetScript("OnClick", function()
    if row.offer and row.offer.chat then
      R.locate(row.offer)
    end
  end)
  return row
end

local function buildBrowse(page, ui)
  local block = CreateFrame("Frame", nil, page)
  block:SetAllPoints(page)
  ui.browseBlock = block
  local list = W.panel(block, C.PANEL, C.EDGE)
  list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.list)
  list:SetSize(PAGE_W, ROWS * ROW_H + 2)
  ui.list = list
  ui.rows = {}
  for i = 1, ROWS do
    ui.rows[i] = buildRow(list, i)
  end
  ui.browseEmpty = W.label(list, "GameFontHighlightSmall", C.MUTED, "CENTER")
  ui.browseEmpty:SetPoint("CENTER", list, "CENTER", 0, 0)
  ui.browseEmpty:SetWidth(PAGE_W - 20)
end

local function buildStatus(page, ui)
  ui.status = W.label(page, "GameFontHighlightSmall", C.TEXT)
  ui.status:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.status - 6)
  ui.status:SetWidth(PAGE_W - 100)
  ui.cancel = W.button(page, L["Cancel"], 90, 22, "ghost")
  ui.cancel:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, Y.status)
  ui.cancel:SetScript("OnClick", function() R.cancel() end)
  ui.riderNote = W.label(page, "GameFontHighlightSmall", C.MUTED)
  ui.riderNote:SetPoint("TOPLEFT", page, "TOPLEFT", 0, Y.note)
  ui.riderNote:SetWidth(PAGE_W)
end

function R.build(page)
  local ui = {}
  R.ui, R.page = ui, page
  buildReadout(page, ui)
  buildTiles(page, ui)
  buildSwitch(page, ui)
  buildHail(page, ui)
  buildBrowse(page, ui)
  buildStatus(page, ui)
  C_Timer.NewTicker(NEAR_REFRESH, function()
    if R.near and R.mode == "browse" and page:IsVisible() then
      R.redraw()
    end
  end)
  return page
end

-- Data --------------------------------------------------------------------------------

local function money()
  local get = ns.api("GetMoney")
  if get then
    return get()
  end
  return R.profile and R.profile.money
end

local function dispatchFn(name)
  local d = ns.Dispatch
  return type(d) == "table" and type(d[name]) == "function" and d[name] or nil
end

local function market()
  local d = ns.Dispatch
  return type(d) == "table" and type(d.market) == "table" and d.market or nil
end

local function status()
  local fn = dispatchFn("status")
  return fn and fn() or {}
end

local function activeRide()
  local ride = ns.Ride
  return type(ride) == "table" and type(ride.current) == "function" and ride.current() or nil
end

-- Offers of the own faction for a city: every service, cheapest first.
local function offersFor(dest)
  local m = market()
  if not (m and dest and R.profile) then
    return {}
  end
  return m:offers({ dest = dest, faction = R.profile.faction })
end

-- Mages' ads from public chat for a city (D18), cheapest first.
local function chatOffersFor(dest)
  local c = ns.ChatOffers
  if not (dest and type(c) == "table" and type(c.list) == "function") then
    return {}
  end
  return c.list(dest)
end

-- "from 1g 50s · 2 taxis", "3 taxis" (no price known) or "no taxis". Mages from chat count too.
function R.tileText(dest)
  local taxis, n, lowest = {}, 0, nil
  local function add(key, price)
    if not taxis[key] then
      taxis[key], n = true, n + 1
    end
    if price and (lowest == nil or price < lowest) then
      lowest = price
    end
  end
  for _, o in ipairs(offersFor(dest)) do
    add(o.key, o.price)
  end
  for _, o in ipairs(chatOffersFor(dest)) do
    add(o.key, o.price)
  end
  if n == 0 then
    return L["no taxis"]
  end
  local count = n == 1 and L["1 taxi"] or L["%d taxis"]:format(n)
  return lowest and (L["from %s"]:format(W.money(lowest)) .. " · " .. count) or count
end

-- Refresh -----------------------------------------------------------------------------

local function playerName()
  local unitName = ns.api("UnitName")
  return unitName and unitName("player") or ""
end

local function refreshReadout(ui, p)
  for _, pill in ipairs(ui.pills) do
    pill:SetShown(p ~= nil)
    pill.text:SetShown(p ~= nil)
  end
  ui.name:SetShown(p ~= nil)
  ui.readoutEmpty:SetShown(p == nil)
  if not p then
    return
  end
  ui.name:SetText(playerName())
  W.setColor(ui.name, W.CLASS_COLOR[p.class or ""] or C.TEXT)
  W.setPill(ui.faction.pill, p.faction and L[p.faction] or "-", p.faction)
  W.setPill(ui.character.pill, ("%s %s %s"):format(p.race or "", W.className(p.class), tostring(p.level or "")))
  W.setPill(ui.place.pill, W.place(p))
  W.setPill(ui.resting.pill, p.resting and L["Resting"] or L["Not resting"], p.resting and "ok" or "bad")
  W.setPill(ui.gold.pill, p.money and L["%s in bags"]:format(W.money(p.money)) or "-", "gold")
  W.flow(ui.pills, R.page, 0, Y.pills, PAGE_W)
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local function refreshTiles(ui, p)
  local keys = p and W.citiesOf(p.faction) or {}
  if R.dest and not contains(keys, R.dest) then
    R.dest = nil
  end
  for i, tile in ipairs(ui.tiles) do
    tile:SetShown(keys[i] ~= nil)
    W.setTileCity(tile, keys[i])
    W.selectTile(tile, keys[i] ~= nil and keys[i] == R.dest)
    tile.sub:SetText(keys[i] and R.tileText(keys[i]) or "")
  end
  ui.tilesEmpty:SetShown(#keys == 0)
end

local function refreshSwitch(ui)
  for mode, b in pairs(ui.modes) do
    W.setToggle(b, mode == R.mode)
  end
  ui.hailBlock:SetShown(R.mode == "hail")
  ui.browseBlock:SetShown(R.mode == "browse")
end

-- Why the Hail button is disabled, or nil when it is enabled.
local function hailBlocker(p, carried, st)
  if not dispatchFn("hail") then
    return L["Network not ready yet."]
  elseif not p then
    return L["Waiting for character data."]
  elseif not R.dest then
    return L["Choose a destination."]
  elseif ns.Const.CITY[R.dest] and ns.Const.CITY[R.dest].name == p.zone then
    return L[R.ERRORS.here]
  elseif IsInGroup() then
    return L[R.ERRORS.group]
  elseif carried and R.max > carried then
    return L["Lower your maximum to what you carry."]
  elseif st.hail then
    return L["Your request is open."]
  elseif activeRide() then
    return L["You are on a ride."]
  end
end

local function refreshHail(ui, p, st)
  local carried = money()
  W.setStepper(ui.max, R.max)
  ui.maxNote:SetText(carried and L["You pay the taxi's own price. You carry %s."]:format(W.money(carried))
    or L["You pay the taxi's own price."])
  local poor = carried ~= nil and R.max > carried
  ui.warning:SetShown(poor)
  ui.warningBox:SetShown(poor)
  if poor then
    ui.warning:SetText(L["You carry only %s. Portaxi won't send an offer for more gold than you have."]
      :format(W.money(carried)))
  end
  local city = R.dest and ns.Const.CITY[R.dest]
  ui.hail:SetText(city and L["Hail a taxi to %s"]:format(L[city.name]) or L["Hail a taxi"])
  local blocker = hailBlocker(p, carried, st)
  W.setEnabled(ui.hail, blocker == nil)
  ui.hint:SetText(blocker or "")
end

local function leaderOrAlone()
  if not IsInGroup() then
    return true
  end
  local leader = ns.api("UnitIsGroupLeader")
  return leader == nil or leader("player") == true
end

-- Why the Invite button of a chat ad is grey, or nil.
local function inviteBlocker(offer, carried, st)
  local c = ns.ChatOffers
  if not (type(c) == "table" and type(c.invite) == "function") or st.hail or activeRide() then
    return "busy"
  elseif not leaderOrAlone() then
    return "group"
  elseif carried and offer.price and offer.price > carried then
    return "money"
  end
end

-- Why a Book button is grey, or nil.
local function bookBlocker(offer, p, carried, st)
  if offer.chat then
    return inviteBlocker(offer, carried, st)
  elseif not dispatchFn("book") or st.hail or activeRide() then
    return "busy"
  elseif offer.self then
    return "self" -- the taxi's own row in the test view (/ptx mapself)
  elseif offer.busy then
    return "fighting"
  elseif IsInGroup() then
    return "group"
  elseif carried and offer.price > carried then
    return "money"
  elseif offer.svc == "COME" and not (p and p.resting) then
    return "resting"
  end
end

local CHAT_QUOTE = 30 -- bytes of the ad shown while the mage's place is unknown

-- The start of a chat line, cut on a whole UTF-8 character.
local function quote(text)
  text = tostring(text or "")
  if #text <= CHAT_QUOTE then
    return '"' .. text .. '"'
  end
  local cut = text:sub(1, CHAT_QUOTE):gsub("[\192-\255][\128-\191]*$", "")
  return '"' .. cut .. '..."'
end

local function drawTaxi(row, o, blocker)
  row.who:SetText(("%s · %s"):format(o.key, L[SERVICE_SHORT[o.svc]]))
  if o.near then
    row.place:SetText(L["~%d yd · ~%d s on foot"]:format(math.floor(o.yards + 0.5), o.walk))
  else
    row.place:SetText(o.offer and o.offer.place or "")
  end
  row.price:SetText(W.money(o.price))
  if blocker == "money" then
    row.book:SetText(L["Too dear"])
  elseif blocker == "fighting" then
    row.book:SetText(L["Busy"])
  elseif blocker == "self" then
    row.book:SetText(L["You"])
  else
    row.book:SetText(L["Book"])
  end
  row.stripe:SetShown(o.near == true)
  row.stripe:SetVertexColor(C.OK[1], C.OK[2], C.OK[3])
  row.where:Hide()
  row.who:SetWidth(200)
  row.place:SetWidth(200)
end

-- A mage's ad from chat: where they stand (or what they wrote), the price they named, Invite and Where?.
local function drawChat(row, o, blocker)
  row.who:SetText(("%s %s"):format(o.key, L["(chat)"]))
  row.place:SetText(o.place or quote(o.text))
  row.price:SetText(o.price and W.money(o.price) or (o.tip and L["tips"] or "?"))
  if blocker == "money" then
    row.book:SetText(L["Too dear"])
  else
    row.book:SetText(o.invited and L["Invite again"] or L["Invite"])
  end
  row.stripe:Show()
  row.stripe:SetVertexColor(C.CHAT[1], C.CHAT[2], C.CHAT[3])
  local c = ns.ChatOffers
  row.where:SetShown(o.whoAt == nil and type(c) == "table" and type(c.locate) == "function")
  local width = row.where:IsShown() and 150 or 200 -- room for Where?
  row.who:SetWidth(width)
  row.place:SetWidth(width)
end

-- Taxis on the map near the rider (D19), nearest first; empty while the rider may not see them.
local function nearbyFor(dest)
  local F = ns.Field
  if not (dest and type(F) == "table" and type(F.nearby) == "function") then
    return {}
  end
  return (F.nearby(dest))
end

-- Taxis on the map first (nearest first), then the other Portaxi taxis (cheapest first), then mages' ads from chat.
local function browseList(dest)
  local list, near = {}, {}
  for _, o in ipairs(nearbyFor(dest)) do
    o.near = true
    near[o.key] = true
    list[#list + 1] = o
  end
  for _, o in ipairs(offersFor(dest)) do
    if not (near[o.key] and o.svc == "PICK") then
      list[#list + 1] = o
    end
  end
  for _, o in ipairs(chatOffersFor(dest)) do
    list[#list + 1] = o
  end
  return list
end

local function refreshBrowse(ui, p, st)
  local offers = browseList(R.dest)
  local carried = money()
  for i, row in ipairs(ui.rows) do
    local o = offers[i]
    row.offer = o
    row:SetShown(o ~= nil)
    if o then
      local blocker = bookBlocker(o, p, carried, st)
      if o.chat then
        drawChat(row, o, blocker)
      else
        drawTaxi(row, o, blocker)
      end
      W.setEnabled(row.book, blocker == nil)
    end
  end
  R.near = offers[1] ~= nil and offers[1].near == true -- taxis on the map come first
  local city = R.dest and ns.Const.CITY[R.dest]
  ui.browseEmpty:SetShown(#offers == 0)
  ui.browseEmpty:SetText(city and L["No taxi offers %s right now."]:format(L[city.name])
    or L["Choose a destination."])
end

local function eta(seconds)
  seconds = math.floor(tonumber(seconds) or 0)
  if seconds < 120 then
    return L["%d s"]:format(seconds)
  end
  return L["%d min"]:format(math.floor(seconds / 60 + 0.5))
end

-- The status line: the last error, the open hail or booking, or how the last one ended.
function R.statusText(st)
  st = st or status()
  if R.error then
    return L[R.ERRORS[R.error] or "The network is not ready. Try again in a moment."], C.WARN
  end
  local h, last = st.hail, st.last
  if h and h.booked then
    return L["Waiting for %s to accept..."]:format(h.booked), C.TEXT
  elseif h then
    local text = L["Searching for a taxi to %s..."]:format(W.cityName(h.dest))
    if (h.takes or 0) > 0 then
      text = text .. " " .. L["%d answered"]:format(h.takes)
    end
    return text, C.TEXT
  elseif last and last.result == "matched" and last.winner then
    return L["Matched with %s, here in about %s."]:format(last.winner.key, eta(last.winner.eta)), C.OK
  elseif last and last.result == "none" then
    return L["No taxi answered. Try a higher maximum or Browse."], C.WARN
  elseif last and last.result == "cancelled" then
    return L["Request cancelled."], C.MUTED
  end
  return "", C.TEXT
end

local function refreshStatus(ui, p, st)
  local text, color = R.statusText(st)
  ui.status:SetText(text)
  W.setColor(ui.status, color)
  ui.cancel:SetShown(st.hail ~= nil and dispatchFn("cancel") ~= nil)
  ui.riderNote:SetShown(p ~= nil and not R.services.canDrive)
  ui.riderNote:SetText(L["Your character can't open portals, so you ride."])
end

function R.refresh(profile, services)
  if not R.ui then
    return
  end
  R.profile, R.services = profile, services or {}
  local st = status()
  refreshReadout(R.ui, profile)
  refreshTiles(R.ui, profile)
  refreshSwitch(R.ui)
  refreshHail(R.ui, profile, st)
  refreshBrowse(R.ui, profile, st)
  refreshStatus(R.ui, profile, st)
  local H = ns.UI.HopTab
  local text, on = "", false
  if H and H.hostToggle then
    text, on = H.hostToggle()
  end
  R.ui.host:SetText(text)
  W.setToggle(R.ui.host, on)
end

-- Redraws with the last data, after a click inside the page or a network event.
function R.redraw()
  R.refresh(R.profile, R.services)
end

local function redrawIfVisible()
  if R.page and R.page:IsVisible() then
    R.redraw()
  end
end

for _, event in ipairs({ "MARKET_CHANGED", "HAIL_RESULT", "RIDE_STARTED", "RIDE_STATE", "CHAT_OFFERS_CHANGED",
  "HOP_CHANGED" }) do
  ns.on(event, redrawIfVisible)
end

-- Actions -----------------------------------------------------------------------------

function R.selectCity(key)
  R.dest, R.error = key, nil
  R.redraw()
end

function R.setMode(mode)
  R.mode, R.error = mode == "browse" and "browse" or "hail", nil
  R.redraw()
end

-- The addon only asks the network; Dispatch does the rest (D10: no casting, no trading here).
function R.hail()
  if hailBlocker(R.profile, money(), status()) == nil then
    local ok, err = ns.Dispatch.hail(R.dest, R.max)
    R.error = (not ok) and err or nil
    R.redraw()
  end
end

function R.book(offer)
  if offer.chat then
    if bookBlocker(offer, R.profile, money(), status()) == nil then
      local ok, err = ns.ChatOffers.invite(offer.key, R.dest)
      R.error = (not ok) and err or nil
      R.redraw()
    end
    return
  end
  local book = dispatchFn("book")
  if offer.yards and offer.eta then
    offer.near = true -- an entry from the map (MapPins) is booked like a Browse row of a taxi on the map
  end
  if book and bookBlocker(offer, R.profile, money(), status()) == nil then
    local ok, err = book(offer.key, R.dest, offer.svc, offer.near and offer.eta or nil)
    R.error = (not ok) and err or nil
    R.redraw()
  end
end

function R.cancel()
  local cancel = dispatchFn("cancel")
  if cancel then
    cancel()
    R.error = nil
    R.redraw()
  end
end

-- Asks /who for a mage from chat (D18); the answer comes back as CHAT_OFFERS_CHANGED.
function R.locate(offer)
  local c = ns.ChatOffers
  if type(c) == "table" and type(c.locate) == "function" then
    local ok, err = c.locate(offer.key)
    R.error = (not ok) and err or nil
    R.redraw()
  end
end
