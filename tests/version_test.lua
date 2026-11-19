-- Core/Version.lua, Changelog.lua, UI/WhatsNew.lua: version compare, the new-version gossip on the channel and
-- the What's new window (playbook D17).
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")
local Sim = dofile("tests/lib/sim.lua")

math.randomseed(17)

local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function loaded(saved)
  return Wow.new():load({ saved = saved })
end

local function printedHas(wow, text)
  for _, line in ipairs(wow.printed) do
    if line:find(text, 1, true) then return true end
  end
  return false
end

local function versSent(wow)
  local out = {}
  for _, s in ipairs(wow.sent) do
    if s.msg:find("^VER|") then out[#out + 1] = s end
  end
  return out
end

local function record(wow, event)
  local got = {}
  wow.ns.on(event, function(...) got[#got + 1] = { ... } end)
  return got
end

local V = loaded().ns.Version

-- Pure ---------------------------------------------------------------------------------------

T.test("parse reads x.y.z with an optional -suffix", function()
  T.eq(V.parse("0.2.0"), { major = 0, minor = 2, patch = 0 })
  T.eq(V.parse("1.10.3-dev"), { major = 1, minor = 10, patch = 3, pre = "dev" })
  for _, bad in ipairs({ "", "1.2", "1.2.3-", "1.2.3 ", "v1.2.3", "1.2.x", "99999.0.0", 1, nil }) do
    T.eq(V.parse(bad), nil, tostring(bad))
  end
end)

T.test("compare orders numerically, a release after its pre-release", function()
  T.eq(V.compare("0.1.0", "0.1.0"), 0)
  T.eq(V.compare("0.2.0", "0.1.9"), 1)
  T.eq(V.compare("0.10.0", "0.9.0"), 1, "numbers, not text")
  T.eq(V.compare("1.0.0", "0.99.99"), 1)
  T.eq(V.compare("0.1.0", "0.1.1"), -1)
  T.eq(V.compare("0.2.0-dev", "0.2.0"), -1)
  T.eq(V.compare("0.2.0", "0.2.0-dev"), 1)
  T.eq(V.compare("0.2.0-dev", "0.1.0"), 1)
  T.eq(V.compare("0.2.0-beta", "0.2.0-alpha"), 1)
  T.eq(V.compare("x", "0.1.0"), nil)
  T.eq(V.compare("0.1.0", nil), nil)
end)

T.test("isRelease is false for a pre-release", function()
  T.ok(V.isRelease("0.2.0"))
  T.ok(not V.isRelease("0.2.0-dev"))
  T.ok(not V.isRelease("nope"))
end)

T.test("notes returns the entries after from up to to, newest first", function()
  local log = {
    { version = "0.3.0", items = { "c" } },
    { version = "0.2.1", items = { "b2" } },
    { version = "0.2.0", items = { "b" } },
    { version = "0.1.0", items = { "a" } },
  }
  local function versions(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.version end
    return out
  end
  T.eq(versions(V.notes(log, "0.1.0", "0.2.1")), { "0.2.1", "0.2.0" })
  T.eq(versions(V.notes(log, "0.2.1", "0.2.1")), {})
  T.eq(versions(V.notes(log, nil, "0.2.0")), { "0.2.0", "0.1.0" })
  T.eq(versions(V.notes(log, "0.2.0", "0.3.0-dev")), { "0.3.0", "0.2.1" }, "a dev build sees its coming notes")
  T.eq(versions(V.notes({ log[4], log[1], log[3] }, nil, "0.3.0")), { "0.3.0", "0.2.0", "0.1.0" }, "sorted")
  T.eq(V.notes(nil, nil, "0.1.0"), {})
end)

-- Release bookkeeping ------------------------------------------------------------------------

T.test("the TOC version, ns.VERSION and the newest changelog entry agree", function()
  local wow = loaded()
  local toc = read("Portaxi/Portaxi.toc"):match("## Version:%s*([^\r\n]-)%s*[\r\n]")
  T.eq(wow.ns.VERSION, toc, "Init.lua ns.VERSION = ## Version of Portaxi.toc")
  local top = wow.ns.Changelog[1]
  T.eq(top.version, (toc:gsub("%-.*$", "")), "Changelog.lua starts with the entry of this version")
end)

T.test("changelog entries are valid, newest first, with a date and items", function()
  local log = loaded().ns.Changelog
  T.ok(#log > 0)
  for i, e in ipairs(log) do
    T.ok(V.isRelease(e.version), "release version " .. tostring(e.version))
    T.ok(type(e.date) == "string" and e.date:find("^%d%d%d%d%-%d%d%-%d%d$"), "date of " .. e.version)
    T.ok(type(e.items) == "table" and #e.items > 0, "items of " .. e.version)
    if i > 1 then
      T.eq(V.compare(log[i - 1].version, e.version), 1, "newest first")
    end
  end
end)

-- Gossip --------------------------------------------------------------------------------------

T.test("the own version goes out on the channel 10-20 s after login, once", function()
  local wow = loaded()
  wow:advance(9.9)
  T.eq(#versSent(wow), 0, "not in the login burst")
  wow:advance(10.2)
  local sent = versSent(wow)
  T.eq(#sent, 1)
  T.eq(sent[1].msg, "VER|" .. wow.ns.VERSION)
  T.eq(sent[1].kind, "CHANNEL")
  wow:advance(600)
  T.eq(#versSent(wow), 1)
end)

T.test("a newer release prints one notice per session and fires VERSION_NEWER", function()
  local wow = loaded()
  local newer = record(wow, "VERSION_NEWER")
  wow:receive("PTX", "VER|9.0.0", "CHANNEL", "Velvet Forever")
  T.ok(printedHas(wow, "Version 9.0.0 is available (you have " .. wow.ns.VERSION .. ")"))
  T.eq(newer, { { "9.0.0" } })
  local n = #wow.printed
  wow:receive("PTX", "VER|9.0.0", "CHANNEL", "Kael Forever")
  wow:receive("PTX", "VER|9.1.0", "CHANNEL", "Kael Forever")
  T.eq(#wow.printed, n, "no second notice")
  T.eq(wow.ns.Version.newest, "9.1.0")
  T.eq(newer, { { "9.0.0" }, { "9.1.0" } })
  wow:slash("version")
  T.ok(wow.printed[#wow.printed]:find("Version 9.1.0 is available.", 1, true))
end)

T.test("a newer pre-release, an equal or older version and garbage tell nothing", function()
  local wow = loaded()
  local newer = record(wow, "VERSION_NEWER")
  local n = #wow.printed
  wow:receive("PTX", "VER|9.0.0-dev", "CHANNEL", "Velvet Forever")
  wow:receive("PTX", "VER|" .. wow.ns.VERSION, "CHANNEL", "Velvet Forever")
  wow:receive("PTX", "VER|0.0.1", "WHISPER", "Velvet Forever")
  wow:receive("PTX", "VER|banana", "CHANNEL", "Velvet Forever")
  T.eq(#wow.printed, n)
  T.eq(newer, {})
  T.eq(wow.ns.Version.newest, nil)
  wow:slash("version")
  T.ok(wow.printed[#wow.printed]:find("newest version seen on the network", 1, true))
end)

T.test("an older version on the channel gets one answer within 2-30 s", function()
  local wow = loaded()
  wow:advance(30) -- past the login announce
  local before = #versSent(wow)
  wow:receive("PTX", "VER|0.0.1", "CHANNEL", "Velvet Forever")
  wow:advance(1.9)
  T.eq(#versSent(wow), before, "not at once")
  wow:advance(28.2)
  T.eq(#versSent(wow), before + 1)
  wow:receive("PTX", "VER|0.0.1", "CHANNEL", "Kael Forever")
  wow:advance(60)
  T.eq(#versSent(wow), before + 1, "at most one answer per 5 minutes")
  wow:advance(300)
  wow:receive("PTX", "VER|0.0.1", "CHANNEL", "Kael Forever")
  wow:advance(31)
  T.eq(#versSent(wow), before + 2, "after the cooldown it answers again")
end)

T.test("the answer is dropped when someone at least as new speaks first", function()
  local wow = loaded()
  wow:advance(30)
  local before = #versSent(wow)
  wow:receive("PTX", "VER|0.0.1", "CHANNEL", "Velvet Forever")
  wow:receive("PTX", "VER|" .. wow.ns.VERSION, "CHANNEL", "Kael Forever")
  wow:advance(31)
  T.eq(#versSent(wow), before)
  wow:receive("PTX", "VER|0.0.1", "CHANNEL", "Velvet Forever")
  wow:receive("PTX", "VER|9.0.0-dev", "CHANNEL", "Kael Forever")
  wow:advance(31)
  T.eq(#versSent(wow), before + 1, "a pre-release does not stand in for a release")
end)

T.test("a pre-release build announces itself but never answers", function()
  local wow = loaded()
  wow.ns.VERSION = "9.9.9-dev"
  wow:advance(30)
  T.eq(#versSent(wow), 1)
  wow:receive("PTX", "VER|0.0.1", "CHANNEL", "Velvet Forever")
  wow:advance(60)
  T.eq(#versSent(wow), 1)
end)

T.test("sim: a player who logs in with an old version learns about the new one from a single answer", function()
  local sim = Sim.new()
  local a = sim:client("Thalindra")
  local b = sim:client("Kael")
  local c = sim:client("Zorn")
  sim:advance(60)
  local old = sim:client("Velvet", { class = "WARRIOR" })
  old.ns.VERSION = "0.0.9"
  sim:advance(60)
  T.ok(printedHas(old, "Version " .. a.ns.VERSION .. " is available (you have 0.0.9)"))
  local answers = 0
  for _, wow in ipairs({ a, b, c }) do answers = answers + #versSent(wow) - 1 end
  T.eq(answers, 1, "one answer, the others stay quiet")
  T.ok(not printedHas(a, "is available"), "the new ones are not told anything")
end)

-- What's new --------------------------------------------------------------------------------------

T.test("a fresh install shows no What's new and remembers the version", function()
  local wow = loaded()
  local got = record(wow, "WHATS_NEW")
  wow:advance(10)
  T.eq(got, {})
  T.eq(wow.env.PortaxiDB.lastVersion, wow.ns.VERSION)
  T.ok(not (wow.ns.UI.WhatsNew.frame and wow.ns.UI.WhatsNew.frame:IsShown()))
end)

T.test("after an update the window opens a few seconds after login with the new entries", function()
  local wow = loaded({ PortaxiDB = { lastVersion = "0.0.1" } })
  local got = record(wow, "WHATS_NEW")
  wow:advance(3.9)
  T.eq(got, {}, "not in the login burst")
  wow:advance(0.2)
  T.eq(#got, 1)
  T.eq(got[1][1][1].version, wow.ns.Changelog[1].version)
  T.eq(wow.env.PortaxiDB.lastVersion, wow.ns.VERSION)
  local N = wow.ns.UI.WhatsNew
  T.ok(N.frame:IsShown())
  T.eq(N.subtitle:GetText(), "Portaxi " .. wow.ns.VERSION)
  N.hide()
  T.ok(not N.frame:IsShown())
end)

T.test("the same version or a downgrade shows nothing", function()
  local current = loaded().ns.VERSION
  for _, last in ipairs({ current, "99.0.0" }) do
    local wow = loaded({ PortaxiDB = { lastVersion = last } })
    local got = record(wow, "WHATS_NEW")
    wow:advance(10)
    T.eq(got, {}, last)
    T.eq(wow.env.PortaxiDB.lastVersion, current)
  end
end)

T.test("a player from before lastVersion existed sees the notes of the running version", function()
  local wow = loaded({ PortaxiDB = { caps = {} } })
  local got = record(wow, "WHATS_NEW")
  wow:advance(5)
  T.eq(#got, 1)
  T.eq(#got[1][1], 1)
  T.eq(got[1][1][1].version, wow.ns.Changelog[1].version)
end)

T.test("/ptx news opens the window with every entry", function()
  local wow = loaded()
  wow:slash("news")
  local N = wow.ns.UI.WhatsNew
  T.ok(N.frame:IsShown())
  T.eq(N.text({ items = { "a", "b" } }), "• a\n• b")
  T.eq(#wow.errors, 0)
end)

T.done()
