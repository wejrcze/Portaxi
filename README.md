# Portaxi

A player-run taxi network for **WoW Forever**. Mages offer portals for gold; anyone else hails a ride.

There is no server and no website. Every player's Portaxi talks to the others over a hidden chat channel
(`PortaxiNet`): taxis announce what they offer, riders send requests, and the two addons agree on a ride
between themselves.

> Status: MVP, version `0.1.0`. Mages only for now; warlock summons come later.

## Requirements

- The WoW Forever client (interface `16001`).
- For driving: a mage with at least one city portal learned, and Runes of Portals in the bags.

## Installation

On CurseForge the addon is called **ForeverPortaxi**:
[curseforge.com/projects/1816274](https://www.curseforge.com/projects/1816274). In the CurseForge app pick the
*Forever* flavour and install it from there. In game it shows as ForeverPortaxi; its folder stays `Portaxi`.

By hand:

1. On GitHub click **Code → Download ZIP** and unpack it. Copy the inner `Portaxi` folder (the one with
   `Portaxi.toc` in it, not `Portaxi-main`) into `World of Warcraft\_forever_\Interface\AddOns\`
   (you should end up with `...\Interface\AddOns\Portaxi\Portaxi.toc`).
2. Restart the game client (a `/reload` is not enough for a new addon).
3. Type `/ptx show` or click the Portaxi button at the minimap.

## Riding (any class)

Open the window and stay on the **Ride** tab.

1. **Check the "Read by the addon" block**: faction, character, place, whether you are resting, and your gold.
2. **Pick a city.** The tiles show the cities of your faction, with the cheapest offer ("from ...") and how many
   taxis serve it.
3. **Hail or Browse.**
   - **Hail**: set **your maximum** and click *Hail a taxi*. Every taxi that serves the city at or below your
     maximum can take it. Portaxi collects answers for 3 seconds after the first one and picks the fastest taxi;
     taxis within 15 seconds of each other count as a tie, and the one that has waited longest for a ride wins.
     You pay **that taxi's own price**, not your maximum.
   - **Browse**: a list of taxis for the city, cheapest first. Click *Book* on the one you want; it waits for
     that taxi to accept.
   A request stays open for 2 minutes. *Cancel* withdraws it.

You cannot hail or book for more gold than you carry, while you are in a group (the taxi has to invite you), or
to the city you are already in.

### The ride

A small ride panel opens with the steps, a cast bar, notes and the buttons you need.

1. **Group.** The taxi invites you. Portaxi accepts the invite for you, but only from the taxi you were matched
   with. If that does not work on your client, an *Accept* button appears.
2. **Travel.**
   - **Come-to-you portal**: the taxi uses a *Scroll of Liminal Passage* on you and appears next to you. This
     is only offered while you are resting (inn or city), and you must stay there until the taxi arrives.
   - **Portal pickup**: you walk to the taxi. The ride moves on when you are within trade range.
3. **Trade.** The taxi's addon opens the trade window. **Type the price into the trade window yourself**
   (the panel tells you the amount; Forever does not allow addons to set trade gold). Both of you click *Trade*.
4. **Portal.** Only after the taxi's addon has seen your gold arrive does it let the taxi open the portal.
   Step through it; the ride ends when you arrive in the city. If you miss the portal, the taxi can open a
   second one at no extra cost.

## Driving (mages)

The **Drive** tab appears when your character can drive.

### What the addon detects

- Which portals of your faction you know, your Runes of Portals, your Scrolls of Liminal Passage, and whether
  you are resting.
- From that, what you offer right now:
  - **Portal pickup** needs a learned portal and a Rune of Portals.
  - **Come-to-you portal** also needs a Scroll of Liminal Passage and you resting (inn or city).
- If something is paused, the tab says why (for example "Come-to-you paused: you're not resting").

### Prices and duty

- Set a price per service (10s to 50g; defaults 3g for Come-to-you and 1g 50s for Pickup). New prices go out
  with your next heartbeat on the network.
- Click **Go on duty**. While on duty your addon announces your offer about once a minute; **Go off duty** says
  goodbye. Duty stays on after a `/reload`.
- During a ride you are not offered to other riders.

### Taking requests

- A new request you can serve shows a **raid warning with a sound**. Requests are listed under *Open requests*;
  bookings addressed to you come first ("booked you").
- Click **Take**. You can have one answer pending at a time; the rider confirms within 10 seconds or you are
  free again.
- **Players without Portaxi.** While you are on duty, Portaxi also reads say, yell, whispers and the public
  channels. A request for a portal to a city you serve, in English or Russian ("WTB port Org", "need portal to
  UC?", "куплю порт в орг"), is listed with a blue stripe, *(chat)* and the start of the message. Sellers' ads
  ("WTS portals ...") are ignored. Click **Invite**: Portaxi invites the player and whispers the city and your
  price (pickup, or come-to-you if you only offer that) in English or Russian. The rest of the ride is up to you:
  there is no ride panel and no payment check. Such a request stays listed for 2 minutes; `/ptx chat` turns
  reading chat off and on.
- The **duty box** is a small movable box shown while you are on duty: your services and prices (or why they
  are paused), the number of open requests, the best one with a *Take* button, and an *Off* button. Click its
  title to open the Drive tab. `/ptx box` locks or unlocks it, or shows it again after you closed it with *x*.

### The Portaxi button

Portaxi never casts for you. When there is something to cast, it prepares the **Portaxi button**
(`PortaxiNextButton`) and you click it:

- Come-to-you: the scroll, aimed at the rider (only while both of you are resting).
- After payment: the portal to the rider's city.

Bind a key with `/ptx key F` (any key, e.g. `CTRL-1`); `/ptx key` alone clears it. A macro works too:
`/click PortaxiNextButton`. Shift-drag moves the button. In combat it cannot change; it catches up after combat.

### The ride panel

The same panel as for riders: steps, the rider's resting state, the cast bar, what the Portaxi button is ready
for, warnings such as "The rider offers 1g of 3g. Do not accept yet.", and the fallback buttons *Invite* and
*Open trade* if your client blocks the automatic step. After the ride, Portaxi leaves the two-person group
it formed.

## Fair play

- **Cancel for free** until the travel starts. A rider who cancels a Come-to-you ride after the scroll was used
  and before paying makes a **late cancel**. In this version it is only recorded on the rider's own computer;
  nothing is shared or charged. A pickup cancel is never late.
- A taxi can cancel before travelling, while waiting for a pickup rider to walk over, and while waiting for the
  payment; not during the scroll cast and not once paid.
- **Timeouts**: the group must form within 60 seconds; the payment must arrive within 3 minutes of meeting,
  otherwise the ride fails on both sides. A ride also fails when the other player goes offline or leaves the
  group.
- **The portal comes only after payment.** The taxi's addon compares its gold before and after the trade.

## Updates and What's new

Portaxi has no server, so the addons tell each other which version they run. About 10–20 seconds after login
your Portaxi says its version on the hidden channel; a player with a newer version answers. When someone on the
network runs a newer release than you, Portaxi prints one line in chat: *Version X is available (you have Y).*
Update the addon then (CurseForge, or the zip from GitHub). Nothing is downloaded or installed by the addon
itself. `/ptx version` shows your version and the newest one seen this session.

After an update, a **What's new** window opens a few seconds after login with the changes since the version you
had before. A new player does not get it. `/ptx news` opens it again with the whole history.

## What Portaxi does on its own, and what it never does

On its own it:

- reads your character (class, portals, runes, scrolls, resting, place, gold) and talks on the hidden channel,
  including its version number;
- sends the party invite (taxi), and accepts the invite of the matched taxi and nobody else (rider);
- reads public chat for taxi requests while you are on duty (it invites and whispers only when you click *Invite*);
- opens the trade window with your matched partner (taxi);
- leaves the two-person ride group after the ride (taxi).

It never:

- casts a spell or uses an item: you click the Portaxi button;
- accepts a trade: you click *Trade*;
- puts gold into the trade: you type it (Forever forbids addons to set trade gold).

## Commands

`/ptx` (or `/portaxi`) alone lists the commands.

| Command | What it does |
|---|---|
| `/ptx show` | Open or close the Portaxi window. |
| `/ptx box` | Lock or unlock the duty box, or show it again after you closed it. |
| `/ptx chat` | Turn reading taxi requests from public chat on or off (on by default). |
| `/ptx key <KEY>` | Bind a key to the Portaxi button; without a key, clear it. |
| `/ptx ride [cancel]` | Show the active ride, or cancel it. |
| `/ptx version` | Show your version and the newest one seen on the network. |
| `/ptx news` | Open the What's new window. |
| `/ptx detect` | Show what the addon detects on this character. |
| `/ptx netstat` | Show the network state (joined, channel, queue, messages sent/received/dropped). |
| `/ptx diag` | Check what the addon can read on this character and save it for a bug report. |

Test tools from the development phase (they log to `PortaxiDB.probe`; you do not need them to ride or drive):

| Command | What it does |
|---|---|
| `/ptx net` | Join the channel and ping it; other Portaxi players answer. |
| `/ptx invite <name>` | Invite a player from a timer. |
| `/ptx accept` | Accept the next party invite automatically, once. |
| `/ptx opentrade` | Open a trade with your target from a timer. |
| `/ptx trade <copper>` | Try to set gold in the next trade through the API (forbidden on Forever). |
| `/ptx tradefield <copper>` | Try to fill the trade window's gold field in the next trade (forbidden on Forever). |
| `/ptx probe [clear]` | Show the last test results, or clear them. |

## Known limitations

- **Mages only.** Warlock summons, "name a price", auto-take, ratings and late-cancel fees are planned for later.
- **You type the trade gold yourself.** Forever lets no addon set or fill trade gold (tested in game).
- **Not verified in game yet**: accepting the invite automatically, two players with Portaxi on a full ride,
  whether the channel is shared between factions (Portaxi filters by faction anyway), the Alliance portal
  spells, the cast time and rules of the Scroll of Liminal Passage, and the requests from chat (the sender name
  format in chat and the invite whisper).
- English interface only. The end of a ride is detected by the English city name, so other client languages
  may not finish a ride on their own.
- Thunder Bluff portals are learned at level 50.

## License

MIT, see [LICENSE](LICENSE).
