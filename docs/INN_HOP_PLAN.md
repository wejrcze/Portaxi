# Portaxi — plán funkce Inn hop

Mág se Scrollem of Liminal Passage přeskočí do libovolné hospody nebo hlavního města, kde právě odpočívá
**hostitel**. Hostitelem je hráč s Portaxi, který se k tomu přihlásil, nebo hráč bez addonu nalezený přes `/who`.
Podnět: addon *Liminal Passage – Mage Teleport Helper* (CurseForge 1802186, All Rights Reserved: přebíráme nápad,
ne kód). Portaxi má oproti němu síť: hostitelé s Portaxi se ukážou hned, bez `/who` a bez šeptání.

Stav (2026-11-19): rozhodnutí R1–R5 v §9 uživatel potvrdil. Rozhraní v §5 a §6 a rozšíření D10 (automatické přijetí pozvánky od domluveného mága) potvrdí architekt v kroku 2. Další krok: fáze 0 (§3).

---

## 1. Co víme o svitku

| Fakt | Zdroj |
|---|---|
| Item `213548`, kouzlo `434752` „Liminal Passage“, stackuje se. | `/ptx diag` 2026-11-18 |
| Použít ho může **jen mág**. | uživatel 2026-11-19 |
| „Teleport to a party member. Both you and the target must be resting at an inn or city.“ Přenese **sesílatele** k členovi party; odpočívat musí **oba** (hlavní město, nebo hospoda s rested). | tooltip, build 70959 (wowhelm); uživatel |
| Sesílání **1,0 s** (naměřeno 0,95–1,02 s). Spotřebuje se **jen při úspěchu**, jeden kus; přenos jde přes loading screen. Cooldown a pohyb neměřeno. | sonda `/ptx scroll` 2026-11-19 |
| Neúspěch (cíl neodpočívá, nebo jiný neplatný cíl): `UNIT_SPELLCAST_SUCCEEDED` **přijde i tak**, hned po něm chyba „Invalid target“ (`UI_ERROR_MESSAGE`), svitek neubude, mág se nehne. | sonda `/ptx scroll` 2026-11-19 |
| `C_FriendList.SendWho` z příkazu (hardwarová událost) **funguje**: `WHO_LIST_UPDATE` za 0,2 s, nejvýš 50 výsledků, okno Who se neotevře. Z časovače ho hra **zablokuje** (`ADDON_ACTION_BLOCKED`). Cooldown neměřeno. | sonda `/ptx who` 2026-11-19 |

Come-to-you portál z MVP používá stejný mechanismus obráceně: taxík (mág) použije svitek na zákazníka, který tím
hraje roli hostitele. Inn hop je tedy **Come-to-you bez obchodu a bez portálu**: mág se přenese k odpočívajícímu
členovi party a tím jízda končí.

## 2. Rozsah

### V první verzi (Inn hop 1)

| Oblast | Co |
|---|---|
| Hostitel (jakákoli třída, s Portaxi) | Přepínač *Host mage travellers*, výchozí **vypnuto**. Zapnutý hostitel ohlašuje do sítě, kde odpočívá, jen dokud odpočívá a má místo v partě. Žádost mága potvrdí **klikem** (*Accept* / *Decline*). Pak ho addon přijme do party, svitek proběhne a addon partu zase opustí. |
| Mág (hopper) | Část *Inn hop* v okně (jen pro mága se svitkem): seznam míst s hostiteli (hlavní města nahoře, pak hospody podle zóny), vyhledávání podle názvu. Klik *Hop here* pošle žádost; po přijetí addon pozve hostitele, připraví svitek na tlačítko Portaxi, mág klikne a je tam. |
| Hostitel bez addonu | Záloha přes `/who`: mág vybere zónu, klikne *Search*, dostane hráče své frakce v zóně a u vybraného klikne *Ask*. Addon pošle šeptání (anglicky nebo rusky, šablona jako u D16) s prosbou o pozvánku a o zůstání v hospodě. Pozvánku od tohoto hráče mág **přijme sám** (klik), svitek se připraví jako výše. Addon neví, jestli hostitel odpočívá; panel to připomene. |
| Bezpečnost | Addon nikdy nesesílá (tlačítko Portaxi). Hostitel každou žádost potvrzuje klikem. Pozvánku přijme addon automaticky jen od toho, s kým je hop domluvený (rozšíření D10). Ohlašování místa je dobrovolné a jen pro vlastní frakci. |

### Mimo první verzi

| Co | Proč později |
|---|---|
| Spropitné hostiteli (cena, trade, kontrola zlata) | Nejdřív zjistit, jestli se hostitelé najdou i bez odměny; viz rozhodnutí R1. |
| Uložená vlastní místa, piny na mapě, šipka k hospodě | Pohodlí; jádro funguje i bez toho. |
| Hop pro warlocky (summon) | Warlocky řeší fáze 2 MVP. |
| Řazení hostitelů podle spolehlivosti | Patří k reputaci ve fázi 3 MVP. |

## 3. Fáze 0 — co ověřit ve hře (uživatel, jeden mág + kamarád)

| # | Co | Jak | Když to nejde |
|---|---|---|---|
| H0.1 | Doba sesílání svitku, jestli ubyde ze stacku, co se stane, když cíl neodpočívá (chyba, spotřeba?). | Použít svitek na člena party v hospodě; sledovat cast bar a počet svitků; jednou s cílem mimo hospodu. | Upravit `Const.CAST.SCROLL`; při spotřebě i na neúspěch varovat v panelu. |
| H0.2 | Svitek přes secure tlačítko na `party1` (platí i pro Come-to-you). | Tlačítko Portaxi s `item:213548` na `party1`. | Zůstává ruční použití; addon jen hlídá podmínky. |
| H0.3 | Co vrací `GetSubZoneText()` a `GetZoneText()` v hospodách (název hospody, nebo vesnice?) a jestli `IsResting()` platí v celé hospodě. | `/ptx diag` ve 3 hospodách. | Místo se pojmenuje zónou + podzónou, jak přijdou. |
| H0.4 | `C_FriendList.SendWho` z kliknutí: funguje, filtr zóny (`z-"Crossroads"` nebo `z-"The Barrens"`), kam přijdou výsledky (událost vs. okno Who), cooldown. | Sonda `/ptx who <zone>` (nový příkaz v `Probe.lua`). | Záloha `/who` vypadne; zbydou hostitelé s Portaxi. |
| H0.5 | Dosah svitku: funguje přes kontinenty (Kalimdor ↔ Eastern Kingdoms)? | Hop z Orgrimmaru do hospody v Eastern Kingdoms. | Seznam míst omezit na kontinent mága. |

### Výsledky (2026-11-19, sondy `/ptx scroll` a `/ptx who`)

| # | Výsledek |
|---|---|
| H0.1 | ✓ Sesílání 1,0 s. Spotřeba jen při úspěchu (2 → 1). Při neplatném cíli přijde `SUCCEEDED` a hned „Invalid target“, svitek zůstane (4 pokusy). **Úspěch se proto nesmí poznávat podle `SUCCEEDED`**, ale podle úbytku svitku nebo přesunu mága (loading screen, změna zóny, blízkost cíle); chyba „Invalid target“ do 1 s po castu = neúspěch. Zbývá: chování za pohybu, cooldown. |
| H0.2 | ✓ Tlačítko Portaxi se svitkem na `party1` funguje (hop Riverglades / Rog'mar → Orgrimmar). |
| H0.3 | Částečně: Rog'mar (Riverglades) je místo s odpočinkem, podzóna = název osady; Orgrimmar má podzónu čtvrti (Valley of Strength). Zbývají 2–3 hospody v klasických zónách. |
| H0.4 | ✓ `/who` ze slash příkazu funguje (50 výsledků, 0,2 s, bez okna Who); z časovače zablokováno. Záloha `/who` v Inn hopu tedy jde, ale jen z tlačítka *Search*. Zbývá cooldown (dvě hledání hned po sobě). |
| H0.5 | Neověřeno: Riverglades → Orgrimmar; na kterém kontinentu Riverglades leží, ještě nevíme. |

**Dopad na Come-to-you (MVP), opraveno 2026-11-19:** `Ride` přepínal na `ARRIVED` už při `SUCCEEDED` svitku, takže
při „Invalid target“ by taxík otevřel trade, i když se nepřenesl. Teď čeká na důkaz přesunu (`LANDED`: úbytek svitku,
nebo zákazník na dosah) a chyba nebo `T.LANDING` bez důkazu vrací jízdu do `GROUPED`. Inn hop to převezme.

## 4. Průběh hopu (hostitel s Portaxi)

```
Mág                                   Síť                         Hostitel
                                      <- HOST (místo, každých 60 s, jen když odpočívá a má volno)
vybere místo, klik "Hop here"
HOP (reqId) --------------------------whisper------------------->  alert + zvuk: "Velvet wants to hop to you"
                                                                   klik Accept (do 30 s)
                                      <-----------------whisper--  HOPOK (reqId)
Ride.start(svc HOP, role taxi)                                     Ride.start(svc HOP, role rider)
InviteUnit(hostitel) z časovače  -------------------------------->  auto AcceptGroup jen od tohoto mága
GROUPED: tlačítko Portaxi = svitek na hostitele, jen když odpočívají oba (STATE RESTING jako u Come-to-you)
klik -> cast Liminal Passage  ---- EN_ROUTE ---------------------->
_SUCCEEDED -> ARRIVED -> DONE; addon mága opustí partu (stejně jako taxík po jízdě)
```

- Odmítnutí nebo 30 s bez odpovědi: `HOPNO`, mág dostane zprávu a může zkusit jiného hostitele.
- Mág má otevřenou nejvýš jednu žádost; nová žádost na stejného hostitele až po 60 s (ochrana před spamem).
- Hostitel s otevřenou žádostí nebo během hopu ohlašuje `HOST` s `free = 0`, takže ho ostatní mágové nevidí.
- Storno: kdokoli zdarma až do začátku sesílání (stejně jako Come-to-you); pozdní storno se u hopu nepočítá
  (nic se neplatí).

## 5. Protokol (verze zůstává 1)

Nové typy zpráv. Starší Portaxi je zahodí jako neznámý typ (`decode` → `"type"`), takže se síť nerozbije.

| type | pole (pořadí na drátě) | kudy |
|---|---|---|
| `HOST` | `fac` str, `lvl` int, `zone` str, `sub` str, `city` city key nebo prázdné, `free` bool | kanál, každých `T.HOST_HELLO` s (60 ± 10), hned po změně místa |
| `UNHOST` | — | kanál: přestal odpočívat, vypnul hostování, odhlásil se |
| `HOP` | `reqId` str, `lvl` int | whisper mág → hostitel |
| `HOPOK` | `reqId` | whisper hostitel → mág |
| `HOPNO` | `reqId`, `why` (`"busy"` / `"declined"` / `"timeout"`) | whisper hostitel → mág |

Dál se používají `STATE` (odpočinek, stavy jízdy) a `CANCEL` s `reqId` hopu. `zone` a `sub` jsou názvy z klienta
bez `|` a `,` (pravidlo z Protocol), délka zprávy ≤ 255 B i s dlouhým názvem hospody.

## 6. Změny modulů

| Modul | Změna |
|---|---|
| `Const` | `T.HOST = 150` (expirace hostitele), `T.HOST_HELLO = 60`, `T.HOP_ANSWER = 30`, `T.HOP_RETRY = 60`; `CAST.SCROLL` podle H0.1; svc `HOP`. |
| `Protocol` (čistý) | Pět nových typů z §5, testy kódování a rozsahů. |
| `Detect` | `profile.placeKind = "city"` (zóna = `Const.CITY[*].name`) / `"inn"` (odpočívá jinde) / `nil`; `services.HOP` = mág se svitkem, odpočívá, není v partě; `services.HOST` = odpočívá, má místo v partě. Pauzy `NO_SCROLL`, `NOT_RESTING`, `IN_GROUP`. |
| `Market` (čistý) | `m:host(key, host, now)`, `m:unhost(key)`, expirace po `T.HOST`, `m:hosts({ faction, exclude })` → seznam míst (město / zóna + podzóna) s hostiteli, města první, pak abecedně. |
| `Dispatch` | Ohlašování `HOST`/`UNHOST` podle `PortaxiCharDB.host` a `services.HOST`; `Dispatch.hop(hostKey)` (mág), `Dispatch.answerHop(reqId, ok)` (hostitel, z kliku); timeouty `T.HOP_ANSWER`, `T.HOP_RETRY`; po `HOPOK` `Ride.start` na obou stranách. Nové události `HOP_REQUEST` (hostitel), `HOP_RESULT` (mág), `HOSTS_CHANGED`. |
| `Ride` | Služba `HOP`: stejné kroky jako `COME` do `ARRIVED`, potom rovnou `DONE` (žádný `TRADING`/`PAID`/`PORTAL_OPEN`). Role: mág = `taxi` (zve, sesílá), hostitel = `rider` (přijímá pozvánku, hlásí odpočinek). U hopu přes `/who` jízda bez protistrany s addonem: `peer.noAddon = true`, bez `STATE`, svitek připravený bez kontroly odpočinku hostitele. Po `DONE` mág opustí partu. |
| `Who` (nový, `Core/Who.lua`) | `Who.search(zone)` jen z kliku (`C_FriendList.SendWho`), výsledky z `WHO_LIST_UPDATE` (`C_FriendList.GetWhoInfo`), filtr vlastní frakce, cooldown podle H0.4; `Who.ask(name)` = whisper ze šablony + zapamatování „čekám pozvánku od X“ na `T.INVITE`. |
| `Locales/enUS` | Texty UI, šablony šeptání EN a RU. |
| UI | Nová část *Inn hop* (`UI/HopTab.lua`, nová záložka *Hop* jen pro mága se svitky): stav svitku a odpočinku, vyhledávání, seznam míst s hostiteli, *Hop here*; blok *No host here?* se zónou, *Search* a výsledky `/who` s *Ask*. Na záložce *Ride* pro všechny přepínač *Host mage travellers*. Alert hostiteli (raid warning + zvuk + okno *Accept*/*Decline* s odpočtem). `RidePanel` umí svc `HOP` (bez kroků obchodu a portálu). |
| `Init` | `PortaxiCharDB.host = false`; příkazy `/ptx host` (zapnout/vypnout hostování) a `/ptx hop` (otevře záložku Hop). |
| `Portaxi.toc` | Nové soubory `Core/Who.lua`, `UI/HopTab.lua` — **vyžaduje restart klienta** (D7). |

Čisté zůstávají `Protocol`, `Market`, jádro `Ride` a `Detect.services` (D3); vše nové v nich dostane testy.

## 7. Testy

| Soubor | Co |
|---|---|
| `tests/protocol_test.lua` | Nové typy: kódování, chybějící pole, rozsahy, dlouhý název hospody. |
| `tests/market_test.lua` | Hostitelé: přidání, expirace, `free = 0` se neukazuje, filtr frakce, řazení míst. |
| `tests/detect_test.lua` | `placeKind`, `services.HOP` / `HOST` a pauzy. |
| `tests/ride_test.lua` | Svc `HOP`: `ARRIVED → DONE`, žádný trade; storno před castem; `noAddon` bez `STATE`. |
| `tests/sim_hop_test.lua` | Simulátor: hostitel ohlásí místo, mág ho vidí, žádost, přijetí, parta, cast, konec, opuštění party; odmítnutí; timeout odpovědi; hostitel přestane odpočívat uprostřed. |
| `tests/who_test.lua` | Zpracování výsledků `/who` z falešného `C_FriendList` (wowstub). |

Brána ve hře (dva hráči s addonem): hostitel v hospodě, mág v Orgrimmaru; tři hopy po sobě bez ručního zásahu
kromě povinných kliků (Accept, tlačítko Portaxi). Záloha `/who` s hráčem bez addonu jednou.

## 8. Postup (jedna vlna = jeden commit, playbook se dopíše před startem)

| Krok | Obsah | Hotovo, když |
|---|---|---|
| 1 | Fáze 0: sonda `/ptx who`, uživatel ověří H0.1–H0.5. | Tabulka §3 vyplněná; rozhodnutí v §9 potvrzená. |
| 2 | Architekt: `Const`, kontrakty v playbooku (§5, §6), TOC s prázdnými `Who.lua` a `HopTab.lua`. | `check.ps1` zelený, klient po restartu načte addon. |
| 3 | Souběžně: `Protocol` + `Market` (čisté, testy); `Detect`; `Who`. | Testy zelené. |
| 4 | `Dispatch` (HOST, HOP handshake) + `Ride` svc `HOP` + simulátor `sim_hop`. | Scénář hopu zelený v simulátoru. |
| 5 | UI: záložka Hop, přepínač hostování, alert hostiteli, `RidePanel` pro `HOP`, texty. | `ui_smoke_test` zelený; ve hře okno bez chyb. |
| 6 | Brána ve hře se dvěma hráči (§7), opravy. | Tři hopy po sobě + jeden přes `/who`. |
| 7 | README, `docs/curseforge/description.md`, `Changelog.lua`, verze 0.2.0, `tools\release.ps1`. | Vydáno na CurseForge. |

## 9. Rozhodnutí (uživatel potvrdil 2026-11-19)

| # | Otázka | Rozhodnutí |
|---|---|---|
| R1 | Odměna hostiteli? | V první verzi **zdarma**; mág může poslat zlato ručně. Spropitné s kontrolou platby až podle zájmu. |
| R2 | Hostování výchozí zapnuté, nebo vypnuté? | **Vypnuté** (ohlašuje polohu); při prvním odpočinku v hospodě jedna nenápadná nabídka „Host mage travellers?“. |
| R3 | Má hostitel každou žádost potvrzovat klikem? | **Ano.** Volitelné „přijímat automaticky“ až později. |
| R4 | Přijímat pozvánku od hráče bez addonu (záloha `/who`) automaticky? | **Ne**, mág klikne sám; automaticky jen u hostitele s Portaxi po `HOPOK`. |
| R5 | Kde v okně? | Vlastní záložka **Hop** (jen mág se svitky), přepínač hostování na záložce Ride. |

## 10. Rizika

| Riziko | Dopad | Zmírnění |
|---|---|---|
| Málo hostitelů | Mág nemá kam skočit | Záloha `/who`; nabídka hostování při odpočinku; hostitelé jsou všechny třídy, ne jen mágové. |
| Svitek nejde přes secure tlačítko | Hop jen ručně | Panel ukáže, na koho svitek použít; stejné riziko už nese Come-to-you (H0.2). |
| `/who` z addonu na Forever nejde | Bez zálohy pro hráče bez addonu | Hostitelé s Portaxi fungují i tak; záloha se skryje (`PortaxiDB.caps.who = "manual"`). |
| Poloha hostitele je vidět v kanálu | Kdokoli v `PortaxiNet` vidí, kde hostitel odpočívá | Dobrovolné, jen během odpočinku v hospodě nebo městě, jen zóna a podzóna; vypne se jedním klikem. |
| Spam žádostí | Otravuje hostitele | Jedna žádost na mága, `T.HOP_RETRY` na stejného hostitele, hostitel může hostování vypnout. |
| Hostitel odejde z hospody během hopu | Svitek selže | `STATE NOT_RESTING` → tlačítko se odzbrojí; panel ukáže proč. |
