-- ChatParse: reads a taxi request out of one public chat line, in English or Russian ("WTB port Org",
-- "need summon BRD", "куплю порт в орг"). Pure module: no game APIs, tested offline (playbook D16).
--   ChatParse.parse(text) -> { kind = "port", dest = "OG", lang = "en" | "ru" }
--                          | { kind = "summon", place = "BRD", lang = ... } | nil
--   ChatParse.clean(text)  -> the line without colour codes, links and raid icons (also for display)
-- A line counts as a request when it names a portal (or a mage, or a summon) and reads as asking:
--   * a seller word (WTS, selling, продаю ...) -> never a request;
--   * a strong buyer word (WTB, LF, looking for, куплю, ищу) -> a request;
--   * otherwise it must ask (need, anyone, pls, нужен, кто ... or a "?"), must name one city only
--     (sellers list several), and must not be a question that asks to be whispered ("Need a port? /w me").
-- A port request needs a city; "IF" counts as Ironforge only in capitals.
--   ChatParse.offer(text) -> a seller's ad, for riders (playbook D18):
--     { kind = "port", dests = { "OG", "UC" } | nil (no city named: any), prices = { OG = 5000 }, price = 5000,
--       tip = true, at = "OG", lang } | { kind = "summon", price, tip, lang } | nil
--   price is the lowest one named (nil = none), prices the price per named city, tip a "free / tips" ad,
--   at the city the mage says they stand in ("in Org", "at UC"; English only). A line is an offer when it names
--   a portal (not just "mage") and sells: a seller word, a question that asks to be whispered, several cities
--   or "all cities" without a buyer word, or a price with a contact word. parse and offer never both match.

local _, ns = ...

local P = {}
ns.ChatParse = P

local function set(list)
  local out = {}
  for _, v in ipairs(list) do
    out[v] = true
  end
  return out
end

-- City aliases: exact tokens, and stems that a token (or two tokens glued, "thunder bluff") starts with.
local CITY_EXACT = {
  og = "OG", org = "OG", orgi = "OG", orgri = "OG", orgr = "OG", ogri = "OG", ogrim = "OG",
  ["орг"] = "OG", ["оргри"] = "OG", ["огри"] = "OG", ["ог"] = "OG", ["орга"] = "OG",
  uc = "UC", ["андер"] = "UC", ["андера"] = "UC",
  tb = "TB", thunder = "TB", ["тб"] = "TB", ["тандер"] = "TB",
  sw = "SW", ["шторм"] = "SW", ["штормик"] = "SW",
  ironforge = "IF", ["иф"] = "IF", ["айрон"] = "IF",
  darn = "DN", darna = "DN", darnas = "DN", ["дарн"] = "DN", ["дарнас"] = "DN",
}
local CITY_STEMS = {
  { "orgrim", "OG" }, { "orgim", "OG" }, { "ogrim", "OG" }, { "оргрим", "OG" }, { "огрим", "OG" },
  { "undercit", "UC" }, { "подгород", "UC" }, { "андерсит", "UC" },
  { "thunderbl", "TB" }, { "громов", "TB" }, { "тандербл", "TB" },
  { "stormwin", "SW" }, { "штормград", "SW" }, { "штормвин", "SW" },
  { "ironfor", "IF" }, { "стальгорн", "IF" }, { "айронфор", "IF" },
  { "darnas", "DN" }, { "дарнас", "DN" },
}

local PORT_EXACT = set({ "port", "ports", "porta", "porting", "portal", "portals", "tp", "teleport", "mage", "mages",
  "lfmage", "lfport", "lfportal", "тп", "маг", "мага", "магу", "магов", "магик", "телепорт" })
local PORT_STEMS = { "порт" } -- порт, порта, портал, порталы, портануть
local SUMMON_EXACT = set({ "summon", "summons", "summ", "sum", "sumon", "lock", "warlock", "lfsummon" })
local SUMMON_STEMS = { "summon", "саммон", "суммон", "самон", "сумон", "призыв", "лок" }

-- Kept short on purpose: "free", "available", "can" and "есть" show up in requests as often as in offers.
local SELLER = set({ "wts", "selling", "sell", "sells", "offering", "lfw", "продаю", "продам", "предлагаю" })
local STRONG_BUYER = set({ "wtb", "buying", "lf", "lfm", "lfmage", "lfport", "lfportal", "lfsummon",
  "куплю", "ищу", "ищем" })
local WEAK_BUYER = set({ "need", "needs", "needed", "any", "anyone", "anybody", "someone", "somebody",
  "pls", "plz", "please", "help", "нужен", "нужна", "нужно", "нужны", "надо", "кто", "можно",
  "плиз", "плз", "пж", "пожалуйста", "помогите" })
local CONTACT = set({ "pst", "pm", "msg", "whisper", "пиши", "пишите", "лс", "пм" })
local FILLER = set({ "to", "at", "in", "into", "for", "me", "us", "a", "pls", "plz", "please", "now", "asap",
  "в", "во", "на", "к", "до", "мне", "нам", "плз", "пж", "плиз", "срочно" })

-- Cyrillic capitals to small letters (UTF-8, two bytes each); ё reads as е.
local function lower(s)
  s = s:lower()
  s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
  s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
  s = s:gsub("\208\129", "\208\181"):gsub("\209\145", "\208\181")
  return s
end

local function startsWith(s, stem)
  return s:sub(1, #stem) == stem
end

local function anyStem(s, stems)
  for _, stem in ipairs(stems) do
    if startsWith(s, stem) then
      return true
    end
  end
  return false
end

local function cityOf(word)
  if CITY_EXACT[word] then
    return CITY_EXACT[word]
  end
  for _, pair in ipairs(CITY_STEMS) do
    if startsWith(word, pair[1]) then
      return pair[2]
    end
  end
end

function P.clean(text)
  if type(text) ~= "string" then
    return ""
  end
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  text = text:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
  text = text:gsub("{[^}]*}", " ")
  return (text:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

-- Words of the line: original spelling and lower case, split on ASCII punctuation, controls and spaces.
local function words(text)
  local orig, low = {}, {}
  for word in text:gsub("[%p%c%s]+", " "):gmatch("%S+") do
    orig[#orig + 1] = word
    low[#low + 1] = lower(word)
  end
  return orig, low
end

-- The cities named in the line, in order, without repeats.
local function cities(low)
  local out, seen = {}, {}
  local i = 1
  while i <= #low do
    local city, used = cityOf(low[i]), 1
    if not city and low[i + 1] and not cityOf(low[i + 1]) then
      city = cityOf(low[i] .. low[i + 1]) -- "storm wind", "under city", "iron forge"
      used = city and 2 or 1
    end
    if city and not seen[city] then
      seen[city] = true
      out[#out + 1] = city
    end
    i = i + used
  end
  return out
end

-- The place of a summon in its original spelling: the first word after the summon word ("need summon to
-- BRD"), else the nearest one before it ("LFM BRD need summon").
local function summonPlace(orig, low, at)
  local function place(i)
    local w = low[i]
    return not (FILLER[w] or STRONG_BUYER[w] or WEAK_BUYER[w] or SUMMON_EXACT[w] or anyStem(w, SUMMON_STEMS))
  end
  for i = at + 1, #low do
    if place(i) then
      return orig[i]
    end
  end
  for i = at - 1, 1, -1 do
    if place(i) then
      return orig[i]
    end
  end
end

local function has(low, words_)
  for _, w in ipairs(low) do
    if words_[w] then
      return true
    end
  end
  return false
end

-- A word or phrase that asks to be whispered: "pst", "/w me", "whisper me", "пиши".
local function contacts(low, lowText)
  return has(low, CONTACT) or lowText:find("/w", 1, true) ~= nil
    or lowText:find("%f[%w]w me%f[%W]") ~= nil or lowText:find("whisper me", 1, true) ~= nil
end

function P.parse(text)
  text = P.clean(text)
  if text == "" or #text > 255 then
    return nil
  end
  -- "IF" means Ironforge only in capitals ("port to IF"); "if anyone ..." is a conjunction.
  text = text:gsub("%f[%w]IF%f[%W]", "ironforge")
  local orig, low = words(text)
  if #low == 0 or has(low, SELLER) then
    return nil
  end
  local lowText = lower(text)
  local strong = has(low, STRONG_BUYER) or lowText:find("looking for", 1, true) ~= nil
  if not strong then
    -- "Need a port to Org? /w me" is a seller's question to the market; "need port org pst" is a rider.
    local question = text:find("?", 1, true) ~= nil
    local asks = question or has(low, WEAK_BUYER)
    local contact = contacts(low, lowText)
    if not asks or (contact and question) then
      return nil
    end
  end
  local lang = text:find("[\208\209]") and "ru" or "en"

  local portAt, summonAt
  for i, w in ipairs(low) do
    if not portAt and (PORT_EXACT[w] or anyStem(w, PORT_STEMS)) then
      portAt = i
    end
    if not summonAt and (SUMMON_EXACT[w] or anyStem(w, SUMMON_STEMS)) then
      summonAt = i
    end
  end

  local dests = cities(low)
  if portAt and #dests > 0 then
    if #dests > 1 and not strong then
      return nil -- "Portals to Org / UC / TB" is an offer
    end
    return { kind = "port", dest = dests[1], lang = lang }
  end
  if summonAt and #dests == 0 then
    return { kind = "summon", place = summonPlace(orig, low, summonAt), lang = lang }
  end
  return nil
end

-- Offers (D18) ---------------------------------------------------------------------------------------

-- A portal named outright: "mage" alone also sells water and food.
local OFFER_PORT = set({ "port", "ports", "porta", "porting", "portal", "portals", "tp", "tps", "teleport",
  "teleports", "taxi", "тп", "телепорт", "телепорты", "такси" })
local ALL = set({ "all", "every", "все", "всех", "любой", "любую", "любые" })
local TIP = set({ "free", "tip", "tips", "donation", "donations", "donate", "бесплатно", "чаевые", "чай" })
local LOCATION = set({ "in", "at", "from" }) -- "WTS ports, in Org" names where the mage stands (English only)
local GOLD = set({ "g", "gold", "golds", "gp", "з", "г", "зол", "золото", "золота", "золотых", "голд", "голда",
  "голды" })
local SILVER = set({ "s", "silver", "silvers", "sil", "с", "сер", "серебро", "серебра", "серебряных" })

local function unitOf(word)
  if GOLD[word] then
    return 10000
  elseif SILVER[word] then
    return 100
  end
end

-- Turns every amount of a lower-case line ("50s", "1.5g", "1g 50s", "5 gold", "50с") into one word
-- "pxmoney<copper>", so the word list keeps prices in their place between the cities.
local function markMoney(low)
  local out, i = {}, 1
  while true do
    local s, e, num = low:find("(%d+[%.,]?%d*)", i)
    if not s then
      break
    end
    local glued = s > 1 and low:sub(s - 1, s - 1):find("[%a\128-\255]") ~= nil -- "lvl60s" is no price
    local _, ue, unit = low:find("^ ?([%a\128-\255]+)", e + 1)
    local mult = unit and unitOf(unit)
    local amount = tonumber((num:gsub(",", ".")))
    if mult and amount and not glued then
      local copper, stop = math.floor(amount * mult + 0.5), ue
      if mult == 10000 then -- "1g 50s", "1g50s"
        local _, se, snum, sunit = low:find("^ ?(%d+) ?([%a\128-\255]+)", ue + 1)
        if snum and unitOf(sunit) == 100 then
          copper, stop = copper + tonumber(snum) * 100, se
        end
      end
      out[#out + 1] = low:sub(i, s - 1) .. " pxmoney" .. copper .. " "
      i = stop + 1
    else
      out[#out + 1] = low:sub(i, e)
      i = e + 1
    end
  end
  out[#out + 1] = low:sub(i)
  return table.concat(out)
end

-- Cities to go to, in order, with their prices: a price belongs to the cities named since the previous
-- price ("UC 50s, Darn 1g"); cities after the last price take it ("50s: Org UC TB"). A city right after
-- "in", "at" or "from" is where the mage stands, not a destination.
local function destsAndPrices(low)
  local dests, prices, named, pending = {}, {}, {}, {}
  local at, last, lowest
  local i = 1
  while i <= #low do
    local w = low[i]
    local copper = tonumber(w:match("^pxmoney(%d+)$"))
    local used = 1
    if copper then
      if copper > 0 then
        for _, city in ipairs(pending) do
          prices[city] = copper
        end
        pending, last = {}, copper
        lowest = lowest and math.min(lowest, copper) or copper
      end
    else
      local city = cityOf(w)
      if not city and low[i + 1] and not cityOf(low[i + 1]) then
        city = cityOf(w .. low[i + 1])
        used = city and 2 or 1
      end
      if city and LOCATION[low[i - 1] or ""] then
        at = at or city
      elseif city and not named[city] then
        named[city] = true
        dests[#dests + 1] = city
        pending[#pending + 1] = city
      end
    end
    i = i + used
  end
  for _, city in ipairs(pending) do
    prices[city] = last
  end
  return dests, prices, lowest, at
end

function P.offer(text)
  if P.parse(text) then
    return nil -- a request; the two never both match
  end
  text = P.clean(text)
  if text == "" or #text > 255 then
    return nil
  end
  text = text:gsub("%f[%w]IF%f[%W]", "ironforge")
  local lowText = lower(text)
  local _, low = words(markMoney(lowText))
  if #low == 0 then
    return nil
  end
  local seller = has(low, SELLER)
  if not seller and (has(low, STRONG_BUYER) or lowText:find("looking for", 1, true)) then
    return nil
  end
  local port, summon = false, false
  for _, w in ipairs(low) do
    port = port or OFFER_PORT[w] or anyStem(w, PORT_STEMS)
    summon = summon or SUMMON_EXACT[w] or anyStem(w, SUMMON_STEMS)
  end
  if not (port or summon) then
    return nil
  end
  local dests, prices, lowest, at = destsAndPrices(low)
  local tip = has(low, TIP) or nil
  if not seller then
    local question = text:find("?", 1, true) ~= nil
    local contact = contacts(low, lowText)
    local weak = has(low, WEAK_BUYER)
    local sells = (question and contact)
      or (not weak and (#dests > 1 or (port and has(low, ALL))))
      or (not weak and contact and (lowest ~= nil or tip ~= nil))
    if not sells then
      return nil
    end
  end
  local lang = text:find("[\208\209]") and "ru" or "en"
  if port then
    return { kind = "port", dests = #dests > 0 and dests or nil, prices = prices, price = lowest, tip = tip,
      at = at, lang = lang }
  end
  return { kind = "summon", price = lowest, tip = tip, lang = lang }
end
