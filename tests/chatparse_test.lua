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

T.done()
