-- What's new, newest first (D17). The What's new window shows the entries a player has not seen yet.
-- Each release adds an entry on top. Its version is the "## Version" of Portaxi.toc without any "-dev" suffix;
-- tests/version_test.lua checks that. Items are short plain English sentences for players, not commit messages.

local _, ns = ...

ns.Changelog = {
  {
    version = "0.3.0",
    date = "2026-11-19",
    items = {
      "Inn hop: a mage with a Scroll of Liminal Passage can hop to any inn or city where a host rests. "
        .. "Open the Hop tab (/ptx hop), click Hop here, and the host accepts with one click.",
      "Anyone can host mage travellers: switch on Hosting on the Ride tab while you rest. "
        .. "It is free and off by default.",
      "No host there? The Hop tab searches a town with an inn by /who and asks the players there for an invite.",
      "Come-to-you: the taxi opens the trade only once the scroll really brought it to you. "
        .. "If the scroll fails (the rider is not resting), the taxi can try again.",
      "Taxis on the map: Browse keeps the distance current while you walk.",
    },
  },
  {
    version = "0.2.0",
    date = "2026-11-19",
    items = {
      "During a ride, a small arrow points to the other player with their name and distance. "
        .. "Drag it to move it, right-click hides it; /ptx arrow turns it off.",
      "Ride: Browse also lists mages who advertise portals in public chat without Portaxi. "
        .. "Invite asks them for your city with one click, Where? finds them with /who.",
      "Drive: switch on Map in the duty box (or /ptx field) while levelling. "
        .. "Riders out in the world near you then see you on their world map and can book a pickup.",
      "Ride: out in the world, taxis near you come first in Browse with the distance, and as pins on your world map.",
    },
  },
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
