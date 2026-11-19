# Portaxi — plán funkce Taxi na mapě (D19)

Mág si při levelení zapne **Na mapě**. Zákazníci, kteří hledají odvoz a jsou mimo hospodu, ho uvidí přibližně
na mapě světa a v seznamu Browse se vzdáleností a mohou ho jedním klikem požádat o odvoz (pickup: dojdou
k němu, zaplatí, projdou portálem). Přání uživatele 2026-11-19. Podnět: addon *Taxi Ride LindaLuna*
(CurseForge, mapa mágů ve službě). Bereme nápad, ne kód ani vzhled.

Stav (2026-11-19): rozhodnutí v §6 zvolil architekt jako výchozí, uživatel je přijal („zapiš a stav“).
Neověřené ve hře: viz §5.

---

## 1. Proč to zapadá

- Služba **PICK** (zákazník dojde k mágovi) nepotřebuje, aby mág odpočíval. Mág venku ji umí už v MVP, jen o něm
  nikdo neví, kde je (`HELLO.place` je jen zóna).
- Zákazník venku nemůže dostat **COME**: svitek chce, aby odpočívali oba. Kdo je ve městě, má Hail/Browse; kdo je
  venku, uvidí mágy poblíž.
- Žádost je obyčejný `BOOK` se službou PICK a dál běží běžná jízda (parta, šipka k mágovi, trade, portál).

## 2. Chování

### Mág

| Co | Jak |
|---|---|
| Přepínač | `PortaxiCharDB.field`, výchozí **vypnuto**. Tlačítko *Map* v DutyBoxu, `/ptx field`. Zapnutí mimo směnu zapne i směnu. |
| Kdy je na mapě | Na směně, `field` zapnuté, umí PICK (portál + runa), **neodpočívá**, není v instanci a addon zná vlastní polohu. Jakmile začne odpočívat (město, hospoda), je z něj zase běžný taxík ve městě, bez mapy. |
| Co posílá | `SPOT` do kanálu: hned po zapnutí, každých `T.SPOT` (30 ± 5 s) a po přechodu do jiného čtverce mřížky (kontrola každých `T.SPOT_CHECK` s, nejdřív `T.SPOT_GAP` s po minulém). Při odchodu z mapy jednou `SPOT` s `inst = -1`. `HELLO` beze změny. |
| Přesnost | Poloha se **před odesláním** zaokrouhlí na mřížku `FIELD.GRID` = 75 yardů. Přesnou polohu nikdo nedostane, dokud nejsou v partě (šipka). |
| Busy | V boji nebo během jízdy `busy = 1`: pin je šedý a nejde objednat. |
| Poptávky | Na mapě mág **nedostává raid warningy z Hailu** (zákazník z Orgrimmaru by šel přes půl světa). Ukazují se mu jen objednávky (`BOOK`), tedy zákazníci, kteří ho viděli na mapě nebo v Browse. |

### Zákazník

| Co | Jak |
|---|---|
| Kdo mapu vidí | Zvolil město v záložce Ride (hledá), neodpočívá, není v jízdě ani v instanci, addon zná jeho polohu. |
| Koho vidí | Mágy své frakce na stejném kontinentu (`inst`), do `FIELD.RANGE` = 1500 yardů, kteří umí zvolené město a nabízejí PICK. `SPOT` bez platného `HELLO` se ignoruje; `SPOT` vyprší po `T.SPOT_TTL` = 90 s. |
| Mapa světa | Pin na mapě (`WorldMapFrame`): měkký kruh o poloměru jedné buňky mřížky (přibližné místo) a ikona portálu. Tooltip: jméno, level, cena, vzdálenost, „asi N s pěšky“, *Click: ride to X*. Klik = objednávka (`Dispatch.book`). |
| Browse | Mágové na mapě jsou v seznamu nahoře, seřazení podle vzdálenosti, se zeleným proužkem a textem „~150 yd · ~25 s on foot“. Tlačítko *Book* jako u ostatních. |
| ETA | Zákazník si ETA spočítá sám ze vzdálenosti: yardy / `FIELD.SPEED` (7 yd/s, běh bez mountu) + doba reakce mága. Mág vzdálenost zákazníka nezná. |

## 3. Protokol (verze zůstává 1)

| type | pole (pořadí na drátě) | kudy |
|---|---|---|
| `SPOT` | `inst` int (-1 = není na mapě), `n` int, `w` int (světové souřadnice v yardech, zaokrouhlené na `FIELD.GRID`), `busy` bool | kanál |

Nová pole do `HELLO` přidat nejdou: `Protocol.decode` vyžaduje přesný počet polí, takže vydaná 0.1.0 by nový
`HELLO` zahodila a mág by v ní zmizel. Nový typ zprávy starší verze zahodí jako neznámý (`"type"`), vše ostatní jí
zůstane funkční.

## 4. Moduly

| Modul | Změna |
|---|---|
| `Const` | `T.SPOT`, `T.SPOT_JITTER`, `T.SPOT_CHECK`, `T.SPOT_GAP`, `T.SPOT_TTL`; `FIELD = { GRID, RANGE, SPEED }`. |
| `Protocol` (čistý) | Typ `SPOT`. |
| `Market` (čistý) | `m:spot(key, spot, now)` (jen k existující nabídce; `inst = -1` maže), spot vyprší s nabídkou nebo po `T.SPOT_TTL`, `m:nearby(q)` = nabídky PICK pro město a frakci na stejném `inst` do dosahu, nejbližší první. |
| `Field` (nový, `Core/Field.lua`) | Čisté: `Field.cell(n, w)`, `Field.walk(yards, resp)`. Za běhu: vlastní poloha (UnitPosition, záloha C_Map, jako šipka), `Field.active()`, smyčka `SPOT` mága, `Field.setOn(on)`, `Field.riderState()`, `Field.nearby(dest)` pro UI, `/ptx field`. Událost `FIELD_CHANGED`. |
| `Dispatch` | `SPOT` → `market:spot`; na mapě `requests()` vrací jen objednávky; `book(key, dest, svc, eta)` si pamatuje ETA zákazníka a dá ji do jízdy. |
| UI | `UI/MapPins.lua` (nový): piny na mapě světa, překreslení každých 0,5 s jen při otevřené mapě (řídicí rámec je dítě `WorldMapFrame`). `RideTab`: mágové na mapě v Browse. `DutyBox`: tlačítko *Map* a řádek „On the map“. |
| `Probe` | `/ptx diag` vypíše `C_Map.GetMapPosFromWorldPos`, `CreateVector2D`, `IsInInstance`, `UnitAffectingCombat`, `WorldMapFrame.ScrollContainer.Child`. |
| `Portaxi.toc` | `Core/Field.lua`, `UI/MapPins.lua` — **vyžaduje restart klienta** (D7). |

## 5. Neověřeno ve hře

| # | Co | Když to nejde |
|---|---|---|
| F1 | `UnitPosition("player")` mimo instanci, nebo `C_Map.GetWorldPosFromMapPos` (stejné jako šipka). | Mág se na mapu nedostane; DutyBox řekne proč. |
| F2 | `C_Map.GetMapPosFromWorldPos` a canvas `WorldMapFrame.ScrollContainer.Child` na Forever. | Bez pinů; zbývá seznam v Browse. |
| F3 | Číslování kontinentů z `UnitPosition` a z `GetWorldPosFromMapPos` je stejné (ID instance). | Porovnávat jen stejné zdroje. |
| F4 | Taint: rámce na canvasu mapy (stejně to dělají jiné addony). | Piny vypnout. |

Brána ve hře (dva hráči): mág venku zapne *Map*, zákazník venku ve stejné zóně zvolí město, vidí pin
i řádek v Browse, klikne na pin, jízda doběhne s šipkou. Mág vejde do hospody → pin zmizí.

## 6. Rozhodnutí

| # | Otázka | Rozhodnutí |
|---|---|---|
| F-R1 | Vlastní malá mapa v okně, nebo mapa světa? | **Mapa světa** + seznam v Browse. Vlastní mapa je výrazně víc práce. |
| F-R2 | Přesnost | Mřížka **75 yardů**, zaokrouhluje mág před odesláním. |
| F-R3 | Co je „hledá“ | Zákazník má v záložce Ride zvolené město. Otevřený Hail není potřeba. |
| F-R4 | Cena | Běžná cena PICK z Drive. Vlastní cena pro mapu až podle zájmu. |
| F-R5 | Soukromí | Filtr „jen hledající mimo hospodu“ dělá addon zákazníka; zaokrouhlená poloha jde do celého kanálu. Skutečnou ochranu dává zaokrouhlení a to, že se mág musí zapnout sám. |
