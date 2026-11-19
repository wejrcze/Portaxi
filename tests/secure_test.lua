-- Secure: the secure action button, its combat queue and the key binding (Core/Secure.lua).
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local SCROLL = 213548
local PORTAL_OG = 11417

local function scrollSpec()
  return { kind = "item", item = SCROLL, unit = "party1", label = "Teleport to Velvet" }
end

local function portalSpec()
  return { kind = "spell", spell = PORTAL_OG, label = "Portal: Orgrimmar" }
end

-- Loads a client and records RegisterForClicks of the secure button (wowstub makes it a no-op).
local function client(loadOpts)
  local wow = Wow.new()
  local create = wow.env.CreateFrame
  wow.registeredClicks = nil
  wow.env.CreateFrame = function(kind, name, parent, template)
    local f = create(kind, name, parent, template)
    if name == "PortaxiNextButton" then
      rawset(f, "RegisterForClicks", function(_, ...) wow.registeredClicks = { ... } end)
    end
    return f
  end
  wow:load(loadOpts)
  return wow
end

local function changes(wow)
  local got = {}
  wow.ns.on("SECURE_CHANGED", function(spec) got[#got + 1] = { spec = spec } end)
  return got
end

local function attrs(button)
  return {
    type = button:GetAttribute("type"), item = button:GetAttribute("item"),
    spell = button:GetAttribute("spell"), unit = button:GetAttribute("unit"),
  }
end

T.test("the button exists after READY with the global name and secure template, hidden", function()
  local wow = client()
  local b = wow.env.PortaxiNextButton
  T.ok(b, "global PortaxiNextButton")
  T.ok(b == wow.ns.Secure.button)
  T.eq(b:GetObjectType(), "Button")
  T.eq(b.__template, "SecureActionButtonTemplate")
  T.eq({ b:GetWidth(), b:GetHeight() }, { 40, 40 })
  T.eq(wow.registeredClicks, { "AnyUp", "AnyDown" })
  T.ok(not b:IsShown(), "hidden while the spec is nil")
  T.eq(wow.ns.Secure.current(), nil)
  T.eq(wow.ns.Secure.pending(), nil)
end)

T.test("the button does not exist before READY; a spec set meanwhile is applied on READY", function()
  local wow = Wow.new():load({ noLogin = true })
  T.eq(wow.env.PortaxiNextButton, nil)
  T.eq(wow.ns.Secure.set(scrollSpec()), false, "queued until the button exists")
  wow:fire("ADDON_LOADED", "Portaxi")
  wow:fire("PLAYER_LOGIN")
  T.eq(attrs(wow.env.PortaxiNextButton), { type = "item", item = "item:213548", unit = "party1" })
end)

T.test("set(item spec) arms type/item/unit, shows it with icon and label", function()
  local wow = client()
  wow.env.C_Item.GetItemIconByID = function(id) return 500000 + id end
  local got = changes(wow)
  local spec = scrollSpec()
  T.eq(wow.ns.Secure.set(spec), true)
  local b = wow.env.PortaxiNextButton
  T.eq(attrs(b), { type = "item", item = "item:213548", unit = "party1" })
  T.ok(b:IsShown())
  T.eq(wow.ns.Secure.ui.icon:GetTexture(), 500000 + SCROLL)
  T.eq(wow.ns.Secure.ui.label:GetText(), "Teleport to Velvet")
  T.ok(wow.ns.Secure.current() == spec)
  T.eq(#got, 1)
  T.ok(got[1].spec == spec)
end)

T.test("set(spell spec) arms type/spell and clears item and unit", function()
  local wow = client()
  local S = wow.ns.Secure
  S.set(scrollSpec())
  S.set(portalSpec())
  local b = wow.env.PortaxiNextButton
  T.eq(attrs(b), { type = "spell", spell = PORTAL_OG })
  T.eq(S.ui.icon:GetTexture(), 100000 + PORTAL_OG, "C_Spell.GetSpellTexture")
  T.eq(S.ui.label:GetText(), "Portal: Orgrimmar")
  T.ok(b:IsShown())
end)

T.test("set(nil) clears the attributes and hides the button", function()
  local wow = client()
  local S = wow.ns.Secure
  local got = changes(wow)
  S.set(scrollSpec())
  T.eq(S.set(nil), true)
  local b = wow.env.PortaxiNextButton
  T.eq(attrs(b), {})
  T.ok(not b:IsShown())
  T.eq(S.current(), nil)
  T.eq(S.ui.label:GetText(), "")
  T.eq(#got, 2)
  T.eq(got[2].spec, nil)
end)

T.test("an invalid spec is refused and changes nothing", function()
  local wow = client()
  local S = wow.ns.Secure
  S.set(portalSpec())
  T.eq({ S.set({ kind = "macro" }) }, { nil, "spec" })
  T.eq({ S.set({ kind = "item" }) }, { nil, "spec" })
  T.eq({ S.set("spell") }, { nil, "spec" })
  T.eq(attrs(wow.env.PortaxiNextButton), { type = "spell", spell = PORTAL_OG })
end)

T.test("in combat set() is queued without touching the button; only the newest spec is applied after", function()
  local wow = client()
  local S = wow.ns.Secure
  local got = changes(wow)
  S.set(scrollSpec())
  wow:setCombat(true)
  T.eq(S.set(nil), false)
  local portal = portalSpec()
  T.eq(S.set(portal), false, "no SetAttribute error in combat")
  local spec, queued = S.pending()
  T.ok(spec == portal and queued == true)
  T.eq(attrs(wow.env.PortaxiNextButton), { type = "item", item = "item:213548", unit = "party1" }, "unchanged")
  T.eq(S.current().kind, "item")
  T.eq(#got, 1, "nothing applied in combat")
  wow:setCombat(false)
  T.eq(attrs(wow.env.PortaxiNextButton), { type = "spell", spell = PORTAL_OG })
  T.ok(S.current() == portal)
  T.eq({ S.pending() }, { nil, false })
  T.eq(#got, 2, "one SECURE_CHANGED for the newest spec")
  T.ok(got[2].spec == portal)
end)

T.test("a nil spec queued in combat is reported and hides the button after combat", function()
  local wow = client()
  local S = wow.ns.Secure
  S.set(portalSpec())
  wow:setCombat(true)
  S.set(nil)
  T.eq({ S.pending() }, { nil, true })
  T.ok(wow.env.PortaxiNextButton:IsShown(), "no Hide in combat")
  wow:setCombat(false)
  T.ok(not wow.env.PortaxiNextButton:IsShown())
  T.eq(attrs(wow.env.PortaxiNextButton), {})
end)

T.test("set() out of combat replaces anything queued", function()
  local wow = client()
  local S = wow.ns.Secure
  wow:setCombat(true)
  S.set(scrollSpec())
  wow.combat = false -- lockdown ended, PLAYER_REGEN_ENABLED not delivered yet
  S.set(portalSpec())
  T.eq({ S.pending() }, { nil, false })
  wow:fire("PLAYER_REGEN_ENABLED")
  T.eq(attrs(wow.env.PortaxiNextButton), { type = "spell", spell = PORTAL_OG })
end)

T.test("a click records the secure action with the armed attributes", function()
  local wow = client()
  wow.ns.Secure.set(scrollSpec())
  wow.env.PortaxiNextButton:Click()
  T.eq(wow.secureClicks[1], { type = "item", item = "item:213548", unit = "party1" })
  wow.ns.Secure.set(portalSpec())
  wow.env.PortaxiNextButton:Click()
  T.eq(wow.secureClicks[2], { type = "spell", spell = PORTAL_OG })
end)

T.test("a Shift-click out of combat does not fire the action and keeps it armed", function()
  local wow = client()
  wow.ns.Secure.set(portalSpec())
  local b = wow.env.PortaxiNextButton
  wow.shift = true
  b:Click()
  T.eq(wow.secureClicks[1].type, nil, "disarmed for the Shift-click")
  T.eq(b:GetAttribute("type"), "spell", "re-armed after it")
  wow.shift = false
  b:Click()
  T.eq(wow.secureClicks[2].type, "spell")
end)

T.test("bindKey sets the override binding, stores the key and clears it", function()
  local wow = client()
  local S = wow.ns.Secure
  T.eq(S.bindKey("f"), true)
  T.eq(wow.env.PortaxiCharDB.nextKey, "F")
  local set = wow:callsTo("SetOverrideBindingClick")
  T.eq(#set, 1)
  T.ok(set[1].args[1] == S.button)
  T.eq({ set[1].args[2], set[1].args[3], set[1].args[4] }, { true, "F", "PortaxiNextButton" })
  local clears = #wow:callsTo("ClearOverrideBindings")
  T.eq(S.bindKey(nil), true)
  T.eq(wow.env.PortaxiCharDB.nextKey, nil)
  T.eq(#wow:callsTo("ClearOverrideBindings"), clears + 1)
  T.eq(#wow:callsTo("SetOverrideBindingClick"), 1, "no new binding")
  T.eq({ S.bindKey("CTRL 1") }, { nil, "key" })
end)

T.test("bindKey refuses in combat and changes nothing", function()
  local wow = client()
  local S = wow.ns.Secure
  S.bindKey("F")
  wow:setCombat(true)
  T.eq({ S.bindKey("G") }, { nil, "combat" })
  T.eq(wow.env.PortaxiCharDB.nextKey, "F")
  T.eq(#wow:callsTo("SetOverrideBindingClick"), 1)
end)

T.test("the saved key is bound again on READY", function()
  local wow = client({ saved = { PortaxiCharDB = { nextKey = "SHIFT-F" } } })
  local set = wow:callsTo("SetOverrideBindingClick")
  T.eq(#set, 1)
  T.eq(set[1].args[3], "SHIFT-F")
end)

T.test("READY in combat creates the button and binds the key after combat", function()
  local wow = Wow.new()
  wow.combat = true
  wow:load({ saved = { PortaxiCharDB = { nextKey = "F" } } })
  T.eq(wow.env.PortaxiNextButton, nil, "no secure frame created in combat")
  T.eq(wow.ns.Secure.set(portalSpec()), false)
  wow:setCombat(false)
  T.ok(wow.env.PortaxiNextButton)
  T.eq(wow.env.PortaxiNextButton:GetAttribute("spell"), PORTAL_OG)
  T.eq(#wow:callsTo("SetOverrideBindingClick"), 1)
end)

T.test("/ptx key sets and clears the key", function()
  local wow = client()
  wow:slash("key ctrl-1")
  T.eq(wow.env.PortaxiCharDB.nextKey, "CTRL-1")
  T.ok(wow.printed[#wow.printed]:find("CTRL%-1"))
  wow:slash("key")
  T.eq(wow.env.PortaxiCharDB.nextKey, nil)
  T.ok(wow.printed[#wow.printed]:find("cleared"))
  wow:setCombat(true)
  wow:slash("key F")
  T.ok(wow.printed[#wow.printed]:find("combat"))
  T.eq(wow.env.PortaxiCharDB.nextKey, nil)
  T.ok(wow.ns.commands.key.help:find("bind a key"))
  T.eq(wow.ns.commands.key.args, "<KEY>")
end)

T.test("the position is saved after a Shift-drag and restored on the next load", function()
  local wow = client()
  local b = wow.env.PortaxiNextButton
  local moved = 0
  rawset(b, "StartMoving", function() moved = moved + 1 end)
  b:GetScript("OnDragStart")(b)
  T.eq(moved, 0, "plain drag does not move")
  wow.shift = true
  wow.combat = true
  b:GetScript("OnDragStart")(b)
  T.eq(moved, 0, "no move in combat")
  wow.combat = false
  b:GetScript("OnDragStart")(b)
  T.eq(moved, 1)
  rawset(b, "GetPoint", function() return "BOTTOM", wow.env.UIParent, "BOTTOM", 220.6, 140.2 end)
  b:GetScript("OnDragStop")(b)
  T.eq(wow.env.PortaxiDB.ui.secure, { point = "BOTTOM", relPoint = "BOTTOM", x = 221, y = 140 })

  local again = Wow.new()
  local points = {}
  local create = again.env.CreateFrame
  again.env.CreateFrame = function(kind, name, parent, template)
    local f = create(kind, name, parent, template)
    if name == "PortaxiNextButton" then
      rawset(f, "SetPoint", function(_, ...) points[#points + 1] = { ... } end)
    end
    return f
  end
  again:load({ saved = { PortaxiDB = { ui = { secure = wow.env.PortaxiDB.ui.secure } } } })
  T.eq(points[1][1], "BOTTOM")
  T.eq({ points[1][3], points[1][4], points[1][5] }, { "BOTTOM", 221, 140 })
end)

T.test("missing or failing icon APIs give the question mark, never an error", function()
  local wow = client()
  local S = wow.ns.Secure
  wow.env.C_Spell = nil
  T.eq(S.set(portalSpec()), true)
  T.eq(S.ui.icon:GetTexture(), "Interface\\Icons\\INV_Misc_QuestionMark")
  T.eq(S.set(scrollSpec()), true, "no C_Item.GetItemIconByID or GetItemIcon in wowstub")
  T.eq(S.ui.icon:GetTexture(), "Interface\\Icons\\INV_Misc_QuestionMark")
  wow.env.GetItemIcon = function() error("boom") end
  T.eq(S.set(scrollSpec()), true)
  T.eq(S.ui.icon:GetTexture(), "Interface\\Icons\\INV_Misc_QuestionMark")
  T.eq(#wow.errors, 0)
end)

T.test("the addon never casts or uses items on its own", function()
  local wow = client()
  wow.ns.Secure.set(scrollSpec())
  wow.ns.Secure.set(portalSpec())
  wow:setCombat(true)
  wow.ns.Secure.set(nil)
  wow:setCombat(false)
  T.eq(#wow.secureClicks, 0)
  T.eq(#wow.errors, 0)
end)

T.done()
