-- Net (Core/Net.lua): channel join, send queue, incoming messages.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local KNOWN = { HELLO = true, BYE = true, HAIL = true, BOOK = true, TAKE = true,
  CONFIRM = true, GONE = true, STATE = true, CANCEL = true }

-- Fake Protocol following the §2 contract: "TYPE|1|x"; unknown types fail with "type".
local function fakeProtocol(wow)
  wow.ns.Protocol.encode = function(msg)
    if not KNOWN[msg.type] then return nil, "type" end
    return msg.type .. "|1|" .. (msg.x or "")
  end
  wow.ns.Protocol.decode = function(text)
    local kind, ver, x = text:match("^([^|]+)|([^|]+)|(.*)$")
    if not kind then return nil, "format" end
    if ver ~= "1" then return nil, "version" end
    if not KNOWN[kind] then return nil, "type" end
    return { type = kind, x = x }
  end
end

-- A loaded client with the fake Protocol; joined = true advances past the first channel poll.
local function client(joined)
  local wow = Wow.new():load()
  fakeProtocol(wow)
  if joined then wow:advance(1) end
  return wow
end

local function texts(wow)
  local out = {}
  for _, e in ipairs(wow.sent) do out[#out + 1] = e.msg end
  return out
end

local function collect(wow)
  local got = {}
  wow.ns.on("NET_MSG", function(...) got[#got + 1] = { ... } end)
  return got
end

T.test("READY registers the prefix and joins the channel", function()
  local wow = Wow.new():load({ noLogin = true })
  wow:fire("ADDON_LOADED", "Portaxi")
  T.ok(not wow.prefixes.PTX, "nothing before READY")
  wow.ns.fire("READY")
  T.ok(wow.prefixes.PTX)
  T.eq(wow:callsTo("JoinTemporaryChannel")[1].args, { "PortaxiNet" })
end)

T.test("start polls for the channel id, then removes the channel from ChatFrame1", function()
  local wow = Wow.new():load({ noLogin = true })
  wow:fire("ADDON_LOADED", "Portaxi")
  local real, polls = wow.env.GetChannelName, 0
  wow.env.GetChannelName = function(name)
    polls = polls + 1
    if polls < 3 then return 0, nil end
    return real(name)
  end
  wow:fire("PLAYER_LOGIN")
  wow:advance(2)
  T.eq(#wow:callsTo("ChatFrame_RemoveChannel"), 0, "not joined after two polls")
  wow:slash("netstat")
  T.ok(wow.printed[#wow.printed]:find("joined no", 1, true))
  wow:advance(1)
  T.eq(wow:callsTo("ChatFrame_RemoveChannel")[1].args, { wow.env.ChatFrame1, "PortaxiNet" })
  T.eq(#wow:callsTo("JoinTemporaryChannel"), 1, "joined once")
end)

T.test("giving up after 30 polls says so once", function()
  local wow = Wow.new():load({ noLogin = true })
  wow:fire("ADDON_LOADED", "Portaxi")
  wow.env.GetChannelName = function() return 0, nil end
  wow:fire("PLAYER_LOGIN")
  wow:advance(60)
  local warnings = 0
  for _, line in ipairs(wow.printed) do
    if line:find("could not join", 1, true) then warnings = warnings + 1 end
  end
  T.eq(warnings, 1)
  T.eq(#wow:callsTo("ChatFrame_RemoveChannel"), 0)
end)

T.test("broadcasts queued before the join go out after it, in order", function()
  local wow = client(false)
  wow.ns.Net.broadcast({ type = "HAIL", x = "a" })
  wow.ns.Net.broadcast({ type = "GONE", x = "b" })
  wow.ns.Net.broadcast({ type = "BYE" })
  wow:advance(0.9)
  T.eq(#wow.sent, 0, "nothing before the join")
  wow:advance(1.6)
  T.eq(texts(wow), { "HAIL|1|a", "GONE|1|b", "BYE|1|" })
  T.eq(wow.sent[1].kind, "CHANNEL")
  T.eq(wow.sent[1].target, 6)
  T.eq(wow.ns.Net.stats.sent, 3)
end)

T.test("a whisper is not held back by broadcasts waiting for the channel", function()
  local wow = client(false)
  wow.ns.Net.broadcast({ type = "HAIL", x = "a" })
  wow.ns.Net.whisper("Velvet Forever", { type = "TAKE", x = "1" })
  wow:advance(0.5)
  T.eq(texts(wow), { "TAKE|1|1" })
end)

T.test("rate limit: 10 broadcasts, 4 sent after 1 s, all after 2.5 s", function()
  local wow = client(true)
  for i = 1, 10 do wow.ns.Net.broadcast({ type = "HAIL", x = tostring(i) }) end
  wow:advance(1)
  T.eq(#wow.sent, 4)
  wow:advance(1.4)
  T.eq(#wow.sent, 9)
  wow:advance(0.1)
  T.eq(#wow.sent, 10)
  T.eq(wow.sent[10].msg, "HAIL|1|10", "FIFO")
end)

T.test("a queued HELLO is replaced in place by a newer one; other types are not", function()
  local wow = client(true)
  local Net = wow.ns.Net
  Net.broadcast({ type = "HELLO", x = "a" })
  Net.broadcast({ type = "HAIL", x = "1" })
  Net.broadcast({ type = "HELLO", x = "b" })
  Net.broadcast({ type = "HAIL", x = "2" })
  wow:advance(2)
  T.eq(texts(wow), { "HELLO|1|b", "HAIL|1|1", "HAIL|1|2" })
  Net.broadcast({ type = "HELLO", x = "c" })
  wow:advance(1)
  T.eq(wow.sent[4].msg, "HELLO|1|c", "a HELLO already sent is not replaced")
end)

T.test("whisper goes to the raw Name Realm target", function()
  local wow = client(true)
  T.ok(wow.ns.Net.whisper("Velvet Forever", { type = "TAKE", x = "r1" }))
  wow:advance(0.25)
  T.eq(wow.sent[1], { prefix = "PTX", msg = "TAKE|1|r1", kind = "WHISPER", target = "Velvet Forever" })
end)

T.test("own channel echo is dropped without counting", function()
  local wow = client(true)
  local got = collect(wow)
  wow.ns.Net.broadcast({ type = "HELLO", x = "me" })
  wow:advance(1)
  T.eq(#wow.sent, 1)
  T.eq(#got, 0)
  T.eq(wow.ns.Net.stats, { sent = 1, received = 0, dropped = 0 })
end)

T.test("a foreign message fires NET_MSG via CHANNEL and via WHISPER", function()
  local wow = client(true)
  local got = collect(wow)
  wow:receive("PTX", "HELLO|1|abc", "CHANNEL", "Velvet Forever")
  wow:receive("PTX", "TAKE|1|r1", "WHISPER", "Velvet Forever")
  T.eq(got[1], { { type = "HELLO", x = "abc" }, "Velvet Forever", "Velvet Forever", "CHANNEL" })
  T.eq(got[2], { { type = "TAKE", x = "r1" }, "Velvet Forever", "Velvet Forever", "WHISPER" })
  T.eq(wow.ns.Net.stats.received, 2)
end)

-- Forever: only first name + surname is unique (no realms). A player with my first name and another surname
-- is someone else, not my own echo (architect, after /ptx diag 2026-11-18).
T.test("same first name, other surname: not dropped as own echo, keyed by the full name", function()
  local wow = client(true)
  local got = collect(wow)
  wow:receive("PTX", "HELLO|1|me", "CHANNEL", "Thalindra Forever")
  wow:receive("PTX", "HELLO|1|twin", "CHANNEL", "Thalindra Stonefel")
  T.eq(#got, 1, "only the other Thalindra")
  T.eq(got[1][2], "Thalindra Stonefel")
end)

T.test("undecodable text is dropped and counted; other prefixes and chat kinds are ignored", function()
  local wow = client(true)
  local got = collect(wow)
  wow:receive("PTX", "PING|1|Velvet|Horde", "CHANNEL", "Velvet Forever")
  wow:receive("PTX", "garbage", "WHISPER", "Velvet Forever")
  wow:fire("CHAT_MSG_ADDON", "OTHER", "HELLO|1|abc", "CHANNEL", "Velvet Forever")
  wow:fire("CHAT_MSG_ADDON", "PTX", "HELLO|1|abc", "PARTY", "Velvet Forever")
  T.eq(#got, 0)
  T.eq(wow.ns.Net.stats, { sent = 0, received = 0, dropped = 2 })
end)

T.test("encode failure is counted and nothing is sent", function()
  local wow = client(true)
  local ok, err = wow.ns.Net.broadcast({ type = "BAD" })
  T.eq(ok, nil)
  T.eq(err, "type")
  wow.ns.Net.whisper("Velvet Forever", { type = "BAD" })
  wow:advance(2)
  T.eq(#wow.sent, 0)
  T.eq(wow.ns.Net.stats.dropped, 2)
end)

T.test("without Protocol functions everything is dropped, nothing errors", function()
  local wow = Wow.new():load()
  wow.ns.Protocol.encode, wow.ns.Protocol.decode = nil, nil -- a partial build without Protocol
  wow:advance(1)
  T.eq({ wow.ns.Net.broadcast({ type = "HELLO" }) }, { nil, "protocol" })
  wow:receive("PTX", "HELLO|1|abc", "CHANNEL", "Velvet Forever")
  wow:advance(1)
  T.eq(#wow.sent, 0)
  T.eq(wow.ns.Net.stats, { sent = 0, received = 0, dropped = 2 })
end)

T.test("rejoin starts a new join after Net gave up, and is a no-op while joined", function()
  local wow = Wow.new()
  local real = wow.env.GetChannelName
  local available = false
  wow.env.GetChannelName = function(name)
    if not available then return 0, nil end
    return real(name)
  end
  wow:load()
  fakeProtocol(wow)
  wow:advance(31)
  T.ok(not wow.ns.Net.joined(), "gave up")
  local joins = #wow:callsTo("JoinTemporaryChannel")
  available = true
  wow.ns.Net.rejoin()
  T.eq(#wow:callsTo("JoinTemporaryChannel"), joins + 1)
  wow:advance(1)
  T.ok(wow.ns.Net.joined())
  wow.ns.Net.rejoin()
  T.eq(#wow:callsTo("JoinTemporaryChannel"), joins + 1, "no second join while joined")
end)

T.test("a lost channel id is re-joined and the broadcast waits for it", function()
  local wow = client(true)
  wow.channels.PortaxiNet = nil -- the client left the channel
  wow.ns.Net.broadcast({ type = "HAIL", x = "a" })
  wow:advance(0.25)
  T.eq(#wow.sent, 0)
  T.eq(#wow:callsTo("JoinTemporaryChannel"), 2)
  wow:advance(1.5)
  T.eq(texts(wow), { "HAIL|1|a" })
  T.eq(wow.sent[1].target, 7, "new channel id")
end)

T.test("/ptx netstat prints the network state", function()
  local wow = client(true)
  wow:receive("PTX", "HELLO|1|abc", "CHANNEL", "Velvet Forever")
  wow.ns.Net.broadcast({ type = "HAIL", x = "a" })
  wow:slash("netstat")
  local line = wow.printed[#wow.printed]
  T.ok(line:find("joined yes · channel 6 · queue 1 · sent 0 · received 1 · dropped 0", 1, true), line)
end)

T.done()
