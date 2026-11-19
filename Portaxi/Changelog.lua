-- What's new, newest first (D17). The What's new window shows the entries a player has not seen yet.
-- Each release adds an entry on top. Its version is the "## Version" of Portaxi.toc without any "-dev" suffix;
-- tests/version_test.lua checks that. Items are short plain English sentences for players, not commit messages.

local _, ns = ...

ns.Changelog = {
  {
    version = "0.1.0",
    date = "2026-11-19",
    items = {
      "First public release. Mages only for now; warlock summons come later.",
      "Ride: hail a mage taxi to a capital of your faction, or browse the taxis and book the one you want.",
      "Drive: go on duty as a mage and take rides for gold, as a come-to-you portal or a portal pickup.",
      "Taxis also see portal requests from public chat (\"WTB port Org\") and can invite those players with one click.",
      "Portaxi tells you when a newer version is out, and shows this window after each update. /ptx news opens it.",
    },
  },
}
