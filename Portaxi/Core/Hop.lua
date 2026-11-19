-- Hop: Inn hop (D20) between players with Portaxi. Hosts announce where they rest; a mage asks one for a hop; the host
-- answers with a click; then both sides run a Ride with svc "HOP" (the mage as taxi, the host as rider).
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Inn hop (D20)". Plan: docs/INN_HOP_PLAN.md §4.
--   Hop.market                 a Market of its own for the hosts (HOST / UNHOST / BYE feed it)
--   Hop.setHosting(on)         PortaxiCharDB.host; HOST while Detect.hop(profile).HOST, UNHOST when that stops
--   Hop.hosting() -> bool
--   Hop.places() -> places     Market:hosts for the own faction, the own key left out
--   Hop.request(hostKey) -> true | nil, err   mage: err "state" (cannot hop now), "busy", "retry", "host" or Net's
--   Hop.answer(reqId, ok) -> true | nil, err  host, from a click (hardware event): HOPOK + Ride.start, or HOPNO
--   Hop.cancel()               mage: forgets the open request (the host's answer is then ignored)
--   Hop.status() -> { hosting, announced, request = { reqId, key, since } | nil, incoming = request | nil, last }
-- Events: HOSTS_CHANGED ; HOP_REQUEST(incoming = { reqId, key, raw, lvl, at }) ; HOP_RESULT(reqId, ok, why) ;
--   HOP_CHANGED (status changed, for the UI)
-- The addon never casts here; the scroll goes through Ride and the Portaxi button (D10). The host's addon accepts only
-- the invite of the mage whose hop the host accepted: that is Ride's rider rule (accept from peer only).
-- luacheck: read globals time

local _, ns = ...
local C = ns.Const

local Hop = {}
ns.Hop = Hop

local EXPIRE_EVERY = 10
local PLACE_GAP = 5     -- at most one HOST per this many seconds after a place change
local REPLY_SLACK = 5   -- the mage waits T.HOP_ANSWER + this for the host's answer

Hop.market = ns.Market.new()

local raws = {}         -- key -> raw sender of that player's last message (D5)
local askedAt = {}      -- mage: host key -> time of the last HOP to that host
local request = nil     -- mage: { reqId, key, raw, since, timer }
local incoming = nil    -- host: { reqId, key, raw, lvl, at, timer }
local last = nil        -- mage: { reqId, key, ok, why }
local announced = false -- host: the last thing we told the channel was a HOST (not UNHOST)
local lastSig, lastHostAt, lastFree = nil, nil, nil
local hostTimer, placeTimer = nil, nil
local seq = nil
local started = false

-- Helpers -------------------------------------------------------------------------------------------

local function now()
  return ns.now()
end

local function charDB()
  return type(PortaxiCharDB) == "table" and PortaxiCharDB or {}
end

local function net(fn, ...)
  local N = ns.Net
  if type(N) == "table" and type(N[fn]) == "function" then
    return N[fn](...)
  end
  return nil, "net"
end

local function profileNow()
  local D = ns.Detect
  if type(D) == "table" and type(D.current) == "function" then
    local profile = D.current()
    if profile then
      return profile, D.hop(profile)
    end
  end
  return nil, nil
end

local function activeRide()
  local R = ns.Ride
  return type(R) == "table" and type(R.current) == "function" and R.current() or nil
end

local function startRide(match)
  local R = ns.Ride
  if type(R) == "table" and type(R.start) == "function" then
    return R.start(match)
  end
end

local function cancelTimer(t)
  if t then
    t:Cancel()
  end
end

local function changed()
  ns.fire("HOP_CHANGED")
end

local function nextReqId()
  seq = (seq or (time() % 100000)) + 1
  return ns.selfKey() .. ":h" .. seq
end

local function level(profile)
  return math.max(1, math.min(100, tonumber(profile and profile.level) or 1))
end

-- Hosting -------------------------------------------------------------------------------------------

function Hop.hosting()
  return charDB().host == true
end

-- The HOST to send now, or nil when we should not be listed.
local function buildHost()
  if not Hop.hosting() then
    return nil
  end
  local profile, hop = profileNow()
  if not (profile and hop and hop.HOST) then
    return nil
  end
  local busy = incoming ~= nil or activeRide() ~= nil
  return {
    type = "HOST", fac = profile.faction or "", lvl = level(profile), zone = profile.zone or "",
    sub = profile.subzone or "", city = hop.city or "", free = not busy,
  }
end

local function signature(msg)
  return table.concat({ msg.fac, msg.zone, msg.sub, msg.city, tostring(msg.free) }, "|")
end

-- Sends HOST or UNHOST as the state demands. force = send HOST even when nothing changed (the period).
local function announce(force)
  local msg = buildHost()
  if msg and msg.zone ~= "" then
    local sig = signature(msg)
    if force or not announced or sig ~= lastSig then
      net("broadcast", msg)
      announced, lastSig, lastHostAt, lastFree = true, sig, now(), msg.free
    end
  elseif announced then
    net("broadcast", { type = "UNHOST" })
    announced, lastSig = false, nil
  end
end

local function scheduleHost()
  cancelTimer(hostTimer)
  local jitter = (math.random() * 2 - 1) * C.T.HOST_JITTER
  hostTimer = C_Timer.NewTimer(C.T.HOST_HELLO + jitter, function()
    hostTimer = nil
    if Hop.hosting() then
      announce(true)
      scheduleHost()
    end
  end)
end

-- After a place or state change: announce at once unless we did within PLACE_GAP; then once the gap is over. Going
-- busy or free, and leaving the list (UNHOST), never wait: other mages must not ask a host that cannot take them.
local function announceSoon()
  if not Hop.hosting() and not announced then
    return
  end
  local msg = buildHost()
  local urgent = not msg or msg.zone == "" or msg.free ~= lastFree
  local wait = lastHostAt and (lastHostAt + PLACE_GAP - now()) or 0
  if wait <= 0 or not announced or urgent then
    announce(false)
    return
  end
  if not placeTimer then
    placeTimer = C_Timer.NewTimer(wait, function()
      placeTimer = nil
      announce(false)
    end)
  end
end

function Hop.setHosting(on)
  charDB().host = on and true or false
  if on then
    announce(true)
    scheduleHost()
  else
    cancelTimer(hostTimer)
    hostTimer = nil
    announce(false) -- UNHOST if we were listed
  end
  changed()
end

-- Host: answering ---------------------------------------------------------------------------------

local function clearIncoming()
  if incoming then
    cancelTimer(incoming.timer)
    incoming = nil
  end
end

local function onHop(msg, key, raw)
  local _, hop = profileNow()
  local free = Hop.hosting() and hop and hop.HOST and not incoming and not activeRide()
  if not free then
    net("whisper", raw, { type = "HOPNO", reqId = msg.reqId, why = "busy" })
    return
  end
  local req = { reqId = msg.reqId, key = key, raw = raw, lvl = msg.lvl, at = now() }
  req.timer = C_Timer.NewTimer(C.T.HOP_ANSWER, function()
    if incoming == req then
      incoming = nil
      net("whisper", raw, { type = "HOPNO", reqId = req.reqId, why = "timeout" })
      announceSoon()
      changed()
    end
  end)
  incoming = req
  announceSoon() -- free = false: nobody else asks meanwhile
  ns.fire("HOP_REQUEST", req)
  changed()
end

function Hop.answer(reqId, ok)
  local req = incoming
  if not (req and req.reqId == reqId) then
    return nil, "request"
  end
  clearIncoming()
  if not ok then
    net("whisper", req.raw, { type = "HOPNO", reqId = reqId, why = "declined" })
    announceSoon()
    changed()
    return true
  end
  local _, hop = profileNow()
  net("whisper", req.raw, { type = "HOPOK", reqId = reqId })
  startRide({ reqId = reqId, role = "rider", svc = "HOP", price = 0, dest = hop and hop.city or nil,
              peer = { key = req.key, raw = req.raw }, eta = C.CAST.SCROLL })
  announceSoon()
  changed()
  return true
end

-- Mage: asking ------------------------------------------------------------------------------------

function Hop.places()
  local profile = profileNow()
  return Hop.market:hosts({ faction = profile and profile.faction, exclude = ns.selfKey() })
end

local function finish(ok, why)
  local req = request
  if not req then
    return
  end
  cancelTimer(req.timer)
  request = nil
  last = { reqId = req.reqId, key = req.key, ok = ok, why = why }
  ns.fire("HOP_RESULT", req.reqId, ok, why)
  changed()
end

function Hop.request(hostKey)
  local profile, hop = profileNow()
  if not (profile and hop and hop.HOP) then
    return nil, "state"
  end
  if request or activeRide() then
    return nil, "busy"
  end
  local t = now()
  if askedAt[hostKey] and t - askedAt[hostKey] < C.T.HOP_RETRY then
    return nil, "retry"
  end
  local host = Hop.market.hostByKey[hostKey]
  local raw = raws[hostKey]
  if not (host and host.free and raw) then
    return nil, "host"
  end
  local reqId = nextReqId()
  local ok, err = net("whisper", raw, { type = "HOP", reqId = reqId, lvl = level(profile) })
  if ok == nil and err then
    return nil, err
  end
  askedAt[hostKey] = t
  local req = { reqId = reqId, key = hostKey, raw = raw, since = t, city = host.city }
  req.timer = C_Timer.NewTimer(C.T.HOP_ANSWER + REPLY_SLACK, function()
    if request == req then
      finish(false, "timeout")
    end
  end)
  request = req
  last = nil
  changed()
  return true
end

function Hop.cancel()
  if request then
    finish(false, "cancelled")
  end
end

local function answerFor(msg, key)
  return request and request.reqId == msg.reqId and ns.sameName(key, request.key)
end

local function onHopOk(msg, key)
  if not answerFor(msg, key) then
    return
  end
  local req = request
  finish(true)
  startRide({ reqId = req.reqId, role = "taxi", svc = "HOP", price = 0, dest = req.city,
              peer = { key = req.key, raw = req.raw }, eta = C.CAST.SCROLL })
end

local function onHopNo(msg, key)
  if answerFor(msg, key) then
    finish(false, msg.why)
  end
end

-- Status --------------------------------------------------------------------------------------------

function Hop.status()
  return {
    hosting = Hop.hosting(),
    announced = announced,
    request = request and { reqId = request.reqId, key = request.key, since = request.since } or nil,
    incoming = incoming,
    last = last,
  }
end

-- Network -------------------------------------------------------------------------------------------

local HANDLERS = {
  HOST = function(msg, key)
    Hop.market:host(key, msg, now())
    ns.fire("HOSTS_CHANGED")
  end,
  UNHOST = function(_, key)
    Hop.market:unhost(key)
    ns.fire("HOSTS_CHANGED")
  end,
  BYE = function(_, key)
    if Hop.market.hostByKey[key] then
      Hop.market:unhost(key)
      ns.fire("HOSTS_CHANGED")
    end
  end,
  HOP = onHop,
  HOPOK = onHopOk,
  HOPNO = onHopNo,
}

local function onNetMsg(msg, key, raw)
  if type(msg) ~= "table" or not key then
    return
  end
  local handler = HANDLERS[msg.type]
  if not handler then
    return
  end
  if raw then
    raws[key] = raw
  end
  handler(msg, key, raw or key)
end

local function expire()
  local _, _, removed = Hop.market:expire(now())
  for _, key in ipairs(removed or {}) do
    raws[key] = nil
  end
  if removed and #removed > 0 then
    ns.fire("HOSTS_CHANGED")
  end
end

-- Lifecycle -----------------------------------------------------------------------------------------

function Hop.start()
  if started then
    return
  end
  started = true
  C_Timer.NewTicker(EXPIRE_EVERY, expire)
  if Hop.hosting() then
    announce(true)
    scheduleHost()
  end
end

ns.on("READY", Hop.start)
ns.on("NET_MSG", onNetMsg)
ns.on("PROFILE_CHANGED", announceSoon)
ns.on("RIDE_STARTED", announceSoon)
ns.on("RIDE_STATE", function(ride)
  if type(ride) == "table" and (ride.state == "DONE" or ride.state == "CANCELLED" or ride.state == "FAILED") then
    announceSoon()
  end
end)

-- /ptx host -----------------------------------------------------------------------------------------

ns.commands.host = {
  fn = function()
    Hop.setHosting(not Hop.hosting())
    ns.say(Hop.hosting() and "hosting mage travellers while you rest (Inn hop)" or "hosting off")
  end,
  help = "Inn hop: host mage travellers while you rest in an inn or a city (on/off)",
}
