-- Market: offers (from HELLO), open requests (from HAIL), Inn hop hosts (from HOST, D20), expiry and hail matching.
-- Pure module (playbook D3): no game API, no ns.now; time comes in as `now`.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Market"; matching rules: docs/PORTAXI_MVP_PLAN.md §6.

local _, ns = ...

local Market = {}
Market.__index = Market
ns.Market = Market

-- Services in order of preference (COME over PICK).
local SERVICES = { "COME", "PICK" }

local function const()
  return ns.Const
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

-- Sorted list of the keys of a set, so results do not depend on pairs() order.
local function sortedKeys(set)
  local keys = {}
  for k in pairs(set) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

function Market.new()
  return setmetatable({ offerByKey = {}, requestByKey = {}, spotByKey = {}, hostByKey = {} }, Market)
end

-- Offers ------------------------------------------------------------------------------------------

-- Stores a decoded HELLO; a newer HELLO from the same key replaces the old offer.
function Market:hello(key, hello, now)
  self.offerByKey[key] = {
    key = key,
    fac = hello.fac,
    cls = hello.cls,
    lvl = hello.lvl,
    place = hello.place,
    dests = hello.dests,
    ask = hello.ask,
    resp = hello.resp,
    waitSince = now - (hello.wait or 0),
    seen = now,
  }
end

function Market:bye(key)
  self.offerByKey[key] = nil
  self.spotByKey[key] = nil
  self.hostByKey[key] = nil
end

local function offerMatches(offer, q, svc)
  if q.faction and offer.fac ~= q.faction then
    return false
  end
  if q.dest and not contains(offer.dests, q.dest) then
    return false
  end
  return offer.ask ~= nil and offer.ask[svc] ~= nil
end

local function byPriceThenKey(a, b)
  if a.price ~= b.price then
    return a.price < b.price
  end
  if a.key ~= b.key then
    return a.key < b.key
  end
  return a.svc < b.svc
end

-- Offers serving q.dest + q.svc for q.faction: { key, svc, price, offer }, by price then key.
-- A filter left out (nil) matches anything; without q.svc every offered service gets its own entry.
function Market:offers(q)
  q = q or {}
  local list = {}
  for _, offer in pairs(self.offerByKey) do
    for _, svc in ipairs(SERVICES) do
      if (q.svc == nil or q.svc == svc) and offerMatches(offer, q, svc) then
        list[#list + 1] = { key = offer.key, svc = svc, price = offer.ask[svc], offer = offer }
      end
    end
  end
  table.sort(list, byPriceThenKey)
  return list
end

-- Taxis on the map (D19) ---------------------------------------------------------------------------

-- Stores a decoded SPOT: { inst, n, w, busy, at }. Kept apart from the offers, so a SPOT that comes before the
-- first HELLO (a rider who just logged in) counts once the HELLO arrives; nearby() needs both. inst -1 (the taxi
-- left the map) removes it. Returns true when something changed.
function Market:spot(key, spot, now)
  if spot.inst < 0 then
    local had = self.spotByKey[key] ~= nil
    self.spotByKey[key] = nil
    return had
  end
  self.spotByKey[key] = { inst = spot.inst, n = spot.n, w = spot.w, busy = spot.busy == true, at = now }
  return true
end

local function spotLive(spot, now)
  return spot ~= nil and now - spot.at < const().T.SPOT_TTL
end

-- Taxis on the map near a rider: offers with a live spot on q.inst within Const.FIELD.RANGE yards of (q.n, q.w)
-- that serve q.dest with PICK for q.faction, except q.exclude (own key). Entries are the Browse entries
-- { key, svc = "PICK", price, offer } plus yards (from the rider to the spot), busy and spot; nearest first.
function Market:nearby(q, now)
  local range = const().FIELD.RANGE
  local list = {}
  for key, offer in pairs(self.offerByKey) do
    local spot = self.spotByKey[key]
    if offer.key ~= q.exclude and spotLive(spot, now) and spot.inst == q.inst and offerMatches(offer, q, "PICK") then
      local dn, dw = spot.n - q.n, spot.w - q.w
      local yards = math.sqrt(dn * dn + dw * dw)
      if yards <= range then
        list[#list + 1] = { key = offer.key, svc = "PICK", price = offer.ask.PICK, offer = offer, yards = yards,
                            busy = spot.busy, spot = spot }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.yards ~= b.yards then
      return a.yards < b.yards
    end
    return a.key < b.key
  end)
  return list
end

-- Inn hop hosts (D20) -----------------------------------------------------------------------------

-- Stores a decoded HOST; a newer HOST from the same key replaces the old one.
function Market:host(key, host, now)
  self.hostByKey[key] = {
    key = key,
    fac = host.fac,
    lvl = host.lvl,
    zone = host.zone,
    sub = host.sub or "",
    city = host.city ~= "" and host.city or nil,
    free = host.free == true,
    seen = now,
  }
end

function Market:unhost(key)
  self.hostByKey[key] = nil
end

local function placeOrder(a, b)
  if (a.kind == "city") ~= (b.kind == "city") then
    return a.kind == "city"
  end
  if a.kind == "city" then
    return a.rank < b.rank
  end
  if a.zone ~= b.zone then
    return a.zone < b.zone
  end
  return a.sub < b.sub
end

-- Places with free hosts of q.faction (q.exclude = own key left out): { kind = "city" | "inn", city, zone, sub,
-- label, hosts = { host, ... } by key }. Cities first in CITY_ORDER, then inns by zone and sub.
function Market:hosts(q)
  q = q or {}
  local C = const()
  local rank = {}
  for i, key in ipairs(C.CITY_ORDER) do
    rank[key] = i
  end
  local byId, places = {}, {}
  for _, key in ipairs(sortedKeys(self.hostByKey)) do
    local h = self.hostByKey[key]
    if h.free and key ~= q.exclude and (q.faction == nil or h.fac == q.faction) then
      local cityKey = h.city and C.CITY[h.city] and h.city or nil
      local id = cityKey and ("city:" .. cityKey) or ("inn:" .. h.zone .. "|" .. h.sub)
      local place = byId[id]
      if not place then
        local label
        if cityKey then
          label = C.CITY[cityKey].name
        elseif h.sub ~= "" and h.sub ~= h.zone then
          label = h.sub .. ", " .. h.zone
        else
          label = h.zone
        end
        place = { kind = cityKey and "city" or "inn", city = cityKey, zone = h.zone, sub = cityKey and "" or h.sub,
                  label = label, hosts = {}, rank = cityKey and rank[cityKey] or 0 }
        byId[id] = place
        places[#places + 1] = place
      end
      place.hosts[#place.hosts + 1] = h
    end
  end
  table.sort(places, placeOrder)
  for _, place in ipairs(places) do
    place.rank = nil
  end
  return places
end

-- Requests ----------------------------------------------------------------------------------------

-- Stores a decoded HAIL; one open request per key, a new hail replaces the previous one.
function Market:hail(key, hail, now)
  self.requestByKey[key] = {
    key = key,
    reqId = hail.reqId,
    fac = hail.fac,
    dest = hail.dest,
    svcs = hail.svcs,
    max = hail.max,
    rest = hail.rest,
    at = now,
  }
end

-- Removes the request with this reqId; returns true when one was removed.
function Market:gone(reqId)
  for key, request in pairs(self.requestByKey) do
    if request.reqId == reqId then
      self.requestByKey[key] = nil
      return true
    end
  end
  return false
end

local function requestExpired(request, now)
  return now - request.at >= const().T.REQUEST
end

-- Drops offers without HELLO for T.OFFER, map spots without SPOT for T.SPOT_TTL, requests older than T.REQUEST and
-- hosts without HOST for T.HOST. Returns the removed offer keys, request reqIds and host keys, each sorted A-Z.
function Market:expire(now)
  local T = const().T
  local removedKeys, removedIds = {}, {}
  for _, key in ipairs(sortedKeys(self.offerByKey)) do
    if now - self.offerByKey[key].seen >= T.OFFER then
      self.offerByKey[key] = nil
      removedKeys[#removedKeys + 1] = key
    end
  end
  for key, spot in pairs(self.spotByKey) do
    if not spotLive(spot, now) then
      self.spotByKey[key] = nil
    end
  end
  for _, key in ipairs(sortedKeys(self.requestByKey)) do
    local request = self.requestByKey[key]
    if requestExpired(request, now) then
      self.requestByKey[key] = nil
      removedIds[#removedIds + 1] = request.reqId
    end
  end
  table.sort(removedIds)
  local removedHosts = {}
  for _, key in ipairs(sortedKeys(self.hostByKey)) do
    if now - self.hostByKey[key].seen >= T.HOST then
      self.hostByKey[key] = nil
      removedHosts[#removedHosts + 1] = key
    end
  end
  return removedKeys, removedIds, removedHosts
end

-- The service the taxi would provide for this request and its price, or nil. COME first.
local function serviceFor(request, taxi)
  local services, prices = taxi.services or {}, taxi.prices or {}
  for _, svc in ipairs(SERVICES) do
    local price = prices[svc]
    if services[svc] and contains(request.svcs, svc) and (svc ~= "COME" or request.rest)
        and price ~= nil and price <= request.max then
      return svc, price
    end
  end
  return nil
end

local function oldestFirst(a, b)
  if a.request.at ~= b.request.at then
    return a.request.at < b.request.at
  end
  return a.request.reqId < b.request.reqId
end

-- Requests this taxi can serve: { request, svc, price }, oldest first.
-- taxi = { faction, services (Detect.services), prices = { COME, PICK }, key = own key (optional) }.
-- Requests from taxi.key (own hails) and requests already past T.REQUEST are skipped.
function Market:openRequests(taxi, now)
  local dests = taxi.services and taxi.services.dests
  local list = {}
  for key, request in pairs(self.requestByKey) do
    if key ~= taxi.key and request.fac == taxi.faction and contains(dests, request.dest)
        and not requestExpired(request, now) then
      local svc, price = serviceFor(request, taxi)
      if svc then
        list[#list + 1] = { request = request, svc = svc, price = price }
      end
    end
  end
  table.sort(list, oldestFirst)
  return list
end

-- Matching ----------------------------------------------------------------------------------------

-- Total order among candidates: longest wait, then key A-Z, then lower eta, price, svc.
local function betterCandidate(a, b)
  if a.wait ~= b.wait then
    return a.wait > b.wait
  end
  if a.key ~= b.key then
    return a.key < b.key
  end
  if a.eta ~= b.eta then
    return a.eta < b.eta
  end
  if a.price ~= b.price then
    return (a.price or 0) < (b.price or 0)
  end
  return tostring(a.svc) < tostring(b.svc)
end

-- takes = { { key, eta, wait, price, svc }, ... }. Lowest eta sets the bar; takes with
-- eta <= min + tie are candidates; the longest-waiting candidate wins, then key A-Z.
-- tie defaults to Const.HAIL_TIE. Returns nil for no takes. Independent of input order.
function Market.pickHailWinner(takes, tie)
  tie = tie or const().HAIL_TIE
  local minEta
  for _, take in ipairs(takes or {}) do
    if minEta == nil or take.eta < minEta then
      minEta = take.eta
    end
  end
  if minEta == nil then
    return nil
  end
  local winner
  for _, take in ipairs(takes) do
    if take.eta <= minEta + tie and (winner == nil or betterCandidate(take, winner)) then
      winner = take
    end
  end
  return winner
end

function Market.affordable(money, price)
  return money >= price
end
