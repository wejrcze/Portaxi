-- Core/ChatParse.lua: taxi requests read from public chat lines, English and Russian (playbook D16).
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local P = Wow.new():load().ns.ChatParse

local function port(text, dest, lang)
  T.eq(P.parse(text), { kind = "port", dest = dest, lang = lang or "en" }, text)
end

local function none(text)
  T.eq(P.parse(text), nil, text)
end

T.test("English port requests name the city", function()
  port("WTB port Org", "OG")
  port("wtb portal to UC pst", "UC")
  port("LF mage port to Thunder Bluff", "TB")
  port("any mage? need port to orgrimmar", "OG")
  port("port to IF?", "IF")
  port("can someone port me to SW pls", "SW")
  port("need portal darnassus", "DN")
  port("Looking for a portal to Undercity", "UC")
  port("need port to storm wind", "SW")
  port("anyone free to port me to org?", "OG")
  port("need port org pst", "OG")
  port("need port org /w me", "OG")
  port("LFport UC", "UC")
end)

T.test("Russian port requests, with case endings and capitals", function()
  port("куплю порт в орг", "OG", "ru")
  port("Нужен портал в Оргриммар", "OG", "ru")
  port("кто сделает порт в подгород?", "UC", "ru")
  port("ищу мага, портал в Громовой Утёс", "TB", "ru")
  port("ПОРТ В ШТОРМГРАД ПЛЗ", "SW", "ru")
  port("нужен тп в стальгорн", "IF", "ru")
  port("маг есть? порт в дарнас", "DN", "ru")
end)

T.test("a strong buyer with several cities gets the first one", function()
  port("wtb port org or uc", "OG")
  port("WTB port to Orgrimmar or Undercity", "OG")
end)

T.test("chat formatting is ignored", function()
  port("|cffffd000need|r portal to |Hchannel:x|h[Orgrimmar]|h {rt1}", "OG")
  T.eq(P.clean("|cff00ff00WTB|r  port {star} Org "), "WTB port Org")
end)

T.test("offers, ads and other chat are not requests", function()
  none("WTS portals to all cities 5g /w me")
  none("Portals to Org/UC/TB, 3g each")
  none("Need a port to Org? /w me")
  none("need a port? whisper me")
  none("Selling portals Org UC TB")
  none("Порты во все столицы, пишите")
  none("продаю порт в орг")
  none("if anyone needs help with SW quests")
  none("LFG Stockades")
  none("port org")                       -- no ask: an ad or a remark
  none("anyone want a port?")            -- no city
  none("LFM SM need mage")               -- a dungeon group
  none("")
  none(nil)
end)

T.test("lowercase 'if' is not Ironforge, capital 'IF' is", function()
  none("port me if you can")
  port("need port to IF", "IF")
end)

T.test("summon requests name the place", function()
  T.eq(P.parse("need summon BRD"), { kind = "summon", place = "BRD", lang = "en" })
  T.eq(P.parse("LFM BRD need summon"), { kind = "summon", place = "BRD", lang = "en" })
  T.eq(P.parse("WTB summon to Gadgetzan"), { kind = "summon", place = "Gadgetzan", lang = "en" })
  T.eq(P.parse("нужен саммон в БРД"), { kind = "summon", place = "БРД", lang = "ru" })
  T.eq(P.parse("WTS summons, any place"), nil)
end)

-- Offers (D18) ---------------------------------------------------------------------------------------

local function offer(text, want)
  local got = P.offer(text)
  want.prices = want.prices or {}
  want.kind = want.kind or "port"
  want.lang = want.lang or "en"
  T.eq(got, want, text)
end

T.test("sellers' ads name cities and prices", function()
  offer("Portals to Org/UC/TB, 3g each",
    { dests = { "OG", "UC", "TB" }, prices = { OG = 30000, UC = 30000, TB = 30000 }, price = 30000 })
  offer("WTS ports UC 50s, TB 1g", { dests = { "UC", "TB" }, prices = { UC = 5000, TB = 10000 }, price = 5000 })
  offer("WTS ports 50s: Org UC", { dests = { "OG", "UC" }, prices = { OG = 5000, UC = 5000 }, price = 5000 })
  offer("Selling portals Org UC TB", { dests = { "OG", "UC", "TB" } })
  offer("LFW portals UC/TB/Org 75 silver",
    { dests = { "UC", "TB", "OG" }, prices = { UC = 7500, TB = 7500, OG = 7500 }, price = 7500 })
  offer("Need a port to Org? /w me", { dests = { "OG" } })
  offer("port to org 50s pst", { dests = { "OG" }, prices = { OG = 5000 }, price = 5000 })
end)

T.test("price forms: decimals, gold and silver together, words, Russian units", function()
  offer("WTS port 1.5g", { price = 15000 })
  offer("wts portals 1g50s pst", { price = 15000 })
  offer("WTS portals 1g 50s", { price = 15000 })
  offer("WTS portals 2 gold", { price = 20000 })
  offer("продаю порт в орг 50с", { dests = { "OG" }, prices = { OG = 5000 }, price = 5000, lang = "ru" })
  offer("продаю порты 2з", { price = 20000, lang = "ru" })
  offer("WTS ports, tips appreciated", { tip = true })
  offer("lvl60s mage wts ports", {}) -- "60s" glued to a word is no price
end)

T.test("no city or all cities means any city; 'in Org' is where the mage stands", function()
  offer("WTS portals to all cities 5g /w me", { price = 50000 })
  offer("Порты во все столицы, пишите", { lang = "ru" })
  offer("WTS ports UC 50s, TB 1g, in Org",
    { dests = { "UC", "TB" }, prices = { UC = 5000, TB = 10000 }, price = 5000, at = "OG" })
  offer("WTS port to IF 2 gold, I'm at SW bank", { dests = { "IF" }, prices = { IF = 20000 }, price = 20000, at = "SW" })
  offer("WTS ports, in Org", { at = "OG" })
end)

T.test("summon ads are told apart; requests and other ads are not offers", function()
  T.eq(P.offer("WTS summons 2g"), { kind = "summon", price = 20000, lang = "en" })
  for _, text in ipairs({ "WTB port Org", "need port org pst", "LF mage port to UC", "WTS mage food and water",
    "any mage? need port to orgrimmar", "port org", "LFG Stockades", "", "куплю порт в орг" }) do
    T.eq(P.offer(text), nil, text)
  end
  T.eq(P.offer(nil), nil)
end)

T.test("a line is never both a request and an offer", function()
  for _, text in ipairs({ "WTB port Org", "WTS port Org", "port org or uc? pst", "need port org 50s pst",
    "anyone port me to org? 1g", "Portals to Org/UC/TB, 3g each", "Need a port to Org? /w me",
    "LF port UC or TB", "ports org uc tb 1g pst", "куплю порт в орг 50с", "продаю порт в орг 50с" }) do
    T.ok(not (P.parse(text) and P.offer(text)), text)
  end
end)

T.done()
