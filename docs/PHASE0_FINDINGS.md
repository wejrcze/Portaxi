# Portaxi — zjištění fáze 0

Souhrn bodů 0.1–0.12 z plánu (`docs/PORTAXI_MVP_PLAN.md` §2): co je ověřené ve hře, co ne a co addon kvůli tomu dělá.
Stav k 2026-11-18 (po bráně G2).

Zdroje:

- **diag**: `/ptx diag` → `PortaxiDB.diag` (jedna postava: Horde mág, lvl 40–41, OG + UC, 7 run, 9 scrollů).
- **sonda**: příkazy z `Core/Probe.lua` → `PortaxiDB.probe.log`.
- **G0 / G1 / G2**: kontroly ve hře na konci vln (playbook §0 a §7). G2 proběhla se skutečným hráčem, který addon neměl.
- **Const**: komentáře v `Portaxi/Core/Const.lua`.

Druhý hráč s addonem zatím nebyl. Všechno, co ho potřebuje, ověří brána G-final (playbook §7).

## Přehled

| # | Bod | Stav | Datum, zdroj |
|---|---|---|---|
| 0.1 | Verze klienta, `## Interface` | ověřeno | 2026-11-18, diag, G0, G1 |
| 0.2 | Scroll of Liminal Passage | částečně | 2026-11-18, diag, G1 |
| 0.3 | Addon zprávy přes vlastní kanál | částečně | 2026-11-18, sonda `/ptx net` |
| 0.4 | Kanál oddělený podle frakce | neověřeno | — |
| 0.5 | Pozvánka z addonu bez kliknutí | ověřeno | 2026-11-18, sonda `/ptx invite`, G2 |
| 0.6 | Automatické přijetí pozvánky | neověřeno | — |
| 0.7 | Otevření tradu z addonu | ověřeno | 2026-11-18, sonda `/ptx opentrade`, G2 |
| 0.8 | Předvyplnění zlata | nejde (API ani pole okna) | 2026-11-18, sondy `/ptx trade` (G2) a `/ptx tradefield` (G3) |
| 0.9 | Čtení přijatého zlata | neověřeno | — |
| 0.10 | ID kouzel a předmětů | částečně | 2026-11-18, diag, G0, G1 |
| 0.11 | Summon na Forever | neověřeno (fáze 2) | — |
| 0.12 | Pravidla serveru k placeným službám | neověřeno | — |

## Body

### 0.1 Verze klienta — ověřeno

- **Zjištěno (diag 2026-11-18, potvrzeno G0):** klient `1.60.1`, build `70959` (13. 11. 2026), interface `16001`. Klientská přípona TOC je `_Forever`.
- Je to **moderní klient**. Globální `GetItemCount` neexistuje (první diag na něm spadl), je jen `C_Item.GetItemCount`. `IsSpellKnown` funguje. Globální `SetTradeMoney` chybí, je `C_TradeInfo.SetTradeMoney` (ale viz 0.8).
- **G1:** Forever nezná událost `LEARNED_SPELL_IN_TAB`. `RegisterEvent` na ní vyhodil chybu a zbylé události Detect se nezaregistrovaly („Place: unknown“, odpočinek se neobnovoval).
- **Co addon dělá:**
  - TOC má `## Interface: 16001`.
  - API, která nemusí existovat, hledá za běhu přes `ns.api("C_X.Fn", "Fn")`, varianta `C_` má přednost (D4). Klasické globály napřímo nevolá.
  - Detect a Ride registrují herní události po jedné přes `pcall`. Neznámá událost tak nezastaví ostatní. `LEARNED_SPELL_IN_TAB` je vyřazená (naučený portál pokryje `SPELLS_CHANGED`) a `wowstub` ji odmítá stejně jako hra.

### 0.2 Scroll of Liminal Passage — částečně

- **Zjištěno (diag 2026-11-18):** itemID `213548`, stackuje se (9 ks v batohu).
- **Zjištěno (diag, G1):** svitek sesílá kouzlo „Liminal Passage“, spellID `434752` (`C_Item.GetItemSpell`).
- **Zbývá:** spotřebovává se?, cooldown, jen mág?, cílení (`party1` / target), doba sesílání a pravidlo odpočinku (musí odpočívat cíl, sesílatel, nebo oba?).
- **Co addon dělá:**
  - `Const.ITEM.LIMINAL_SCROLL = 213548`, `Const.SPELL.LIMINAL_PASSAGE = 434752`.
  - Come-to-you nabízí jen taxík se svitkem, který odpočívá (`Detect.services`).
  - Secure tlačítko dostane `type=item`, `item:213548` a `unit` = jednotka zákazníka ve skupině. Připraví se jen když odpočívají **oba** (`ride.riderResting` a `ride.selfResting`). Je to předpoklad, ve hře neověřený.
  - Ride pozná svitek podle `UNIT_SPELLCAST_*` se spellID `434752`: START → `EN_ROUTE`, SUCCEEDED → `ARRIVED`, FAILED/INTERRUPTED → zpět `GROUPED`.
  - ETA Come-to-you počítá s `Const.CAST.SCROLL = 10` s. Hodnota je neověřená.

### 0.3 Addon zprávy přes vlastní kanál — částečně

- **Zjištěno (sonda `/ptx net`, 2026-11-18, jedna postava):**
  - `JoinTemporaryChannel("PortaxiNet")` → kanál id 6.
  - `SendAddonMessage` do `CHANNEL` vrací `0` (Success) a server zprávu vrátí i odesílateli.
  - Odesílatel přichází jako `"Jméno Příjmení"` (**mezera**, ne pomlčka; `Ambiguate` ji neodstraní).
  - Whisper na vlastní krátké jméno nedorazí. Whisper na řetězec odesílatele z kanálu ano.
- **Zbývá:** příjem zprávy u jiného hráče s addonem (G-final). Bod je blokující pro celý koncept.
- **Co addon dělá:**
  - Net se po přihlášení připojí ke kanálu `PortaxiNet` a odebere ho ze všech chatovacích oken. Zkouší to 30× po 1 s, pak to vzdá do `/reload`; zapnutí směny zkusí připojení znovu.
  - Klíč hráče je `ns.playerKey(sender)`, část před první mezerou nebo pomlčkou (D5). Whisper jde vždy na celý řetězec odesílatele, jak přišel.
  - Vlastní ozvěnu z kanálu Net zahodí.
  - Fronta odesílání má nejvýš 4 zprávy/s a strop 50 zpráv.
  - Celý průběh jízdy je ověřený jen offline v simulátoru více klientů (`tests/lib/sim.lua`, scénáře 1–9).

### 0.4 Kanál oddělený podle frakce — neověřeno

- **Zbývá:** stejný kanál z postavy Alliance a Horde (sonda `/ptx net` na obou).
- **Co addon dělá:** nespoléhá na oddělení. `HELLO` a `HAIL` nesou pole `fac`. Market ukazuje zákazníkovi jen nabídky jeho frakce a taxíkovi jen poptávky jeho frakce. Dlaždice měst jsou jen pro města vlastní frakce.

### 0.5 Pozvánka z addonu bez kliknutí — ověřeno

- **Zjištěno (G2, 2026-11-18, skutečný hráč):** `C_PartyInfo.InviteUnit("Jméno Příjmení")` z timeru prošel bez zablokování. Forever nemá realmy; druhé slovo je příjmení a jedinečná je jen dvojice jméno + příjmení, proto se zve celým jménem.
- **Co addon dělá:**
  - Taxík pozve zákazníka 0,5 s po spárování z timeru. Zve vždy celým jménem (řetězec odesílatele `"Jméno Příjmení"`).
  - Záloha (D11): zablokované volání → `PortaxiDB.caps.invite = "manual"` natrvalo a v panelu jízdy tlačítko *Invite*. Když se skupina nevytvoří do 15 s, tlačítko se ukáže jen pro tuto jízdu. Skupina se musí vytvořit do `T.INVITE = 60` s, jinak jízda skončí `FAILED`.

### 0.6 Automatické přijetí pozvánky — neověřeno

- **Zbývá:** `PARTY_INVITE_REQUEST` → `AcceptGroup()` + `StaticPopup_Hide("PARTY_INVITE")` z addonu (sonda `/ptx accept`). Při G2 se neověřovalo.
- **Co addon dělá:**
  - Zákazník přijme pozvánku jen od spárovaného taxíka (podle klíče hráče) a jen ve stavu `MATCHED`.
  - Dialog označí jako přijatý (`inviteAccepted`), aby ho skrytí neodmítlo.
  - Záloha (D11): zablokované volání → `caps.accept = "manual"` a tlačítko *Accept*. Bez skupiny 5 s po přijetí se tlačítko ukáže jen pro tuto jízdu.

### 0.7 Otevření tradu z addonu — ověřeno

- **Zjištěno (G2, 2026-11-18):** `InitiateTrade("target")` z timeru otevřel trade se skutečným hráčem.
- **Co addon dělá:**
  - Taxík ve stavu `ARRIVED` otevře trade s jednotkou zákazníka ve skupině (`InitiateTrade(peerUnit)` z timeru).
  - Záloha (D11): zablokované volání → `caps.openTrade = "manual"` natrvalo. Žádný `TRADE_SHOW` do 3 s (často jen vzdálenost) → tlačítko *Open trade* jen pro tuto jízdu.
  - Trade se nikdy nepotvrzuje za hráče (D10).

### 0.8 Předvyplnění zlata — nejde (API ani pole okna)

- **Zjištěno (G2, 2026-11-18, sonda `/ptx trade`):** `C_TradeInfo.SetTradeMoney` z addonu → `ADDON_ACTION_FORBIDDEN` s funkcí `"UNKNOWN()"`, částka zůstala 0.
- **Zjištěno (G3, 2026-11-18, sonda `/ptx tradefield`):** `MoneyInputFrame_SetCopper(TradePlayerInputMoneyFrame, 1)` → chyba „calling 'GetNumber' on bad self (Attempt to access forbidden object from code tainted by an AddOn)“. Pole okna tradu je pro kód addonu zakázaný objekt.
- **Co addon dělá:**
  - `Const.TRADE.SET_MONEY_API = false`: Trade `SetTradeMoney` nikdy nevolá.
  - `Const.TRADE.FILL_MONEY_FIELD = false` natrvalo.
  - Zákazník dostane v panelu jízdy výzvu „Put X into the trade window yourself.“ (`TRADE_MANUAL "prefill"`).
- **Další zjištění:** Forever hlásí zablokované volání jako `ADDON_ACTION_FORBIDDEN` s funkcí `"UNKNOWN()"`, ne jménem funkce. Ride a Trade proto přiřazují zablokování volání, které právě běží (`calling`); jméno funkce je jen záloha.

### 0.9 Čtení přijatého zlata — neověřeno

- **Zbývá:** celý trade se zlatem mezi dvěma hráči s addonem (G-final).
- **Co addon dělá (ověřeno jen v simulátoru):**
  - Taxík sleduje nabídku zákazníka (`GetTargetTradeMoney` na `TRADE_MONEY_CHANGED` / `TRADE_ACCEPT_UPDATE`). Nižší částku hlásí v panelu („Do not accept yet“).
  - Konec tradu pozná podle `UI_INFO_MESSAGE` „Trade complete.“ (nebo `ERR_TRADE_COMPLETE`), případně podle `TRADE_CLOSED` po potvrzení obou stran.
  - Platbu ověří rozdílem `GetMoney()` od `TRADE_SHOW` (`Trade.verify`). Když zlato dorazí později, čeká ještě 5 s na `PLAYER_MONEY`.
  - Teprve potom `TRADE_PAID` → stav `PAID` → secure tlačítko dostane portál.
  - Bez platby do `T.TRADE = 180` s po setkání jízda skončí `FAILED "trade_timeout"` na obou stranách.

### 0.10 ID kouzel a předmětů — částečně

- **Zjištěno (diag 2026-11-18, Horde mág lvl 40, znovu G0 na lvl 41):**
  - Portal: Orgrimmar `11417` a Undercity `11418` známé.
  - Thunder Bluff `11420` neznámý: učí se až na lvl 50, sedí s Classic.
  - Rune of Portals `17032` sedí (7 ks).
  - Svitek `213548` a jeho kouzlo `434752`, viz 0.2.
- **Zbývá:** Alliance portály (Stormwind `10059`, Ironforge `11416`, Darnassus `11419`), Thunder Bluff na mágovi lvl 50+, Ritual of Summoning `698` a Soul Shard `6265` na warlockovi (fáze 2).
- **Co addon dělá:** všechna ID jsou v `Const.lua`; neověřená mají komentář „unverified“. Destinace taxíka jsou jen naučené portály vlastní frakce (`IsPlayerSpell` / `IsSpellKnown`). `/ptx diag` vypíše, co postava zná, a uloží to.

### 0.11 Summon na Forever — neověřeno (fáze 2)

- **Zbývá:** Ritual of Summoning se 2 pomocníky (počet klikačů, dosah).
- **Co addon dělá:** v MVP nic. Warlock nemůže jezdit (`NOT_MAGE`). `Const` má jen ID pro fázi 2.

### 0.12 Pravidla serveru k placeným službám — neověřeno

- **Zbývá:** podmínky a fórum Forever. Bez souhlasu addon nepouštět veřejně.
- **Co addon dělá:** nic. Je to podmínka vydání, ne kódu.

## Další zjištění mimo body 0.x

- **Jméno a příjmení místo realmů (web, 2026-11-18).** Forever nemá realmy, jen rulesety; postava má jméno a příjmení a jedinečná je jen dvojice. `/ptx diag` (2026-11-18) ukázal: `UnitName(unit)` a `UnitFullName(unit)` vracejí jméno a příjmení jako dvě hodnoty (`"Aelric"`, `"Dawnmere"`), `GetUnitName(unit, true)` = `"Aelric Dawnmere"`, `GetRealmName()` = interní `"CAMWOW EU4 Realm 1 PvE"`. Klíčem hráče je proto celé `"Jméno Příjmení"` (`ns.playerKey`, `ns.unitKey`, `ns.selfKey`), stejná křestní jména už nesplývají.
- **Detekce místa a odpočinku za pohybu (G2):** po opravě z G1 funguje.
- **Okno, záložky, poloha okna a tlačítka u minimapy (G1), box na směně a klávesa secure tlačítka (G2):** fungují; poloha boxu se ukládá, klávesa F je přiřazená přes `/ptx key F`.
