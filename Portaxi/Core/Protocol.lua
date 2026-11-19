-- Protocol: encodes and decodes Portaxi chat messages. Pure module: no game API (playbook D3).
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Protocol". Card A, wave 1.
--
-- Wire format: "TYPE|<PROTO>|f1|f2|..." with the fields in Protocol.FIELDS[type] order, max 255 bytes.
--   list "a,b"   map "COME:30000,PICK:15000"   bool "1"/"0"   int in decimal
--   Protocol.encode(msg) -> str | nil, err   err: "type" | "field" | "range" | "too_long"
--   Protocol.decode(str) -> msg | nil, err   err: "format" | "version" | "type" | "field" | "range"
-- A message is a table { type = "HAIL", reqId = ..., ... }. decode never raises, whatever the input.

local _, ns = ...

local Const = ns.Const
local Protocol = {}
ns.Protocol = Protocol

local MAX_LEN = 255
local VERSION = tostring(Const.PROTO)
local INT_MAX = 2147483647 -- sanity cap for ints without a contract maximum (eta, wait, resp)
local INT_DIGITS = 12      -- longer int tokens are out of range without parsing them

local SVC = { COME = true, PICK = true }
local SVC_ORDER = { "COME", "PICK" } -- map keys are written in this order
local BY = { rider = true, taxi = true }

-- Splits s on a one-character separator, keeping empty parts.
local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local i = s:find(sep, pos, true)
    if not i then
      out[#out + 1] = s:sub(pos)
      return out
    end
    out[#out + 1] = s:sub(pos, i - 1)
    pos = i + 1
  end
end

-- Field kinds ------------------------------------------------------------------------
-- Each kind has enc(value) -> wire | nil, err and dec(wire) -> value | nil, err.

-- Free string. encode strips "|", "," and control characters; decode rejects "," and control characters.
-- required = must not be empty.
local function strKind(required)
  return {
    enc = function(v)
      if type(v) ~= "string" then
        return nil, "field"
      end
      v = (v:gsub("[|,%c]", "")) -- separators and control characters (e.g. "\0", "\n") never go on the wire
      if required and v == "" then
        return nil, "field"
      end
      return v
    end,
    dec = function(s)
      if s:find("[,%c]") or (required and s == "") then
        return nil, "field"
      end
      return s
    end,
  }
end

local function isInt(v)
  return type(v) == "number" and v % 1 == 0 -- NaN and +-inf give NaN here
end

local function intKind(min, max)
  max = max or INT_MAX
  return {
    enc = function(v)
      if not isInt(v) then
        return nil, "field"
      end
      if v < min or v > max then
        return nil, "range"
      end
      return ("%.0f"):format(v)
    end,
    dec = function(s)
      if not s:find("^%-?%d+$") then
        return nil, "field"
      end
      if #s > INT_DIGITS then
        return nil, "range"
      end
      local v = tonumber(s)
      if v < min or v > max then
        return nil, "range"
      end
      return v
    end,
  }
end

-- One value out of a set (city keys, services, "rider"/"taxi").
local function enumKind(set)
  return {
    enc = function(v)
      if type(v) ~= "string" then
        return nil, "field"
      end
      if not set[v] then
        return nil, "range"
      end
      return v
    end,
    dec = function(s)
      if not set[s] then
        return nil, "range"
      end
      return s
    end,
  }
end

local boolKind = {
  enc = function(v)
    if type(v) ~= "boolean" then
      return nil, "field"
    end
    return v and "1" or "0"
  end,
  dec = function(s)
    if s == "1" then
      return true
    elseif s == "0" then
      return false
    end
    return nil, "field"
  end,
}

-- Array of items, "a,b"; the empty list is "".
local function listKind(item)
  return {
    enc = function(v)
      if type(v) ~= "table" then
        return nil, "field"
      end
      local out = {}
      for i = 1, #v do
        local s, err = item.enc(v[i])
        if err then
          return nil, err
        end
        out[i] = s
      end
      return table.concat(out, ",")
    end,
    dec = function(s)
      local out = {}
      if s == "" then
        return out
      end
      for _, part in ipairs(split(s, ",")) do
        local v, err = item.dec(part)
        if err then
          return nil, err
        end
        out[#out + 1] = v
      end
      return out
    end,
  }
end

-- Map key -> value, "k:v,k:v" with keys in keyOrder; the empty map is "".
local function mapKind(key, value, keyOrder)
  return {
    enc = function(v)
      if type(v) ~= "table" then
        return nil, "field"
      end
      for k in pairs(v) do
        local _, err = key.enc(k)
        if err then
          return nil, err
        end
      end
      local out = {}
      for _, k in ipairs(keyOrder) do
        if v[k] ~= nil then
          local s, err = value.enc(v[k])
          if err then
            return nil, err
          end
          out[#out + 1] = k .. ":" .. s
        end
      end
      return table.concat(out, ",")
    end,
    dec = function(s)
      local out = {}
      if s == "" then
        return out
      end
      for _, part in ipairs(split(s, ",")) do
        local ks, vs = part:match("^([^:]*):(.*)$")
        if not ks then
          return nil, "field"
        end
        local k, kerr = key.dec(ks)
        if kerr then
          return nil, kerr
        end
        if out[k] ~= nil then
          return nil, "field" -- duplicate key
        end
        local v, verr = value.dec(vs)
        if verr then
          return nil, verr
        end
        out[k] = v
      end
      return out
    end,
  }
end

-- Message specs ----------------------------------------------------------------------

local str = strKind(false)
local reqId = strKind(true)
local city = enumKind(Const.CITY)
local svc = enumKind(SVC)
local price = intKind(Const.PRICE.MIN, Const.PRICE.MAX)
local secs = intKind(0)

local SPEC = {
  HELLO = {
    { "fac", str }, { "cls", str }, { "lvl", intKind(1, 100) }, { "place", str },
    { "dests", listKind(city) }, { "ask", mapKind(svc, price, SVC_ORDER) }, { "resp", secs }, { "wait", secs },
  },
  BYE = {},
  HAIL = {
    { "reqId", reqId }, { "fac", str }, { "dest", city }, { "svcs", listKind(svc) }, { "max", price },
    { "rest", boolKind },
  },
  BOOK = { { "reqId", reqId }, { "dest", city }, { "svc", svc }, { "price", price } },
  TAKE = { { "reqId", reqId }, { "svc", svc }, { "price", price }, { "eta", secs }, { "wait", secs } },
  CONFIRM = { { "reqId", reqId }, { "svc", svc }, { "price", price } },
  GONE = { { "reqId", reqId } },
  STATE = { { "reqId", reqId }, { "state", str } },
  CANCEL = { { "reqId", reqId }, { "by", enumKind(BY) }, { "late", boolKind } },
}

Protocol.FIELDS = {}
for msgType, spec in pairs(SPEC) do
  local names = {}
  for i, field in ipairs(spec) do
    names[i] = field[1]
  end
  Protocol.FIELDS[msgType] = names
end

-- API --------------------------------------------------------------------------------

function Protocol.encode(msg)
  local spec = type(msg) == "table" and SPEC[msg.type]
  if not spec then
    return nil, "type"
  end
  local parts = { msg.type, VERSION }
  for i, field in ipairs(spec) do
    local v = msg[field[1]]
    if v == nil then
      return nil, "field"
    end
    local s, err = field[2].enc(v)
    if err then
      return nil, err
    end
    parts[i + 2] = s
  end
  local out = table.concat(parts, "|")
  if #out > MAX_LEN then
    return nil, "too_long"
  end
  return out
end

function Protocol.decode(s)
  if type(s) ~= "string" or #s > MAX_LEN then
    return nil, "format"
  end
  local parts = split(s, "|")
  if #parts < 2 then
    return nil, "format"
  end
  if parts[2] ~= VERSION then
    return nil, "version"
  end
  local spec = SPEC[parts[1]]
  if not spec then
    return nil, "type"
  end
  if #parts ~= #spec + 2 then
    return nil, "format"
  end
  local msg = { type = parts[1] }
  for i, field in ipairs(spec) do
    local v, err = field[2].dec(parts[i + 2])
    if err then
      return nil, err
    end
    msg[field[1]] = v
  end
  return msg
end
