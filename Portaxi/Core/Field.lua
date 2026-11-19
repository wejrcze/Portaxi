-- Field: a taxi on the map (D19, docs/FIELD_TAXI_PLAN.md). A mage levelling outside towns switches on "Map";
-- riders who look for a ride and are not resting see them near by on the world map and in Browse.
--
-- Pure helpers (no game API)
--   Field.cell(n, w) -> n, w        world yards rounded to the nearest point of Const.FIELD.GRID
--   Field.walk(yards, resp) -> s     seconds for the rider to walk there (FIELD.SPEED) plus the taxi's response
--
-- Taxi
--   Field.setOn(on)                  PortaxiCharDB.field; switching it on off duty also goes on duty
--   Field.blocker() -> nil | code    why the taxi is not on the map: "off" "duty" "drive" "resting" "instance"
--                                    "position"; nil = on the map
--   Field.active() -> bool           Field.blocker() == nil
--   Field.tick()                     every T.SPOT_CHECK s (and after a profile or duty change): sends a SPOT now
--                                    when the taxi came on the map, after T.SPOT_GAP when its cell or busy flag
--                                    changed, every T.SPOT +- T.SPOT_JITTER anyway; one SPOT with inst -1 when
--                                    it leaves the map. Only rounded positions leave the client.
--   Field.status() -> { on, active, blocker, sent = last SPOT or nil }
--
-- Rider
--   Field.riderBlocker(dest) -> nil | code   "dest" "profile" "resting" "ride" "instance" "position"
--   Field.nearby(dest) -> list, blocker      Market:nearby around the rider (own faction, own key left out),
--                                            each entry with eta = Field.walk(yards, offer.resp)
--
-- Test view (/ptx mapself, this session only): a taxi on the map also sees itself, built from its own last SPOT
-- (the network never echoes it back), as an entry with self = true. It cannot be booked.
--
-- Positions: UnitPosition("player") first, then C_Map (best map, map position, world position), as UI.Arrow.
-- World N grows to the north, W to the west; inst is the instance (continent) ID from either source.
-- Fires FIELD_CHANGED when the switch or the taxi's state on the map changes. /ptx field toggles the switch.
-- luacheck: read globals IsInInstance UnitAffectingCombat date

local _, ns = ...
local C = ns.Const
local L = ns.L

local Field = {}
ns.Field = Field

-- Pure -------------------------------------------------------------------------------------------

local function round(v, grid)
  return math.floor(v / grid + 0.5) * grid
end

function Field.cell(n, w)
  local grid = C.FIELD.GRID
  return round(n, grid), round(w, grid)
end

function Field.walk(yards, resp)
  return math.floor(yards / C.FIELD.SPEED + (resp or 0) + 0.5)
end

-- Game readers -----------------------------------------------------------------------------------

local function call(fn, ...)
  if not fn then
    return nil
  end
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then
    return a, b, c, d
  end
end

local function fromUnitPosition()
  local n, w, _, inst = call(ns.api("UnitPosition"), "player")
  if type(n) == "number" and type(w) == "number" and type(inst) == "number" then
    return n, w, inst
  end
end

local function fromMap()
  local mapId = call(ns.api("C_Map.GetBestMapForUnit"), "player")
  local pos = mapId and call(ns.api("C_Map.GetPlayerMapPosition"), mapId, "player")
  if not pos then
    return nil
  end
  local inst, world = call(ns.api("C_Map.GetWorldPosFromMapPos"), mapId, pos)
  if type(world) ~= "table" or type(inst) ~= "number" then
    return nil
  end
  local n, w = world.x, world.y
  if type(world.GetXY) == "function" then
    n, w = world:GetXY()
  end
  if type(n) == "number" and type(w) == "number" then
    return n, w, inst
  end
end

-- Own world position: n, w, inst, or nil when the client gives none.
function Field.position()
  local n, w, inst = fromUnitPosition()
  if n then
    return n, w, inst
  end
  return fromMap()
end

local function inInstance()
  local inside, kind = call(ns.api("IsInInstance"))
  return inside == true and kind ~= "none"
end

local function inCombat()
  return call(ns.api("UnitAffectingCombat"), "player") == true
end

local function charDB()
  return type(PortaxiCharDB) == "table" and PortaxiCharDB or {}
end

local function current()
  local detect = ns.Detect
  if type(detect) == "table" and type(detect.current) == "function" then
    local profile, services = detect.current()
    return profile, services or {}
  end
  return nil, {}
end

local function activeRide()
  local ride = ns.Ride
  return type(ride) == "table" and type(ride.current) == "function" and ride.current() or nil
end

-- Taxi -------------------------------------------------------------------------------------------

function Field.blocker()
  local db = charDB()
  if db.field ~= true then
    return "off"
  elseif db.onDuty ~= true then
    return "duty"
  end
  local profile, services = current()
  if not (profile and services.PICK) then
    return "drive"
  elseif profile.resting then
    return "resting"
  elseif inInstance() then
    return "instance"
  elseif not Field.position() then
    return "position"
  end
end

function Field.active()
  return Field.blocker() == nil
end

local sent = nil      -- last SPOT on the map { inst, n, w, busy }, nil while off the map
local sentAt = nil    -- time of the last SPOT
local beatAt = nil    -- next heartbeat SPOT
local lastBlocker = nil

local function broadcast(msg)
  local N = ns.Net
  if type(N) == "table" and type(N.broadcast) == "function" then
    N.broadcast(msg)
  end
end

local function nextBeat(t)
  return t + C.T.SPOT + (math.random() * 2 - 1) * C.T.SPOT_JITTER
end

local function send(spot, t)
  broadcast({ type = "SPOT", inst = spot.inst, n = spot.n, w = spot.w, busy = spot.busy })
  sent, sentAt, beatAt = spot, t, nextBeat(t)
end

local function same(a, b)
  return a.inst == b.inst and a.n == b.n and a.w == b.w and a.busy == b.busy
end

function Field.tick()
  local t = ns.now()
  local blocker = Field.blocker()
  if blocker then
    if sent then
      broadcast({ type = "SPOT", inst = -1, n = 0, w = 0, busy = false })
      sent, sentAt, beatAt = nil, t, nil
    end
  else
    local n, w, inst = Field.position()
    n, w = Field.cell(n, w)
    local spot = { inst = inst, n = n, w = w, busy = inCombat() or activeRide() ~= nil }
    if not sent then
      send(spot, t)
    elseif not same(spot, sent) then
      if t - sentAt >= C.T.SPOT_GAP then
        send(spot, t)
      end
    elseif t >= beatAt then
      send(spot, t)
    end
  end
  if blocker ~= lastBlocker then
    lastBlocker = blocker
    ns.fire("FIELD_CHANGED")
  end
end

function Field.setOn(on)
  local db = charDB()
  db.field = on and true or false
  if db.field and db.onDuty ~= true and ns.Dispatch and ns.Dispatch.setOnDuty then
    ns.Dispatch.setOnDuty(true)
  end
  Field.tick()
  ns.fire("FIELD_CHANGED")
end

function Field.status()
  local blocker = Field.blocker()
  return { on = charDB().field == true, active = blocker == nil, blocker = blocker, sent = sent }
end

-- Rider ------------------------------------------------------------------------------------------

function Field.riderBlocker(dest)
  local profile = current()
  if not (dest and C.CITY[dest]) then
    return "dest"
  elseif not profile then
    return "profile"
  elseif profile.resting then
    return "resting"
  elseif activeRide() then
    return "ride"
  elseif inInstance() then
    return "instance"
  elseif not Field.position() then
    return "position"
  end
end

function Field.nearby(dest)
  local blocker = Field.riderBlocker(dest)
  local D = ns.Dispatch
  if blocker or not (type(D) == "table" and D.market) then
    return {}, blocker
  end
  local profile = current()
  local n, w, inst = Field.position()
  local list = D.market:nearby({ faction = profile.faction, dest = dest, inst = inst, n = n, w = w,
                                 exclude = ns.selfKey() }, ns.now())
  local own = Field.showSelf and Field.selfEntry(dest, n, w, inst)
  if own then
    list[#list + 1] = own
    table.sort(list, function(a, b)
      if a.yards ~= b.yards then
        return a.yards < b.yards
      end
      return a.key < b.key
    end)
  end
  for _, e in ipairs(list) do
    e.eta = Field.walk(e.yards, e.offer.resp)
  end
  return list
end

-- The taxi's own pin for the test view: what riders get from its last SPOT and its offer, or nil while it is
-- not on the map or does not serve dest.
function Field.selfEntry(dest, n, w, inst)
  local profile, services = current()
  local price = (charDB().prices or {}).PICK
  if not (sent and Field.active() and profile and price and sent.inst == inst) then
    return nil
  end
  local serves = false
  for _, d in ipairs(services.dests or {}) do
    serves = serves or d == dest
  end
  if not serves then
    return nil
  end
  local dn, dw = sent.n - n, sent.w - w
  return {
    key = ns.selfKey() or "?", svc = "PICK", price = price, self = true, busy = sent.busy,
    yards = math.sqrt(dn * dn + dw * dw),
    spot = { inst = sent.inst, n = sent.n, w = sent.w, busy = sent.busy },
    offer = { cls = profile.class, lvl = profile.level, dests = services.dests, resp = ns.Dispatch.response(),
              place = profile.zone },
  }
end

-- Lifecycle --------------------------------------------------------------------------------------

local started = false

function Field.start()
  if started then
    return
  end
  started = true
  C_Timer.NewTicker(C.T.SPOT_CHECK, Field.tick)
  Field.tick()
end

ns.on("READY", Field.start)
for _, event in ipairs({ "PROFILE_CHANGED", "MARKET_CHANGED", "RIDE_STARTED" }) do
  ns.on(event, function()
    if started then
      Field.tick()
    end
  end)
end

-- /ptx field --------------------------------------------------------------------------------------

Field.REASONS = {
  off = "Map is off.",
  duty = "You are off duty.",
  drive = "No pickup to offer: you need a portal and a Rune of Portals.",
  resting = "Resting: riders here get the town taxi, not the map.",
  instance = "Not shown inside instances.",
  position = "This client gives the addon no position.",
}

-- On the map means switched on and on duty: when the switch is on but duty is off (the duty box's Off button
-- leaves the switch alone), /ptx field puts the taxi back on the map instead of switching it off.
local function command()
  local db = charDB()
  Field.setOn(not (db.field == true and db.onDuty == true))
  local st = Field.status()
  if st.active then
    ns.say(L["Map on: riders near you who look for a ride see you on their map."])
  elseif st.on then
    ns.say(L["Map on, but you are not shown: %s"]:format(L[Field.REASONS[st.blocker]]))
  else
    ns.say(L["Map off."])
  end
end

ns.commands.field = { fn = command, help = "taxi on the map while levelling: on or off" }

-- /ptx mapself: the test view, for checking the pin and the Browse row alone.
local function mapSelf()
  Field.showSelf = not Field.showSelf
  if not Field.showSelf then
    ns.say("mapself: off")
    return
  end
  ns.say("mapself: on for this session. You see your own pin and Browse row as riders do; it cannot be booked.")
  local st = Field.status()
  if not st.active then
    ns.say("You are not on the map yet: " .. tostring(st.blocker) .. ". /ptx field puts you there.")
  end
  local R = ns.UI and ns.UI.RideTab
  local blocker = Field.riderBlocker(type(R) == "table" and R.dest or nil)
  if blocker == "dest" then
    ns.say("Pick a city in the Ride tab (Browse), then open the world map.")
  elseif blocker then
    ns.say("Riders see nothing while: " .. blocker)
  end
  ns.fire("MARKET_CHANGED")
end

ns.commands.mapself = { fn = mapSelf, help = "test: see yourself on the map and in Browse as riders do" }

-- /ptx where: what the position APIs really return here (plan §5 F1-F3; /ptx diag only sees that they exist).
-- Prints and stores PortaxiDB.where: UnitPosition, the C_Map map and world positions, the way back from the
-- world position to the map (what the world map pins use) and why the taxi is or is not on the map.
local function fmt(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    out[i] = type(v) == "number" and ("%.4f"):format(v):gsub("%.?0+$", "") or tostring(v)
  end
  return table.concat(out, ", ")
end

local function where()
  local w = { at = date("%Y-%m-%d %H:%M:%S") }
  local zone, sub = call(ns.api("GetZoneText")), call(ns.api("GetSubZoneText"))
  w.zone, w.subzone = zone, sub
  w.instance = { call(ns.api("IsInInstance")) }
  w.combat = inCombat()
  w.unitPosition = { call(ns.api("UnitPosition"), "player") }
  local mapId = call(ns.api("C_Map.GetBestMapForUnit"), "player")
  w.mapId = mapId
  local pos = mapId and call(ns.api("C_Map.GetPlayerMapPosition"), mapId, "player")
  if type(pos) == "table" then
    w.mapPos = { pos.x, pos.y }
    if type(pos.GetXY) == "function" then
      w.mapPos = { pos:GetXY() }
    end
    local inst, world = call(ns.api("C_Map.GetWorldPosFromMapPos"), mapId, pos)
    w.mapWorld = { inst, type(world) == "table" and world.x or nil, type(world) == "table" and world.y or nil }
  end
  local n, wy, inst = Field.position()
  w.position = { n, wy, inst }
  if n then
    w.cell = { Field.cell(n, wy) }
    local make = ns.api("CreateVector2D")
    local back, bpos = call(ns.api("C_Map.GetMapPosFromWorldPos"), inst, make and make(n, wy) or { x = n, y = wy },
      mapId)
    w.backToMap = { back, type(bpos) == "table" and bpos.x or nil, type(bpos) == "table" and bpos.y or nil }
  end
  local db = charDB()
  local st = Field.status()
  w.field = { on = st.on, onDuty = db.onDuty == true, blocker = st.blocker or "none (on the map)",
              sent = st.sent and fmt(st.sent.inst, st.sent.n, st.sent.w, st.sent.busy) or nil }
  if type(PortaxiDB) == "table" then
    PortaxiDB.where = w
  end
  ns.say(("where: %s / %s · map %s · instance %s · combat %s"):format(tostring(zone), tostring(sub),
    tostring(mapId), fmt(unpack(w.instance)), tostring(w.combat)))
  ns.say("UnitPosition: " .. fmt(unpack(w.unitPosition)))
  ns.say("map position: " .. (w.mapPos and fmt(unpack(w.mapPos)) or "none") .. " -> world (inst, n, w): "
    .. (w.mapWorld and fmt(unpack(w.mapWorld)) or "none"))
  ns.say("used: " .. (n and fmt(n, wy, inst) or "none") .. (w.cell and (" · cell " .. fmt(unpack(w.cell))) or "")
    .. " · back to map: " .. (w.backToMap and fmt(unpack(w.backToMap)) or "none"))
  ns.say(("map switch %s · duty %s · %s%s"):format(tostring(st.on), tostring(db.onDuty == true),
    st.blocker or "on the map", w.field.sent and (" · last SPOT " .. w.field.sent) or ""))
end

ns.commands.where = { fn = where, help = "show what the position APIs return here (taxi on the map)" }
