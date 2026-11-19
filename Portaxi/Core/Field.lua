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
-- Positions: UnitPosition("player") first, then C_Map (best map, map position, world position), as UI.Arrow.
-- World N grows to the north, W to the west; inst is the instance (continent) ID from either source.
-- Fires FIELD_CHANGED when the switch or the taxi's state on the map changes. /ptx field toggles the switch.
-- luacheck: read globals IsInInstance UnitAffectingCombat

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
  for _, e in ipairs(list) do
    e.eta = Field.walk(e.yards, e.offer.resp)
  end
  return list
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

local function command()
  Field.setOn(charDB().field ~= true)
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
