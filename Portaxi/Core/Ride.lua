-- Ride: the ride state machine (pure core) and its game glue.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Ride" (flow, cancel rules: docs/PORTAXI_MVP_PLAN.md §7). Card H, wave 2.
--
-- Public API
--   Ride.start(match) -> ride | nil, err   err "busy" (a ride is active) or "match" (bad match table)
--   Ride.current() -> ride | nil           read-only snapshot; nil once the ride ended
--   Ride.cancel(reason) -> true, late | nil, err   err "no_ride", "too_late" (taxi after EN_ROUTE)
--   Ride.manual(what) -> true | nil, err   what "invite" | "accept" | "trade"; called from a click (hardware event)
--   Ride.canCancel(ride) -> true, late | nil, err   pure; the RidePanel uses it for the Cancel button
--   Ride.new(match, now) -> ride, actions | nil, err   pure; the MATCHED ride
--   Ride.step(ride, event, now) -> ride, actions       pure; returns a new table, never changes the old one
--   Ride.isOver(ride) -> bool               true for nil, DONE, CANCELLED, FAILED
--
-- States: MATCHED -> GROUPED -> EN_ROUTE -> ARRIVED -> TRADING -> PAID -> PORTAL_OPEN -> DONE; CANCELLED, FAILED.
-- Extra ride fields (besides §2): startedAt, castGuid, landing (time of the scroll's SUCCEEDED until LANDED),
--   scrollError (last failed scroll: the UI error text, or "unconfirmed"), invited (rider got the peer's invite),
--   inviteAt/acceptAt (auto call made), inviteManual/acceptManual (caps switched in this ride), paid (copper),
--   cancelledBy, armedKey.
--
-- Step events (event.type, fields)
--   TICK                              every second: timeouts (T.INVITE in MATCHED, T.PORTAL in PORTAL_OPEN, auto
--                                     invite/accept waits -> caps "manual")
--   ROSTER       unit, connected      the peer's partyN unit (nil when not in the group) and UnitIsConnected
--   INVITE       from                 rider got PARTY_INVITE_REQUEST from player key `from`
--   INVITE_SENT  manual               taxi called InviteUnit (auto, or manual from the panel)
--   ACCEPT_SENT  manual               rider called AcceptGroup
--   BLOCKED      what                 ADDON_ACTION_BLOCKED for "invite" | "accept"
--   RESTING      resting              own IsResting() (also once at start); rider: announced to the taxi;
--                                     taxi: ride.selfResting, the scroll is armed only while both rest
--   CAST         who, spell, phase, guid   who "self" | "peer"; spell "SCROLL" | "PORTAL";
--                                     phase "START" | "SUCCEEDED" | "FAILED" | "INTERRUPTED"
--   NEAR                              PICK: CheckInteractDistance(peerUnit, 2) was true (polled every second)
--   LANDED                            taxi COME: proof that the scroll moved us after its SUCCEEDED (a scroll
--                                     fewer in the bags, or the rider within interact distance)
--   SCROLL_ERROR message              taxi COME: a UI error right after the scroll's SUCCEEDED ("Invalid target":
--                                     the rider was not resting; nothing moved and no scroll was used)
--   PAID         copper               taxi: TRADE_PAID for this reqId
--   ZONE         zone                 rider: GetZoneText() after a zone change
--   PEER_STATE   state                STATE message from the peer (state name, or "RESTING" / "NOT_RESTING")
--   PEER_CANCEL  by, late             CANCEL message from the peer
--   CANCEL       reason               local Ride.cancel (ignored when Ride.canCancel says no)
--
-- Actions (action.type, fields) that the glue executes
--   SEND         state                Net.whisper(peer.raw, STATE { reqId, state })
--   CANCEL_MSG   late                 Net.whisper(peer.raw, CANCEL { reqId, by = role, late })
--   INVITE                            taxi: C_PartyInfo.InviteUnit(peer.key) from a timer, unless caps.invite manual
--   ACCEPT                            rider: AcceptGroup + StaticPopup_Hide("PARTY_INVITE"), unless caps.accept manual
--   SECURE       spec                 ns.Secure.set(spec); spec nil disarms
--   TRADE_OPEN                        taxi: ns.Trade.open(peerUnit)
--   CAPS         what                 PortaxiDB.caps[what] = "manual", ns.fire("CAPS_CHANGED", caps)
--   RECORD_LATE                       PortaxiCharDB.lateCancels += { reqId, at = time(), peer, price }
--   LAST_RIDE                         taxi: PortaxiCharDB.lastRideAt = time()
--   END                               the ride is over: Ride.current() becomes nil, the ticker stops
-- The glue fires RIDE_STARTED once and RIDE_STATE whenever state, peerUnit, riderResting, invited, late or reason
-- changed. Every end state also disarms Secure (SECURE nil).
--
-- Who leads which transition (the leader whispers STATE with the new state name; the other side follows)
--   GROUPED            both sides on their own (the peer's partyN unit found by name)
--   EN_ROUTE           COME: both sides from the scroll's UNIT_SPELLCAST_START (taxi "player", rider peerUnit);
--                      the taxi also sends it, because the rider may be too far away to see the cast.
--                      PICK: both sides at once after GROUPED.
--   GROUPED (again)    taxi, when its scroll cast fails or is interrupted (EN_ROUTE -> GROUPED)
--   ARRIVED            taxi leads: COME after the scroll's SUCCEEDED *and* LANDED (SUCCEEDED also fires when the
--                      scroll fails with "Invalid target", in-game probe 2026-11-19); PICK on proximity (the rider
--                      also detects that on its own)
--   GROUPED (again)    taxi, after SCROLL_ERROR, or no LANDED within T.LANDING s of SUCCEEDED (EN_ROUTE -> GROUPED)
--   TRADING, PAID      taxi leads, the rider follows
--   PORTAL_OPEN        taxi leads (portal SUCCEEDED on "player"); the rider also sees it on peerUnit
--   PAID (again)       T.PORTAL in PORTAL_OPEN without DONE, on both sides; the taxi also sends it
--   DONE               rider leads (zone == Const.CITY[dest].name), the taxi follows
--   CANCELLED          whoever cancels sends CANCEL; the other side follows (any active state)
--   FAILED             each side on its own (invite timeout, peer offline, peer left the group); a side that fails
--                      for any reason but "peer_offline" sends STATE "FAILED" and the other side follows
-- The rider sends STATE "RESTING" / "NOT_RESTING" at start, when grouped and on every change.
-- A side follows only forward moves (by state order) and the two reverts above; anything else is ignored.
--
-- Inn hop (D20), svc "HOP": the mage is the taxi (invites, casts the scroll on the host), the host is the rider. The
-- same steps as COME up to ARRIVED (LANDED proof included), then the taxi leads DONE at once: no trade, no portal,
-- price 0, dest = the host's city key or nil, never late, no LAST_RIDE. peer.noAddon (a /who host without Portaxi):
-- no STATE is sent and the host counts as resting.
-- Cancel rules: the rider cancels free before EN_ROUTE; a Come-to-you cancel in EN_ROUTE, ARRIVED or TRADING is
-- late (the scroll is spent; recorded in PortaxiCharDB.lateCancels); a pickup cancel is never late; after PAID it is
-- free again (the taxi is paid). The taxi cancels before EN_ROUTE, while waiting for a pickup rider (PICK EN_ROUTE)
-- and while waiting for the payment (ARRIVED, TRADING); not during the scroll cast nor once paid.
-- ARRIVED / TRADING last at most T.TRADE seconds, then the ride ends FAILED "trade_timeout" (architect, G2 review).

-- luacheck: read globals UnitIsConnected CheckInteractDistance time

local _, ns = ...
local C = ns.Const
local L = ns.L

local Ride = {}
ns.Ride = Ride

local INVITE_DELAY = 0.5                    -- seconds from Ride.start to the taxi's automatic invite
local AUTO_WAIT = { invite = 15, accept = 5 } -- no group this long after an automatic call -> caps "manual"
local TICK = 1                              -- seconds between TICK events (and the PICK proximity poll)

local ORDER = { "MATCHED", "GROUPED", "EN_ROUTE", "ARRIVED", "TRADING", "PAID", "PORTAL_OPEN", "DONE" }
local RANK = {}
for i, s in ipairs(ORDER) do
  RANK[s] = i
end
local ENDED = { DONE = true, CANCELLED = true, FAILED = true }

-- States each role announces with STATE when it gets there on its own (FAILED: see fail()).
local LEADS = {
  taxi = { EN_ROUTE = true, ARRIVED = true, TRADING = true, PAID = true, PORTAL_OPEN = true },
  rider = { DONE = true },
}
-- STATE values each role follows from the peer.
local FOLLOWS = {
  rider = { GROUPED = true, EN_ROUTE = true, ARRIVED = true, TRADING = true, PAID = true, PORTAL_OPEN = true,
            FAILED = true },
  taxi = { DONE = true, FAILED = true },
}
-- Reverts a side follows although they go backwards: [from] = to.
local REVERTS = { EN_ROUTE = "GROUPED", PORTAL_OPEN = "PAID" }

-- Pure core ------------------------------------------------------------------------------

function Ride.isOver(ride)
  return ride == nil or ENDED[ride.state] == true
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

local function emit(acts, action)
  acts[#acts + 1] = action
end

local SCROLL_SVC = { COME = true, HOP = true } -- services that move the taxi with the scroll

local function validMatch(m)
  if not (type(m) == "table" and type(m.reqId) == "string" and m.reqId ~= "" and (m.role == "rider" or m.role == "taxi")
      and type(m.price) == "number" and type(m.peer) == "table" and type(m.peer.key) == "string"
      and type(m.peer.raw) == "string") then
    return false
  end
  if m.svc == "HOP" then
    return m.dest == nil or C.CITY[m.dest] ~= nil
  end
  return (m.svc == "COME" or m.svc == "PICK") and C.CITY[m.dest] ~= nil
end

function Ride.new(match, now)
  if not validMatch(match) then
    return nil, "match"
  end
  local ride = copy(match)
  ride.peer = { key = match.peer.key, raw = match.peer.raw, noAddon = match.peer.noAddon == true or nil }
  if ride.peer.noAddon then
    ride.riderResting = true -- a host without Portaxi cannot tell; the scroll's error tells instead
  end
  ride.state, ride.since, ride.startedAt = "MATCHED", now, now
  ride.late = false
  ride.armedKey = "none"
  local acts = {}
  if ride.role == "taxi" then
    emit(acts, { type = "INVITE" })
  end
  return ride, acts
end

function Ride.canCancel(ride)
  if Ride.isOver(ride) then
    return nil, "no_ride"
  end
  local rank = RANK[ride.state]
  if rank < RANK.EN_ROUTE then
    return true, false
  end
  if ride.role == "taxi" then
    -- The taxi may walk away from a rider who does not come (PICK) or does not pay (ARRIVED/TRADING);
    -- during the scroll cast and once paid it must deliver.
    local waiting = (ride.svc == "PICK" and ride.state == "EN_ROUTE")
      or ride.state == "ARRIVED" or ride.state == "TRADING"
    if waiting then
      return true, false
    end
    return nil, "too_late"
  end
  -- Only a Come-to-you cancel after the scroll costs the taxi something (late); a pickup or a hop cancel never does.
  return true, ride.svc == "COME" and rank < RANK.PAID
end

-- Secure spec the taxi wants armed right now (nil for the rider and between steps).
local function specFor(r)
  if r.role ~= "taxi" then
    return nil
  end
  if SCROLL_SVC[r.svc] and r.state == "GROUPED" and r.riderResting == true and r.selfResting ~= false
      and r.peerUnit then
    return { kind = "item", item = C.ITEM.LIMINAL_SCROLL, unit = r.peerUnit,
             label = L["Teleport to %s"]:format(r.peer.key) }
  end
  if r.state == "PAID" then
    local city = C.CITY[r.dest]
    return { kind = "spell", spell = city.spell, label = L["Portal: %s"]:format(L[city.name]) }
  end
  return nil
end

local function specKey(spec)
  if not spec then
    return "none"
  end
  return ("%s:%s:%s"):format(spec.kind, tostring(spec.item or spec.spell), tostring(spec.unit or ""))
end

local function restingState(r)
  return r.riderResting and "RESTING" or "NOT_RESTING"
end

-- Moves to state. followed = true when the peer led the move (nothing is sent back).
local function go(r, acts, state, now, followed)
  local prev = r.state
  r.state, r.since = state, now
  if not followed then
    local revert = state == "GROUPED" and prev == "EN_ROUTE" and r.role == "taxi"
    local hopDone = r.svc == "HOP" and r.role == "taxi" and state == "DONE"
    if LEADS[r.role][state] or revert or hopDone then
      emit(acts, { type = "SEND", state = state })
    end
  end
  if state ~= "EN_ROUTE" then
    r.castGuid = nil
    r.landing = nil
  end
  if state == "GROUPED" and r.role == "rider" and r.riderResting ~= nil then
    emit(acts, { type = "SEND", state = restingState(r) })
  end
  if ENDED[state] then
    emit(acts, { type = "SECURE", spec = nil })
    r.armedKey = "none"
    if state == "DONE" and r.role == "taxi" and r.svc ~= "HOP" then
      emit(acts, { type = "LAST_RIDE" })
    end
    emit(acts, { type = "END" })
  end
end

local function fail(r, acts, reason, now, followed)
  r.reason = reason
  if not followed and reason ~= "peer_offline" then
    emit(acts, { type = "SEND", state = "FAILED" })
  end
  go(r, acts, "FAILED", now, true)
end

-- Shows the manual step for this ride. remember = true only when the client refused the call (BLOCKED):
-- then caps[what] = "manual" for good. A timeout (AFK rider, slow roster) affects this ride only.
local function switchManual(r, acts, what, remember)
  r[what .. "Manual"] = true
  local stored = what .. "Remembered"
  if remember and not r[stored] then
    r[stored] = true
    emit(acts, { type = "CAPS", what = what })
  end
end

local H = {} -- event handlers: H[type](r, event, now, acts)

function H.TICK(r, _, now, acts)
  local age = now - (r.since or now)
  if r.state == "MATCHED" then
    if age >= C.T.INVITE then
      return fail(r, acts, "invite_timeout", now)
    end
    for what, wait in pairs(AUTO_WAIT) do
      local at = r[what .. "At"]
      if at and now - at >= wait then
        switchManual(r, acts, what, false)
      end
    end
  elseif r.state == "EN_ROUTE" and r.landing and now - r.landing >= C.T.LANDING then
    r.scrollError = "unconfirmed" -- the scroll did not visibly move us: try again from GROUPED
    go(r, acts, "GROUPED", now)
  elseif r.state == "PORTAL_OPEN" and age >= C.T.PORTAL then
    go(r, acts, "PAID", now)
  elseif (r.state == "ARRIVED" or r.state == "TRADING") and age >= C.T.TRADE then
    fail(r, acts, "trade_timeout", now) -- nobody paid: neither side stays stuck in the ride
  end
end

function H.ROSTER(r, e, now, acts)
  if not e.unit then
    if r.peerUnit then
      r.peerUnit = nil
      fail(r, acts, "left_group", now)
    end
    return
  end
  if e.connected == false then
    r.peerUnit = e.unit
    return fail(r, acts, "peer_offline", now)
  end
  r.peerUnit = e.unit
  if r.state == "MATCHED" then
    go(r, acts, "GROUPED", now)
  end
end

function H.INVITE(r, e, _, acts)
  if r.role == "rider" and r.state == "MATCHED" and e.from == r.peer.key then
    r.invited = true
    emit(acts, { type = "ACCEPT" })
  end
end

local function sent(what)
  return function(r, e, now)
    if r.state == "MATCHED" then
      r[what .. "At"] = now
      if e.manual then
        r[what .. "Manual"] = true
      end
    end
  end
end
H.INVITE_SENT = sent("invite")
H.ACCEPT_SENT = sent("accept")

function H.BLOCKED(r, e, _, acts)
  if e.what == "invite" or e.what == "accept" then
    switchManual(r, acts, e.what, true)
  end
end

function H.RESTING(r, e, _, acts)
  local resting = e.resting and true or false
  if r.role == "taxi" then
    r.selfResting = resting -- the scroll needs both players resting
    return
  end
  if r.riderResting ~= resting then
    r.riderResting = resting
    emit(acts, { type = "SEND", state = restingState(r) })
  end
end

local function castScroll(r, e, now, acts)
  if not SCROLL_SVC[r.svc] then
    return
  end
  if e.phase == "START" then
    if r.state == "GROUPED" then
      go(r, acts, "EN_ROUTE", now)
      r.castGuid = e.guid
    end
    return
  end
  local own = not (r.castGuid and e.guid and e.guid ~= r.castGuid)
  if not own then
    return -- another attempt failed while the real cast runs (e.g. a second click)
  end
  if e.phase == "SUCCEEDED" and (r.state == "EN_ROUTE" or r.state == "GROUPED") then
    -- Not ARRIVED yet: SUCCEEDED also fires when the scroll fails ("Invalid target"). The taxi waits for LANDED or
    -- SCROLL_ERROR; the rider waits for the taxi's STATE.
    if r.role == "taxi" then
      if r.state == "GROUPED" then
        go(r, acts, "EN_ROUTE", now) -- START was missed
      end
      r.landing = now
    end
  elseif (e.phase == "FAILED" or e.phase == "INTERRUPTED") and r.state == "EN_ROUTE" then
    go(r, acts, "GROUPED", now)
  end
end

function H.CAST(r, e, now, acts)
  local expected = r.role == "taxi" and "self" or "peer"
  if e.who ~= expected then
    return
  end
  if e.spell == "SCROLL" then
    castScroll(r, e, now, acts)
  elseif e.spell == "PORTAL" and e.phase == "SUCCEEDED" and r.state == "PAID" then
    go(r, acts, "PORTAL_OPEN", now)
  end
end

function H.NEAR(r, _, now, acts)
  if r.svc == "PICK" and r.state == "EN_ROUTE" then
    go(r, acts, "ARRIVED", now)
  end
end

function H.LANDED(r, _, now, acts)
  if r.role == "taxi" and SCROLL_SVC[r.svc] and r.state == "EN_ROUTE" and r.landing then
    r.scrollError = nil
    go(r, acts, "ARRIVED", now)
  end
end

function H.SCROLL_ERROR(r, e, now, acts)
  if r.role == "taxi" and SCROLL_SVC[r.svc] and r.state == "EN_ROUTE" and r.landing then
    r.scrollError = e.message or "error"
    go(r, acts, "GROUPED", now) -- the revert is sent; the rider follows and the scroll is armed again
  end
end

function H.PAID(r, e, now, acts)
  local rank = RANK[r.state]
  if r.role == "taxi" and rank >= RANK.EN_ROUTE and rank <= RANK.TRADING then
    r.paid = e.copper
    go(r, acts, "PAID", now)
  end
end

function H.ZONE(r, e, now, acts)
  if r.role == "rider" and (r.state == "PAID" or r.state == "PORTAL_OPEN") and e.zone == C.CITY[r.dest].name then
    go(r, acts, "DONE", now)
  end
end

function H.PEER_STATE(r, e, now, acts)
  local state = e.state
  if state == "RESTING" or state == "NOT_RESTING" then
    if r.role == "taxi" then
      r.riderResting = state == "RESTING"
    end
    return
  end
  local hopDone = r.svc == "HOP" and r.role == "rider" and state == "DONE"
  if not FOLLOWS[r.role][state] and not hopDone then
    return
  end
  if state == "FAILED" then
    return fail(r, acts, "peer_failed", now, true)
  end
  if REVERTS[r.state] == state or RANK[state] > RANK[r.state] then
    go(r, acts, state, now, true)
  end
end

function H.PEER_CANCEL(r, e, now, acts)
  r.late = e.late == true
  r.cancelledBy = e.by
  r.reason = "peer_cancelled"
  go(r, acts, "CANCELLED", now, true)
end

function H.CANCEL(r, e, now, acts)
  local ok, late = Ride.canCancel(r)
  if not ok then
    return
  end
  r.late = late
  r.cancelledBy = r.role
  r.reason = e.reason or "cancelled"
  emit(acts, { type = "CANCEL_MSG", late = late })
  if late then
    emit(acts, { type = "RECORD_LATE" })
  end
  go(r, acts, "CANCELLED", now, true)
end

-- Follow-ups that need no event: PICK goes on at once, the taxi opens the trade, Secure follows the state.
local function settle(r, now, acts)
  if r.svc == "PICK" and r.state == "GROUPED" then
    go(r, acts, "EN_ROUTE", now)
  end
  if r.role == "taxi" and r.state == "ARRIVED" then
    if r.svc == "HOP" then
      go(r, acts, "DONE", now) -- the hop is the whole ride
    else
      go(r, acts, "TRADING", now)
      emit(acts, { type = "TRADE_OPEN" })
    end
  end
  if Ride.isOver(r) then
    return
  end
  local spec = specFor(r)
  local key = specKey(spec)
  if key ~= r.armedKey then
    r.armedKey = key
    emit(acts, { type = "SECURE", spec = spec })
  end
end

function Ride.step(ride, event, now)
  if Ride.isOver(ride) or type(event) ~= "table" then
    return ride, {}
  end
  local handler = H[event.type]
  if not handler then
    return ride, {}
  end
  local r, acts = copy(ride), {}
  handler(r, event, now, acts)
  settle(r, now, acts)
  return r, acts
end

-- Glue ---------------------------------------------------------------------------------------

local active      -- current ride snapshot
local ticker      -- 1 s ticker while a ride is active
local queue = {}  -- step events waiting while another one is processed (actions can raise game events)
local busy = false
local blocked = {} -- what -> true when ADDON_ACTION_BLOCKED arrived during our own call

local VISIBLE = { "state", "peerUnit", "riderResting", "selfResting", "invited", "late", "reason",
  "inviteManual", "acceptManual", "scrollError" }

local function visibleChanged(a, b)
  for _, k in ipairs(VISIBLE) do
    if a[k] ~= b[k] then
      return true
    end
  end
  return false
end

local function reportError(err)
  local handler = geterrorhandler and geterrorhandler()
  if handler then
    handler(err)
  end
end

local function caps()
  if type(PortaxiDB) ~= "table" then
    return {}
  end
  PortaxiDB.caps = PortaxiDB.caps or {}
  return PortaxiDB.caps
end

local function charDB()
  return type(PortaxiCharDB) == "table" and PortaxiCharDB or {}
end

local function module(name, fn)
  local m = ns[name]
  return type(m) == "table" and type(m[fn]) == "function" and m[fn] or nil
end

local function whisper(ride, msg)
  local send = module("Net", "whisper")
  if send then
    send(ride.peer.raw, msg)
  end
end

local apply -- forward declaration

local calling -- "invite" | "accept" while that protected call runs (blocked-event attribution)

-- Calls fn() and reports whether ADDON_ACTION_BLOCKED/FORBIDDEN arrived meanwhile. Forever reports the
-- function as "UNKNOWN()" (gate G2), so the event is attributed to the call in progress.
local function guarded(what, fn, ...)
  blocked[what] = nil
  calling = what
  local ok, err = pcall(fn, ...)
  calling = nil
  if not ok then
    reportError(err)
  end
  local wasBlocked = blocked[what] or not ok
  blocked[what] = nil
  return not wasBlocked
end

-- The name to invite: always the full "First Surname" (the raw sender). Forever has no realms; first
-- names are not unique, only first name + surname is (gate G2: InviteUnit("First Surname") worked).
local function inviteName(peer)
  return peer.raw or peer.key
end

local function inviteNow(manual)
  local invite = ns.api("C_PartyInfo.InviteUnit", "InviteUnit")
  if not (active and invite) then
    return false
  end
  if guarded("invite", invite, inviteName(active.peer)) then
    apply({ type = "INVITE_SENT", manual = manual })
    return true
  end
  return false
end

-- Marks the visible PARTY_INVITE dialog as accepted, so hiding it does not decline the invite.
local function hideInvitePopup()
  local find = ns.api("StaticPopup_FindVisible")
  local dialog = find and find("PARTY_INVITE")
  if dialog then
    dialog.inviteAccepted = 1
  end
  StaticPopup_Hide("PARTY_INVITE")
end

local function acceptNow(manual)
  if not active or not guarded("accept", AcceptGroup) then
    return false
  end
  hideInvitePopup()
  apply({ type = "ACCEPT_SENT", manual = manual })
  return true
end

local function autoInvite(reqId)
  local r = active
  if r and r.reqId == reqId and r.state == "MATCHED" and not r.peerUnit and caps().invite ~= "manual" then
    inviteNow(false)
  end
end

local EXEC = {}

function EXEC.SEND(r, a)
  if not r.peer.noAddon then
    whisper(r, { type = "STATE", reqId = r.reqId, state = a.state })
  end
end

function EXEC.CANCEL_MSG(r, a)
  if not r.peer.noAddon then
    whisper(r, { type = "CANCEL", reqId = r.reqId, by = r.role, late = a.late })
  end
end

function EXEC.INVITE(r)
  local reqId = r.reqId
  C_Timer.After(INVITE_DELAY, function()
    autoInvite(reqId)
  end)
end

function EXEC.ACCEPT()
  if caps().accept ~= "manual" then
    acceptNow(false)
  end
end

function EXEC.SECURE(_, a)
  local set = module("Secure", "set")
  if set then
    set(a.spec)
  end
end

function EXEC.TRADE_OPEN(r)
  local open = module("Trade", "open")
  if open and r.peerUnit then
    open(r.peerUnit)
  end
end

function EXEC.CAPS(_, a)
  ns.setCap(a.what, "manual")
end

function EXEC.RECORD_LATE(r)
  local db = charDB()
  db.lateCancels = db.lateCancels or {}
  table.insert(db.lateCancels, { reqId = r.reqId, at = time(), peer = r.peer.key, price = r.price })
end

function EXEC.LAST_RIDE()
  charDB().lastRideAt = time()
end

local LEAVE_DELAY = 3 -- seconds after the end, so the rider can still step through the portal

-- The taxi leaves the two-person group it created for this ride, so the next invite to the same rider
-- does not fail with "already in a group" (architect, G2). A bigger group is left alone.
local function leaveRideGroup()
  local leave = ns.api("C_PartyInfo.LeaveParty", "LeaveParty")
  local members = ns.api("GetNumGroupMembers")
  if leave and members and members() == 2 and not active then
    local ok, err = pcall(leave)
    if not ok then
      reportError(err)
    end
  end
end

function EXEC.END(r)
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
  if r.role == "taxi" and r.inviteAt then
    C_Timer.After(LEAVE_DELAY, leaveRideGroup)
  end
end

-- Runs one step: new snapshot first (actions may read Ride.current()), then actions, then RIDE_STATE.
local function process(event)
  local old = active
  local new, acts = Ride.step(old, event, ns.now())
  if new == old then
    return
  end
  active = new
  for _, a in ipairs(acts) do
    local exec = EXEC[a.type]
    if exec then
      local ok, err = pcall(exec, new, a) -- one failing action (e.g. another card's module) must not skip the rest
      if not ok then
        reportError(err)
      end
    end
  end
  if Ride.isOver(new) then
    if active == new then
      active = nil
    end
    queue = {} -- events for the finished ride are void
  end
  if visibleChanged(old, new) then
    ns.fire("RIDE_STATE", new)
  end
end

-- Queues a step event; events raised by our own actions run after the current one.
function apply(event)
  queue[#queue + 1] = event
  if busy then
    return
  end
  busy = true
  while #queue > 0 do
    local e = table.remove(queue, 1)
    if active then
      xpcall(function()
        process(e)
      end, reportError)
    end
  end
  busy = false
end

-- Game state readers -------------------------------------------------------------------------

local function findPeerUnit(key)
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) and ns.sameName(ns.unitKey(unit), key) then
      return unit
    end
  end
end

local function rosterEvent()
  local unit = active and findPeerUnit(active.peer.key)
  local connected
  if unit then
    connected = UnitIsConnected(unit) and true or false
  end
  return { type = "ROSTER", unit = unit, connected = connected }
end

local function restingEvent()
  return { type = "RESTING", resting = IsResting() and true or false }
end

local function zoneEvent()
  return { type = "ZONE", zone = GetZoneText() }
end

local function spellKind(spellId)
  if spellId == nil then
    return nil
  end
  if C.SPELL.LIMINAL_PASSAGE and spellId == C.SPELL.LIMINAL_PASSAGE then
    return "SCROLL"
  end
  local city = active and C.CITY[active.dest or ""]
  if city and spellId == city.spell then
    return "PORTAL"
  end
end

local CAST_PHASE = {
  UNIT_SPELLCAST_START = "START",
  UNIT_SPELLCAST_SUCCEEDED = "SUCCEEDED",
  UNIT_SPELLCAST_FAILED = "FAILED",
  UNIT_SPELLCAST_INTERRUPTED = "INTERRUPTED",
}

-- Proof that our own scroll moved us (taxi COME): SUCCEEDED alone is no proof, it also fires on "Invalid target".
local LANDING_GRACE = 1   -- s after SUCCEEDED before proximity counts (a UI error may still come)
local ERROR_WINDOW = 2    -- s after SUCCEEDED in which a UI error means the scroll failed
local scrollsBefore       -- scrolls in the bags when our scroll cast started

local function scrollCount()
  local count = ns.api("C_Item.GetItemCount", "GetItemCount")
  return count and (tonumber(count(C.ITEM.LIMINAL_SCROLL)) or 0) or nil
end

local function checkLanded()
  local r = active
  if not (r and r.role == "taxi" and SCROLL_SVC[r.svc] and r.landing) then
    return
  end
  local n = scrollCount()
  local used = scrollsBefore and n and n < scrollsBefore
  local near = ns.now() - r.landing >= LANDING_GRACE and r.peerUnit and CheckInteractDistance(r.peerUnit, 2)
  if used or near then
    apply({ type = "LANDED" })
  end
end

local function onCast(event, unit, guid, spellId)
  local kind = spellKind(tonumber(spellId))
  if not kind then
    return
  end
  local who = unit == "player" and "self" or (unit == active.peerUnit and "peer") or nil
  if not who then
    return
  end
  local phase = CAST_PHASE[event]
  if who == "self" and kind == "SCROLL" and phase == "START" then
    scrollsBefore = scrollCount()
  end
  apply({ type = "CAST", who = who, spell = kind, phase = phase, guid = guid })
  if who == "self" and kind == "SCROLL" and phase == "SUCCEEDED" then
    checkLanded()
  end
end

local function onUiError(_, message)
  local r = active
  if r and r.role == "taxi" and r.landing and ns.now() - r.landing <= ERROR_WINDOW then
    apply({ type = "SCROLL_ERROR", message = tostring(message) })
  end
end

local function onBlocked(addon, fn)
  if addon ~= ns.ADDON or type(fn) ~= "string" then
    return
  end
  local what = calling
    or (fn:find("InviteUnit", 1, true) and "invite")
    or (fn:find("AcceptGroup", 1, true) and "accept")
  if what then
    blocked[what] = true
    apply({ type = "BLOCKED", what = what })
  end
end

local GAME = {}
GAME.GROUP_ROSTER_UPDATE = function() apply(rosterEvent()) end
GAME.UNIT_CONNECTION = GAME.GROUP_ROSTER_UPDATE
-- The invite event's name format on Forever is unverified (first name only, or "First Surname"); a name
-- that matches the peer by ns.sameName is passed on as the peer's key, anything else as it came.
GAME.PARTY_INVITE_REQUEST = function(name)
  local from = ns.playerKey(name)
  if active and ns.sameName(from, active.peer.key) then
    from = active.peer.key
  end
  apply({ type = "INVITE", from = from })
end
GAME.PLAYER_UPDATE_RESTING = function() apply(restingEvent()) end
GAME.ZONE_CHANGED_NEW_AREA = function() apply(zoneEvent()) end
GAME.PLAYER_ENTERING_WORLD = function()
  apply(zoneEvent())
  checkLanded()
end
GAME.BAG_UPDATE_DELAYED = checkLanded
GAME.UI_ERROR_MESSAGE = onUiError
GAME.ADDON_ACTION_BLOCKED = onBlocked
GAME.ADDON_ACTION_FORBIDDEN = onBlocked
for event in pairs(CAST_PHASE) do
  GAME[event] = function(...) onCast(event, ...) end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  local handler = GAME[event]
  if handler and active then
    handler(...)
  end
end)

local function onTick()
  if not active then
    return
  end
  apply(rosterEvent())
  apply({ type = "TICK" })
  local r = active
  if not r then
    return
  end
  if r.svc == "PICK" and r.state == "EN_ROUTE" and r.peerUnit and CheckInteractDistance(r.peerUnit, 2) then
    apply({ type = "NEAR" })
  end
  checkLanded()
  if r.role == "rider" and (r.state == "PAID" or r.state == "PORTAL_OPEN") then
    apply(zoneEvent())
  end
end

local function onNetMsg(msg, key)
  local r = active
  if not (r and type(msg) == "table" and ns.sameName(key, r.peer.key) and msg.reqId == r.reqId) then
    return
  end
  if msg.type == "STATE" then
    apply({ type = "PEER_STATE", state = msg.state })
  elseif msg.type == "CANCEL" then
    apply({ type = "PEER_CANCEL", by = msg.by, late = msg.late })
  end
end

local function onTradePaid(reqId, copper)
  if active and active.role == "taxi" and reqId == active.reqId then
    apply({ type = "PAID", copper = copper })
  end
end

local initialized = false

function Ride.init()
  if initialized then
    return
  end
  initialized = true
  -- One by one: an event unknown to this client raises in RegisterEvent and must not stop the rest (G1 lesson).
  for event in pairs(GAME) do
    pcall(events.RegisterEvent, events, event)
  end
  ns.on("NET_MSG", onNetMsg)
  ns.on("TRADE_PAID", onTradePaid)
end

ns.on("READY", Ride.init)

-- Public API ---------------------------------------------------------------------------------

function Ride.current()
  return active
end

function Ride.start(match)
  if active then
    return nil, "busy"
  end
  Ride.init()
  local ride, acts = Ride.new(match, ns.now())
  if not ride then
    return nil, acts
  end
  active = ride
  queue = {}
  ns.fire("RIDE_STARTED", ride)
  for _, a in ipairs(acts) do
    EXEC[a.type](ride, a)
  end
  ticker = C_Timer.NewTicker(TICK, onTick)
  apply(restingEvent()) -- rider: announced to the taxi; taxi: its own resting gates the scroll
  apply(rosterEvent())
  return active or ride
end

function Ride.cancel(reason)
  if not active then
    return nil, "no_ride"
  end
  local ok, late = Ride.canCancel(active)
  if not ok then
    return nil, late
  end
  apply({ type = "CANCEL", reason = reason })
  return true, late
end

local MANUAL = {}

local function result(ok)
  if ok then
    return true
  end
  return nil, "blocked"
end

function MANUAL.invite(r)
  if r.role ~= "taxi" or r.state ~= "MATCHED" then
    return nil, "state"
  end
  return result(inviteNow(true))
end

function MANUAL.accept(r)
  if r.role ~= "rider" or r.state ~= "MATCHED" then
    return nil, "state"
  end
  return result(acceptNow(true))
end

function MANUAL.trade(r)
  if not r.peerUnit or (r.state ~= "ARRIVED" and r.state ~= "TRADING") then
    return nil, "state"
  end
  local ok, err = pcall(InitiateTrade, r.peerUnit)
  if not ok then
    reportError(err)
    return nil, "error"
  end
  return true
end

function Ride.manual(what)
  local r = active
  if not r then
    return nil, "no_ride"
  end
  local fn = MANUAL[what]
  if not fn then
    return nil, "what"
  end
  return fn(r)
end

-- /ptx ride ------------------------------------------------------------------------------------

local function rideCommand(args)
  if args == "cancel" then
    local ok, err = Ride.cancel("cancelled")
    ns.say(ok and "ride cancelled" or ("cannot cancel: " .. tostring(err)))
    return
  end
  local r = active
  if not r then
    ns.say("no active ride")
    return
  end
  ns.say(("ride %s · %s %s to %s · %s with %s · unit %s · since %ds"):format(r.reqId, r.role, r.svc, tostring(r.dest),
    r.state, r.peer.key, tostring(r.peerUnit), math.floor(ns.now() - r.since)))
end

ns.commands.ride = { fn = rideCommand, args = "[cancel]", help = "show the active ride, or cancel it" }
