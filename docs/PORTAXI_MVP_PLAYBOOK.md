# Portaxi — playbook MVP (víc agentů, jeden architekt)

Jak postavit MVP z `docs/PORTAXI_MVP_PLAN.md`. Plán říká **co** a **proč**, playbook říká **kdo, v jakém pořadí a s jakými rozhraními**.

Práce běží ve vlnách:

- **Architekt** je hlavní session. Drží rozhraní, soubory sdílené všemi moduly, merge a brány (kontroly na konci vlny).
- **Implementační agenti** běží souběžně, každý ve vlastním git worktree a na vlastní větvi.
- Agent smí měnit **jen soubory ze své karty** (§5).

---

## 0. Výchozí stav

| Hotovo | Kde |
|---|---|
| Repo, junction do hry, `check.ps1`, Lua 5.1 + luacheck | `tools/` |
| `/ptx diag` a zjištění fáze 0: klient 1.60.1, build 70959, interface 16001; ID portálů, runy a scrollu; `C_` API | `Core/Init.lua`, plán §2 |
| Sondy fáze 0 (`/ptx net`, `invite`, `accept`, `opentrade`, `trade`) | `Core/Probe.lua` |
| Kanál `PortaxiNet`: odeslání funguje a server vrátí zprávu i odesílateli. Odesílatel přichází jako `"Jméno Příjmení"`. | plán §2 bod 0.3, §5 |

**Druhý hráč zatím není.** Neověřené body jsou:

- 0.3: příjem zprávy u jiného hráče,
- 0.4: oddělení kanálu podle frakce,
- 0.5–0.9: pozvánka, přijetí, trade a zlato bez kliknutí.

Důsledky pro tento playbook:

1. Celý průběh jízdy se ověřuje **offline v simulátoru dvou a více klientů** (§3).
2. Ve hře kontroluje uživatel jen to, co zvládne jedna postava (§7).
3. Každý neověřený bod má v kódu **automatickou cestu i ruční zálohu**. O tom, která se použije, rozhoduje addon za běhu (rozhodnutí D11).

Před vlnou 0 se commitne rozpracovaná práce na sondách.

**Vlna 0 hotová (2026-11-18):** `Init` (události, `api`, `playerKey`, výchozí SavedVariables, `READY`), `Const`, `Locales/enUS.lua`, diagnostika přesunutá do `Probe.lua`, prázdné moduly a kompletní TOC, `.gitattributes`, `tests/` (framework, `wowstub`, 32 testů) a `check.ps1` (spouští i testy a kontroluje TOC). **Brána G0 prošla (2026-11-18 19:21):** addon 0.1.0-dev se po restartu načetl celý, `PortaxiDB` i `PortaxiCharDB` mají výchozí hodnoty, `/ptx diag` sedí (Horde mág 41, OG + UC, 7 run, 9 scrollů) a v BugGrabberu není žádná nová chyba Portaxi.

**Brána G3 prošla (2026-11-18 21:06):** po restartu se načetly všechny erby (vybraný barevný se zlatým prstencem, ostatní šedé), pilulky, karta detekce s erby, ceny, box na směně, titulek s portrétem a „0 taxis online“; žádná nová chyba v BugGrabberu. `/ptx tradefield` s hráčem: pole okna tradu je pro addon zakázaný objekt → `FILL_MONEY_FIELD` zůstává `false`, bod 0.8 uzavřen. **Vlny 0–3 jsou hotové; zbývá G-final se dvěma hráči s addonem.**

**Vlna 3 hotová (2026-11-18):** karta J (erby měst jako TGA z makety přes `tools/make-emblems.mjs`, `ring`/`glow`/`portal` textury, vzhled všech oken podle makety v0.8, úplný `enUS.lua` s testem klíčů, text pro každý důvod konce jízdy) a karta K (`README.md` pro hráče, `docs/PHASE0_FINDINGS.md`, aktualizovaný plán). Architekt: řídicí znaky v Protocol, plán sladěný s kódem (předvyplnění, storna, auto-take ve fázi 2). 27 testovacích souborů, 347 testů. Brána G3 čeká: **nové textury vyžadují restart klienta.**

**Vlna 2 a brána G2 (2026-11-18 20:31):** karty G, H, I spojené, integrace se scénářem 4 a code review (10 oprav). Ve hře: detekce místa za pohybu ✓, box na směně ✓ (pozice uložena), klávesa F ✓. Se skutečným hráčem (Varekhal Stonefel, addon neměl): pozvánka z timeru ✓ (0.5), trade z timeru ✓ (0.7), `SetTradeMoney` zakázané ✗ (0.8). Opraveno: přiřazení zablokování podle běžícího volání, pozvánka celým jménem, předvyplnění vypnuté. Zbývá: `/ptx tradefield`, přijetí pozvánky (0.6), test se dvěma hráči s addonem.

**Vlna 1 hotová (2026-11-18):** karty A–F spojené do `main` (6 commitů), integrace: oprava testu v `net_test`, doplňky `wowstub`, ID kouzla svitku v `/ptx diag`, `tests/integration_test.lua`. 11 testovacích souborů, 165 testů, `check.ps1` zelený. **Brána G1 (2026-11-18 19:44):** okno, záložky, detekce, ceny, směna a pozice okna i tlačítka u minimapy fungují. Nalezená chyba: Forever nezná událost `LEARNED_SPELL_IN_TAB`. `RegisterEvent` vyhodil chybu a zbylé události Detect se nezaregistrovaly („Place: unknown“, odpočinek se neobnovoval). Opraveno: registrace po jedné přes `pcall`, událost vyřazena a `wowstub` ji teď odmítá stejně jako hra. ID kouzla svitku `434752` je v `Const`. Požadavek uživatele: malý přesouvatelný box na směně → karta G (`UI/DutyBox.lua`, v TOC). Ověřit znovu při G2: místo a odpočinek se mění za pohybu.

---

## 1. Rozhodnutí architekta (platí pro všechny agenty)

| # | Rozhodnutí | Proč |
|---|---|---|
| D1 | **V MVP žádné externí knihovny** (Ace3, ChatThrottleLib, LibDBIcon). Vlastní: event bus, fronta odesílání, tlačítko u minimapy, prosté SavedVariables. | Zprávy mají pod 255 B, takže dělení zpráv netřeba. Odpadne stahování, licence a riziko, že agent přinese špatnou verzi. Plán §3 je upravený. |
| D2 | Moduly žijí v `ns` (`ns.Protocol`, `ns.Market`, …). Vlastní globály jsou jen `PortaxiDB`, `PortaxiCharDB`, `SLASH_*` a jména rámců, která musí být globální (`PortaxiNextButton`, hlavní okno). | Žádné kolize s jinými addony. |
| D3 | **Čisté moduly** nevolají herní API a čas dostávají parametrem `now`. Jsou to `Protocol`, `Market`, jádro `Ride` (stavový automat), `Detect.services`, `Trade.verify`. Každý má testy v `tests/`. | Jde je testovat offline. |
| D4 | API, u kterých není jisté, že na Forever existují, se volají přes `ns.api("C_X.Fn", "Fn")` (z `Init`). Varianta s `C_` má přednost. | Forever je moderní klient a klasické globály chybí. |
| D5 | Klíč hráče je `ns.playerKey(sender)` = celé `"Jméno Příjmení"` (Forever nemá realmy, jedinečná je jen dvojice). Whisper a pozvánka jdou na celý řetězec odesílatele. Vlastní ozvěnu z kanálu `Net` zahodí (`ns.selfKey()`). | Ověřeno ve hře 2026-11-18 (`/ptx diag`, G2). Původně „jméno před mezerou“, opraveno. |
| D6 | Nové herní globály agent deklaruje **v hlavičce svého souboru**: `-- luacheck: read globals GetTime UnitName`. `.luacheckrc` patří architektovi. | Agenti si neperou jeden soubor. |
| D7 | **TOC je od vlny 0 kompletní**: všechny soubory MVP, zatím jako prázdné moduly. | Nový soubor v TOC vyžaduje restart klienta. Takhle stačí jeden. |
| D8 | Agent mění jen soubory ze své karty. Potřebuje-li změnu jinde, napíše ji do reportu jako „Požadavky na architekta“. | Žádné konflikty při merge. |
| D9 | Kód, komentáře a commity jsou anglicky, dokumenty v `docs/` česky. | Stejně jako dosud. |
| D10 | Addon nikdy sám nesesílá kouzlo, nepoužije předmět a nepotvrdí trade. Připraví jen secure tlačítko. Přijetí pozvánky je povolené jen od spárovaného taxíka (plán 0.6). | `CLAUDE.md`. |
| D11 | **Schopnosti s fallbackem.** Automatická pozvánka, přijetí, otevření tradu a předvyplnění zlata se zkusí automaticky. Když přijde `ADDON_ACTION_BLOCKED`, chyba nebo timeout, addon přepne na ruční tlačítko a zapamatuje si to v `PortaxiDB.caps`. | Body 0.5–0.8 nejde teď ve hře ověřit. |
| D12 | Nový soubor `Core/Dispatch.lua`: logika mezi sítí a trhem (časovač `HELLO`, zpracování `HAIL`/`BOOK`/`TAKE`/`CONFIRM`/`GONE`). | Plán neříkal, kde tahle logika bude. `Market` zůstává čistý modul. |
| D13 | Ikony měst jsou v MVP **ikony portálových kouzel** (`C_Spell.GetSpellTexture`), šedé přes `SetDesaturated`. Vlastní erby až ve vlně 3. | Agenti neumí bez dalších nástrojů vyrobit TGA. |
| D14 | **Žádný `Bindings.xml`.** Secure tlačítko je globální `PortaxiNextButton`. Hráč ho spustí makrem `/click PortaxiNextButton`, nebo klávesou z nastavení addonu přes `SetOverrideBindingClick` (mimo boj). | Chybný `Bindings.xml` rozbije načtení addonu a jeho změna vyžaduje restart klienta. |
| D15 | Moduly startují z `ns.on("READY", Module.start)`. `READY` přichází na `PLAYER_LOGIN`, kdy jsou SavedVariables už naplněné výchozími hodnotami. Moduly startují v pořadí TOC. | Jedno místo startu, předvídatelné pořadí. |
| D16 | **Žádosti z veřejného chatu** (přání uživatele 2026-11-19). Na směně addon čte say, yell, whisper a číslované kanály (kromě `PortaxiNet`). Čistý modul `Core/ChatParse.lua` pozná žádost o portál nebo summon anglicky i rusky („WTB port Org“, „куплю порт в орг“) a odliší nabídky prodejců. `Core/ChatReq.lua` drží seznam žádostí do měst, kam taxík umí, `Const.T.CHAT_REQUEST` sekund. Žádost se v seznamu ukáže s modrým proužkem a tlačítkem *Invite*. Klik (hardwarová událost hráče) pošle `C_PartyInfo.InviteUnit` a whisper s městem a cenou (pickup, jinak come-to-you) v jazyce žádosti. Dál jízda běží ručně: bez Ride, bez kontroly platby. Summon se zatím jen rozpozná; zobrazí se až s warlocky. Vypíná a zapíná se příkazem `/ptx chat` (`PortaxiCharDB.chatRequests`). | Taxík obslouží i hráče bez addonu. Pozvánka a whisper jdou jen z kliknutí. |

---

## 2. Rozhraní modulů

Mění je jen architekt. Agent na ně nesmí sahat. Když nesedí, napíše to do reportu.

### Init (architekt, vlna 0)

```lua
ns.say(msg)                          -- chat line with the Portaxi prefix
ns.api(path1, path2, ...) -> fn|nil  -- first existing function by path
ns.hasApi(path) -> bool
ns.playerKey(sender) -> "Name"       -- D5
ns.on(event, fn) -> handle ; ns.off(handle) ; ns.fire(event, ...)   -- internal bus, sync, errors isolated per listener
ns.commands[name] = { fn = function(args), args = "<x>", help = "..." }  -- /ptx subcommands
ns.now() -> GetTime()                -- the only time source glue code uses
ns.fillDefaults(dst, defaults)       -- recursive, existing values win
ns.L[key] -> text                    -- Locales/enUS.lua; returns the key until wave 3
-- Lifecycle: ADDON_LOADED fills SavedVariables; PLAYER_LOGIN fires "READY" (D15).
-- SavedVariables, defaults filled on ADDON_LOADED:
PortaxiDB     = { version = 1, ui = { pos, minimap = { angle } }, caps = {}, diag, probe }
PortaxiCharDB = { prices = { COME = 30000, PICK = 15000 }, onDuty = false, respTimes = {}, lastRideAt = 0, lateCancels = {} }
```

### Interní události (`ns.fire`)

| Událost | Argumenty | Kdo posílá |
|---|---|---|
| `READY` | — | Init (na `PLAYER_LOGIN`) |
| `PROFILE_CHANGED` | profile, services | Detect |
| `NET_MSG` | msg, key, rawSender, via (`"CHANNEL"`/`"WHISPER"`) | Net |
| `MARKET_CHANGED` | — | Dispatch |
| `HAIL_RESULT` | reqId, winner or nil | Dispatch |
| `INCOMING_REQUEST` | request | Dispatch (taxík: nová poptávka, kterou umí splnit); ChatReq (žádost z chatu, `entry.chat = true`, D16) |
| `CHAT_REQUESTS_CHANGED` | — | ChatReq (seznam žádostí z chatu se změnil, D16) |
| `RIDE_STARTED` / `RIDE_STATE` | ride | Ride |
| `TRADE_PAID` | reqId, copper | Trade (taxík) |
| `TRADE_MANUAL` | what (`"open"`/`"prefill"`/`"short"`), … | Trade (RidePanel ukáže ruční krok) |
| `SECURE_CHANGED` | spec or nil | Secure |
| `CAPS_CHANGED` | caps | kdokoli, kdo mění `PortaxiDB.caps` |

### Const (architekt, vlna 0)

Zdroj pravdy je `Portaxi/Core/Const.lua`. Tvar:

```lua
ns.Const = {
  PREFIX = "PTX", CHANNEL = "PortaxiNet", PROTO = 1,
  CITY = { OG = { name = "Orgrimmar", faction = "Horde", spell = 11417 }, UC = ..., TB = ..., SW = ..., IF = ..., DN = ... },
  CITY_ORDER = { "OG", "UC", "TB", "SW", "IF", "DN" },  -- iterate in this order
  ITEM = { RUNE_OF_PORTALS = 17032, LIMINAL_SCROLL = 213548, SOUL_SHARD = 6265 },
  SPELL = { RITUAL_OF_SUMMONING = 698 },
  PRICE = { MIN = 1000, MAX = 500000 },                  -- copper, 10s..50g
  T = { OFFER = 150, REQUEST = 120, COLLECT = 3, CONFIRM = 10, INVITE = 60, PORTAL = 60,
        HELLO = 60, HELLO_JITTER = 10, HAIL_COOLDOWN = 10, DEBOUNCE = 2 },
  HAIL_TIE = 15, ETA_PICK = 600,
  SECURE_BUTTON = "PortaxiNextButton",                    -- D14
}
```

### Detect (agent C)

```lua
Detect.read(api) -> profile            -- api: table of functions (tests pass fakes), names below
-- api = { UnitFactionGroup, UnitRace, UnitClass, UnitLevel, IsResting, GetZoneText, GetSubZoneText, GetMoney,
--         IsSpellKnown(id), GetItemCount(id), GetBestMapForUnit(unit) }   -- Detect.start builds it via ns.api
-- profile = { faction, race, class, level, resting, zone, subzone, mapId, money,
--             portals = { OG = true, ... }  -- only cities of the own faction whose portal is known
--             runes, scrolls, shards }
Detect.services(profile) -> services   -- pure
-- services = { canDrive, COME, PICK, dests = { "OG", "UC" } (CITY_ORDER), pauses = { ... } }
--   canDrive = MAGE with >= 1 portal; PICK = canDrive and runes > 0; COME = PICK and scrolls > 0 and resting
--   pauses: reasons why a service is off, from { "NOT_MAGE", "NO_PORTAL", "NO_RUNE", "NO_SCROLL", "NOT_RESTING" }
Detect.start()                         -- on READY: read now, fire PROFILE_CHANGED; game events -> debounce T.DEBOUNCE
                                       -- -> read again -> fire only if something changed
Detect.current() -> profile, services  -- nil before start
```

### Protocol (agent A, čistý)

```lua
Protocol.encode(msg) -> str | nil, err   -- err: "type" | "field" | "range" | "too_long"
Protocol.decode(str) -> msg | nil, err   -- err: "format" | "version" | "type" | "field" | "range"
Protocol.FIELDS[type] -> ordered list of field names (wire order)
```

Dekódovaná zpráva je tabulka s `type` a poli níže. `encode` bere stejný tvar. Na drátě je `TYPE|1|f1|f2|…` v pořadí polí, celé max 255 B.

| type | pole (pořadí na drátě) |
|---|---|
| `HELLO` | `fac` str, `cls` str, `lvl` int, `place` str, `dests` list of city keys, `ask` map svc→copper (nabízené služby = klíče), `resp` int s (průměrná reakce), `wait` int s (od poslední jízdy) |
| `BYE` | — |
| `HAIL` | `reqId` str, `fac` str, `dest` city key, `svcs` list of svc, `max` copper, `rest` bool |
| `BOOK` | `reqId`, `dest`, `svc`, `price` copper |
| `TAKE` | `reqId`, `svc`, `price`, `eta` int s, `wait` int s |
| `CONFIRM` | `reqId`, `svc`, `price` |
| `GONE` | `reqId` |
| `STATE` | `reqId`, `state` str |
| `CANCEL` | `reqId`, `by` (`"rider"` / `"taxi"`), `late` bool |

- Kódování: seznam `a,b`; mapa `COME:30000,PICK:15000`; bool `1`/`0`; int desítkově.
- Svc ∈ {`COME`, `PICK`}, city key ∈ `Const.CITY`, ceny (`ask`, `max`, `price`) v rozmezí `Const.PRICE`, `lvl` 1–100, `eta`/`wait`/`resp` ≥ 0. Mimo rozsah → `"range"`.
- Řetězce (`place`, `reqId`, `state`, …) nesmí obsahovat `|` ani `,`. `encode` je odstraní, `decode` je nikdy nedostane.
- Časy na drátě jsou vždy **relativní v sekundách** (`wait`, `eta`, `resp`), protože `GetTime()` má každý klient jiný.
- `reqId` tvoří odesílatel: `<playerKey>:<pořadí>`.

### Net (agent D)

```lua
Net.start()                 -- on READY: register prefix, join channel, wait for its id (retry), remove it from chat frames
Net.broadcast(msg)          -- Protocol.encode + queue to CHANNEL (queued until the channel is joined)
Net.whisper(rawSender, msg) -- Protocol.encode + queue to WHISPER, target = raw sender string (D5)
Net.stats -> { sent, received, dropped }
Net.rejoin()                -- joins again after Net gave up; no-op while joined or joining (wave 2)
Net.joined() -> bool
-- incoming CHAT_MSG_ADDON with prefix PTX via CHANNEL or WHISPER: key = ns.playerKey(sender);
--   own echo (key == UnitName("player")) dropped; Protocol.decode fails -> dropped (stats.dropped);
--   else ns.fire("NET_MSG", msg, key, rawSender, via)
-- queue: max 4 msgs/s; a queued HELLO broadcast is replaced by a newer one
```

### Market (agent B, čistý)

```lua
local m = Market.new()
m:hello(key, hello, now)  -- hello = decoded HELLO; stores { key, fac, cls, lvl, place, dests, ask, resp,
                          --   waitSince = now - hello.wait, seen = now }
m:bye(key)
m:hail(key, hail, now)    -- stores { key, reqId, fac, dest, svcs, max, rest, at = now }; one open request per key
m:gone(reqId)
m:expire(now) -> removedOfferKeys, removedReqIds   -- offers after T.OFFER without HELLO, requests after T.REQUEST
m:offers({ dest, svc, faction }) -> list   -- { key, svc, price, offer } for offers that serve dest+svc,
                                           -- sorted by price, then key
m:openRequests(taxi, now) -> list          -- taxi = { faction, services (Detect.services), prices = { COME, PICK } }
  -- requests of the same faction, dest in services.dests, a service both sides want with price <= max
  -- (COME only if services.COME and request.rest); prefers COME over PICK;
  -- returns { request, svc, price }, oldest request first
Market.pickHailWinner(takes, tie) -> take|nil
  -- takes = { { key, eta, wait, price, svc }, ... }; lowest eta; candidates eta <= min + tie;
  -- winner = longest wait among candidates; then key A-Z (deterministic)
Market.affordable(money, price) -> bool
```

### Společné tvary vlny 2

```lua
-- match: what Dispatch hands to Ride.start once a ride is agreed (both sides build their own).
match = {
  reqId = "Velvet:3", role = "rider" | "taxi", svc = "COME" | "PICK", price = 30000, dest = "OG",
  peer = { key = "Thalindra", raw = "Thalindra Forever" },   -- the other side; raw is for whispers (D5)
  eta = 25,                                                  -- seconds, from TAKE (rider side) or own estimate
}
-- ride: what Ride.current(), RIDE_STARTED and RIDE_STATE carry (read-only for everyone but Ride).
ride = { <all match fields>, state = "MATCHED" | ..., since = now, peerUnit = "party1" | nil,
         riderResting = bool|nil (taxi side, from STATE), late = bool, reason = string|nil }
-- secure spec: what Ride asks Secure to arm; label/icon are for the button face.
spec = { kind = "item", item = Const.ITEM.LIMINAL_SCROLL, unit = "party1", label = "Teleport to Velvet" }
     | { kind = "spell", spell = Const.CITY[dest].spell, label = "Portal: Orgrimmar" } | nil
```

Stavy jízdy (plán §7): `MATCHED → GROUPED → EN_ROUTE → ARRIVED → TRADING → PAID → PORTAL_OPEN → DONE`, odbočky `CANCELLED` a `FAILED`. Konec jízdy = `RIDE_STATE` se stavem `DONE`, `CANCELLED` nebo `FAILED`. Potom `Ride.current()` vrací `nil`.

`PortaxiDB.caps` (D11) má klíče `invite`, `accept`, `openTrade`, `prefill`, každý `"auto"` (výchozí, nebo neověřeno) nebo `"manual"`. Na `"manual"` se přepne po `ADDON_ACTION_BLOCKED` nebo po timeoutu. Kdo klíč změní, pošle `CAPS_CHANGED`.

### Dispatch (agent G, vlna 2)

```lua
Dispatch.market                     -- the one Market instance; NET_MSG HELLO/BYE/HAIL/GONE feed it; expire every 10 s
Dispatch.setOnDuty(bool)            -- writes PortaxiCharDB.onDuty; on: Net.rejoin() if needed, HELLO now and every
                                    -- T.HELLO +- T.HELLO_JITTER, and after PROFILE_CHANGED (at most one per 5 s); off: BYE
                                    -- on READY: resumes duty if PortaxiCharDB.onDuty
Dispatch.hail(dest, max) -> ok, err -- rider: err "money" (not affordable), "cooldown" (T.HAIL_COOLDOWN), "busy" (ride or
                                    -- hail open); svcs = { "COME", "PICK" } when resting else { "PICK" }; reqId = key:n
                                    -- collects TAKEs T.COLLECT s after the first, Market.pickHailWinner -> whisper CONFIRM,
                                    -- broadcast GONE, fire HAIL_RESULT(reqId, winnerTake), Ride.start(match)
                                    -- no TAKE within T.REQUEST -> GONE, HAIL_RESULT(reqId, nil)
Dispatch.book(key, dest, svc) -> ok, err  -- rider, Browse: whisper BOOK to that taxi; its TAKE is confirmed at once
Dispatch.cancel()                   -- rider: withdraws the open hail/book (GONE)
Dispatch.take(reqId) -> ok, err     -- taxi: whisper TAKE { svc, price, eta, wait }; one pending TAKE at a time; free again
                                    -- after T.CONFIRM without CONFIRM; on CONFIRM -> Ride.start(match)
Dispatch.status() -> { onDuty, hail = { reqId, dest, max, takes, since } | nil, pendingTake = reqId | nil }
-- taxi: INCOMING_REQUEST(entry) once per reqId for every new entry of market:openRequests(...) (entry = { request,
--   svc, price, booked = bool }); not while a ride is active. Alerts: raid warning + sound for it.
-- eta: COME = average response (PortaxiCharDB.respTimes, last 10, default Const.RESP_DEFAULT) + Const.CAST.SCROLL;
--      PICK = Const.ETA_PICK + average response. wait = time() - PortaxiCharDB.lastRideAt (login time if 0).
-- A response time (request seen -> TAKE sent) is appended to respTimes on every TAKE.
```

### Ride (agent H, vlna 2)

```lua
Ride.step(ride, event, now) -> ride, actions   -- pure FSM; events and actions are H's own vocabulary, documented in
                                               -- the file header; no game API inside step
Ride.start(match) ; Ride.current() -> ride|nil ; Ride.cancel(reason)
Ride.manual(what)                              -- what: "invite" | "accept" | "trade"; the manual fallback (D11), called
                                               -- from a RidePanel button click (hardware event)
-- Glue (game + NET_MSG STATE/CANCEL + TRADE_PAID):
--   taxi MATCHED: C_PartyInfo.InviteUnit(peer.key) from a timer; rider: AcceptGroup on PARTY_INVITE_REQUEST from
--     peer.key only (then StaticPopup_Hide("PARTY_INVITE")); GROUPED when the peer is in the party (peerUnit found
--     by name); no group within T.INVITE -> FAILED. Blocked/timeout -> caps.invite / caps.accept = "manual".
--   rider sends STATE "RESTING" / "NOT_RESTING" on change (taxi side keeps ride.riderResting).
--   COME: taxi arms Secure.set(scroll spec on peerUnit) only while riderResting; UNIT_SPELLCAST_START with
--     Const.SPELL.LIMINAL_PASSAGE (player on taxi side, peerUnit on rider side) -> EN_ROUTE; _SUCCEEDED -> ARRIVED;
--     _FAILED/_INTERRUPTED -> back to GROUPED.
--   PICK: GROUPED -> EN_ROUTE at once; ARRIVED when CheckInteractDistance(peerUnit, 2) (poll 1 s).
--   ARRIVED (taxi) -> TRADING: ns.Trade.open(peerUnit). Rider follows STATE.
--   TRADE_PAID(reqId, copper) on the taxi -> PAID: Secure.set(portal spec for dest), STATE "PAID" to the rider.
--   portal _SUCCEEDED -> PORTAL_OPEN (both sides); no DONE within T.PORTAL -> back to PAID (a second portal is free).
--   rider zone == Const.CITY[dest].name -> STATE "DONE" -> DONE on both; taxi: PortaxiCharDB.lastRideAt = time().
--   end of ride (DONE/CANCELLED/FAILED): Secure.set(nil).
--   cancel: rider free until EN_ROUTE (for COME: until the scroll cast starts); later -> late = true, recorded in
--     PortaxiCharDB.lateCancels { reqId, at = time(), peer, price }; CANCEL whisper to the peer either way.
--   peer offline (UnitIsConnected false) or left the group -> FAILED.
-- Every state change: ns.fire("RIDE_STATE", ride) and Net.whisper(peer.raw, STATE) where the plan says so.
```

### Trade a Secure (agent I, vlna 2)

```lua
Trade.verify(expected, received) -> ok, reason   -- pure; reason "short" when received < expected
Trade.open(unit)            -- taxi: InitiateTrade(unit) from a timer; no TRADE_SHOW within 3 s or blocked ->
                            -- caps.openTrade = "manual" and ns.fire("TRADE_MANUAL", "open")
Trade.status() -> { open, partner, expected, mine, theirs, prefilled }
-- TRADE_SHOW with the active ride's peer (UnitName("NPC") == peer.key):
--   rider: if GetMoney() >= price, C_TradeInfo.SetTradeMoney(price) after 0.3 s; blocked or not applied ->
--     caps.prefill = "manual", MoneyInputFrame_SetCopper(TradePlayerInputMoneyFrame, price) if available,
--     else ns.fire("TRADE_MANUAL", "prefill", price)
--   taxi: watches GetTargetTradeMoney on TRADE_MONEY_CHANGED / TRADE_ACCEPT_UPDATE; when the rider offers less than
--     the price, ns.fire("TRADE_MANUAL", "short", offered, price) (RidePanel warns before the taxi accepts)
--   completion: "Trade complete." (UI_INFO_MESSAGE, or ERR_TRADE_COMPLETE when defined) or TRADE_CLOSED after
--     both accepted; the taxi checks GetMoney() delta against the price with Trade.verify; ok ->
--     ns.fire("TRADE_PAID", reqId, copper)
-- Trade never calls AcceptTrade (D10): the player clicks Trade.
Secure.button               -- SecureActionButtonTemplate, global "PortaxiNextButton" (D14), created on READY,
                            -- 40x40 icon + label, movable, position in PortaxiDB.ui.secure, hidden while spec is nil
Secure.set(spec)            -- spec shape above; queued while InCombatLockdown(), applied on PLAYER_REGEN_ENABLED;
                            -- fires ns.fire("SECURE_CHANGED", spec) when applied
Secure.current() -> spec|nil ; Secure.pending() -> spec|nil (queued in combat)
Secure.bindKey(key)         -- SetOverrideBindingClick outside combat; key in PortaxiCharDB.nextKey, re-applied on READY
                            -- /ptx key <KEY> sets it, /ptx key clears it
```

### UI (agent F, potom G a H)

Okno nevolá herní logiku přímo. Čte `Detect.current()`, `Market` přes `Dispatch` a `Ride.current()` a reaguje na události. Akce volá přes `Dispatch.*` a `Ride.*`. Modul, který ještě neexistuje (prázdná tabulka), UI zvládne: zobrazí prázdný stav a nespadne.

```lua
ns.UI.toggle() ; ns.UI.show(tab) ; ns.UI.hide()   -- tab: "ride" | "drive"
-- main window global "PortaxiMainFrame", movable, position in PortaxiDB.ui.pos, closes on Esc (UISpecialFrames)
-- /ptx show toggles the window; the minimap button angle lives in PortaxiDB.ui.minimap.angle
-- RideTab: read-by-addon block (faction, class, place, resting, gold), city tiles of the own faction (D13),
--          hail max price stepper (Dispatch.hail when it exists)
-- DriveTab (only when services.canDrive): detection block with pauses, on-duty toggle (PortaxiCharDB.onDuty,
--          Dispatch.setOnDuty when it exists), prices per service (PortaxiCharDB.prices, within Const.PRICE)
-- DutyBox (card G, user request at G1): a small movable box, visible only while on duty and canDrive.
--   ~200x70, global name "PortaxiDutyBox", drag to move, position in PortaxiDB.ui.dutyBox, can be locked.
--   Lines: status dot + "On duty" + services with prices ("Come 3g · Pickup 1g 50s") or the pause reason;
--   open requests count; the best request (city, service, price, age) with a Take button (Dispatch.take);
--   a small "Off" button (Dispatch.setOnDuty(false)); clicking the title opens the window on Drive.
--   Pulses on INCOMING_REQUEST (next to the raid warning). Hidden in pet battles/cinematics is not needed.
--   ns.UI.DutyBox.refresh() ; /ptx box toggles its lock or shows it again after the user hid it.
```

---

## 3. Testy a simulátor

| Soubor | Obsah | Kdo |
|---|---|---|
| `tests/run.ps1` | Spustí všechny `tests/*_test.lua` na `tools\bin\lua51\lua5.1.exe`, souhrn a exit kód. `check.ps1` ho volá na konci. | architekt, vlna 0 |
| `tests/lib/t.lua` | Mini framework: `test(name, fn)`, `eq`, `ok`, `fails`. | architekt, vlna 0 |
| `tests/lib/wowstub.lua` | Falešný WoW klient, popis API je v hlavičce souboru. `Wow.new(opts)` vrací klienta s vlastním prostředím bez `os`/`io`. `wow:load()` načte TOC; dál `wow:slash`, `wow:advance`, `wow:fire`. Pomocníci hráče: `setResting`, `setItem`, `setMoney`, `setCombat`, `inviteFrom`, `joinParty`, `tradeOpenedBy`, `tradeTheirMoney`, `tradeComplete`, `receive`. Záznamy: `sent`, `calls`/`callsTo`, `printed`, `errors`, `raidWarnings`, `secureClicks`. `wow.blocked[api] = true` simuluje zablokované chráněné volání. Zakázaná volání (D10) vyhodí chybu. Háčky pro simulátor: `wow.hooks.send / invite / accept / initiateTrade / tradeMoney`. **Agenti ho nemění.** Chybějící API si definují ve svém testu (`wow.env.X = …`) a požádají architekta o doplnění. | architekt, vlna 0 |
| `tests/lib/sim.lua` | **Simulátor N klientů** nad `wowstub`. Každý klient je jeden `Wow.new()`. Sdílený falešný server přes `wow.hooks` rozvádí `CHANNEL` (všem klientům včetně odesílatele) a `WHISPER` na `"Jméno Příjmení"` (na krátké jméno se nedoručí). Řeší i pozvánky a party na obou stranách a trade mezi dvěma klienty. Hodiny jsou společné: `sim:advance(s)` posouvá všechny klienty. Skriptované kroky hráče: `sim:click(client)` (secure tlačítko → simulované sesílání a jeho události) a `sim:acceptTrade(a, b)`. Neověřené chování jde přepnout přes `wow.blocked` a testují se obě větve D11. | agent E, vlna 1 |
| `tests/*_test.lua` | Jeden soubor na modul nebo scénář, vlastní ho agent modulu. | agenti |

Scénáře z plánu §9 se v simulátoru jmenují `tests/sim_s1_test.lua` až `sim_s9_test.lua`. Na konci vlny 2 musí být všechny zelené.

---

## 4. Vlny

| Vlna | Karta | Agent | Vlastní soubory | Hotovo, když |
|---|---|---|---|---|
| **0** ✓ | P0 Základy | architekt | `Core/Init.lua`, `Core/Const.lua`, `Core/Probe.lua`, `Locales/enUS.lua`, `Portaxi.toc` (všechny soubory MVP jako prázdné moduly), `.luacheckrc`, `.gitattributes`, `tools/check.ps1`, `tests/run.ps1`, `tests/lib/t.lua`, `tests/lib/wowstub.lua`, `tests/init/diag/probe/wowstub_test.lua` | Kontrola a testy zelené. Brána G0. |
| **1** ✓ | A Protocol | agent | `Core/Protocol.lua`, `tests/protocol_test.lua` | Všechny typy zpráv: encode → decode beze ztráty; chyby verze, rozsahu, délky a formátu. |
| 1 | B Market | agent | `Core/Market.lua`, `tests/market_test.lua` | Expirace, filtry, řazení. `pickHailWinner`: nejnižší ETA; remíza do 15 s → nejdéle čekající; pak abecedně. Determinismus. |
| 1 | C Detect | agent | `Core/Detect.lua`, `tests/detect_test.lua` | `services` pro mága s runou, bez runy, bez scrollu, mimo hostinec; pro warriora. Debounce. |
| 1 | D Net | agent | `Core/Net.lua`, `tests/net_test.lua` | Zahození vlastní ozvěny, whisper na celé jméno, limit fronty, opakované připojení ke kanálu, neplatné zprávy zahodí. Proti falešnému `Protocol` podle §2. |
| 1 | E Simulátor | agent | `tests/lib/sim.lua`, `tests/sim_smoke_test.lua` | Dva klienti s `Probe.lua` si vymění `PING`/`PONG`; ozvěna, whisper a hodiny fungují. |
| 1 | F Kostra UI | agent | `UI/Widgets.lua`, `UI/MainFrame.lua`, `UI/Minimap.lua`, `UI/RideTab.lua`, `UI/DriveTab.lua`, `tests/ui_smoke_test.lua` | Okno se záložkami Ride / Drive (Drive jen při `canDrive`), blok „read by addon“, dlaždice měst (D13), tlačítko u minimapy. Data přes `Detect.current()`, testy s falešným profilem. |
| | **G1** | architekt | merge v pořadí A → B → C → D → E → F, integrační commit | Celá sada testů zelená. Kontrola ve hře G1 (§7). |
| **2** | G Párování | agent | `Core/Dispatch.lua`, `UI/RideTab.lua`, `UI/DriveTab.lua`, `UI/Alerts.lua`, `UI/DutyBox.lua`, `tests/dispatch_test.lua`, `tests/dutybox_test.lua`, `tests/ui_smoke_test.lua`, `tests/sim_s1/s2/s3/s7_test.lua` | `HELLO` cyklus, Hail se sběrem 3 s, Book, `GONE`, raid warning, box na směně (DutyBox), nový pokus o kanál při zapnutí směny. Scénáře 1, 2, 3, 7 zelené. |
| 2 | H Jízda | agent | `Core/Ride.lua`, `UI/RidePanel.lua`, `tests/ride_test.lua`, `tests/sim_s5/s6/s9_test.lua` | Stavový automat podle plánu §7, timeouty, storna, sledování sesílání na `party1`. Scénáře 5, 6, 9 zelené. |
| 2 | I Trade a Secure | agent | `Core/Trade.lua`, `Core/Secure.lua`, `tests/trade_test.lua`, `tests/secure_test.lua`, `tests/sim_s8_test.lua` | Předvyplnění zlata, kontrola platby, `TRADE_PAID`, secure tlačítko s frontou v boji, klávesa přes `SetOverrideBindingClick` (D14), fallbacky D11. Scénář 8 zelený. |
| | **G2** | architekt | merge v pořadí I → H → G, `tests/sim_s4_test.lua` (celá jízda Come-to-you, potřebuje G+H+I), integrační commit, `/code-review high` | Scénáře 1–9 v simulátoru zelené. Kontrola ve hře G2. |

Ve vlně 2 testuje každá karta proti falešným modulům ostatních karet podle §2. Scénáře v simulátoru, které potřebují cizí kartu, si ji nahradí falešnou implementací (např. H falešný `Secure.set`, který nastaví atributy na tlačítku `PortaxiNextButton` vytvořeném v testu; G falešný `Ride.start`, který jen zapíše match).
| **3** | J Vzhled | agent | `Portaxi/Media/*` (nové), `Portaxi/UI/*.lua`, `Portaxi/Locales/enUS.lua`, `tools/make-emblems.mjs`, `tests/media_test.lua`, `tests/locales_test.lua`, `tests/ui_smoke_test.lua`, `tests/dutybox_test.lua` | Erby měst jako TGA 64×64 z SVG v maketě (vlastní převodník v Node bez balíčků), dlaždice měst s erby místo ikon kouzel, vzhled oken podle makety v0.8, úplný `Locales/enUS.lua` a test, že každý klíč z kódu v něm je. |
| 3 | K Dokumenty | agent | `README.md` (nový, anglicky, pro hráče), `docs/PHASE0_FINDINGS.md` (nový, česky), `docs/PORTAXI_MVP_PLAN.md` (§2 stav, §10, §11, §12) | Návod pro hráče (instalace, Ride, Drive, box na směně, tlačítko a klávesa, `/ptx` příkazy, co addon dělá a nedělá sám), souhrn fáze 0, aktualizovaný plán. |

Pravidla vlny 3:
- **Texty jsou klíče lokalizace.** Žádný řetězec předaný do `ns.L[...]` se nemění (testy na ně spoléhají). `enUS.lua` mapuje klíč na stejný text. Hodí se seznam klíčů pro budoucí překlady.
- **Erby:** `Portaxi/Media/emblem_<KEY>.tga` pro `OG, UC, TB, SW, IF, DN`, 64×64, 32 bit s alfou, nekomprimované. Cesta v kódu `Interface\AddOns\Portaxi\Media\emblem_OG` (bez přípony). Nový soubor textury ve hře vyžaduje restart klienta. Když textura chybí, dlaždice použije ikonu kouzla (D13) jako zálohu.
- **Erby jsou vlastní kresby z makety,** žádná loga Blizzardu.
- Logiku (Core) vlna 3 nemění. Když kvůli vzhledu potřebuje změnu jinde, jde do „Requests for the architect“.
| | **G3** | architekt | merge, finální review | Kontrola ve hře G3. Pak test se dvěma hráči, až bude druhý hráč (G-final). |

Vlna 1 má 6 agentů, vlna 2 tři, vlna 3 dva. Celkem 11 agentů plus architekt.

Ve vlně 2 přebírá G soubory `RideTab.lua`/`DriveTab.lua` a H soubor `RidePanel.lua`. F je ve vlně 1 jen založí.

---

### Upřesnění z vlny 1 (platí jako součást §2)

| Modul | Upřesnění |
|---|---|
| Detect | Třída je token velkými písmeny (`"MAGE"`), rasa je druhá návratová hodnota `UnitRace` (`"Orc"`, `"Scourge"`). Postava, která není mág, má v `pauses` jen `{ "NOT_MAGE" }`. Pořadí pauz: `NOT_MAGE, NO_PORTAL, NO_RUNE, NO_SCROLL, NOT_RESTING`. Tabulky z `current()` a `PROFILE_CHANGED` se nesmí měnit. Moduly startující po Detect volají při startu `Detect.current()`, první `PROFILE_CHANGED` jim uteče. |
| Protocol | `reqId` nesmí být prázdný. `eta`/`wait`/`resp` mají strop 2³¹−1. `decode` odmítá `,` v textovém poli (`"field"`) a vstup nad 255 B (`"format"`). Kontrola verze je před kontrolou typu. Mapa `ask` se píše v pořadí `COME`, `PICK`. |
| Net | `broadcast`/`whisper` vrací `true` nebo `nil, err` (chyba z `encode`, `"queue_full"`, `"target"`, `"protocol"`). Fronta má strop 50 zpráv. Whisper nečeká za broadcasty, které čekají na kanál. ID kanálu se čte před každým odesláním, při ztrátě se kanál znovu připojí. Po 30 neúspěšných pokusech o připojení Net to vzdá do `/reload` (vlna 2: nový pokus při zapnutí směny). Vlastní ozvěna se nepočítá do `dropped`. |
| Market | Filtry v `offers()` jsou volitelné (nil = cokoli; bez `svc` jedna položka na službu). `openRequests` bere volitelný `taxi.key` (přeskočí vlastní poptávky) a vynechá poptávky starší než `T.REQUEST`, i když `expire()` ještě neběželo. `gone()` vrací `true`, když něco smazal. `pickHailWinner(takes, tie)`: `tie` je volitelné (výchozí `HAIL_TIE`); úplné pořadí je wait ↓, key A–Z, eta, price, svc. |
| UI | Tlačítko u minimapy nemá globální jméno. Cíl a maximum pro Hail platí jen do `/reload`. Dlaždice mají prázdný popisek `sub` pro ceny „from“ (karta G). |
| Const | `SPELL.LIMINAL_PASSAGE` je zatím `nil`. Hodnotu dodá `/ptx diag` (`items.scrollSpellId`, přes `C_Item.GetItemSpell`). |
| wowstub | Nově: `UnitIsConnected`, `UISpecialFrames`, `IsShiftKeyDown`, `C_Item.GetItemSpell` (`wow.itemSpells`), `GetEffectiveScale`, `joinParty(name, unit)`. `PreClick` běží před záznamem secure kliknutí. Nenastavená interní pole widgetů jsou `nil`. |
| Testy | `tests/integration_test.lua` spojuje skutečné Detect, Protocol, Net, Market a UI na simulátoru. Ve vlně 2 ho rozšíří Dispatch. |

### Úpravy po code review G2 (platí jako součást §2)

| Téma | Pravidlo |
|---|---|
| Caps (D11) | `ns.cap(what)` / `ns.setCap(what, value)` v Init. Natrvalo se ukládá jen odmítnuté volání (BLOCKED, chyba). Timeout ukáže ruční krok jen pro tu jízdu (`ride.inviteManual`, `ride.acceptManual`, `TRADE_MANUAL "open"`). |
| Storna | Zákazník: pozdní jen u Come-to-you od svitku do zaplacení, Pickup nikdy. Taxík: zdarma před EN_ROUTE, při čekání na chodce (PICK EN_ROUTE) a při čekání na platbu (ARRIVED, TRADING); ne během svitku a ne po zaplacení. |
| Timeout tradu | `Const.T.TRADE = 180`: ARRIVED/TRADING bez platby → `FAILED "trade_timeout"` na obou stranách. |
| Svitek | Ride sleduje i odpočinek taxíka (`ride.selfResting`); svitek se připraví jen když odpočívají oba. |
| Hail/Book | Nové chyby `"here"` (cíl = město, kde zákazník je) a `"group"` (zákazník je ve skupině, pozvánka by nedošla). Ride tab je ukazuje předem. |
| Reakce taxíka | Reakce delší než `2 × RESP_DEFAULT` (taxík nebyl u klávesnice) se do průměru nepočítá. |
| Směna | Poptávky otevřené při zapnutí směny se jen vypíšou, raid warning dostanou jen nové. |
| Party | Taxík 3 s po konci jízdy opustí dvoučlennou skupinu, kterou pro jízdu vytvořil. |
| `CLAUDE.md` | Doplněna výjimka: přijetí pozvánky od spárovaného taxíka, otevření tradu a předvyplnění zlata; potvrzení tradu je vždy klik hráče. |

### Zjištění z brány G2 (platí jako součást §2)

- **Blokované volání hlásí Forever jako `ADDON_ACTION_FORBIDDEN` s funkcí `"UNKNOWN()"`.** Moduly nesmí poznávat zablokování podle jména funkce. Přiřazují ho volání, které právě běží (`calling` v Ride a Trade); jméno je jen záloha.
- **`C_TradeInfo.SetTradeMoney` je pro addon zakázané** → `Const.TRADE.SET_MONEY_API = false`, předvyplnění se nevolá, panel vyzve zákazníka. `Const.TRADE.FILL_MONEY_FIELD` (pole okna tradu) čeká na `/ptx tradefield`.
- **Forever nemá realmy, jen rulesety** (Normal, PvP, Roleplay, Hardcore; ověřeno na webu 2026-11-18). Každá postava má **jméno a příjmení**; jedinečná je jen dvojice v regionu, samotné jméno ne. Části jména neobsahují mezeru ani pomlčku. Odesílatel `"Varekhal Stonefel"` = jméno + příjmení. Ride proto zve vždy celým jménem.
- **Klíč hráče = `"Jméno Příjmení"` (D5, opraveno 2026-11-18).** `/ptx diag` ukázal: `UnitName(unit)` a `UnitFullName(unit)` vracejí jméno a příjmení jako dvě hodnoty (`"Aelric"`, `"Dawnmere"`), `GetUnitName(unit, true)` = `"Aelric Dawnmere"`, odesílatel zprávy má stejný tvar; `GetRealmName()` je interní server (`"CAMWOW EU4 Realm 1 PvE"`), nepoužívá se. Init: `ns.playerKey(sender)` → `"Jméno Příjmení"`, `ns.unitKey(unit)`, `ns.selfKey()`, `ns.sameName(a, b)` (celé klíče přesně; zdroj jen s křestním jménem, např. neověřený formát pozvánky, se porovná podle jména), `ns.firstName(key)`. Net, Dispatch, Ride, Trade a sonda je používají; UI ukazuje celá jména.
- `wowstub`: `wow.blocked[api] = "forbidden"` simuluje chování Forever. Pole `realm` ve stubu drží příjmení.

### Pracovní prostředí agenta

Worktree nemá `tools\bin`, ten je v gitignore. Agent ho jako první krok připojí z hlavního repa:
`New-Item -ItemType Junction -Path tools\bin -Target <hlavní checkout>\tools\bin`.
Junction se necommituje.

---

## 5. Karta agenta (šablona briefu)

Architekt posílá každému agentovi tenhle brief vyplněný. Agent nic jiného neví.

```
Role: implementation agent for Portaxi (WoW Forever addon, Lua 5.1), card <ID> <name>.
Read first: CLAUDE.md; docs/PORTAXI_MVP_PLAYBOOK.md §1, §2 (<relevant contracts>), §3; docs/PORTAXI_MVP_PLAN.md §<sections>.
Goal: <one paragraph>.
You own (edit only these): <files>. Everything else is read-only; needs elsewhere go to "Requests for the architect".
Implement contract: <§2 block>. Consume contracts: <§2 blocks> (they may not exist yet: use a fake that follows the contract in your tests).
Tests: <files>, covering: <list>.
Done when: tools\check.ps1 passes (it runs tests\run.ps1); every listed test is green; new WoW globals declared inline (D6).
Do not: add libraries, add files to the TOC, touch WTF, call game APIs from pure modules, cast/use/trade on the player's behalf.
Commit on your branch: one commit, English message, ending with the Co-Authored-By line.
Report (final message): what you built; files; tests and their result; deviations from the contract; requests for the architect; open questions. Say plainly that nothing was verified in game.
```

---

## 6. Orchestrace

Co dělá architekt v každé vlně:

1. **Start.** Spustí karty vlny souběžně, každou ve vlastním worktree (`Agent` s `isolation: "worktree"` nebo `Workflow`). Pošle vyplněný brief z §5. Větve se jmenují `ptx/<karta>`, například `ptx/w1-protocol`.
2. **Za běhu.** Odpovídá na dotazy agentů. Jejich soubory nemění.
3. **Review.** Čte **diff**, ne jen report. Kontroluje:
   - shodu s rozhraním (§2),
   - čistotu modulů (D3),
   - že agent neměnil cizí soubory (D8),
   - testy.
   Co nesedí, vrátí agentovi přes `SendMessage`.
4. **Merge.** Spojuje v pořadí z §4. Po každém merge spustí `check.ps1`. Integrační chyby opravuje jen ve svých souborech, jinak je vrací agentovi.
5. **Commit.** Jeden commit na kartu (z větve agenta) a jeden integrační commit na bránu. Push jen na pokyn uživatele.
   **Úklid:** nejdřív v každém worktree odstranit junction `tools\bin` (`cmd /c rmdir <worktree>\tools\bin`, smaže jen odkaz), pak `git worktree remove --force --force` a `git branch -D`. Obráceně hrozí, že se smaže obsah hlavního `tools\bin`.
6. **Brána.** Uživateli shrne, co je hotové a co ověřené. Dá mu seznam kontrol ve hře (§7) a s další vlnou čeká na jeho výsledky. Výsledky čte ze SavedVariables a BugGrabberu.
7. **Změna rozhraní.** Nejdřív se upraví §2 tohoto dokumentu. Pak architekt informuje všechny agenty, kterých se týká, a teprve potom se pokračuje.

Spuštění: uživatel napíše například „spusť vlnu 1 podle playbooku“. To je souhlas s během více agentů pro tu jednu vlnu.

---

## 7. Kontroly ve hře (uživatel, jedna postava)

Před každou bránou běží `check.ps1` a testy. Pak:

| Brána | Co udělat | Co architekt čte |
|---|---|---|
| G0 | Restart klienta, `/ptx`, `/ptx diag`, `/reload` | Žádné chyby v BugGrabberu; `PortaxiDB` a `PortaxiCharDB` s výchozími hodnotami |
| G1 | Klik na tlačítko u minimapy. Záložky Ride / Drive. Blok „read by addon“ sedí (zóna, odpočinek, portály, runy, scrolly). `/ptx detect` před a po odchodu z hostince (změna do 2 s). `/ptx netstat` (připojeno, kanál). `/ptx diag` (ID kouzla svitku). Posunout okno a tlačítko u minimapy, `/reload`, poloha drží. | BugGrabber, `PortaxiDB.ui`, `PortaxiDB.diag.items.scrollSpellId`, screenshot okna |
| G2 | **Restart klienta** (nový `UI/DutyBox.lua`). Detekce místa a odpočinku za pohybu (oprava z G1). Zapnout směnu: box na směně (tah, zámek, `/ptx box`, x a znovu zobrazit, klik na titulek otevře Drive), `/ptx netstat` (sent roste po minutě). Ride: dlaždice, Hail na vlastní město hlásí „already in that city“. `/ptx key F` a `/ptx ride`. S jakýmkoli hráčem: `/ptx invite`, `/ptx trade 1` + `/ptx opentrade` (doplní body 0.5, 0.7, 0.8). | `PortaxiDB.probe.log`, `PortaxiDB.caps`, `PortaxiDB.ui.dutyBox`, BugGrabber, screenshoty |
| G3 | **Restart klienta** (nové soubory v `Media/`). Screenshoty: záložka Ride (pilulky, erby šedé a vybraný se zlatým prstencem, Hail/Browse, cenový box), záložka Drive (karta detekce s erby, ceny, poptávky), box na směně, tlačítko u minimapy, titulek okna (portrét, „taxis online“). Erb jako zelený nebo černý čtverec = textura se nenačetla. Volitelně `/ptx tradefield 1` s hráčem. | Screenshoty, BugGrabber |
| G-final | S druhým hráčem: body fáze 0.3 (příjem), 0.4, 0.6, 0.9, potom scénáře 1–9 z plánu §9. | Logy z obou účtů |

---

## 8. Rizika playbooku

| Riziko | Zmírnění |
|---|---|
| Špatně navržené rozhraní → přepisování ve vlně 2 | Rozhraní §2 se zkontroluje na konci vlny 0. Vlna 1 testuje proti falešným modulům, které rozhraní dodržují. Změny jdou přes §6 bod 7. |
| Simulátor se chová jinak než skutečný klient | Simulátor napodobuje jen ověřené chování (formát odesílatele, ozvěna, whispery). Neověřené chování je přepínatelné a testují se obě větve. Rozdíly opraví brána G-final. |
| Konflikty při merge | Vlastnictví souborů (D8), deklarace globálů v souborech (D6), kompletní TOC (D7), pevné pořadí merge. |
| Agent „opraví“ cizí modul | Brief to zakazuje. Architekt kontroluje seznam změněných souborů v diffu. |
| Náklady | Vlny se pouštějí po jedné, a jen na pokyn uživatele. |
