-- Net: the hidden channel, a rate-limited send queue and incoming addon messages.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Net". Card D, wave 1.
--   Net.start()                  on READY: register the prefix, join the channel, hide it from chat windows
--   Net.broadcast(msg)           encode + queue to the channel (waits until the channel is joined)
--   Net.whisper(rawSender, msg)  encode + queue a whisper to the raw "First Surname" string (D5)
--   Net.stats                    { sent, received, dropped }
--   incoming messages            ns.fire("NET_MSG", msg, key, rawSender, via)
-- Protocol is looked up at call time (ns.Protocol.encode / decode), so load order does not matter.

-- luacheck: read globals NUM_CHAT_WINDOWS

local _, ns = ...
local C = ns.Const

local Net = {}
ns.Net = Net

local SEND_INTERVAL = 0.25 -- one message per tick: at most 4 per second
local JOIN_POLL = 1        -- seconds between GetChannelName checks while joining
local JOIN_TRIES = 30
local MAX_QUEUE = 50       -- safety cap while the channel is unavailable

Net.stats = { sent = 0, received = 0, dropped = 0 }
local stats = Net.stats

local started = false
local channelId = nil -- set once GetChannelName returns an id > 0
local poller = nil    -- join poll ticker while joining
local tries = 0       -- failed polls of the current join
local sender = nil    -- send ticker while the queue has work
local queue = {}      -- FIFO of { kind = "CHANNEL" | "WHISPER", target, text, type }

-- Channel ---------------------------------------------------------------------------

local function hideFromChat()
  local remove = ns.api("ChatFrame_RemoveChannel")
  if not remove then
    return
  end
  for i = 1, NUM_CHAT_WINDOWS or 0 do
    local frame = _G["ChatFrame" .. i]
    if frame then
      remove(frame, C.CHANNEL)
    end
  end
end

local ensureSender -- forward declaration: joining starts the queue

local function poll()
  local id = GetChannelName(C.CHANNEL)
  if id and id > 0 then
    channelId = id
    poller:Cancel()
    poller = nil
    hideFromChat()
    ensureSender()
    return
  end
  tries = tries + 1
  if tries >= JOIN_TRIES then
    poller:Cancel()
    poller = nil
    ns.say(("could not join the %s channel; the taxi network is offline."):format(C.CHANNEL))
  end
end

local function join()
  if poller then
    return
  end
  channelId = nil
  tries = 0
  JoinTemporaryChannel(C.CHANNEL)
  poller = C_Timer.NewTicker(JOIN_POLL, poll, JOIN_TRIES)
end

-- The id can change or vanish while playing (channels renumber), so it is re-read before each send.
local function channelReady()
  if not channelId then
    return false
  end
  local id = GetChannelName(C.CHANNEL)
  if id and id > 0 then
    channelId = id
    return true
  end
  join()
  return false
end

-- Send queue ---------------------------------------------------------------------------

local function stopSender()
  if sender then
    sender:Cancel()
    sender = nil
  end
end

-- First entry that can go now: whispers always, broadcasts once the channel is joined.
local function nextSendable()
  local ready
  for i, e in ipairs(queue) do
    if e.kind == "WHISPER" then
      return i
    end
    if ready == nil then
      ready = channelReady()
    end
    if ready then
      return i
    end
  end
end

local function transmit(e)
  local target = e.kind == "CHANNEL" and channelId or e.target
  local ok, err = pcall(C_ChatInfo.SendAddonMessage, C.PREFIX, e.text, e.kind, target)
  if ok then
    stats.sent = stats.sent + 1
  else
    stats.dropped = stats.dropped + 1
    local handler = geterrorhandler and geterrorhandler()
    if handler then
      handler(err)
    end
  end
end

local function tick()
  local i = nextSendable()
  if not i then
    stopSender() -- restarted by the next enqueue or by a successful join
    return
  end
  transmit(table.remove(queue, i))
end

function ensureSender()
  if not sender and #queue > 0 then
    sender = C_Timer.NewTicker(SEND_INTERVAL, tick)
  end
end

-- A queued, unsent HELLO broadcast is replaced in place by a newer one.
local function replaceHello(text)
  for _, e in ipairs(queue) do
    if e.kind == "CHANNEL" and e.type == "HELLO" then
      e.text = text
      return true
    end
  end
  return false
end

-- Protocol may be missing in a partial build; Net then drops everything instead of erroring.
local function protocol(fn)
  local P = ns.Protocol
  return P and type(P[fn]) == "function" and P[fn] or nil
end

local function enqueue(kind, target, msg)
  local encode = protocol("encode")
  if not encode then
    stats.dropped = stats.dropped + 1
    return nil, "protocol"
  end
  local text, err = encode(msg)
  if not text then
    stats.dropped = stats.dropped + 1
    return nil, err
  end
  if kind == "CHANNEL" and msg.type == "HELLO" and replaceHello(text) then
    return true
  end
  if #queue >= MAX_QUEUE then
    stats.dropped = stats.dropped + 1
    return nil, "queue_full"
  end
  queue[#queue + 1] = { kind = kind, target = target, text = text, type = msg.type }
  ensureSender()
  return true
end

-- Returns true when queued, or nil and an error: a Protocol.encode error, "queue_full", "target" or "protocol".
function Net.broadcast(msg)
  return enqueue("CHANNEL", nil, msg)
end

function Net.whisper(rawSender, msg)
  if type(rawSender) ~= "string" or rawSender == "" then
    stats.dropped = stats.dropped + 1
    return nil, "target"
  end
  return enqueue("WHISPER", rawSender, msg)
end

-- Incoming ---------------------------------------------------------------------------------

local function onAddonMessage(prefix, text, via, rawSender)
  if prefix ~= C.PREFIX or (via ~= "CHANNEL" and via ~= "WHISPER") then
    return
  end
  local key = ns.playerKey(rawSender)
  if key ~= nil and ns.sameName(key, ns.selfKey()) then
    return -- own channel echo (D5)
  end
  -- Undecodable text, including phase 0 PING/PONG on the same prefix, is dropped quietly.
  local decode = protocol("decode")
  local msg = key and decode and decode(text)
  if not msg then
    stats.dropped = stats.dropped + 1
    return
  end
  stats.received = stats.received + 1
  ns.fire("NET_MSG", msg, key, rawSender, via)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, _, ...)
  onAddonMessage(...)
end)

-- Lifecycle -----------------------------------------------------------------------------------

function Net.start()
  if started then
    return
  end
  started = true
  C_ChatInfo.RegisterAddonMessagePrefix(C.PREFIX)
  events:RegisterEvent("CHAT_MSG_ADDON")
  join()
end

ns.on("READY", Net.start)

-- Joins again after Net gave up (e.g. when the taxi goes on duty); no-op while joined or joining.
function Net.rejoin()
  if started and not channelId and not poller then
    join()
  end
end

function Net.joined()
  return channelId ~= nil
end

-- /ptx netstat ----------------------------------------------------------------------------------

local function netstat()
  ns.say(("net: joined %s · channel %s · queue %d · sent %d · received %d · dropped %d"):format(
    channelId and "yes" or "no", tostring(channelId or 0), #queue, stats.sent, stats.received, stats.dropped))
end

ns.commands.netstat = { fn = netstat, help = "show network state" }
