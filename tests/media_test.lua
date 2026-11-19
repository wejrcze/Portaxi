-- Media (card J, wave 3): the TGA files written by tools/make-emblems.mjs exist, have a valid header for
-- 64x64 32-bit uncompressed true-colour with alpha and the expected size, and the UI points at them.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local MEDIA = "Portaxi/Media/"
local CITIES = { "OG", "UC", "TB", "SW", "IF", "DN" }
local EXTRA = { "ring", "glow", "portal", "arrow" }
local SIZE = 64
local FILE_SIZE = 18 + SIZE * SIZE * 4

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function u16(data, i)
  return data:byte(i) + 256 * data:byte(i + 1)
end

-- Checks the 18-byte header; returns the file data.
local function checkTga(name)
  local data = T.ok(read(MEDIA .. name .. ".tga"), name .. ".tga exists")
  T.eq(#data, FILE_SIZE, name .. " size")
  T.eq(data:byte(1), 0, name .. ": no image ID")
  T.eq(data:byte(2), 0, name .. ": no colour map")
  T.eq(data:byte(3), 2, name .. ": uncompressed true-colour")
  T.eq(u16(data, 13), SIZE, name .. ": width")
  T.eq(u16(data, 15), SIZE, name .. ": height")
  T.eq(data:byte(17), 32, name .. ": 32 bits per pixel")
  T.eq(data:byte(18) % 16, 8, name .. ": 8 alpha bits")
  T.eq(math.floor(data:byte(18) / 64), 0, name .. ": no interleaving")
  return data
end

-- Alpha of pixel (x, y) counted from the top-left, for a bottom-left origin file.
local function alpha(data, x, y)
  local topLeft = math.floor(data:byte(18) / 32) % 2 == 1
  local row = topLeft and y or (SIZE - 1 - y)
  return data:byte(18 + (row * SIZE + x) * 4 + 4)
end

T.test("every city emblem is a 64x64 32-bit uncompressed TGA", function()
  for _, key in ipairs(CITIES) do
    checkTga("emblem_" .. key)
  end
end)

T.test("the emblems are round: opaque in the middle, transparent in the corners", function()
  for _, key in ipairs(CITIES) do
    local data = checkTga("emblem_" .. key)
    T.eq(alpha(data, 32, 32), 255, key .. " centre")
    T.eq(alpha(data, 0, 0), 0, key .. " top-left corner")
    T.eq(alpha(data, 63, 63), 0, key .. " bottom-right corner")
  end
end)

T.test("the emblems differ from each other", function()
  local seen = {}
  for _, key in ipairs(CITIES) do
    local data = checkTga("emblem_" .. key)
    T.ok(not seen[data], key .. " is not a copy")
    seen[data] = true
  end
end)

T.test("the ring, glow and portal textures exist with the same format", function()
  for _, name in ipairs(EXTRA) do
    checkTga(name)
  end
  T.eq(alpha(checkTga("ring"), 32, 32), 0, "the ring is hollow")
  T.eq(alpha(checkTga("ring"), 32, 1), 255, "the ring is solid at the edge")
  local arrow = checkTga("arrow")
  T.eq(alpha(arrow, 32, 20), 255, "the arrow is solid in the middle")
  T.eq(alpha(arrow, 32, 60), 0, "the arrow has a notch at the bottom")
  T.eq(alpha(arrow, 2, 2), 0, "the arrow points up: top-left corner empty")
end)

T.test("the tiles, ride panel and minimap button use the Media paths", function()
  local wow = Wow.new()
  wow:load()
  local ns = wow.ns
  local profile = { faction = "Alliance", race = "Human", class = "WARRIOR", level = 30, resting = true,
    zone = "Goldshire", subzone = "", money = 10000, portals = {}, runes = 0, scrolls = 0 }
  ns.Detect.current = function() return profile, { canDrive = false, dests = {}, pauses = { "NOT_MAGE" } } end
  ns.UI.show("ride")
  local tiles = ns.UI.RideTab.ui.tiles
  for i, key in ipairs({ "SW", "IF", "DN" }) do
    T.eq(tiles[i].icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\emblem_" .. key)
    T.eq(ns.UI.Widgets.emblemPath(key), "Interface\\AddOns\\Portaxi\\Media\\emblem_" .. key)
  end
  T.eq(ns.UI.Minimap.button.icon:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\portal")
  T.eq(tiles[1].emblem.ring:GetTexture(), "Interface\\AddOns\\Portaxi\\Media\\ring")
  T.eq(#wow.errors, 0)
end)

T.test("every path the UI asks for has its file on disk", function()
  local src = ""
  for _, file in ipairs({ "Widgets", "MainFrame", "Minimap" }) do
    src = src .. read("Portaxi/UI/" .. file .. ".lua")
  end
  local names = {}
  for name in src:gmatch('W%.MEDIA %.%. "([%w_]+)"') do
    names[#names + 1] = name
  end
  T.ok(#names >= 3, "found the Media names in the code")
  for _, name in ipairs(names) do
    T.ok(name == "emblem_" or read(MEDIA .. name .. ".tga"), name .. ".tga exists")
  end
end)

T.done()
