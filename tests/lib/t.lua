-- Minimal test framework. Usage in tests/<name>_test.lua:
--   local T = dofile("tests/lib/t.lua")
--   T.test("does a thing", function() T.eq(1 + 1, 2) end)
--   T.done()
-- Run from the repo root (tests\run.ps1 does that).

local T = {}
local passed, failed = 0, 0

local function show(v)
  if type(v) == "string" then
    return ("%q"):format(v)
  end
  return tostring(v)
end

local function deepEq(a, b, path)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false, ("%s: got %s, expected %s"):format(path, show(a), show(b))
  end
  for k, v in pairs(b) do
    local ok, why = deepEq(a[k], v, path .. "." .. tostring(k))
    if not ok then
      return false, why
    end
  end
  for k in pairs(a) do
    if b[k] == nil then
      return false, ("%s.%s: unexpected value %s"):format(path, tostring(k), show(a[k]))
    end
  end
  return true
end

function T.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("  FAIL ", name, "\n    ", tostring(err):gsub("\n", "\n    "), "\n")
  end
end

-- Deep equality for tables, == for the rest.
function T.eq(actual, expected, msg)
  local ok, why = deepEq(actual, expected, "value")
  if not ok then
    error((msg and (msg .. ": ") or "") .. why, 2)
  end
end

function T.ok(value, msg)
  if not value then
    error(msg or "expected a truthy value", 2)
  end
  return value
end

-- Asserts fn raises an error, optionally matching a Lua pattern.
function T.fails(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    error(msg or "expected an error", 2)
  end
  if pattern and not tostring(err):find(pattern) then
    error(("%serror %q does not match %q"):format(msg and (msg .. ": ") or "", tostring(err), pattern), 2)
  end
end

function T.done()
  io.write(("%s: %d passed, %d failed\n"):format(arg and arg[0] or "?", passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return T
