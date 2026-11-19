-- UI of Inn hop (D20): the Hop tab, the host toggle on the Ride tab, the host's request popup and the ride panel
-- for svc HOP. Real Detect, Hop and Ride on wowstub; network messages are injected through NET_MSG.
local T = dofile("tests/lib/t.lua")
local Wow = dofile("tests/lib/wowstub.lua")

local WARRIOR = { name = "Hostess", class = "WARRIOR", race = "Orc", zone = "The Barrens", subzone = "The Crossroads",
  spells = {}, items = {}, resting = true }

local function client(player)
  local wow = Wow.new({ player = player })
  wow.env.UISpecialFrames = {}
  wow:load()
  wow:advance(3)
  return wow
end

local function host(wow, key, fields)
  local msg = { type = "HOST", fac = "Horde", lvl = 30, zone = "The Barrens", sub = "The Crossroads", city = "",
    free = true }
  for k, v in pairs(fields or {}) do
    msg[k] = v
  end
  wow.ns.fire("NET_MSG", msg, key, key)
end

local function noErrors(wow)
  T.eq(#wow.errors, 0, "errors: " .. tostring(wow.errors[1]))
end

T.test("the Hop tab shows for a mage with scrolls only; /ptx hop opens it", function()
  local mage = client()
  mage:slash("hop")
  local M = mage.ns.UI.MainFrame
  T.eq(M.tab, "hop")
  T.ok(M.tabButtons.hop:IsShown())
  T.ok(M.pages.hop:IsShown())
  T.eq(M.subtitle:GetText(), "Horde · Inn hop · Mage 40")
  mage:setItem(213548, 0)
  mage:advance(3)
  T.eq(M.tab, "ride", "no scrolls: back to Ride")
  T.ok(not M.tabButtons.hop:IsShown())
  local warrior = client(WARRIOR)
  warrior:slash("hop")
  T.eq(warrior.ns.UI.MainFrame.tab, "ride")
  noErrors(mage)
  noErrors(warrior)
end)

T.test("places with hosts, Hop here sends the request and shows its state; the list redraws on HOST", function()
  local mage = client()
  mage:slash("hop")
  local H = mage.ns.UI.HopTab
  local v = H.view((mage.ns.Detect.current()))
  T.eq(v.status, "Scrolls: 9 · resting: yes")
  T.eq(v.pauses, "")
  T.ok(v.empty)
  host(mage, "Velvet Forever")
  host(mage, "Ola Forever", { zone = "Orgrimmar", sub = "Valley of Strength", city = "OG", lvl = 55 })
  T.ok(H.ui.rows[1]:IsShown(), "redrawn on HOSTS_CHANGED")
  T.eq(H.ui.rows[1].place:GetText(), "Orgrimmar")
  T.eq(H.ui.rows[1].hosts:GetText(), "1 host · Ola Forever (55)")
  T.eq(H.ui.rows[2].place:GetText(), "The Crossroads, The Barrens")
  H.ui.rows[2].go:GetScript("OnClick")()
  T.ok(H.ui.request:GetText():find("^Asking Velvet Forever%.%.%."))
  mage:advance(1) -- Net's queue
  local hop = mage.sent[#mage.sent]
  T.eq(hop.kind, "WHISPER")
  T.eq(hop.target, "Velvet Forever")
  T.ok(hop.msg:find("^HOP|1|"))
  T.eq(H.view((mage.ns.Detect.current())).places[1].enabled, false, "no second request meanwhile")
  local reqId = mage.ns.Hop.status().request.reqId
  mage.ns.fire("NET_MSG", { type = "HOPNO", reqId = reqId, why = "declined" }, "Velvet Forever", "Velvet Forever")
  T.eq(H.ui.request:GetText(), "Velvet Forever declined.")
  H.ui.rows[2].go:GetScript("OnClick")()
  T.eq(H.ui.request:GetText(), "You asked this host a moment ago. Try another one or wait a minute.")
  noErrors(mage)
end)

T.test("pauses in words when the mage cannot hop", function()
  local mage = client()
  mage:setResting(false)
  mage:advance(3)
  local v = mage.ns.UI.HopTab.view((mage.ns.Detect.current()))
  T.eq(v.pauses, "Rest in an inn or a city first: the scroll needs both of you resting.")
  -- in-game 2026-11-19: Ask stayed grey on the way to the inn; asking is fine without resting
  local fl = { list = { { fullName = "Zorg Axehand", level = 22, classStr = "Warrior", area = "Crossroads" } } }
  mage.env.C_FriendList = {
    SendWho = function() end,
    GetNumWhoResults = function() return #fl.list, #fl.list end,
    GetWhoInfo = function(i) return fl.list[i] end,
  }
  mage.ns.Who.search("The Barrens")
  mage:fire("WHO_LIST_UPDATE")
  v = mage.ns.UI.HopTab.view((mage.ns.Detect.current()))
  T.eq(v.who[1].enabled, true, "Ask works while not resting")
  T.eq(v.places, {})
  mage:setItem(213548, 0)
  mage:advance(3)
  T.eq(mage.ns.UI.HopTab.view((mage.ns.Detect.current())).who[1].enabled, false, "not without scrolls")
  noErrors(mage)
end)

T.test("/who fallback: Search sends the zone, results listed with Ask", function()
  local mage = client()
  local fl = { sent = {}, list = {} }
  mage.env.C_FriendList = {
    SendWho = function(f) fl.sent[#fl.sent + 1] = f end,
    GetNumWhoResults = function() return #fl.list, #fl.list end,
    GetWhoInfo = function(i) return fl.list[i] end,
  }
  mage:slash("hop")
  local H = mage.ns.UI.HopTab
  H.ui.zone:SetText("The Barrens")
  H.ui.search:GetScript("OnClick")()
  T.eq(fl.sent, { 'z-"The Barrens"' })
  fl.list = { { fullName = "Zorg Axehand", level = 22, classStr = "Warrior", area = "The Barrens" } }
  mage:fire("WHO_LIST_UPDATE")
  T.ok(H.ui.whoRows[1]:IsShown())
  T.eq(H.ui.whoRows[1].text:GetText(), "Zorg Axehand · 22 Warrior · The Barrens")
  H.ui.whoRows[1].ask:GetScript("OnClick")()
  T.eq(H.ui.whoRows[1].ask:GetText(), "Asked")
  T.ok(H.ui.whoNote:GetText():find("accept the invite yourself", 1, true))
  noErrors(mage)
end)

T.test("host toggle on the Ride tab; the request popup with Accept starts the host's HOP ride", function()
  local wow = client(WARRIOR)
  wow:slash("show")
  local R = wow.ns.UI.RideTab
  T.eq(R.ui.host:GetText(), "Hosting: off")
  R.ui.host:GetScript("OnClick")()
  T.eq(R.ui.host:GetText(), "Hosting: on")
  T.eq(wow.ns.Hop.hosting(), true)
  wow:advance(1) -- Net's queue
  T.ok(wow.sent[#wow.sent].msg:find("^HOST|1|Horde|40|The Barrens|The Crossroads||1"))

  wow.ns.fire("NET_MSG", { type = "HOP", reqId = "Thalindra Forever:h7", lvl = 42 }, "Thalindra Forever",
    "Thalindra Forever")
  local popup = wow.env.PortaxiHopRequest
  T.ok(popup and popup:IsShown(), "popup shown")
  T.eq(popup.text:GetText(),
    "Thalindra Forever (mage, level 42) wants to teleport to you with a scroll. Stay rested until they arrive.")
  T.eq(popup.left:GetText(), "Answer within 30 s.")
  wow:advance(5)
  T.eq(popup.left:GetText(), "Answer within 25 s.")
  popup.accept:GetScript("OnClick")()
  T.ok(not popup:IsShown())
  local r = wow.ns.Ride.current()
  T.eq({ r.svc, r.role, r.peer.key }, { "HOP", "rider", "Thalindra Forever" })
  local v = wow.ns.UI.RidePanel.view()
  T.eq({ v.title, v.sub, v.peerKey, v.service, v.price }, { "Hosting a hop", "You host", "Mage", "Inn hop", "free" })
  T.eq({ v.steps[3].text, v.steps[4].text, v.steps[5].text },
    { "The mage teleports to you", "Arrive", "The mage leaves" })
  noErrors(wow)
end)

T.test("Decline answers HOPNO and closes the popup; no answer closes it after T.HOP_ANSWER", function()
  local wow = client(WARRIOR)
  wow.ns.Hop.setHosting(true)
  wow.ns.fire("NET_MSG", { type = "HOP", reqId = "A:1", lvl = 30 }, "Aaron Forever", "Aaron Forever")
  local popup = wow.env.PortaxiHopRequest
  popup.decline:GetScript("OnClick")()
  T.ok(not popup:IsShown())
  wow:advance(1)
  local found = false
  for _, s in ipairs(wow.sent) do
    if s.msg == "HOPNO|1|A:1|declined" then found = true end
  end
  T.ok(found, "HOPNO declined sent")
  wow.ns.fire("NET_MSG", { type = "HOP", reqId = "B:1", lvl = 30 }, "Bert Forever", "Bert Forever")
  T.ok(popup:IsShown())
  wow:advance(31)
  T.ok(not popup:IsShown(), "closed after the timeout")
  noErrors(wow)
end)

T.done()
