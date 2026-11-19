# Portaxi — plán implementace MVP

Addon pro WoW Forever (Blizzard). Taxislužba: mág se ke klientovi přenese Scroll of Liminal Passage a otevře portál, nebo klient dojde k mágovi; warlock summonuje. Dispečink běží v addonech hráčů, bez serveru.

Podklad: klikací maketa v0.8 (artifact „Portaxi“). Maketa je referenční UX; tenhle dokument říká, co z ní se staví v MVP, jak a v jakém pořadí.

---

## 1. Rozsah

### V MVP (fáze 1)

| Oblast | Co |
|---|---|
| Detekce | Frakce, rasa, třída, level, naučené portály, Rune of Portals, Scroll of Liminal Passage, odpočinek, zóna, zlato. Z toho role (taxi / zákazník) a nabídka. |
| Služby | **Come-to-you portal** (scroll) a **Portal pickup** (zákazník dojde). Jen mágové. |
| Trh | Taxík si nastaví cenu pro každou službu. Zákazník: **Hail** (jen max cena, vyhraje nejrychlejší) a **Browse** (vybere taxík ze seznamu). |
| Párování | Hail: nejnižší ETA; remíza ≤ 15 s → déle čekající taxík. |
| Jízda | Automatická parta, živý stav sesílání, automaticky otevřený trade, částka v panelu jízdy (zákazník ji zapíše sám, předvyplnění Forever zakazuje), kontrola přijatého zlata, portál odemčený až po zaplacení. |
| Ochrana | Zákazník nepošle nabídku nad své zlato. Taxík bez runy/scrollu/naučeného portálu se nenabízí. Portál nikdy před platbou. |
| UI | Hlavní okno (záložky Ride / Drive), dlaždice měst s erby, panel jízdy, tlačítko u minimapy, raid warning + zvuk při nové poptávce, `/ptx`. |

### Mimo MVP

| Fáze | Co |
|---|---|
| 2 | „Name a price“ (fronta zákazníků podle ceny), auto-take, ukazatel trhu a obvyklé ceny, warlock summony (do města i „anywhere“). |
| 3 | Poplatek za pozdní storno (50 %, min. 50s), dluhy a jejich mazání, spolehlivost, Trusted, body v řadě taxíků (+3 / −10), hodnocení, blacklist, statistiky výdělku. |

V MVP se storno řeší jednoduše: zdarma do začátku scrollu; po něm se pozdní storno jen **lokálně zaznamená** (příprava na fázi 3), nikam se nešíří.

---

## 2. Fáze 0 — co ověřit ve hře, než se začne psát

Všechno ostatní na těchto bodech stojí. Testovat se dvěma účty (ideálně mág + jiná postava, stejná frakce).

**Stav bodů, co se zjistilo a co addon kvůli tomu dělá, je v `docs/PHASE0_FINDINGS.md`** (k 2026-11-18, po bráně G2: ověřeno 0.1, 0.5, 0.7; částečně 0.2, 0.3, 0.10; nejde 0.8 přes API; zbytek neověřený). Tabulka níže je původní zadání s průběžnými poznámkami; při rozporu platí `PHASE0_FINDINGS.md`.

| # | Otázka | Jak ověřit | Když to nejde |
|---|---|---|---|
| 0.1 | Verze klienta / `## Interface` | **Potvrzeno 2026-11-18** (`/ptx diag`): klient `1.60.1`, build `70959` (13. 11. 2026), interface `16001`; klientská přípona TOC je `_Forever`. **Je to moderní klient:** globální `GetItemCount` neexistuje (diag na něm spadl), je jen `C_Item.GetItemCount`. `IsSpellKnown` funguje. Addon proto API hledá za běhu (`api()` v `Core/Init.lua`), klasické globály nevolá napřímo. | — |
| 0.2 | Scroll of Liminal Passage: itemID, spotřebovává se?, cooldown, jen mág?, jak cílí (target / party unit) | **Částečně zjištěno 2026-11-18:** itemID `213548`, stackuje se (9 ks v batohu). **2026-11-19:** jen mág (potvrdil uživatel). Tooltip (build 70959, wowhelm): „Teleport to a party member. Both you and the target must be resting at an inn or city.“ Tedy přenese *sesílatele* k členovi party; odpočívat musí oba (hlavní město, nebo hospoda s rested). Podle fanouškovských databází: sesílání 1 s, bez cooldownu, spouští GCD, nejde za pohybu, kategorie Consumable › Scrolls. **Ověřeno sondou `/ptx scroll` 2026-11-19:** sesílání 1,0 s, ubyde jen při úspěchu, secure tlačítko na `party1` funguje; při neplatném cíli přijde `SUCCEEDED` a hned chyba „Invalid target“ bez přesunu (viz `docs/INN_HOP_PLAN.md` §3). Tooltip, makro `/use [@party1] item:213548` | Pokud ho nemůže použít addon přes secure button, zůstává ruční použití; addon jen hlídá podmínky. |
| 0.3 | Addon zprávy přes vlastní kanál | **Z poloviny ověřeno 2026-11-18 (jedna postava):** `JoinTemporaryChannel("PortaxiNet")` → kanál id 6, `SendAddonMessage` do `CHANNEL` vrací `0` (Success) a server zprávu vrátí i odesílateli. Odesílatel přichází jako `"Jméno Příjmení"` (**mezera**, ne pomlčka; `Ambiguate` ji neodstraní) — vlastní zprávy poznávat podle části před mezerou/pomlčkou. Whisper na vlastní krátké jméno nedorazí, whisper na řetězec odesílatele z kanálu ano. Zbývá: příjem u druhého hráče. | Záloha: `GUILD` + whisper (výrazně menší dosah) — pak je nutné přehodnotit koncept. **Blokující.** |
| 0.4 | Jsou kanály oddělené podle frakce? | Stejný kanál z Alliance a Horde postavy | Pokud ne, filtrovat podle pole `fac` ve zprávě. |
| 0.5 | Pozvánka z addonu bez kliknutí | **Ověřeno 2026-11-18 (G2, se skutečným hráčem):** `C_PartyInfo.InviteUnit` z timeru prošel bez zablokování. Zve se celým jménem `"Jméno Příjmení"` (`"Varekhal Stonefel"`); Forever nemá realmy, jedinečná je jen dvojice jméno + příjmení. | Tlačítko „Invite“ (1 klik taxíka). |
| 0.6 | Automatické přijetí pozvánky | `PARTY_INVITE_REQUEST` → `AcceptGroup()` + `StaticPopup_Hide("PARTY_INVITE")` | Zvýrazněná výzva „Accept“. |
| 0.7 | Otevření tradu z addonu | **Ověřeno 2026-11-18 (G2):** `InitiateTrade("target")` z timeru otevřel trade. | Tlačítko „Open trade“ (1 klik). |
| 0.8 | Předvyplnění zlata | **Nejde (G2, 2026-11-18):** `C_TradeInfo.SetTradeMoney` z addonu → `ADDON_ACTION_FORBIDDEN` s funkcí `"UNKNOWN()"`, částka zůstala 0. Addon ho nevolá (`Const.TRADE.SET_MONEY_API = false`), zákazník dostane v panelu výzvu „vlož X“. Ani pole okna tradu nejde (G3, `/ptx tradefield`): `MoneyInputFrame_SetCopper` → „forbidden object from code tainted by an AddOn“. Zlato vždy zapisuje zákazník. | Addon jen ukáže částku k ručnímu zadání. |
| 0.9 | Čtení přijatého zlata | `GetTargetTradeMoney()`, `TRADE_ACCEPT_UPDATE`, `UI_INFO_MESSAGE` (ERR_TRADE_COMPLETE), rozdíl `GetMoney()` | — (mělo by fungovat). |
| 0.10 | ID kouzel a předmětů na Forever | **Částečně potvrzeno 2026-11-18** (Horde mág lvl 40): Portal: Orgrimmar `11417` a Undercity `11418` známé, Thunder Bluff `11420` ne (učí se až na 50, sedí s Classic). Rune of Portals `17032` sedí (7 ks). Zbývá: Alliance portály, Ritual of Summoning `698` a Soul Shard `6265` na warlockovi. | Upravit tabulku konstant. |
| 0.11 | Summon na Forever (počet klikačů, dosah) | Ritual of Summoning se 2 pomocníky | Jen pro fázi 2. |
| 0.12 | Pravidla serveru k placeným službám | Podmínky / fórum Forever | Bez souhlasu nepouštět veřejně. |

### Sondy v addonu (`Core/Probe.lua`)

Body 0.3–0.9 potřebují druhého hráče. Každou sondu spouští příkaz, výsledky jdou do chatu a do `PortaxiDB.probe.log` (uloží se po `/reload`). Volání jdou z `C_Timer`, ne z kliknutí — tak je bude volat i skutečný addon. Zablokované chráněné volání se zapíše jako `blocked` (`ADDON_ACTION_BLOCKED`).

| Příkaz | Bod | Co dělá |
|---|---|---|
| `/ptx net` | 0.3, 0.4 | Připojí `PortaxiNet` a pošle `PING` do kanálu. Addon na cizí `PING` sám odpoví `PONG` whisperem na řetězec odesílatele. |
| `/ptx invite <jméno>` | 0.5 | Za 1 s pozve hráče přes `C_PartyInfo.InviteUnit`. |
| `/ptx accept` | 0.6 | Příští pozvánku přijme sám (`AcceptGroup`), jen jednou. |
| `/ptx opentrade` | 0.7 | Za 1 s otevře trade s cílem (`InitiateTrade("target")`). |
| `/ptx trade <měďáky>` | 0.8, 0.9 | Při příštím tradu předvyplní částku (`C_TradeInfo.SetTradeMoney`), jen jednou. Log zapisuje změny částek, potvrzení a zlato po tradu. |
| `/ptx probe [clear]` | — | Vypíše posledních 10 záznamů / smaže log. |

Postup se dvěma postavami A a B (obě v hostinci):

1. Obě: `/ptx net` → každá má vidět vlastní `PING` a od té druhé `PING` + `PONG`. Pro 0.4 zopakovat s postavami různých frakcí. (Jen s vlastní ozvěnou je 0.3 ověřený z poloviny: odeslání ano, příjem u jiného hráče ne.)
2. B: `/ptx accept`, A: `/ptx invite B` → B je v partě bez kliknutí.
3. B: `/ptx trade 100`, A: zacílit B a `/ptx opentrade` → trade se otevře a u B je předvyplněný 1s. Obě kliknou Trade.
4. Obě: `/reload` → přečtu `PortaxiDB.probe` z obou účtů.

Předpokládané konstanty (ověřit v 0.10):

```lua
SPELL = { -- Portal spells (Classic IDs)
  SW = 10059, IF = 11416, DN = 11419,
  OG = 11417, UC = 11418, TB = 11420,
  RITUAL_OF_SUMMONING = 698,
}
ITEM = { RUNE_OF_PORTALS = 17032, SOUL_SHARD = 6265, LIMINAL_SCROLL = 213548 }
```

---

## 3. Architektura

Bez serveru: každý klient drží vlastní kopii „nástěnky“ (nabídky taxíků, otevřené poptávky) a rozhoduje sám za sebe. Pravidla párování jsou deterministická, takže dva klienti nad stejnými daty dojdou ke stejnému výsledku.

### Struktura

```
Portaxi/
  Portaxi.toc
  Core/                        -- no external libraries in MVP (playbook D1)
    Init.lua                   -- namespace, event bus, api resolver, SavedVariables, slash /ptx
    Const.lua                  -- spell/item IDs, cities, prices bounds, timeouts
    Probe.lua                  -- phase 0 probes (/ptx net, invite, accept, opentrade, trade)
    Detect.lua                 -- character profile + services
    Net.lua                    -- channel join/hide, send/receive, send queue
    Protocol.lua               -- message encode/decode, versioning  (pure Lua)
    Market.lua                 -- offers, requests, expiry, matching (pure Lua)
    Dispatch.lua               -- HELLO timer, HAIL/BOOK/TAKE/CONFIRM/GONE glue (playbook D12)
    Ride.lua                   -- ride state machine (rider + taxi)
    Trade.lua                  -- trade open, prefill, verification
    Secure.lua                 -- secure action button, combat lockdown queue
  UI/
    MainFrame.lua  RideTab.lua  DriveTab.lua  RidePanel.lua
    Minimap.lua    Alerts.lua   Widgets.lua
  Media/                       -- city emblems 64x64 .tga (z SVG z makety)
  Locales/enUS.lua
  tests/                       -- offline testy pure-Lua modulů (Lua 5.1)
```

`Protocol.lua` a `Market.lua` nesmí volat herní API (jen přes injektované funkce `now()`, `self`). Díky tomu jdou testovat mimo hru.

### SavedVariables

- `PortaxiDB` (účet): nastavení UI, pozice okna a minimapy, cache hodnocení (fáze 3).
- `PortaxiCharDB` (postava): ceny za služby, na směně ano/ne, klávesa tlačítka, průměrná doba reakce (pro ETA), čas poslední jízdy, lokální záznam pozdních storen.

---

## 4. Detekce (`Detect.lua`)

Výstup: `Portaxi.profile` a odvozené `canDrive`, `services`, `pauses`.

| Pole | API | Přepočet na event |
|---|---|---|
| faction | `UnitFactionGroup("player")` | `PLAYER_LOGIN` |
| race, class, level | `UnitRace`, `UnitClass`, `UnitLevel` | `PLAYER_LEVEL_UP` |
| portals | `IsSpellKnown(SPELL.x)` pro města své frakce | `LEARNED_SPELL_IN_TAB`, `SPELLS_CHANGED` |
| runes, scrolls | `C_Item.GetItemCount(ITEM.x)` (globální `GetItemCount` na Forever chybí) | `BAG_UPDATE_DELAYED` |
| resting | `IsResting()` | `PLAYER_UPDATE_RESTING` |
| place | `GetZoneText()`, `GetSubZoneText()` | `ZONE_CHANGED*` |
| gold | `GetMoney()` | `PLAYER_MONEY` |

Pravidla:

- `canDrive` = mág s aspoň jedním naučeným portálem (warlock až ve fázi 2).
- `PICK` = canDrive a runes > 0.
- `COME` = PICK a scroll > 0 a resting.
- Destinace = naučené portály.
- Každá změna profilu → debounce 2 s → nový `HELLO`, pokud je taxík na směně.

---

## 5. Síť a protokol

### Kanál

- Po přihlášení `JoinTemporaryChannel("PortaxiNet")`, odebrat ho ze všech chat oken (`ChatFrame_RemoveChannel`).
- Prefix `PTX`, vlastní fronta odesílání (max 4 zprávy/s). Zprávy se vejdou pod 255 B, dělení netřeba (playbook D1).
- Broadcast jde do kanálu; vše v rámci jízdy přes `WHISPER`.

### Zprávy (verze 1)

Kompaktní řetězce `TYP|v|pole…`. Odesílatele dává klient (jméno), nikdy se nečte z obsahu. Na Forever má tvar `"Jméno Příjmení"` (s mezerou; realmy nejsou). Jedinečná je jen celá dvojice, proto je klíčem hráče celý řetězec (`ns.playerKey`, `ns.unitKey` z `UnitName` jméno + příjmení); whispery a pozvánky jdou na celý řetězec, jak přišel. Vlastní ozvěnu z kanálu ignorovat.

| Typ | Kanál | Pole | Kdy |
|---|---|---|---|
| `HELLO` | CHANNEL | fac, cls, lvl, place, svc (COME/PICK), dests, ask per svc, resp, waitSince | taxík na směně: každých 60 s ± 10 s jitter + při změně |
| `BYE` | CHANNEL | — | konec směny, logout |
| `HAIL` | CHANNEL | reqId, fac, dest, svcs, max, rest | zákazník |
| `BOOK` | WHISPER → taxík | reqId, dest, svc, price | zákazník z Browse |
| `TAKE` | WHISPER → zákazník | reqId, svc, price, eta, wait | taxík bere |
| `CONFIRM` | WHISPER → vítěz | reqId, svc, price | zákazník vybral |
| `GONE` | CHANNEL | reqId | poptávka obsazena / zrušena |
| `STATE` | WHISPER | reqId, state | průběh jízdy (sync obou stran) |
| `CANCEL` | WHISPER | reqId, by, late | storno |

Ochrany: neznámá verze → ignorovat; ceny mimo 10s–50g → ignorovat; max 1 otevřená poptávka na zákazníka; `HAIL` max 1× za 10 s od jednoho hráče; nabídky bez `HELLO` 150 s → smazat; poptávky po 120 s vyprší.

---

## 6. Párování (`Market.lua`)

### Hail

1. Zákazník lokálně ověří `GetMoney() >= max` a pošle `HAIL`.
2. Každý taxík na směně, který je volný, umí cíl, má cenu ≤ max a (u COME) zákazník odpočívá → ukáže poptávku (raid warning + zvuk). Po kliknutí na Take pošle `TAKE` s ETA a časem čekání (auto-take až ve fázi 2).
3. Zákazník sbírá `TAKE` ještě **3 s po prvním**. Pak:
   - min = nejnižší ETA,
   - kandidáti = ETA ≤ min + 15 s,
   - vítěz = nejdéle čekající z kandidátů (remíza → abecedně podle jména, kvůli determinismu).
4. `CONFIRM` vítězi, `GONE` do kanálu. Ostatní taxíky se po `GONE` uvolní.
5. Taxík po odeslání `TAKE` drží max 1 nevyřízenou nabídku; bez `CONFIRM` do 10 s je zase volný.

ETA (MVP): `COME` = průměrná doba reakce taxíka + doba použití scrollu (z 0.2). `PICK` = 600 s + reakce (vzdálenost podle zón až později). Průměr reakce: klouzavý průměr posledních 10 časů od poptávky k `TAKE`.

### Browse / Book

Seznam z nabídek (`HELLO`) pro vybrané město, řazený podle ceny; tlačítko Book je šedé při nedostatku zlata. `BOOK` → taxík přijme klikem → `TAKE` → `CONFIRM`.

Celé párování je v `Market.lua` jako čisté funkce, např. `Market.pickHailWinner(takes, now)`.

---

## 7. Průběh jízdy (`Ride.lua`, `Trade.lua`, `Secure.lua`)

### Stavový automat (sdílený, každá strana svou rolí)

```
REQUESTED → MATCHED → GROUPED → EN_ROUTE → ARRIVED → TRADING → PAID → PORTAL_OPEN → DONE
                                       ↘ CANCELLED / FAILED (timeout, odchod ze skupiny)
```

| Přechod | Spouštěč | Kdo co dělá |
|---|---|---|
| MATCHED → GROUPED | `CONFIRM` | Taxík pozve (0.5), zákazník přijme jen od spárovaného taxíka (0.6). Timeout 60 s. |
| GROUPED → EN_ROUTE | COME: taxík použije scroll (secure tlačítko). PICK: hned. | Obě strany čtou `UNIT_SPELLCAST_START/SUCCEEDED/FAILED` na `party1` / `player` → živý cast bar. |
| EN_ROUTE → ARRIVED | COME: `UNIT_SPELLCAST_SUCCEEDED` scrollu + jsou u sebe. PICK: `CheckInteractDistance("party1", 2)`. | Pokud zákazník přestane odpočívat před scrollem → tlačítko scrollu zešedne, taxík může zrušit bez postihu. |
| ARRIVED → TRADING | automaticky | Taxík otevře trade (0.7); zákazník dostane v panelu částku a zapíše ji sám (předvyplnění Forever zakazuje, 0.8). Bez platby do `T.TRADE` (180 s) → `FAILED`. |
| TRADING → PAID | trade dokončen a `GetTargetTradeMoney() >= price` | Taxíkovi se teprve teď zpřístupní tlačítko portálu. Špatná částka → varování před potvrzením. |
| PAID → PORTAL_OPEN | `UNIT_SPELLCAST_SUCCEEDED` portálu | Portál 60 s; nestihne-li zákazník, nabídka druhého portálu zdarma. |
| PORTAL_OPEN → DONE | zákazník změní zónu na cílové město | Taxík: čas poslední jízdy = teď (konec řady), statistika. |

Storno v MVP (po code review G2): zákazník zdarma před `EN_ROUTE`; pozdní storno (jen lokální záznam) jen u Come-to-you od svitku do zaplacení, Pickup nikdy, po zaplacení zase zdarma. Taxík zdarma před `EN_ROUTE`, při čekání na chodce (Pickup) a při čekání na platbu (`ARRIVED`, `TRADING`); ne během svitku a ne po zaplacení.

### Secure tlačítko

- Jedno `SecureActionButtonTemplate` tlačítko „next step“, globálně `PortaxiNextButton`: makro `/click PortaxiNextButton` nebo klávesa z nastavení přes `SetOverrideBindingClick` (playbook D14, žádný `Bindings.xml`).
- Atributy (`type=item` + scroll a cíl `party1` / `type=spell` + portál) se mění jen mimo boj. V `InCombatLockdown()` se změna zařadí do fronty a provede na `PLAYER_REGEN_ENABLED`.
- Addon nikdy nesesílá sám; jen připraví tlačítko.

---

## 8. UI

Podle makety v0.8, ve WoW frame API (XML nebo čisté Lua, doporučuji Lua + `BackdropTemplate`):

- **MainFrame**: portrét třídy (`SetPortraitTexture` nebo ikona třídy), titulek, zavírací křížek, spodní záložky Ride / Drive (Drive jen když `canDrive`), pamatuje pozici.
- **RideTab**: řádek „read by addon“ (frakce, třída, místo, odpočinek, zlato), dlaždice měst (šedé `SetDesaturated(true)`, vybraná barevná se zlatým rámečkem), volba Hail / Browse, stepper maxima, varování při nedostatku zlata.
- **DriveTab**: blok detekce (portály naučené/nenaučené, runy, scroll, odpočinek, co se teď nabízí a proč je něco pozastavené), na směně ano/ne, ceny za služby, seznam poptávek s tlačítky Take.
- **RidePanel**: emblém cíle, kroky jízdy, cast bar (`UnitCastingInfo("party1")`), okno tradu se stavem, tlačítka akcí.
- **DutyBox**: malý přesouvatelný box, jen na směně: stav, ceny, počet poptávek, nejlepší poptávka s tlačítkem Take (požadavek z G1).
- **Minimap**: vlastní tlačítko (bez LibDBIcon, playbook D1), tooltip (role a stav směny), klik otevře/zavře.
- **Alerts**: `RaidNotice_AddMessage(RaidWarningFrame, …)` + `PlaySound(SOUNDKIT.RAID_WARNING)` při nové poptávce, kterou taxík umí splnit.
- **Emblémy**: SVG z makety → 64×64 TGA (ImageMagick/Inkscape) do `Media/`. Vlastní kresby, žádná Blizzard loga.

---

## 9. Testování

- **Offline** (Lua 5.1, `busted` nebo jednoduchý runner v `tests/`): `Protocol` (encode/decode, verze, ořezy), `Market` (expirace, Hail: nejnižší ETA, remíza 15 s → nejdéle čekající, determinismus, filtr podle zlata/runy/scrollu/odpočinku).
- **Ve hře** (2–3 účty, stejná frakce): scénáře
  1. Mág bez runy se nenabízí; po koupi runy se nabídne do 60 s.
  2. Zákazník s 50s nepošle Hail s max 3g.
  3. Hail se dvěma mágy: vyhraje rychlejší; při remíze ≤ 15 s ten déle čekající.
  4. Come-to-you celý průchod: parta, scroll, trade (zákazník zapíše částku podle panelu), portál až po platbě.
  5. Zákazník odejde z hostince před scrollem → tlačítko scrollu zešedne.
  6. Zákazník zruší po scrollu → lokální záznam pozdního storna.
  7. Pickup přes Browse.
  8. Boj během jízdy → secure tlačítko se aktualizuje po boji.
  9. Odhlášení taxíka uprostřed jízdy → timeout a `FAILED` u zákazníka.

---

## 10. Postup po krocích (jeden krok = jedna session = jeden commit)

> Nahrazeno vlnami v `docs/PORTAXI_MVP_PLAYBOOK.md` (víc agentů souběžně, offline simulátor místo druhého hráče). Tabulka níže zůstává jako přehled obsahu.

**Stav k 2026-11-18:** vlny 0, 1 a 2 hotové a spojené, brány G0, G1 a G2 prošly (playbook §0). Scénáře 1–9 z §9 jsou zelené **v simulátoru** (`tests/sim_s1`–`s9`), `tools\check.ps1` zelený. Ve hře je ověřené to, co zvládne jedna postava, a navíc pozvánka a otevření tradu se skutečným hráčem bez addonu (body 0.5 a 0.7). Probíhá vlna 3 (karta J vzhled a erby, karta K dokumenty), pak brána G3 a G-final se dvěma hráči s addonem.

| Krok | Obsah | Hotovo, když | Stav |
|---|---|---|---|
| 1 | Kostra: `.toc`, knihovny, `Init`, `Const`, `/ptx`, prázdné okno se záložkami, tlačítko u minimapy | Addon se načte bez chyb, okno jde otevřít a zavřít. | ✓ Vlna 0 + karta F, brány G0 a G1. Bez externích knihoven (playbook D1). |
| 2 | `Detect` + blok „read by addon“ v obou záložkách | Údaje sedí na 3 postavách (mág s runou, mág bez scrollu, warrior). | ✓ Karty C a F, G1 (oprava `LEARNED_SPELL_IN_TAB`), G2 (místo a odpočinek za pohybu). Ve hře zatím jen Horde mág; warrior a mág bez scrollu jen v testech. |
| 3 | `Protocol` + `Net` + offline testy protokolu | Dva klienti si v kanálu vymění `HELLO`; testy zelené. | ✓ offline (karty A, D, simulátor E). Výměna `HELLO` mezi dvěma hráči ve hře čeká na G-final. |
| 4 | `Market`: nabídky, expirace, Browse seznam, dlaždice s cenou „from“ | Druhý klient vidí taxíka s cenou; po odhlášení zmizí do 150 s. | ✓ offline (karty B a G). Ve hře čeká na G-final. |
| 5 | Hail + Book párování + raid warning + offline testy výběru vítěze | Scénář 3 ve hře; testy zelené. | ✓ offline (karta G, scénáře 1, 2, 3, 7). Scénář 3 ve hře čeká na G-final. |
| 6 | `Ride`: parta, stavy, cast bar, storna, timeouty | Scénáře 5, 6, 9. | ✓ offline (karta H, scénáře 5, 6, 9). Pozvánka z timeru ověřená ve hře (G2). |
| 7 | `Trade` + `Secure`: trade, předvyplnění, kontrola platby, tlačítko scroll/portál, keybind | Scénáře 4, 7, 8. | ✓ offline (karta I, scénáře 4 a 8). Ve hře: trade z timeru ✓, klávesa ✓, předvyplnění zlata přes API **nejde** (zákazník zlato píše sám, viz `PHASE0_FINDINGS.md` 0.8). |
| 8 | Dotažení UI (emblémy, texty), test s 3–5 kamarády, záznam chyb | Deset jízd bez ručního zásahu kromě povinných kliků. | Probíhá: vlna 3 (karta J erby a texty, karta K README a dokumenty). Test s kamarády po G-final. Zadání zlata do tradu zůstává ruční krok. |

Fáze 2 a 3 dostanou vlastní plán podle výsledků testu s kamarády.

---

## 11. Rizika

| Riziko | Dopad | Zmírnění | Co víme teď (2026-11-18) |
|---|---|---|---|
| Addon zprávy přes vlastní kanál nefungují | Bez sítě není dispečink | Fáze 0.3 jako první; plán B: guild + whisper (menší rozsah). | Kanál funguje z jedné postavy: připojení, odeslání do `CHANNEL`, ozvěna od serveru a whisper na řetězec odesílatele. Příjem u druhého hráče s addonem ověří G-final. Riziko je menší, ne pryč. |
| Pozvánka / trade z addonu vyžadují klik | Víc kliknutí | Tlačítka s jasným „další krok“; jádro funguje i tak. | Pozvánka (0.5) a otevření tradu (0.7) z timeru fungují. Přijetí pozvánky (0.6) neověřené. Ruční tlačítka *Invite*, *Accept* a *Open trade* jsou hotová (D11). |
| Předvyplnění zlata v tradu nejde | Zákazník musí částku napsat sám; víc chyb v částce | Panel jízdy ukáže částku; taxík vidí varování při nižší nabídce a portál se odemkne až po kontrole přijatého zlata. | **Nastalo (G2):** `C_TradeInfo.SetTradeMoney` je pro addon zakázané. Addon ho nevolá (`Const.TRADE.SET_MONEY_API = false`). Záloha přes pole okna tradu (`MoneyInputFrame_SetCopper`) je také zakázaná (G3). Zákazník zlato zapisuje vždy sám. |
| Blokované volání se nedá poznat podle jména | Addon nepřepne na ruční krok, nebo přepne špatný | Zablokování se přiřazuje volání, které právě běží (`calling` v Ride a Trade); jméno funkce je jen záloha. | **Nastalo (G2):** Forever hlásí `ADDON_ACTION_FORBIDDEN` s funkcí `"UNKNOWN()"`. Opraveno v Ride a Trade. |
| Stejná křestní jména | Dva hráči se stejným jménem splývají; hráč se stejným jménem jako já se zahodí jako vlastní ozvěna | Klíč hráče = celé `"Jméno Příjmení"`; zvát celým jménem. | **Platí (web, 2026-11-18):** Forever nemá realmy, postavy mají jméno a příjmení a jedinečná je jen dvojice. Pozvánka celým jménem funguje (G2) a Ride ji používá. **Vyřešeno:** klíč hráče je celé `"Jméno Příjmení"` (podle `/ptx diag`: `UnitName` vrací jméno a příjmení). |
| Scroll nejde použít přes secure tlačítko nebo je vzácný | Come-to-you jen ručně / drahé | Hlídání podmínek zůstává; cenu řeší trh. | ID svitku `213548` a jeho kouzla `434752` známe. Použití přes secure tlačítko na člena skupiny, doba sesílání, cooldown a pravidlo odpočinku jsou neověřené. Addon svitek připraví jen když odpočívají oba. |
| Upravený klient lže v protokolu | Falešné nabídky, ceny | Portál až po platbě; sanity checks; reputace ve fázi 3. | Beze změny. Protocol odmítá hodnoty mimo rozsah a řídicí znaky; taxík ověřuje platbu podle vlastního zlata. |
| Změna klienta Forever | Rozbité API | Konstanty v `Const.lua`, kontrola `## Interface` při každém patchi. | Forever je moderní klient a klasické globály chybí. Addon hledá API za běhu (`ns.api`) a události registruje po jedné, protože neznámá událost (`LEARNED_SPELL_IN_TAB`, G1) vyhodí chybu. |
| Pravidla serveru | Zákaz služby | Ověřit v 0.12 před veřejným vydáním. | Neověřeno. |

---

## 12. Otevřené otázky

Zodpovězené a vyřazené: výchozí ceny (v MVP pevné 3g / 1g 50s, `Core/Init.lua`; „obvyklá cena“ ze sítě až ve fázi 2) a jazyky UI (v MVP jen angličtina, `Locales/enUS.lua`; klíče jsou připravené pro další jazyky).

1. ~~Finální název.~~ Vyřešeno 2026-11-19: veřejně **ForeverPortaxi** (titulek v TOC, CurseForge); složka, příkazy, SavedVariables a kanál zůstávají `Portaxi`.
2. ~~Repozitář a distribuce.~~ Vyřešeno 2026-11-19: GitHub `wejrcze/Portaxi`, CurseForge projekt 1816274 (`tools/release.ps1`).
3. ~~Klíč hráče = jméno + příjmení.~~ Vyřešeno 2026-11-18: `/ptx diag` ukázal, že `UnitName` vrací jméno a příjmení; klíčem je celé `"Jméno Příjmení"`. Otevřené zůstává jen, v jakém tvaru přichází jméno v `PARTY_INVITE_REQUEST` (addon porovná aspoň křestní jméno).
4. **Svitek ve hře.** Odpočívat musí oba (tooltip, 2026-11-19), addon to tak už má; použít ho může jen mág. Ověřeno 2026-11-19: sesílání 1,0 s, ubyde jen při úspěchu, secure tlačítko na `party1` funguje. Opraveno 2026-11-19: `Ride` už nebere `SUCCEEDED` svitku jako příchod (přijde i při „Invalid target“), čeká na úbytek svitku nebo blízkost zákazníka; `Const.CAST.SCROLL = 1`.
5. ~~Záloha pro zlato v tradu.~~ Rozhodnuto (G3): pole okna tradu je pro addon zakázaný objekt, zlato zapisuje zákazník. Otevřené zůstává jen: mají sondy `/ptx trade` a `/ptx tradefield` (obě vyvolají chybu) v addonu zůstat do vydání?
6. **Konec jízdy v jiném jazyce klienta.** Zákazník končí jízdu, když `GetZoneText()` = anglický název města z `Const.CITY`. Na neanglickém klientu jízda sama neskončí. Poznávat cíl podle `mapId` místo názvu?
7. ~~Auto-take.~~ Rozhodnuto (architekt, vlna 3): zůstává ve fázi 2 podle §1; zmínky v §3, §6 a §8 jsou odstraněné.
