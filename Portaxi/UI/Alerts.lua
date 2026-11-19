-- UI.Alerts: raid warning and sound when a new request this taxi can serve comes in (INCOMING_REQUEST).
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "UI" and "Dispatch" (plan §8 Alerts). Card G, wave 2.
--   Alerts.text(entry) -> "Portaxi: Velvet wants Orgrimmar (Come-to-you, 3g)"
--                         "Portaxi: Velvet wants Orgrimmar (from chat)" for a ChatReq entry (D16)
-- luacheck: read globals RaidNotice_AddMessage RaidWarningFrame ChatTypeInfo PlaySound SOUNDKIT

local _, ns = ...

ns.UI = ns.UI or {}
local A = {}
ns.UI.Alerts = A

local L = ns.L
local W = ns.UI.Widgets

A.SERVICE_SHORT = { COME = "Come-to-you", PICK = "Pickup" }

-- Text of the raid warning for an INCOMING_REQUEST entry { request, svc, price, booked }.
function A.text(entry)
  local request = entry.request or {}
  local city = ns.Const.CITY[request.dest or ""]
  local where = city and L[city.name] or tostring(request.dest)
  if entry.chat then
    return L["Portaxi: %s wants %s (from chat)"]:format(tostring(request.key), where)
  end
  local what = L[A.SERVICE_SHORT[entry.svc] or tostring(entry.svc)]
  local fmt = entry.booked and L["Portaxi: %s booked you to %s (%s, %s)"] or L["Portaxi: %s wants %s (%s, %s)"]
  return fmt:format(tostring(request.key), where, what, W.money(entry.price))
end

function A.show(entry)
  if type(entry) ~= "table" then
    return
  end
  if RaidNotice_AddMessage and RaidWarningFrame then
    RaidNotice_AddMessage(RaidWarningFrame, A.text(entry), ChatTypeInfo and ChatTypeInfo.RAID_WARNING)
  end
  if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
    PlaySound(SOUNDKIT.RAID_WARNING)
  end
end

ns.on("INCOMING_REQUEST", A.show)
