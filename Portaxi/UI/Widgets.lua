-- UI.Widgets: small shared builders for the Portaxi windows (plain frame API, no libraries, playbook D1).
-- Look of the UX mock v0.8: dark panels with gold trim, section headers between trim lines, red-gold primary
-- buttons, pills, round city emblems. Built-in fonts, WHITE8x8 and the addon's own Media files only.
-- City emblems are Portaxi/Media/emblem_<KEY>.tga (card J, wave 3); when a texture cannot be set, the portal
-- spell icon is the fallback (D13). Card F built it in wave 1; card J polished it in wave 3.
-- luacheck: read globals BackdropTemplateMixin CreateColor

local _, ns = ...

ns.UI = ns.UI or {}
local W = {}
ns.UI.Widgets = W

local L = ns.L
local WHITE = "Interface\\Buttons\\WHITE8x8"
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
W.MEDIA = "Interface\\AddOns\\Portaxi\\Media\\"
-- Modern clients need the template for SetBackdrop; older ones have SetBackdrop on every frame.
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil

-- Colours of the mock (r, g, b).
W.COLOR = {
  PANEL = { 0.118, 0.102, 0.082 },
  PANEL2 = { 0.157, 0.133, 0.106 },
  DARK = { 0.090, 0.075, 0.059 },
  EDGE = { 0.290, 0.247, 0.188 },
  ROW_LINE = { 0.184, 0.157, 0.122 },
  TRIM = { 0.541, 0.427, 0.184 },
  TRIM_HORDE = { 0.541, 0.227, 0.133 },
  GOLD = { 1, 0.820, 0 },
  GOLD_DIM = { 0.722, 0.588, 0.227 },
  CHAT = { 0.443, 0.698, 0.902 }, -- requests read from public chat (D16)
  TEXT = { 0.922, 0.890, 0.820 },
  MUTED = { 0.651, 0.604, 0.514 },
  OK = { 0.373, 0.816, 0.408 },
  OK_EDGE = { 0.247, 0.478, 0.271 },
  WARN = { 1, 0.541, 0.239 },
  WARN_EDGE = { 0.478, 0.290, 0.141 },
  WARN_FILL = { 0.141, 0.098, 0.059 },
  BUTTON = { 0.541, 0.102, 0.071 },
  BUTTON_DARK = { 0.361, 0.059, 0.039 },
  BUTTON_EDGE = { 0.769, 0.627, 0.263 },
  OFF = { 0.400, 0.357, 0.290 },
  EMBLEM_EDGE = { 0.365, 0.318, 0.255 },
  TITLE_TOP = { 0.208, 0.173, 0.125 },
  TITLE_BOTTOM = { 0.133, 0.110, 0.082 },
  TILE_TOP = { 0.129, 0.110, 0.086 },
  TILE_ON_TOP = { 0.180, 0.145, 0.102 },
  GLOW = { 0.161, 0.133, 0.102 },
  CAST_TOP = { 1, 0.878, 0.400 },
  CAST_BOTTOM = { 0.788, 0.604, 0.071 },
  HORDE = { 1, 0.561, 0.518 },
  HORDE_EDGE = { 0.659, 0.196, 0.165 },
  ALLIANCE = { 0.561, 0.702, 1 },
  ALLIANCE_EDGE = { 0.231, 0.373, 0.690 },
}
local C = W.COLOR

-- Class colours of the mock; everything else uses the text colour.
W.CLASS_COLOR = {
  MAGE = { 0.247, 0.780, 0.922 },
  WARLOCK = { 0.529, 0.533, 0.933 },
  WARRIOR = { 0.776, 0.608, 0.427 },
}

-- Pill styles: text colour and border colour.
local PILL = {
  plain = { C.MUTED, C.EDGE },
  ok = { C.OK, C.OK_EDGE },
  bad = { C.WARN, C.WARN_EDGE },
  gold = { C.GOLD, C.GOLD_DIM },
  Horde = { C.HORDE, C.HORDE_EDGE },
  Alliance = { C.ALLIANCE, C.ALLIANCE_EDGE },
}

-- Data access -------------------------------------------------------------------------

-- Profile and services from Detect; nil, {} while Detect is missing or not started yet.
function W.current()
  local detect = ns.Detect
  if type(detect) == "table" and type(detect.current) == "function" then
    local profile, services = detect.current()
    if profile then
      return profile, services or {}
    end
  end
  return nil, {}
end

-- The own faction's city keys in CITY_ORDER.
function W.citiesOf(faction)
  local out = {}
  for _, key in ipairs(ns.Const.CITY_ORDER) do
    if ns.Const.CITY[key].faction == faction then
      out[#out + 1] = key
    end
  end
  return out
end

-- Number of different taxis of a faction in Dispatch.market; nil while there is no market.
function W.taxisOnline(faction)
  local d = ns.Dispatch
  local m = type(d) == "table" and type(d.market) == "table" and d.market or nil
  if not (m and type(m.offers) == "function" and faction) then
    return nil
  end
  local seen, n = {}, 0
  for _, o in ipairs(m:offers({ faction = faction })) do
    if not seen[o.key] then
      seen[o.key], n = true, n + 1
    end
  end
  return n
end

-- Trim colour of the window frame: Horde gets the red-brown trim of the mock, everyone else gold.
function W.trimFor(faction)
  return faction == "Horde" and C.TRIM_HORDE or C.TRIM
end

-- Formatting --------------------------------------------------------------------------

-- 455723 -> "45g 57s"; copper is dropped once there is gold or silver.
function W.money(copper)
  copper = math.floor(tonumber(copper) or 0)
  local g, s = math.floor(copper / 10000), math.floor(copper / 100) % 100
  if g > 0 and s > 0 then
    return ("%dg %ds"):format(g, s)
  elseif g > 0 then
    return ("%dg"):format(g)
  elseif s > 0 then
    return ("%ds"):format(s)
  end
  return ("%dc"):format(copper)
end

-- "MAGE" -> "Mage".
function W.className(token)
  if type(token) ~= "string" or token == "" then
    return ""
  end
  return token:sub(1, 1):upper() .. token:sub(2):lower()
end

-- "Valley of Strength, Orgrimmar", or just the zone.
function W.place(profile)
  local zone, sub = profile.zone or "", profile.subzone or ""
  if sub ~= "" and sub ~= zone then
    return sub .. ", " .. zone
  end
  return zone ~= "" and zone or L["unknown"]
end

function W.spellIcon(spellId)
  local fn = ns.api("C_Spell.GetSpellTexture", "GetSpellTexture")
  return (fn and spellId and fn(spellId)) or QUESTION_MARK
end

function W.cityName(key)
  local city = key and ns.Const.CITY[key]
  return city and L[city.name] or tostring(key)
end

-- Textures ---------------------------------------------------------------------------------

-- Sets a texture file; false when the client refuses it (a missing file returns false in game, the test stub
-- returns nothing, which counts as success).
function W.trySetTexture(tex, path)
  return tex:SetTexture(path) ~= false
end

-- Vertical gradient from top to bottom colour. Modern clients take colour objects, older ones numbers; when
-- neither works the texture keeps the flat bottom colour.
function W.gradient(tex, top, bottom)
  tex:SetTexture(WHITE)
  tex:SetVertexColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1)
  if CreateColor and tex.SetGradient then
    local ok = pcall(tex.SetGradient, tex, "VERTICAL",
      CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1), CreateColor(top[1], top[2], top[3], top[4] or 1))
    if ok then
      return
    end
  end
  if tex.SetGradientAlpha then
    pcall(tex.SetGradientAlpha, tex, "VERTICAL", bottom[1], bottom[2], bottom[3], bottom[4] or 1,
      top[1], top[2], top[3], top[4] or 1)
  end
end

-- A gradient fill inside a frame's border (above its backdrop fill).
function W.fill(frame, top, bottom, inset)
  inset = inset or 1
  local t = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  t:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
  t:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
  W.gradient(t, top, bottom)
  return t
end

-- Round status dot (the soft glow texture, or a small square when it is missing).
function W.dot(parent, size, color)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(size, size)
  if not W.trySetTexture(t, W.MEDIA .. "glow") then
    t:SetTexture(WHITE)
    t:SetSize(size - 2, size - 2)
  end
  t:SetVertexColor(color[1], color[2], color[3], 1)
  return t
end

-- Builders ----------------------------------------------------------------------------

function W.setBackdrop(frame, fill, border, edgeSize)
  if not frame.SetBackdrop then
    return
  end
  frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = edgeSize or 1 })
  frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
  W.setBorder(frame, border)
end

function W.setBorder(frame, color)
  if frame.SetBackdropBorderColor then
    frame:SetBackdropBorderColor(color[1], color[2], color[3], color[4] or 1)
  end
end

function W.setFill(frame, color)
  if frame.SetBackdropColor then
    frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
  end
end

-- A frame with a filled backdrop and a thin border.
function W.panel(parent, fill, border, edgeSize, name)
  local f = CreateFrame("Frame", name, parent, BACKDROP)
  W.setBackdrop(f, fill or C.PANEL, border or C.EDGE, edgeSize)
  return f
end

-- Raised card of the mock (.card): slightly lighter fill, thin edge.
function W.card(parent)
  return W.panel(parent, C.PANEL2, C.EDGE)
end

-- Warning box of the mock (.confirm): brown-orange edge, dark warm fill, text inside.
function W.warnBox(parent, width, height)
  local box = W.panel(parent, C.WARN_FILL, C.WARN_EDGE)
  box:SetSize(width, height)
  box.text = W.label(box, "GameFontHighlightSmall", C.WARN)
  box.text:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -7)
  box.text:SetWidth(width - 16)
  return box
end

function W.label(parent, font, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  if color then
    fs:SetTextColor(color[1], color[2], color[3])
  end
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Small caps caption (the mock's .label): muted, upper case.
function W.caption(parent, text)
  local fs = W.label(parent, "GameFontNormalSmall", C.MUTED)
  fs:SetText(text:upper())
  return fs
end

function W.texture(parent, color, layer)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  t:SetTexture(WHITE)
  t:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
  return t
end

-- A 1 px horizontal line between two x offsets of parent at y.
function W.hline(parent, color, y, left, right)
  local t = W.texture(parent, color, "BORDER")
  t:SetHeight(1)
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", left or 0, y)
  t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(right or 0), y)
  return t
end

-- Button. style nil = primary (red gradient, gold edge and text), "ghost" = dark fill, muted text (secondary
-- actions, tabs, toggles).
function W.button(parent, text, width, height, style)
  local b = CreateFrame("Button", nil, parent, BACKDROP)
  b:SetSize(width, height)
  local ghost = style == "ghost"
  W.setBackdrop(b, ghost and C.PANEL or C.BUTTON_DARK, ghost and C.EDGE or C.BUTTON_EDGE)
  if not ghost then
    b.fill = W.fill(b, C.BUTTON, C.BUTTON_DARK)
  end
  local fs = b:CreateFontString(nil, "OVERLAY", ghost and "GameFontHighlightSmall" or "GameFontNormal")
  fs:SetPoint("CENTER")
  if ghost then
    W.setColor(fs, C.MUTED)
  end
  b:SetFontString(fs)
  b.label = fs
  local hl = W.texture(b, { 1, 0.9, 0.6, 0.10 }, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
  hl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
  b:SetText(text)
  return b
end

-- Enables a button and dims it when disabled (the WHITE8x8 look has no disabled state of its own).
function W.setEnabled(button, on)
  button:SetEnabled(on and true or false)
  button:SetAlpha(on and 1 or 0.45)
end

-- Ghost button state for toggles and tabs: gold text and trim when on.
function W.setToggle(button, on, trim)
  W.setBorder(button, on and (trim or C.TRIM) or C.EDGE)
  W.setFill(button, on and C.PANEL2 or C.PANEL)
  W.setColor(button.label, on and C.GOLD or C.MUTED)
end

-- Section header: gold-dim caps text between two trim lines.
function W.section(parent, text)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(14)
  local fs = W.label(f, "GameFontNormalSmall", C.GOLD_DIM, "CENTER")
  fs:SetPoint("CENTER")
  fs:SetText(text:upper())
  local left = W.texture(f, C.TRIM)
  left:SetHeight(1)
  left:SetPoint("LEFT", f, "LEFT", 0, 0)
  left:SetPoint("RIGHT", fs, "LEFT", -8, 0)
  left:SetAlpha(0.8)
  local right = W.texture(f, C.TRIM)
  right:SetHeight(1)
  right:SetPoint("LEFT", fs, "RIGHT", 8, 0)
  right:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  right:SetAlpha(0.8)
  f.label = fs
  return f
end

-- Key/value row inside a card: muted key on the left, value on the right. Returns the value font string.
function W.kv(parent, key, y, pad)
  pad = pad or 10
  local k = W.label(parent, "GameFontHighlightSmall", C.MUTED)
  k:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)
  k:SetText(key)
  local v = W.label(parent, "GameFontHighlightSmall", C.TEXT, "RIGHT")
  v:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -pad, y)
  v.key = k
  return v
end

function W.setColor(fs, color)
  fs:SetTextColor(color[1], color[2], color[3])
end

-- Pills -------------------------------------------------------------------------------------

-- Small rounded-looking tag with a coloured edge (the mock's .pill). pill.text is the font string.
function W.pill(parent)
  local p = W.panel(parent, C.DARK, C.EDGE)
  p:SetHeight(18)
  p.text = W.label(p, "GameFontHighlightSmall", C.MUTED, "CENTER")
  p.text:SetPoint("CENTER", p, "CENTER", 0, 0)
  return p
end

-- Text and style ("plain" | "ok" | "bad" | "gold" | "Horde" | "Alliance"); the width follows the text.
function W.setPill(p, text, style)
  local s = PILL[style] or PILL.plain
  p.text:SetText(text)
  W.setColor(p.text, s[1])
  W.setBorder(p, s[2])
  local width = tonumber((p.text:GetStringWidth())) or 0
  p:SetWidth(math.max(24, math.floor(width + 14)))
end

-- Lays out the shown pills left to right from (x, y) of parent, wrapping at maxWidth. Returns the rows used.
function W.flow(pills, parent, x, y, maxWidth, gap)
  gap = gap or 4
  local cx, row = 0, 0
  for _, p in ipairs(pills) do
    if p:IsShown() then
      local w = tonumber((p:GetWidth())) or 0
      if cx > 0 and cx + w > maxWidth then
        cx, row = 0, row + 1
      end
      p:ClearAllPoints()
      p:SetPoint("TOPLEFT", parent, "TOPLEFT", x + cx, y - row * 22)
      cx = cx + w + gap
    end
  end
  return row + 1
end

-- Emblems -----------------------------------------------------------------------------------

-- Path of a city emblem texture (no extension, as WoW wants it).
function W.emblemPath(key)
  return W.MEDIA .. "emblem_" .. tostring(key)
end

-- Round city emblem: a glow behind it (selected), the emblem and a ring on top. All textures of parent,
-- centred on the given point. e.icon is the emblem texture.
function W.emblem(parent, size, point, relativeTo, relPoint, x, y)
  local e = { size = size }
  e.glow = parent:CreateTexture(nil, "ARTWORK", nil, -1)
  e.glow:SetSize(size * 1.7, size * 1.7)
  e.icon = parent:CreateTexture(nil, "ARTWORK", nil, 1)
  e.icon:SetSize(size, size)
  e.icon:SetPoint(point, relativeTo, relPoint, x, y)
  e.glow:SetPoint("CENTER", e.icon, "CENTER", 0, 0)
  e.ring = parent:CreateTexture(nil, "ARTWORK", nil, 2)
  e.ring:SetSize(size, size)
  e.ring:SetPoint("CENTER", e.icon, "CENTER", 0, 0)
  e.hasRing = W.trySetTexture(e.ring, W.MEDIA .. "ring")
  e.hasGlow = W.trySetTexture(e.glow, W.MEDIA .. "glow")
  e.glow:Hide()
  return e
end

-- Shows the city's emblem; falls back to the portal spell icon (D13) when the texture cannot be set.
function W.setEmblem(e, key)
  e.key = key
  local city = key and ns.Const.CITY[key]
  e.fallback = false
  if city and W.trySetTexture(e.icon, W.emblemPath(key)) then
    e.icon:SetTexCoord(0, 1, 0, 1)
  else
    e.fallback = true
    e.icon:SetTexture(W.spellIcon(city and city.spell))
    e.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
  e.ring:SetShown(e.hasRing and not e.fallback)
end

-- "on": full colour, gold ring and glow. "off": grey and dimmed (D13), dark ring. "plain": full colour, trim ring.
function W.setEmblemState(e, state)
  local on = state ~= "off"
  e.icon:SetDesaturated(not on)
  local v = on and 1 or 0.6
  e.icon:SetVertexColor(v, v, v, 1)
  local ring = (state == "on" and C.GOLD) or (state == "plain" and C.GOLD_DIM) or C.EMBLEM_EDGE
  e.ring:SetVertexColor(ring[1], ring[2], ring[3], 1)
  e.glow:SetVertexColor(C.GOLD[1], C.GOLD[2], C.GOLD[3], 0.35)
  e.glow:SetShown(state == "on" and e.hasGlow and not e.fallback)
end

-- City tile ---------------------------------------------------------------------------

-- Tile with the city emblem, the name in caps and a small line under it. onClick(cityKey).
function W.cityTile(parent, width, height, onClick)
  local tile = CreateFrame("Button", nil, parent, BACKDROP)
  tile:SetSize(width, height)
  W.setBackdrop(tile, C.DARK, C.EDGE)
  tile.fill = W.fill(tile, C.TILE_TOP, C.DARK)
  tile.emblem = W.emblem(tile, 52, "TOP", tile, "TOP", 0, -10)
  tile.icon = tile.emblem.icon
  tile.name = W.label(tile, "GameFontNormalSmall", C.MUTED, "CENTER")
  tile.name:SetPoint("TOP", tile, "TOP", 0, -70)
  tile.name:SetWidth(width - 8)
  tile.sub = W.label(tile, "GameFontHighlightSmall", C.MUTED, "CENTER")
  tile.sub:SetPoint("TOP", tile.name, "BOTTOM", 0, -3)
  tile.sub:SetWidth(width - 8)
  local hl = W.texture(tile, { 1, 0.82, 0, 0.06 }, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", tile, "TOPLEFT", 1, -1)
  hl:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -1, 1)
  tile:SetScript("OnClick", function()
    if tile.cityKey then
      onClick(tile.cityKey)
    end
  end)
  W.selectTile(tile, false)
  return tile
end

function W.setTileCity(tile, key)
  tile.cityKey = key
  W.setEmblem(tile.emblem, key)
  tile.name:SetText(key and W.cityName(key):upper() or "")
  W.selectTile(tile, tile.selected)
end

-- Selected: coloured emblem with a gold ring and glow, gold-dim border, gold name. Otherwise grey (D13).
function W.selectTile(tile, on)
  tile.selected = on and true or false
  W.setEmblemState(tile.emblem, on and "on" or "off")
  W.setBorder(tile, on and C.GOLD_DIM or C.EDGE)
  W.gradient(tile.fill, on and C.TILE_ON_TOP or C.TILE_TOP, C.DARK)
  W.setColor(tile.name, on and C.GOLD or C.MUTED)
  W.setColor(tile.sub, on and C.TEXT or C.MUTED)
end

-- Steps bar ----------------------------------------------------------------------------------

-- n thin segments in a row (the mock's .steps). W.setSteps(bar, k) lights the first k.
function W.steps(parent, n, width)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetSize(width, 4)
  bar.segments = {}
  local gap = 4
  local seg = (width - gap * (n - 1)) / n
  for i = 1, n do
    local t = W.texture(bar, C.ROW_LINE)
    t:SetSize(seg, 4)
    t:SetPoint("LEFT", bar, "LEFT", (i - 1) * (seg + gap), 0)
    bar.segments[i] = t
  end
  return bar
end

function W.setSteps(bar, lit)
  for i, t in ipairs(bar.segments) do
    local c = i <= lit and C.GOLD_DIM or C.ROW_LINE
    t:SetVertexColor(c[1], c[2], c[3], 1)
  end
end

-- Price stepper ---------------------------------------------------------------------------

-- [-] 3g [+] for copper prices. opts = { min, max, step, value, onChange(value) }.
-- Shift-click moves ten steps. The value is clamped to [min, max].
function W.stepper(parent, opts)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(132, 26)
  s.min, s.max, s.step, s.onChange = opts.min, opts.max, opts.step, opts.onChange
  s.minus = W.button(s, "-", 26, 26, "ghost")
  s.minus:SetPoint("LEFT")
  s.plus = W.button(s, "+", 26, 26, "ghost")
  s.plus:SetPoint("RIGHT")
  for _, b in ipairs({ s.minus, s.plus }) do
    W.setFill(b, C.PANEL2)
    W.setColor(b.label, C.TEXT)
  end
  s.text = W.label(s, "GameFontHighlight", C.GOLD, "CENTER")
  s.text:SetPoint("CENTER")
  local function nudge(sign)
    local shift = ns.api("IsShiftKeyDown")
    local steps = (shift and shift()) and 10 or 1
    local before = s.value
    if W.setStepper(s, s.value + sign * steps * s.step) ~= before and s.onChange then
      s.onChange(s.value)
    end
  end
  s.minus:SetScript("OnClick", function() nudge(-1) end)
  s.plus:SetScript("OnClick", function() nudge(1) end)
  W.setStepper(s, opts.value or opts.min)
  return s
end

-- Sets the value without calling onChange; returns the clamped value.
function W.setStepper(s, value)
  value = math.max(s.min, math.min(s.max, math.floor(tonumber(value) or s.min)))
  s.value = value
  s.text:SetText(W.money(value))
  W.setEnabled(s.minus, value > s.min)
  W.setEnabled(s.plus, value < s.max)
  return value
end

-- Price box of the mock (.pricebox): a card with a label, a small line under it and a stepper on the right.
-- Returns the card; card.label, card.sub, card.stepper.
function W.priceBox(parent, width, label, opts)
  local card = W.card(parent)
  card:SetSize(width, 46)
  card.label = W.label(card, "GameFontHighlight", C.TEXT)
  card.label:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
  card.label:SetText(label)
  card.sub = W.label(card, "GameFontHighlightSmall", C.MUTED)
  card.sub:SetPoint("TOPLEFT", card.label, "BOTTOMLEFT", 0, -3)
  card.sub:SetWidth(width - 160)
  card.stepper = W.stepper(card, opts)
  card.stepper:SetPoint("RIGHT", card, "RIGHT", -10, 0)
  return card
end
