-- Core/Protocol.lua: encode/decode of every message type, validation, error codes, robustness.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local wow = Wow.new():load()
local P = wow.ns.Protocol

-- One valid message per type.
local SAMPLES = {
  HELLO = {
    type = "HELLO", fac = "Horde", cls = "MAGE", lvl = 40, place = "Orgrimmar",
    dests = { "OG", "UC" }, ask = { COME = 30000, PICK = 15000 }, resp = 12, wait = 300,
  },
  BYE = { type = "BYE" },
  HAIL = {
    type = "HAIL", reqId = "Thalindra:3", fac = "Horde", dest = "UC", svcs = { "COME", "PICK" },
    max = 30000, rest = true,
  },
  BOOK = { type = "BOOK", reqId = "Thalindra:4", dest = "TB", svc = "PICK", price = 15000 },
  TAKE = { type = "TAKE", reqId = "Thalindra:4", svc = "COME", price = 30000, eta = 0, wait = 620 },
  CONFIRM = { type = "CONFIRM", reqId = "Thalindra:4", svc = "COME", price = 30000 },
  GONE = { type = "GONE", reqId = "Thalindra:4" },
  STATE = { type = "STATE", reqId = "Thalindra:4", state = "PORTAL_OPEN" },
  CANCEL = { type = "CANCEL", reqId = "Thalindra:4", by = "taxi", late = false },
  SPOT = { type = "SPOT", inst = 1, n = -1275, w = 4350, busy = false },
}
local TYPES = { "HELLO", "BYE", "HAIL", "BOOK", "TAKE", "CONFIRM", "GONE", "STATE", "CANCEL", "SPOT" }

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = type(v) == "table" and copy(v) or v
  end
  return out
end

local NIL = {} -- marks a field to remove in with()

-- Sample of a type with some fields replaced (NIL removes a field).
local function with(msgType, changes)
  local msg = copy(SAMPLES[msgType])
  for k, v in pairs(changes) do
    if v == NIL then
      msg[k] = nil
    else
      msg[k] = v
    end
  end
  return msg
end

local function encodeErr(msg)
  local s, err = P.encode(msg)
  T.eq(s, nil, "encode should fail")
  return err
end

local function decodeErr(s)
  local msg, err = P.decode(s)
  T.eq(msg, nil, "decode of " .. tostring(s) .. " should fail")
  return err
end

local function roundTrip(msg)
  local s, err = P.encode(msg)
  T.ok(s, "encode " .. tostring(msg.type) .. ": " .. tostring(err))
  local back, derr = P.decode(s)
  T.ok(back, "decode " .. s .. ": " .. tostring(derr))
  T.eq(back, msg)
  return s
end

-- Round trips ------------------------------------------------------------------------

T.test("every message type survives encode -> decode unchanged", function()
  for _, msgType in ipairs(TYPES) do
    roundTrip(SAMPLES[msgType])
  end
end)

T.test("FIELDS lists every type in wire order", function()
  T.eq(P.FIELDS.HELLO, { "fac", "cls", "lvl", "place", "dests", "ask", "resp", "wait" })
  T.eq(P.FIELDS.BYE, {})
  T.eq(P.FIELDS.HAIL, { "reqId", "fac", "dest", "svcs", "max", "rest" })
  T.eq(P.FIELDS.BOOK, { "reqId", "dest", "svc", "price" })
  T.eq(P.FIELDS.TAKE, { "reqId", "svc", "price", "eta", "wait" })
  T.eq(P.FIELDS.CONFIRM, { "reqId", "svc", "price" })
  T.eq(P.FIELDS.GONE, { "reqId" })
  T.eq(P.FIELDS.STATE, { "reqId", "state" })
  T.eq(P.FIELDS.CANCEL, { "reqId", "by", "late" })
  T.eq(P.FIELDS.SPOT, { "inst", "n", "w", "busy" })
  T.eq(P.FIELDS.VER, { "ver" })
  local n = 0
  for _ in pairs(P.FIELDS) do
    n = n + 1
  end
  T.eq(n, #TYPES + 1, "the TYPES above and VER")
end)

-- VER (D17) has no protocol version on the wire, so it must stay readable whatever PROTO becomes.
T.test("VER round trips without a protocol version", function()
  T.eq(P.encode({ type = "VER", ver = "0.2.0" }), "VER|0.2.0")
  T.eq(P.decode("VER|0.2.0"), { type = "VER", ver = "0.2.0" })
  T.eq(P.decode("VER|1.10.3-dev"), { type = "VER", ver = "1.10.3-dev" })
  T.eq(P.decode("VER|0.3.0-beta.2"), { type = "VER", ver = "0.3.0-beta.2" })
end)

T.test("VER rejects anything that is not a version", function()
  for _, bad in ipairs({ "", "1", "1.2", "1.2.x", "v1.2.3", "1.2.3-", "1.2.3 ", "1.2.3-a,b", "1.2.3-" .. ("x"):rep(30) }) do
    T.eq(select(2, P.decode("VER|" .. bad)), "field", bad)
    T.eq(select(2, P.encode({ type = "VER", ver = bad })), "field", bad)
  end
  T.eq(select(2, P.encode({ type = "VER" })), "field")
  T.eq(select(2, P.encode({ type = "VER", ver = 1 })), "field")
  T.eq(select(2, P.decode("VER|1.2.3|x")), "format")
end)

T.test("empty lists, empty maps and empty free strings round trip", function()
  T.eq(roundTrip(with("HELLO", { dests = {}, ask = {}, place = "" })), "HELLO|1|Horde|MAGE|40||||12|300")
  roundTrip(with("HAIL", { svcs = {} }))
  roundTrip(with("STATE", { state = "" }))
  T.eq(roundTrip(with("HELLO", { ask = { PICK = 15000 } })), "HELLO|1|Horde|MAGE|40|Orgrimmar|OG,UC|PICK:15000|12|300")
end)

T.test("BYE is just type and version", function()
  T.eq(P.encode({ type = "BYE" }), "BYE|1")
  T.eq(P.decode("BYE|1"), { type = "BYE" })
end)

T.test("bools, boundaries and every city key round trip", function()
  roundTrip(with("HAIL", { rest = false }))
  roundTrip(with("CANCEL", { by = "rider", late = true }))
  roundTrip(with("HELLO", { lvl = 1, dests = { "OG", "UC", "TB", "SW", "IF", "DN" } }))
  roundTrip(with("HELLO", { lvl = 100, resp = 0, wait = 0 }))
  roundTrip(with("BOOK", { price = 1000 }))
  roundTrip(with("BOOK", { price = 500000 }))
  roundTrip(with("TAKE", { eta = 2147483647 }))
end)

-- Exact wire strings -----------------------------------------------------------------

T.test("HELLO wire string follows the field order, map keys in COME, PICK order", function()
  T.eq(P.encode(SAMPLES.HELLO), "HELLO|1|Horde|MAGE|40|Orgrimmar|OG,UC|COME:30000,PICK:15000|12|300")
end)

T.test("HAIL wire string follows the field order, list order is kept", function()
  T.eq(P.encode(SAMPLES.HAIL), "HAIL|1|Thalindra:3|Horde|UC|COME,PICK|30000|1")
  T.eq(P.encode(with("HAIL", { svcs = { "PICK" }, rest = false })), "HAIL|1|Thalindra:3|Horde|UC|PICK|30000|0")
end)

T.test("version on the wire is Const.PROTO", function()
  T.eq(wow.ns.Const.PROTO, 1)
  T.ok(P.encode(SAMPLES.GONE):find("^GONE|1|"))
end)

-- Decode errors ----------------------------------------------------------------------

T.test("decode: wrong or missing version -> version", function()
  T.eq(decodeErr("HELLO|2|Horde|MAGE|40|Orgrimmar|OG|PICK:15000|12|300"), "version")
  T.eq(decodeErr("GONE|x|Thalindra:4"), "version")
  T.eq(decodeErr("GONE||Thalindra:4"), "version")
  T.eq(decodeErr("BYE|01"), "version")
end)

-- D19: the map position is a message of its own. A HELLO with one more field would be "format" for 0.1.0,
-- which counts fields exactly; an unknown type is dropped quietly and everything else keeps working.
T.test("SPOT: wire form, off-the-map marker, ranges", function()
  T.eq(P.encode({ type = "SPOT", inst = 0, n = 150, w = -75, busy = true }), "SPOT|1|0|150|-75|1")
  T.eq(P.decode("SPOT|1|-1|0|0|0"), { type = "SPOT", inst = -1, n = 0, w = 0, busy = false })
  T.eq(decodeErr("SPOT|1|-2|0|0|0"), "range")
  T.eq(decodeErr("SPOT|1|1|1000001|0|0"), "range")
  T.eq(decodeErr("SPOT|1|1|0|1.5|0"), "field")
  T.eq(decodeErr("SPOT|1|1|0|0"), "format")
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG|PICK:15000|12|300|1"), "format",
    "why SPOT is not a HELLO field")
end)

T.test("decode: unknown type -> type", function()
  T.eq(decodeErr("PING|1|x|Horde"), "type")
  T.eq(decodeErr("hello|1|Horde|MAGE|40|Orgrimmar|OG|PICK:15000|12|300"), "type")
  T.eq(decodeErr("|1"), "type")
end)

T.test("decode: not a message at all -> format", function()
  T.eq(decodeErr(nil), "format")
  T.eq(decodeErr(""), "format")
  T.eq(decodeErr("BYE"), "format")
  T.eq(decodeErr(42), "format")
  T.eq(decodeErr({}), "format")
  T.eq(decodeErr("GONE|1|" .. ("x"):rep(250)), "format") -- over 255 bytes
end)

T.test("decode: wrong field count -> format", function()
  T.eq(decodeErr("BYE|1|"), "format")
  T.eq(decodeErr("GONE|1"), "format")
  T.eq(decodeErr("GONE|1|a|b"), "format")
  T.eq(decodeErr("BOOK|1|Thalindra:4|TB|PICK"), "format")
  T.eq(decodeErr("HAIL|1|Thalindra:3|Horde|UC|COME,PICK|30000|1|"), "format")
end)

T.test("decode: malformed field values -> field", function()
  T.eq(decodeErr("GONE|1|"), "field") -- empty reqId
  T.eq(decodeErr("HELLO|1|Horde|MAGE|forty|Orgrimmar|OG|PICK:15000|12|300"), "field")
  T.eq(decodeErr("HELLO|1|Horde|MAGE|4e1|Orgrimmar|OG|PICK:15000|12|300"), "field")
  T.eq(decodeErr("HELLO|1|Horde|MAGE||Orgrimmar|OG|PICK:15000|12|300"), "field")
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG|PICK|12|300"), "field") -- map entry without ':'
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG|PICK:1000,PICK:2000|12|300"), "field") -- duplicate key
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Org,rimmar|OG|PICK:15000|12|300"), "field") -- ',' in a free string
  T.eq(decodeErr("HAIL|1|Thalindra:3|Horde|UC|COME|30000|yes"), "field")
  T.eq(decodeErr("HAIL|1|Thalindra:3|Horde|UC|COME|30000|2"), "field")
  T.eq(decodeErr("TAKE|1|Thalindra:4|COME|30000|1.5|0"), "field")
  T.eq(decodeErr("TAKE|1|Thalindra:4|COME|30000| 5|0"), "field")
end)

T.test("decode: values out of range -> range", function()
  T.eq(decodeErr("BOOK|1|Thalindra:4|XX|PICK|15000"), "range") -- city key
  T.eq(decodeErr("BOOK|1|Thalindra:4|og|PICK|15000"), "range")
  T.eq(decodeErr("BOOK|1|Thalindra:4|TB|SUMMON|15000"), "range") -- svc
  T.eq(decodeErr("BOOK|1|Thalindra:4|TB|PICK|999"), "range") -- price below PRICE.MIN
  T.eq(decodeErr("BOOK|1|Thalindra:4|TB|PICK|500001"), "range") -- price above PRICE.MAX
  T.eq(decodeErr("TAKE|1|Thalindra:4|COME|30000|-5|0"), "range") -- negative eta
  T.eq(decodeErr("TAKE|1|Thalindra:4|COME|30000|0|-1"), "range") -- negative wait
  T.eq(decodeErr("TAKE|1|Thalindra:4|COME|30000|99999999999999999999|0"), "range")
  T.eq(decodeErr("HELLO|1|Horde|MAGE|0|Orgrimmar|OG|PICK:15000|12|300"), "range") -- lvl
  T.eq(decodeErr("HELLO|1|Horde|MAGE|101|Orgrimmar|OG|PICK:15000|12|300"), "range")
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG,XX|PICK:15000|12|300"), "range") -- city in list
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG,|PICK:15000|12|300"), "range") -- empty list item
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG|SUMMON:15000|12|300"), "range") -- map key
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG|PICK:100|12|300"), "range") -- ask price
  T.eq(decodeErr("HELLO|1|Horde|MAGE|40|Orgrimmar|OG|PICK:15000|-1|300"), "range") -- resp
  T.eq(decodeErr("HAIL|1|Thalindra:3|Horde|UC|COME,LIFT|30000|1"), "range") -- svc in list
  T.eq(decodeErr("HAIL|1|Thalindra:3|Horde|UC|COME|600000|1"), "range") -- max
  T.eq(decodeErr("CANCEL|1|Thalindra:4|nobody|0"), "range") -- by
end)

T.test("decode reports the first bad field in wire order", function()
  T.eq(decodeErr("BOOK|1|Thalindra:4|XX|PICK|nope"), "range")
  T.eq(decodeErr("BOOK|1||XX|PICK|15000"), "field")
end)

-- Encode errors ----------------------------------------------------------------------

T.test("encode: unknown or missing type -> type", function()
  T.eq(encodeErr({ type = "PING" }), "type")
  T.eq(encodeErr({}), "type")
  T.eq(encodeErr(nil), "type")
  T.eq(encodeErr("BYE"), "type")
end)

T.test("encode: missing or mistyped field -> field", function()
  T.eq(encodeErr(with("HAIL", { max = NIL })), "field")
  T.eq(encodeErr(with("GONE", { reqId = NIL })), "field")
  T.eq(encodeErr(with("GONE", { reqId = "" })), "field")
  T.eq(encodeErr(with("GONE", { reqId = "|,|" })), "field") -- empty after stripping
  T.eq(encodeErr(with("HELLO", { lvl = "40" })), "field")
  T.eq(encodeErr(with("HELLO", { lvl = 40.5 })), "field")
  T.eq(encodeErr(with("HELLO", { fac = 1 })), "field")
  T.eq(encodeErr(with("HELLO", { dests = "OG" })), "field")
  T.eq(encodeErr(with("HELLO", { ask = 30000 })), "field")
  T.eq(encodeErr(with("HELLO", { ask = { [1] = 30000 } })), "field")
  T.eq(encodeErr(with("HAIL", { rest = 1 })), "field")
  T.eq(encodeErr(with("TAKE", { eta = 0 / 0 })), "field")
  T.eq(encodeErr(with("TAKE", { eta = math.huge })), "field")
end)

T.test("encode: values out of range -> range", function()
  T.eq(encodeErr(with("HELLO", { lvl = 0 })), "range")
  T.eq(encodeErr(with("HELLO", { lvl = 101 })), "range")
  T.eq(encodeErr(with("HELLO", { dests = { "OG", "XX" } })), "range")
  T.eq(encodeErr(with("HELLO", { ask = { COME = 30000, SUMMON = 15000 } })), "range")
  T.eq(encodeErr(with("HELLO", { ask = { COME = 999 } })), "range")
  T.eq(encodeErr(with("HELLO", { resp = -1 })), "range")
  T.eq(encodeErr(with("HAIL", { dest = "Orgrimmar" })), "range")
  T.eq(encodeErr(with("HAIL", { svcs = { "COME", "LIFT" } })), "range")
  T.eq(encodeErr(with("HAIL", { max = 500001 })), "range")
  T.eq(encodeErr(with("BOOK", { price = 999 })), "range")
  T.eq(encodeErr(with("BOOK", { svc = "SUMMON" })), "range")
  T.eq(encodeErr(with("TAKE", { eta = -1 })), "range")
  T.eq(encodeErr(with("TAKE", { wait = 2147483648 })), "range")
  T.eq(encodeErr(with("CANCEL", { by = "admin" })), "range")
end)

T.test("encode: over 255 bytes -> too_long, 255 exactly is fine", function()
  local head = #"STATE|1|Thalindra:4|"
  T.eq(encodeErr(with("STATE", { state = ("x"):rep(255 - head + 1) })), "too_long")
  local s = P.encode(with("STATE", { state = ("x"):rep(255 - head) }))
  T.eq(#s, 255)
  T.ok(P.decode(s), "a 255 byte message decodes")
end)

T.test("encode strips '|' and ',' from free strings, other fields are untouched", function()
  local s = P.encode(with("HELLO", { fac = "Ho|rde", cls = "MA,GE", place = "Valley, of |Strength" }))
  T.eq(s, "HELLO|1|Horde|MAGE|40|Valley of Strength|OG,UC|COME:30000,PICK:15000|12|300")
  T.eq(P.encode(with("STATE", { reqId = "Tha|lin,dra:4", state = "a|b,c" })), "STATE|1|Thalindra:4|abc")
  T.eq(P.encode(with("HAIL", { fac = "|Horde," })), P.encode(SAMPLES.HAIL))
  -- Control characters are dropped too (architect, wave 3).
  T.eq(P.encode(with("STATE", { reqId = "Thalindra:4", state = "PA\0I\nD" })), "STATE|1|Thalindra:4|PAID")
end)

T.test("encode ignores unknown keys and does not change the message", function()
  local msg = with("BOOK", { extra = "x", v = 2 })
  local before = copy(msg)
  T.eq(P.encode(msg), "BOOK|1|Thalindra:4|TB|PICK|15000")
  T.eq(msg, before)
end)

-- Robustness -------------------------------------------------------------------------

-- Deterministic LCG, so the fuzz cases are the same on every run.
local function rng(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
end

local ALPHABET = { "|", "|", "|", ",", ",", ":", "1", "0", "-", "OG", "COME", "PICK", "HELLO", "HAIL",
  "TAKE", "BYE", "rider", "15000", "x", " ", "\0", "\255", "\n" }

local function randomString(rand)
  local parts = {}
  for i = 1, rand(40) - 1 do
    if rand(4) == 1 then
      parts[i] = string.char(rand(256) - 1)
    else
      parts[i] = ALPHABET[rand(#ALPHABET)]
    end
  end
  return table.concat(parts)
end

-- A valid message with one character replaced, inserted or deleted.
local function mutated(rand)
  local s = P.encode(SAMPLES[TYPES[rand(#TYPES)]])
  local at = rand(#s)
  local c = rand(3) == 1 and ALPHABET[rand(#ALPHABET)] or string.char(rand(256) - 1)
  local op = rand(3)
  if op == 1 then
    return s:sub(1, at - 1) .. c .. s:sub(at + 1)
  elseif op == 2 then
    return s:sub(1, at - 1) .. c .. s:sub(at)
  end
  return s:sub(1, at - 1) .. s:sub(at + 1)
end

local ERRORS = { format = true, version = true, type = true, field = true, range = true }

-- decode must not raise; a success must be a stable message that re-encodes to itself.
local function checkDecode(s)
  local ok, msg, err = pcall(P.decode, s)
  T.ok(ok, "decode raised on " .. ("%q"):format(tostring(s)) .. ": " .. tostring(msg))
  if msg == nil then
    T.ok(ERRORS[err], "unknown error code " .. tostring(err))
    return false
  end
  local again = P.encode(msg)
  T.ok(again, "a decoded message re-encodes")
  T.eq(P.decode(again), msg)
  return true
end

T.test("decode never raises on pseudo-random strings", function()
  local rand = rng(20261118)
  for _ = 1, 500 do
    checkDecode(randomString(rand))
  end
end)

T.test("decode never raises on mutated valid messages", function()
  local rand = rng(4242)
  local decoded = 0
  for _ = 1, 500 do
    if checkDecode(mutated(rand)) then
      decoded = decoded + 1
    end
  end
  T.ok(decoded > 0, "some mutations are still valid messages")
end)

T.test("decode never raises on odd inputs", function()
  for _, s in ipairs({ "", "|", "||", "|||||||||", ",", ":", "\0", "BYE|1\0", ("|"):rep(255), ("|"):rep(10000),
    ("9"):rep(255), "HELLO|1|||||||", "HELLO|1|a|b|c|d|e|f|g|h", "HAIL|1|a|b|c|d|e|f" }) do
    checkDecode(s)
  end
  for _, v in ipairs({ 0, true, {}, print }) do
    checkDecode(v)
  end
  checkDecode(nil)
end)

-- Purity -----------------------------------------------------------------------------

-- Environment with only the Lua standard library; any other global read raises.
local function strictEnv()
  local env = {}
  for _, name in ipairs({ "ipairs", "pairs", "next", "type", "tostring", "tonumber", "select", "error",
    "string", "table", "math" }) do
    env[name] = _G[name]
  end
  return setmetatable(env, {
    __index = function(_, key)
      error("global read: " .. tostring(key), 2)
    end,
    __newindex = function(_, key)
      error("global write: " .. tostring(key), 2)
    end,
  })
end

local function loadInto(file, ns)
  local chunk = assert(loadfile("Portaxi/Core/" .. file))
  setfenv(chunk, strictEnv())
  chunk("Portaxi", ns)
end

T.test("Protocol.lua runs with ns.Const and the Lua standard library only (no game API)", function()
  local ns = {}
  loadInto("Const.lua", ns)
  local bare = { Const = ns.Const }
  loadInto("Protocol.lua", bare)
  local P2 = bare.Protocol
  for _, msgType in ipairs(TYPES) do
    local s = assert(P2.encode(SAMPLES[msgType]))
    T.eq(P2.decode(s), SAMPLES[msgType])
  end
  T.eq(select(2, P2.decode("PING|1|x|Horde")), "type")
  T.eq(select(2, P2.encode(with("BOOK", { price = 1 }))), "range")
  T.eq(select(2, P2.decode(nil)), "format")
end)

T.done()
