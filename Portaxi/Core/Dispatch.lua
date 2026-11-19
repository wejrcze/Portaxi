-- Dispatch: glue between Net and Market. HELLO cycle while on duty, rider hails and bookings,
-- taxi takes, CONFIRM / GONE handling and the hand-over to Ride.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Dispatch" (matching rules: docs/PORTAXI_MVP_PLAN.md §6).
-- Card G, wave 2.
--   Dispatch.market                   the one Market instance (NET_MSG HELLO/BYE/HAIL/GONE feed it)
--   Dispatch.setOnDuty(on)            taxi duty: HELLO now, every T.HELLO +- T.HELLO_JITTER, after PROFILE_CHANGED
--   Dispatch.hail(dest, max)          rider: -> true | nil, err ("dest" "here" "profile" "busy" "group" "money"
--                                     "cooldown" or Net's)
--   Dispatch.book(key, dest, svc, eta) rider, Browse or the map: -> true | nil, err (also "offer" "resting");
--                                     eta (optional, D19) = the rider's own estimate, used for the ride
--   Dispatch.cancel()                 rider: withdraws the open hail or booking (GONE)
--   Dispatch.take(reqId)              taxi: -> true | nil, err ("duty" "busy" "pending" "request" or Net's)
--   Dispatch.status()                 { onDuty, hail, pendingTake, last }
--   Dispatch.requests()               taxi: bookings addressed to this taxi, then market:openRequests (UI list)
-- Additions beyond §2: status().last (outcome of the last hail/book for the Ride tab), Dispatch.requests()
-- (bookings are not in the Market), Dispatch.eta(svc) / Dispatch.wait(). MARKET_CHANGED also fires when
-- duty, the open hail, or the pending TAKE change, so the UI has one event to redraw on.
-- The addon never casts, uses items or trades here (D10); a confirmed match goes to ns.Ride.start.
-- Taxi on the map (D19): SPOT feeds market:spot; while ns.Field.active() the taxi's list (and its alerts) has
-- only the bookings addressed to it, no hails from anywhere.
-- luacheck: read globals time

local _, ns = ...
local C = ns.Const

local Dispatch = {}
ns.Dispatch = Dispatch

local EXPIRE_EVERY = 10    -- seconds between Market:expire runs
local PROFILE_HELLO_GAP = 5 -- at most one PROFILE_CHANGED HELLO per this many seconds
local RESP_KEEP = 10       -- response times kept for the average
local HAIL_SLACK = 2       -- seconds of delivery jitter tolerated by the HAIL spam guard
local END_STATES = { DONE = true, CANCELLED = true, FAILED = true }

Dispatch.market = ns.Market.new()

local raws = {}          -- key -> raw sender string of that player's last message (D5)
local hailAt = {}        -- key -> time of that player's last accepted HAIL (spam guard)
local seenAt = {}        -- reqId -> time this taxi first saw the request (response time)
local alerted = {}       -- reqId -> true once INCOMING_REQUEST fired for it
local bookings = {}      -- reqId -> entry { request, svc, price, booked = true } addressed to this taxi
local recentTakes = {}   -- reqId -> pending take dropped by GONE; its CONFIRM may still be on the way

local hail = nil         -- rider: { reqId, dest, max, svcs, takes, since, booked, svc, collect, timeout }
local last = nil         -- rider: { reqId, dest, result = "matched" | "none" | "cancelled", winner }
local pending = nil      -- taxi: { reqId, svc, price, eta, dest, peer, timer }
local lastHailSent = nil
local seq = nil          -- reqId counter, seeded from time() so a /reload does not reuse ids

local started = false
local loginAt = nil      -- time() at READY: "wait" before the first ride
local helloTimer = nil
local profileHelloTimer = nil
local lastHelloAt = nil
local lastHelloSig = nil

-- Helpers -----------------------------------------------------------------------------------

local function now()
  return ns.now()
end

local function charDB()
  if type(PortaxiCharDB) ~= "table" then
    return {}
  end
  return PortaxiCharDB
end

local function current()
  local detect = ns.Detect
  if type(detect) == "table" and type(detect.current) == "function" then
    local profile, services = detect.current()
    if profile then
      return profile, services or {}
    end
  end
  return nil, {}
end

local function activeRide()
  local ride = ns.Ride
  if type(ride) == "table" and type(ride.current) == "function" then
    return ride.current()
  end
end

local function startRide(match)
  local ride = ns.Ride
  if type(ride) == "table" and type(ride.start) == "function" then
    ride.start(match)
  end
end

local function net(fn, ...)
  local N = ns.Net
  if type(N) == "table" and type(N[fn]) == "function" then
    return N[fn](...)
  end
  return nil, "net"
end

local function ownKey()
  return ns.selfKey() -- "First Surname" (D5)
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

local function changed()
  ns.fire("MARKET_CHANGED")
end

local function cancelTimer(t)
  if t then
    t:Cancel()
  end
end

-- Estimates ---------------------------------------------------------------------------------

local function averageResponse()
  local list = charDB().respTimes
  if type(list) ~= "table" or #list == 0 then
    return C.RESP_DEFAULT
  end
  local sum = 0
  for _, v in ipairs(list) do
    sum = sum + v
  end
  return sum / #list
end

-- The taxi's average response time in seconds (what its HELLO sends as resp).
Dispatch.response = averageResponse

-- Seconds until this taxi can deliver the service (plan §6): COME = response + scroll cast,
-- PICK = Const.ETA_PICK + response.
function Dispatch.eta(svc)
  local resp = averageResponse()
  if svc == "COME" then
    return math.floor(resp + C.CAST.SCROLL + 0.5)
  end
  return math.floor(C.ETA_PICK + resp + 0.5)
end

-- Seconds since the last ride (or since login before the first one).
function Dispatch.wait()
  local db = charDB()
  local since = (tonumber(db.lastRideAt) or 0) > 0 and db.lastRideAt or loginAt or time()
  return math.max(0, math.floor(time() - since))
end

-- Responses slower than this mean the taxi was away (e.g. took an old request from the list); they would
-- skew the ETA of the next rides and are not recorded.
local RESP_MAX = 2 * C.RESP_DEFAULT

local function recordResponse(seconds)
  if seconds > RESP_MAX then
    return
  end
  local db = charDB()
  db.respTimes = type(db.respTimes) == "table" and db.respTimes or {}
  local list = db.respTimes
  list[#list + 1] = math.max(0, math.floor(seconds + 0.5))
  while #list > RESP_KEEP do
    table.remove(list, 1)
  end
end

-- HELLO -------------------------------------------------------------------------------------

local function onDuty()
  return charDB().onDuty == true
end

-- The HELLO for the current profile; nil when this character cannot drive. Nothing is offered
-- (empty ask) while a ride is active.
local function buildHello()
  local profile, services = current()
  if not (profile and services.canDrive) then
    return nil
  end
  local prices = charDB().prices or {}
  local ask = {}
  if not activeRide() then
    for _, svc in ipairs({ "COME", "PICK" }) do
      if services[svc] and prices[svc] then
        ask[svc] = prices[svc]
      end
    end
  end
  return {
    type = "HELLO", fac = profile.faction or "", cls = profile.class or "",
    lvl = math.max(1, math.min(100, tonumber(profile.level) or 1)), place = profile.zone or "",
    dests = services.dests or {}, ask = ask,
    resp = math.floor(averageResponse() + 0.5), wait = Dispatch.wait(),
  }
end

-- What riders see of a HELLO; resp and wait change every time and are left out.
local function signature(msg)
  local ask = {}
  for _, svc in ipairs({ "COME", "PICK" }) do
    ask[#ask + 1] = svc .. "=" .. tostring(msg.ask[svc])
  end
  return table.concat({ msg.fac, msg.cls, msg.lvl, msg.place, table.concat(msg.dests, ","),
    table.concat(ask, ",") }, "|")
end

local function sendHello()
  local msg = buildHello()
  if not msg then
    return false
  end
  lastHelloAt = now()
  lastHelloSig = signature(msg)
  net("broadcast", msg)
  return true
end

local function scheduleHello()
  cancelTimer(helloTimer)
  local jitter = (math.random() * 2 - 1) * C.T.HELLO_JITTER
  helloTimer = C_Timer.NewTimer(C.T.HELLO + jitter, function()
    helloTimer = nil
    if onDuty() then
      sendHello()
      scheduleHello()
    end
  end)
end

-- A HELLO soon after a change: now, or once PROFILE_HELLO_GAP has passed since the last one.
-- Skipped when riders would see nothing new.
local function helloSoon()
  if not onDuty() or profileHelloTimer then
    return
  end
  local msg = buildHello()
  if not msg or signature(msg) == lastHelloSig then
    return
  end
  local gap = lastHelloAt and (lastHelloAt + PROFILE_HELLO_GAP - now()) or 0
  if gap <= 0 then
    sendHello()
    return
  end
  profileHelloTimer = C_Timer.NewTimer(gap, function()
    profileHelloTimer = nil
    helloSoon()
  end)
end

-- Taxi: requests ---------------------------------------------------------------------------------

local function taxiInfo()
  local profile, services = current()
  return {
    key = ownKey(), faction = profile and profile.faction, services = services, prices = charDB().prices or {},
  }
end

-- A booking is valid while the service is on, the city is served and it is not older than T.REQUEST.
local function bookingValid(entry, services, t)
  return services[entry.svc] == true and contains(services.dests, entry.request.dest)
    and t - entry.request.at < C.T.REQUEST
end

local function onTheMap()
  local F = ns.Field
  return type(F) == "table" and type(F.active) == "function" and F.active()
end

-- Requests this taxi can serve: bookings addressed to it first (oldest first), then the Market's (not while
-- the taxi is on the map: a hail from a town is too far to walk).
function Dispatch.requests()
  local info = taxiInfo()
  if not info.faction then
    return {}
  end
  local t = now()
  local list = {}
  for _, entry in pairs(bookings) do
    if bookingValid(entry, info.services, t) then
      list[#list + 1] = entry
    end
  end
  table.sort(list, function(a, b)
    if a.request.at ~= b.request.at then
      return a.request.at < b.request.at
    end
    return a.request.reqId < b.request.reqId
  end)
  if onTheMap() then
    return list
  end
  for _, entry in ipairs(Dispatch.market:openRequests(info, t)) do
    entry.booked = false
    list[#list + 1] = entry
  end
  return list
end

local function findRequest(reqId)
  for _, entry in ipairs(Dispatch.requests()) do
    if entry.request.reqId == reqId then
      return entry
    end
  end
end

-- INCOMING_REQUEST once per reqId for every request this taxi can serve; not off duty or during a ride.
local function checkIncoming()
  if not onDuty() or activeRide() then
    return
  end
  local _, services = current()
  if not services.canDrive then
    return
  end
  for _, entry in ipairs(Dispatch.requests()) do
    local id = entry.request.reqId
    if not alerted[id] then
      alerted[id] = true
      ns.fire("INCOMING_REQUEST", entry)
    end
  end
end

-- Going on duty: requests already open are listed, not announced (no burst of raid warnings).
local function markKnown()
  for _, entry in ipairs(Dispatch.requests()) do
    alerted[entry.request.reqId] = true
  end
end

local function forget(reqId)
  seenAt[reqId] = nil
  alerted[reqId] = nil
  bookings[reqId] = nil
end

-- Taxi: TAKE / CONFIRM ----------------------------------------------------------------------------

local function clearPending()
  if pending then
    cancelTimer(pending.timer)
    pending = nil
  end
end

-- Taxi: answers a request with a TAKE whisper. One pending TAKE at a time; free again after T.CONFIRM.
function Dispatch.take(reqId)
  if not onDuty() then
    return nil, "duty"
  elseif activeRide() then
    return nil, "busy"
  elseif pending then
    return nil, "pending"
  end
  local entry = findRequest(reqId)
  local request = entry and entry.request
  local raw = entry and (entry.raw or raws[request.key])
  if not raw then
    return nil, "request"
  end
  local msg = { type = "TAKE", reqId = reqId, svc = entry.svc, price = entry.price,
    eta = Dispatch.eta(entry.svc), wait = Dispatch.wait() }
  local ok, err = net("whisper", raw, msg)
  if not ok then
    return nil, err
  end
  recordResponse(now() - (seenAt[reqId] or now()))
  pending = { reqId = reqId, svc = msg.svc, price = msg.price, eta = msg.eta, dest = request.dest,
    peer = { key = request.key, raw = raw } }
  pending.timer = C_Timer.NewTimer(C.T.CONFIRM, function()
    pending = nil
    changed()
  end)
  changed()
  return true
end

local function taxiMatch(p)
  return { reqId = p.reqId, role = "taxi", svc = p.svc, price = p.price, dest = p.dest,
    peer = { key = p.peer.key, raw = p.peer.raw }, eta = p.eta }
end

local function onConfirm(msg, key)
  local p = pending
  if not (p and p.reqId == msg.reqId) then
    -- GONE overtook the CONFIRM: still ours while nothing else is pending.
    p = recentTakes[msg.reqId]
    if not p or pending or now() > p.expires then
      return
    end
  end
  if p.peer.key ~= key or activeRide() then
    return
  end
  if p == pending then
    clearPending()
  end
  recentTakes[msg.reqId] = nil
  Dispatch.market:gone(msg.reqId)
  forget(msg.reqId)
  startRide(taxiMatch(p))
  changed()
end

-- Taxi: a BOOK whispered to this taxi becomes a booking when the taxi can serve it at its price.
-- Ignored off duty, during a ride, or when the booked price is below the taxi's own (a stale offer).
local function onBook(msg, key, raw)
  local profile, services = current()
  local price = (charDB().prices or {})[msg.svc]
  if not (onDuty() and not activeRide() and profile and services[msg.svc] and contains(services.dests, msg.dest)
      and price and price <= msg.price) then
    return
  end
  local request = { key = key, reqId = msg.reqId, fac = profile.faction, dest = msg.dest, svcs = { msg.svc },
    max = msg.price, rest = msg.svc == "COME", at = now() }
  bookings[msg.reqId] = { request = request, svc = msg.svc, price = price, booked = true, raw = raw }
  seenAt[msg.reqId] = seenAt[msg.reqId] or now()
  checkIncoming()
  changed()
end

-- Rider: hail and book ------------------------------------------------------------------------------

local function nextReqId()
  seq = (seq or (time() % 1000000)) + 1
  return ("%s:%d"):format(ownKey() or "?", seq)
end

local function endHail(result, winner)
  local h = hail
  cancelTimer(h.collect)
  cancelTimer(h.timeout)
  hail = nil
  last = { reqId = h.reqId, dest = h.dest, result = result, winner = winner, booked = h.booked }
  return h
end

local function riderMatch(h, take)
  return { reqId = h.reqId, role = "rider", svc = take.svc, price = take.price, dest = h.dest,
    peer = { key = take.key, raw = take.raw }, eta = take.eta }
end

-- CONFIRM to the winner, GONE to everyone, HAIL_RESULT, then the ride starts.
local function confirm(take)
  local h = endHail("matched", take)
  net("whisper", take.raw, { type = "CONFIRM", reqId = h.reqId, svc = take.svc, price = take.price })
  net("broadcast", { type = "GONE", reqId = h.reqId })
  ns.fire("HAIL_RESULT", h.reqId, take)
  startRide(riderMatch(h, take))
  changed()
end

local function pickWinner()
  if not hail then
    return
  end
  local winner = ns.Market.pickHailWinner(hail.takes, C.HAIL_TIE)
  if winner then
    confirm(winner)
  end
end

local function noTaxi()
  if not hail then
    return
  end
  local h = endHail("none")
  net("broadcast", { type = "GONE", reqId = h.reqId })
  ns.fire("HAIL_RESULT", h.reqId, nil)
  changed()
end

local function onTake(msg, key, raw)
  local h = hail
  if not (h and h.reqId == msg.reqId) then
    return
  end
  local take = { key = key, raw = raw, svc = msg.svc, price = msg.price, eta = h.eta or msg.eta, wait = msg.wait }
  if h.booked then
    if key == h.booked and msg.svc == h.svc and msg.price <= h.max then
      confirm(take)
    end
    return
  end
  if not contains(h.svcs, msg.svc) or msg.price > h.max then
    return
  end
  for _, t in ipairs(h.takes) do
    if t.key == key then
      return -- one TAKE per taxi
    end
  end
  h.takes[#h.takes + 1] = take
  if not h.collect then
    h.collect = C_Timer.NewTimer(C.T.COLLECT, pickWinner)
  end
  changed()
end

-- Common checks for hail and book; returns the profile or nil, err.
local function riderCheck(dest, price)
  local profile = current()
  if not profile then
    return nil, "profile"
  end
  local city = C.CITY[dest or ""]
  if not city or city.faction ~= profile.faction then
    return nil, "dest"
  end
  if city.name == profile.zone then
    return nil, "here" -- the ride would end DONE at payment, with no portal taken
  end
  if hail or activeRide() then
    return nil, "busy"
  end
  if IsInGroup() then
    return nil, "group" -- the taxi's invite cannot reach a player who is already in a group
  end
  local money = GetMoney()
  if not ns.Market.affordable(money, price) then
    return nil, "money"
  end
  if lastHailSent and now() - lastHailSent < C.T.HAIL_COOLDOWN then
    return nil, "cooldown"
  end
  return profile
end

local function openHail(fields)
  hail = fields
  hail.takes, hail.since = {}, now()
  lastHailSent = hail.since
  last = nil
  hail.timeout = C_Timer.NewTimer(C.T.REQUEST, noTaxi)
  changed()
end

function Dispatch.hail(dest, max)
  max = math.floor(tonumber(max) or 0)
  if max < C.PRICE.MIN or max > C.PRICE.MAX then
    return nil, "range"
  end
  local profile, err = riderCheck(dest, max)
  if not profile then
    return nil, err
  end
  local svcs = profile.resting and { "COME", "PICK" } or { "PICK" }
  local reqId = nextReqId()
  local ok, nerr = net("broadcast", { type = "HAIL", reqId = reqId, fac = profile.faction, dest = dest,
    svcs = svcs, max = max, rest = profile.resting == true })
  if not ok then
    return nil, nerr
  end
  openHail({ reqId = reqId, dest = dest, max = max, svcs = svcs })
  return true
end

-- Rider, Browse or the map: books one taxi's offer; that taxi's TAKE is confirmed at once.
function Dispatch.book(key, dest, svc, eta)
  local profile = current()
  local offer
  for _, o in ipairs(Dispatch.market:offers({ dest = dest, svc = svc, faction = profile and profile.faction })) do
    if o.key == key then
      offer = o
    end
  end
  if not offer or not raws[key] then
    return nil, "offer"
  end
  local _, err = riderCheck(dest, offer.price)
  if err then
    return nil, err
  end
  if svc == "COME" and not profile.resting then
    return nil, "resting"
  end
  local reqId = nextReqId()
  local ok, nerr = net("whisper", raws[key], { type = "BOOK", reqId = reqId, dest = dest, svc = svc,
    price = offer.price })
  if not ok then
    return nil, nerr
  end
  openHail({ reqId = reqId, dest = dest, max = offer.price, svcs = { svc }, svc = svc, booked = key,
    eta = tonumber(eta) and math.max(0, math.floor(eta)) or nil })
  return true
end

-- Rider: withdraws the open hail or booking.
function Dispatch.cancel()
  if not hail then
    return false
  end
  local h = endHail("cancelled")
  net("broadcast", { type = "GONE", reqId = h.reqId })
  changed()
  return true
end

-- Duty --------------------------------------------------------------------------------------------

function Dispatch.setOnDuty(on)
  local db = charDB()
  db.onDuty = on and true or false
  cancelTimer(helloTimer)
  cancelTimer(profileHelloTimer)
  helloTimer, profileHelloTimer = nil, nil
  if db.onDuty then
    local N = ns.Net
    if type(N) == "table" and N.joined and N.rejoin and not N.joined() then
      N.rejoin()
    end
    sendHello()
    scheduleHello()
    markKnown()
  else
    lastHelloSig = nil
    net("broadcast", { type = "BYE" })
  end
  changed()
end

function Dispatch.status()
  local h
  if hail then
    h = { reqId = hail.reqId, dest = hail.dest, max = hail.max, takes = #hail.takes, since = hail.since,
          booked = hail.booked, svc = hail.svc }
  end
  return { onDuty = onDuty(), hail = h, pendingTake = pending and pending.reqId or nil, last = last }
end

-- Incoming messages -----------------------------------------------------------------------------

local function onHail(msg, key)
  local t = now()
  if hailAt[key] and t - hailAt[key] < C.T.HAIL_COOLDOWN - HAIL_SLACK then
    return -- plan §5: one HAIL per player per T.HAIL_COOLDOWN (minus slack for uneven delivery)
  end
  hailAt[key] = t
  Dispatch.market:hail(key, msg, t)
  seenAt[msg.reqId] = t
  checkIncoming()
  changed()
end

local function onGone(reqId)
  local removed = Dispatch.market:gone(reqId)
  if bookings[reqId] then
    removed = true
  end
  forget(reqId)
  if pending and pending.reqId == reqId then
    pending.expires = now() + C.T.CONFIRM
    recentTakes[reqId] = pending
    clearPending()
    removed = true
  end
  if removed then
    changed()
  end
end

local HANDLERS = {
  HELLO = function(msg, key)
    Dispatch.market:hello(key, msg, now())
    changed()
  end,
  BYE = function(_, key)
    Dispatch.market:bye(key)
    changed()
  end,
  HAIL = onHail,
  GONE = function(msg) onGone(msg.reqId) end,
  BOOK = onBook,
  TAKE = onTake,
  CONFIRM = onConfirm,
  SPOT = function(msg, key)
    if Dispatch.market:spot(key, msg, now()) then
      changed()
    end
  end,
}

local function onNetMsg(msg, key, raw)
  if type(msg) ~= "table" or not key then
    return
  end
  if raw then
    raws[key] = raw
  end
  local handler = HANDLERS[msg.type]
  if handler then
    handler(msg, key, raw)
  end
end

-- Expiry ------------------------------------------------------------------------------------------

local function expire()
  local t = now()
  local keys, ids = Dispatch.market:expire(t)
  for _, id in ipairs(ids) do
    forget(id)
  end
  for id, entry in pairs(bookings) do
    if t - entry.request.at >= C.T.REQUEST then
      forget(id)
    end
  end
  for id, p in pairs(recentTakes) do
    if t > p.expires then
      recentTakes[id] = nil
    end
  end
  -- Raw senders are kept for players the Market still knows; bookings carry their own.
  for key in pairs(raws) do
    if not Dispatch.market.offerByKey[key] and not Dispatch.market.requestByKey[key] then
      raws[key] = nil
    end
  end
  -- Ages on the request list move; redraw while there is anything to show.
  if #keys > 0 or #ids > 0 or next(Dispatch.market.requestByKey) or next(bookings) then
    changed()
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

function Dispatch.start()
  if started then
    return
  end
  started = true
  loginAt = time()
  C_Timer.NewTicker(EXPIRE_EVERY, expire)
  if onDuty() then
    Dispatch.setOnDuty(true)
  end
end

ns.on("READY", Dispatch.start)
ns.on("NET_MSG", onNetMsg)
ns.on("PROFILE_CHANGED", function()
  helloSoon()
  checkIncoming()
end)
ns.on("RIDE_STARTED", helloSoon)
ns.on("RIDE_STATE", function(ride)
  if type(ride) == "table" and END_STATES[ride.state] then
    helloSoon()
    checkIncoming()
  end
end)
