-- Locales (card J, wave 3): Locales/enUS.lua lists every localisation key the code uses, each mapped to the
-- same English text, and nothing else. Scans every .lua file of the TOC for L["..."] / ns.L["..."] with a
-- string literal. Keys reached indirectly (L[city.name], L[ERRORS[code]]) count as used when the text appears
-- as a string literal anywhere in the code.
local T = dofile("tests/lib/t.lua")

local ADDON = "Portaxi"
local LOCALE = "Locales/enUS.lua"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

-- Every file listed in the TOC (check.ps1 makes sure the TOC lists every .lua file of the addon).
local function tocFiles()
  local out = {}
  for line in read(ADDON .. "/Portaxi.toc"):gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not line:find("^#") then
      out[#out + 1] = line:gsub("\\", "/")
    end
  end
  return out
end

-- The double-quoted string literal starting at i (the opening quote): its value and the index after it.
local function stringAt(src, i)
  local j = i + 1
  while j <= #src do
    local c = src:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == '"' then
      local value = assert(loadstring("return " .. src:sub(i, j)))()
      return value, j + 1
    elseif c == "\n" then
      return nil, j
    else
      j = j + 1
    end
  end
  return nil, j
end

-- Keys of L["..."] (also ns.L["..."]) and every double-quoted literal of a source text.
local function scan(src)
  local keys, literals = {}, {}
  local i = 1
  while true do
    local q = src:find('"', i, true)
    if not q then
      break
    end
    local value, after = stringAt(src, q)
    if value then
      literals[value] = true
      if src:sub(q - 2, q - 1) == "L[" and not src:sub(q - 3, q - 3):match("[%w_]")
        and src:sub(after, after) == "]" then
        keys[value] = true
      end
    end
    i = after
  end
  return keys, literals
end

local function codeScan()
  local keys, literals, where = {}, {}, {}
  for _, file in ipairs(tocFiles()) do
    if file ~= LOCALE then
      local k, l = scan(read(ADDON .. "/" .. file))
      for key in pairs(k) do
        keys[key] = true
        where[key] = where[key] or file
      end
      for lit in pairs(l) do
        literals[lit] = true
      end
    end
  end
  return keys, literals, where
end

-- Loads enUS.lua like the game does (addon name, namespace) and returns ns.L.
local function loadLocale()
  local chunk = assert(loadfile(ADDON .. "/" .. LOCALE))
  local ns = {}
  chunk(ADDON, ns)
  return ns.L
end

local function sorted(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

T.test("the scanner finds L[...] keys and ignores other indexing", function()
  local keys, literals = scan('x = L["A b"] .. ns.L["C %s"]:format(1) .. URL["no"] .. L[k] .. "lit"\n'
    .. 'y = L["say \\"hi\\""]')
  T.eq(sorted(keys), { "A b", "C %s", 'say "hi"' })
  T.ok(literals.lit and literals.no)
end)

T.test("every key used in the code has an entry in enUS.lua", function()
  local L = loadLocale()
  local keys, _, where = codeScan()
  local missing = {}
  for _, key in ipairs(sorted(keys)) do
    if rawget(L, key) == nil then
      missing[#missing + 1] = ("%q (%s)"):format(key, where[key])
    end
  end
  T.ok(#missing == 0, "missing in enUS.lua:\n" .. table.concat(missing, "\n"))
  T.ok(#sorted(keys) > 100, "the scan found the keys")
end)

T.test("enUS.lua maps each key to the same English text", function()
  local L = loadLocale()
  for key, text in pairs(L) do
    T.eq(text, key, "entry " .. ("%q"):format(key))
  end
end)

T.test("enUS.lua has no entry that the code does not use", function()
  local L = loadLocale()
  local keys, literals = codeScan()
  local unused = {}
  for _, key in ipairs(sorted(L)) do
    if not (keys[key] or literals[key]) then
      unused[#unused + 1] = ("%q"):format(key)
    end
  end
  T.ok(#unused == 0, "unused in enUS.lua:\n" .. table.concat(unused, "\n"))
end)

T.test("a key missing from enUS.lua still returns the key itself", function()
  local L = loadLocale()
  T.eq(L["Some text nobody wrote yet"], "Some text nobody wrote yet")
  T.eq(rawget(L, "Some text nobody wrote yet"), nil, "the fallback does not store it")
end)

T.done()
