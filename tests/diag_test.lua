-- /ptx diag (Core/Probe.lua) on a modern client without the classic globals.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

T.test("diag reads the character and stores it", function()
  local wow = Wow.new():load()
  wow:slash("diag")
  local d = wow.env.PortaxiDB.diag
  T.eq(d.client, { version = "1.60.1", build = "70959", buildDate = "Nov 13 2026", interface = 16001 })
  T.eq(d.player.class, "MAGE")
  T.eq(d.player.mapId, 1454)
  T.eq(d.portals, { Orgrimmar = true, Undercity = true, ["Thunder Bluff"] = false })
  T.eq(d.items, { runeOfPortals = 7, soulShard = 0, scroll = 9 })
  T.eq(d.apis.GetItemCount, false)
  T.eq(d.apis["C_Item.GetItemCount"], true)
  T.eq(d.apis["C_TradeInfo.SetTradeMoney"], true)
  T.eq(#wow.errors, 0)
end)

T.test("diag reads the scroll's spell when the client knows it", function()
  local wow = Wow.new()
  wow.itemSpells = { [213548] = { "Liminal Passage", 123456 } }
  wow:load()
  wow:slash("diag")
  local items = wow.env.PortaxiDB.diag.items
  T.eq(items.scrollSpellName, "Liminal Passage")
  T.eq(items.scrollSpellId, 123456)
  T.ok(table.concat(wow.printed, "\n"):find("Scroll spell: Liminal Passage (123456)", 1, true))
  T.eq(#wow.errors, 0)
end)

T.test("diag lists Alliance portals for an Alliance character", function()
  local wow = Wow.new({ player = { faction = "Alliance", race = "Human", spells = { [10059] = true } } }):load()
  wow:slash("diag")
  T.eq(wow.env.PortaxiDB.diag.portals, { Stormwind = true, Ironforge = false, Darnassus = false })
end)

T.done()
