-- Constants: spell and item IDs, cities, price bounds, timeouts.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Const". Owned by the architect.
-- IDs verified on Forever (client 1.60.1, build 70959) on 2026-11-18 unless marked "unverified".

local _, ns = ...

ns.Const = {
  PREFIX = "PTX",
  CHANNEL = "PortaxiNet",
  PROTO = 1, -- protocol version in every message

  -- Portal destinations. spell = the mage's Portal spell for that city.
  CITY = {
    OG = { name = "Orgrimmar", faction = "Horde", spell = 11417 },
    UC = { name = "Undercity", faction = "Horde", spell = 11418 },
    TB = { name = "Thunder Bluff", faction = "Horde", spell = 11420 }, -- learned at 50, not seen yet
    SW = { name = "Stormwind", faction = "Alliance", spell = 10059 },  -- unverified
    IF = { name = "Ironforge", faction = "Alliance", spell = 11416 },  -- unverified
    DN = { name = "Darnassus", faction = "Alliance", spell = 11419 },  -- unverified
  },
  CITY_ORDER = { "OG", "UC", "TB", "SW", "IF", "DN" }, -- iterate in this order for deterministic output

  ITEM = {
    RUNE_OF_PORTALS = 17032,
    LIMINAL_SCROLL = 213548, -- Scroll of Liminal Passage, stacks
    SOUL_SHARD = 6265,       -- phase 2 (warlocks)
  },
  SPELL = {
    RITUAL_OF_SUMMONING = 698, -- phase 2 (warlocks)
    LIMINAL_PASSAGE = 434752,  -- the scroll's cast "Liminal Passage" (C_Item.GetItemSpell, diag 2026-11-18)
  },

  PRICE = { MIN = 1000, MAX = 500000 }, -- copper: 10s .. 50g

  -- Seconds.
  T = {
    OFFER = 150,        -- drop an offer without HELLO for this long
    REQUEST = 120,      -- a request expires
    CHAT_REQUEST = 120, -- a request read from public chat expires (D16)
    CHAT_OFFER = 300,   -- a mage's ad read from public chat expires (D18); ads repeat every few minutes
    WHO = 10,           -- a /who for a chat mage waits this long for its answer (D18)
    COLLECT = 3,        -- hail: keep collecting TAKEs after the first one
    CONFIRM = 10,       -- taxi waits this long for CONFIRM after TAKE
    INVITE = 60,        -- group must form within this
    PORTAL = 60,        -- portal stays open
    TRADE = 180,        -- ARRIVED/TRADING without payment this long -> the ride fails
    LANDING = 12,       -- scroll SUCCEEDED without proof of the move this long -> back to GROUPED (2026-11-19)
    HELLO = 60,         -- HELLO period while on duty
    HELLO_JITTER = 10,  -- +- random jitter on the HELLO period
    HAIL_COOLDOWN = 10, -- max one HAIL per player per this many seconds
    DEBOUNCE = 2,       -- profile change debounce
    SPOT = 30,          -- SPOT period while a taxi is on the map (D19)
    SPOT_JITTER = 5,    -- +- random jitter on the SPOT period
    SPOT_CHECK = 5,     -- the taxi checks its own grid cell this often
    SPOT_GAP = 10,      -- at most one SPOT per this many seconds after a cell change
    SPOT_TTL = 90,      -- a rider drops a SPOT not repeated for this long
    HOST = 150,         -- Inn hop (D20): drop a host without HOST for this long
    HOST_HELLO = 60,    -- HOST period while hosting
    HOST_JITTER = 10,   -- +- random jitter on the HOST period
    HOP_ANSWER = 30,    -- the host answers a HOP within this, else HOPNO "timeout"
    HOP_RETRY = 60,     -- a mage asks the same host again only after this
  },
  -- Taxi on the map (D19, docs/FIELD_TAXI_PLAN.md). Yards and yards per second.
  FIELD = {
    GRID = 75,    -- positions are rounded to this grid before they leave the taxi's client
    RANGE = 1500, -- riders see taxis on the map up to this far
    SPEED = 7,    -- running speed without a mount, for the rider's ETA
  },
  HAIL_TIE = 15,  -- seconds of ETA counted as a tie
  ETA_PICK = 600, -- MVP estimate for a portal pickup walk, seconds
  RESP_DEFAULT = 30, -- seconds from request to TAKE until a taxi has its own history
  CAST = { SCROLL = 1, PORTAL = 10 }, -- cast times in seconds; SCROLL measured 1.0 s (2026-11-19), PORTAL unverified

  SECURE_BUTTON = "PortaxiNextButton", -- global name, so players can /click it from a macro or key

  -- Inn hop (D20): towns with an inn outside the capitals, as the client names them (zone, town = subzone).
  -- From the original game's world, not checked on Forever yet; places where the player or a host rests are learned
  -- on top of this list (PortaxiDB.inns, Who.isInn). fac: "Horde", "Alliance" or "" for neutral towns.
  INNS = {
    { zone = "Durotar", town = "Razor Hill", fac = "Horde" },
    { zone = "Mulgore", town = "Bloodhoof Village", fac = "Horde" },
    { zone = "Tirisfal Glades", town = "Brill", fac = "Horde" },
    { zone = "The Barrens", town = "The Crossroads", fac = "Horde" },
    { zone = "The Barrens", town = "Camp Taurajo", fac = "Horde" },
    { zone = "The Barrens", town = "Ratchet", fac = "" },
    { zone = "Silverpine Forest", town = "The Sepulcher", fac = "Horde" },
    { zone = "Hillsbrad Foothills", town = "Tarren Mill", fac = "Horde" },
    { zone = "Hillsbrad Foothills", town = "Southshore", fac = "Alliance" },
    { zone = "Stonetalon Mountains", town = "Sun Rock Retreat", fac = "Horde" },
    { zone = "Stonetalon Mountains", town = "Stonetalon Peak", fac = "Alliance" },
    { zone = "Ashenvale", town = "Splintertree Post", fac = "Horde" },
    { zone = "Ashenvale", town = "Astranaar", fac = "Alliance" },
    { zone = "Thousand Needles", town = "Freewind Post", fac = "Horde" },
    { zone = "Desolace", town = "Shadowprey Village", fac = "Horde" },
    { zone = "Desolace", town = "Nijel's Point", fac = "Alliance" },
    { zone = "Arathi Highlands", town = "Hammerfall", fac = "Horde" },
    { zone = "Swamp of Sorrows", town = "Stonard", fac = "Horde" },
    { zone = "Stranglethorn Vale", town = "Grom'gol Base Camp", fac = "Horde" },
    { zone = "Stranglethorn Vale", town = "Booty Bay", fac = "" },
    { zone = "Dustwallow Marsh", town = "Brackenwall Village", fac = "Horde" },
    { zone = "Dustwallow Marsh", town = "Theramore Isle", fac = "Alliance" },
    { zone = "Feralas", town = "Camp Mojache", fac = "Horde" },
    { zone = "Feralas", town = "Feathermoon Stronghold", fac = "Alliance" },
    { zone = "Badlands", town = "Kargath", fac = "Horde" },
    { zone = "The Hinterlands", town = "Revantusk Village", fac = "Horde" },
    { zone = "The Hinterlands", town = "Aerie Peak", fac = "Alliance" },
    { zone = "Tanaris", town = "Gadgetzan", fac = "" },
    { zone = "Winterspring", town = "Everlook", fac = "" },
    { zone = "Silithus", town = "Cenarion Hold", fac = "" },
    { zone = "Eastern Plaguelands", town = "Light's Hope Chapel", fac = "" },
    { zone = "Elwynn Forest", town = "Goldshire", fac = "Alliance" },
    { zone = "Dun Morogh", town = "Kharanos", fac = "Alliance" },
    { zone = "Teldrassil", town = "Dolanaar", fac = "Alliance" },
    { zone = "Westfall", town = "Sentinel Hill", fac = "Alliance" },
    { zone = "Loch Modan", town = "Thelsamar", fac = "Alliance" },
    { zone = "Redridge Mountains", town = "Lakeshire", fac = "Alliance" },
    { zone = "Darkshore", town = "Auberdine", fac = "Alliance" },
    { zone = "Duskwood", town = "Darkshire", fac = "Alliance" },
    { zone = "Wetlands", town = "Menethil Harbor", fac = "Alliance" },
    { zone = "Riverglades", town = "Rog'mar", fac = "Horde" }, -- Forever; resting seen 2026-11-19 (/ptx scroll)
  },

  -- What the Forever client lets an addon do in a trade (gate G2, 2026-11-18, with a real player).
  TRADE = {
    SET_MONEY_API = false,   -- C_TradeInfo.SetTradeMoney -> ADDON_ACTION_FORBIDDEN "UNKNOWN()"; never call it
    FILL_MONEY_FIELD = false, -- MoneyInputFrame_SetCopper(TradePlayerInputMoneyFrame): "forbidden object from code
                              -- tainted by an AddOn" (gate G3, /ptx tradefield); the rider always types the gold
  },
}
