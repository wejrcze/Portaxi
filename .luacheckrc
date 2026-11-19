-- luacheck config for the Portaxi addon (WoW Forever, Lua 5.1). Owned by the architect.
-- Agents declare new WoW globals inline at the top of their own file (playbook D6):
--   -- luacheck: read globals GetTime UnitName
std = "lua51"
max_line_length = 120
exclude_files = { "Portaxi/Libs/**", "tools/**" }

-- Globals the addon writes.
globals = {
  "PortaxiDB",
  "PortaxiCharDB",
  "SlashCmdList",
  "SLASH_PORTAXI1",
  "SLASH_PORTAXI2",
}

-- WoW API used by the architect's files (Init, Const, Probe) and common to every module.
read_globals = {
  "date",
  "geterrorhandler",
  "CreateFrame",
  "GetTime",
  "UIParent",
  -- Core/Probe.lua
  "AcceptGroup",
  "C_ChatInfo",
  "C_PartyInfo",
  "C_Timer",
  "C_TradeInfo",
  "GetBuildInfo",
  "GetChannelName",
  "GetMoney",
  "GetNumGroupMembers",
  "GetPlayerTradeMoney",
  "GetSubZoneText",
  "GetTargetTradeMoney",
  "GetZoneText",
  "InitiateTrade",
  "IsInGroup",
  "IsResting",
  "JoinTemporaryChannel",
  "StaticPopup_Hide",
  "TradePlayerInputMoneyFrame",
  "UnitClass",
  "UnitExists",
  "UnitFactionGroup",
  "UnitIsPlayer",
  "UnitLevel",
  "UnitName",
  "UnitRace",
}
-- Forever is a modern client: GetItemCount, GetContainer*, GetCoinTextureString are missing.
-- Resolve uncertain APIs at runtime with ns.api("C_X.Fn", "Fn") instead of calling the globals.
