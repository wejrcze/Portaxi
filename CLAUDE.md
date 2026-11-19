# Portaxi

WoW Forever addon: a taxi network for mages (portals, Scroll of Liminal Passage) and warlocks (summons).
No server: the dispatch runs inside the players' addons over a hidden chat channel.

## Layout

- `Portaxi/` — the addon itself. This folder is junctioned into the game, so only addon files belong here.
- `docs/PORTAXI_MVP_PLAN.md` — MVP plan: scope, phase 0 checks, architecture, protocol, steps.
- `docs/PORTAXI_MVP_PLAYBOOK.md` — how the MVP is built: waves of parallel agents, architect decisions (D1–D15),
  module contracts, file ownership, test simulator, in-game gates. Contracts there change only through the architect.
- `docs/mock/portaxi.html` — clickable UX mock (open it in a browser).
- `CLAUDE.local.md` (git-ignored, optional) — machine-specific notes: the game path, published mock link.
- `tools/` — dev scripts (`link-addon.ps1`, `check.ps1`, `setup-tools.ps1`, `package.ps1` builds `dist/ForeverPortaxi-<version>.zip` for CurseForge).
- `tests/` — offline tests (`*_test.lua`, run by `tests\run.ps1`). `tests/lib/t.lua` is the test framework,
  `tests/lib/wowstub.lua` a fake Forever client (its header documents the API).

## Game install

- WoW Forever client: `<WoW>\_forever_` (the actual path is in `CLAUDE.local.md`). Interface version `16001`.
  Other addons use the `_Forever` TOC suffix for client-specific TOCs.
- `tools/link-addon.ps1` junctions `Portaxi/` to `Interface\AddOns\Portaxi`. Edits are live in the game;
  the user runs `/reload`. Adding a new file to the TOC may need a full client restart.

## Verifying changes

- Before asking for a `/reload`, run `tools\check.ps1`: luac 5.1 syntax check, luacheck, TOC completeness
  and the offline tests. It must pass. On a new machine run `tools\setup-tools.ps1` first; tools live in
  `tools\bin` (git-ignored), no admin needed.
- New WoW globals: declare them inline at the top of the file (`-- luacheck: read globals X Y`);
  `.luacheckrc` is the architect's. New addon files must be listed in `Portaxi/Portaxi.toc`.
- Offline tests run on `tools\bin\lua51\lua5.1.exe` (same Lua version as WoW).
- In game the user runs `/reload`, and `/ptx diag` for diagnostics. `/ptx` alone lists all commands;
  phase 0 probes (`/ptx net`, `invite`, `accept`, `opentrade`, `trade`) log to `PortaxiDB.probe.log`. SavedVariables are written on `/reload` or logout.
- Read results from `<WoW>\_forever_\WTF\Account\*\SavedVariables\Portaxi.lua`
  (`PortaxiDB.diag`, later `PortaxiDB.log`).
- Lua errors: BugGrabber + BugSack, read `...\SavedVariables\!BugGrabber.lua`.
- Screenshots: `<WoW>\_forever_\Screenshots`.
- Never write into the WTF folder; it belongs to the game and is overwritten on logout.

## Releasing

- Bump the version in `Portaxi/Portaxi.toc` (`## Version`) and `Portaxi/Core/Init.lua` (`ns.VERSION`), and add
  an entry on top of `Portaxi/Changelog.lua` (player-facing sentences; it feeds the What's new window).
  `tests/version_test.lua` fails when the three disagree. A `-dev` suffix marks a build that is not released:
  it never tells others to update.
- Then `tools\package.ps1` builds `dist/ForeverPortaxi-<version>.zip`.
- The `VER|<version>` message (playbook D17) is the one message without a protocol version. Never change its
  format: every released Portaxi must keep reading it.

## Code rules

- Lua 5.1 (WoW). Code, comments and identifiers in English.
- `Protocol`, `Market` and `ChatParse` modules must not call game APIs, so they can be tested offline.
- The addon never casts, uses items, trades or accepts on its own. It only prepares secure buttons;
  the click is always the player's. Exceptions decided in the playbook (D10, D11): the rider's addon
  accepts the group invite of the matched taxi only, the taxi's addon opens the trade window, and the
  rider's addon prefills the agreed gold. Accepting the trade itself is always the player's click.
- Spell and item IDs live in `Portaxi/Core/Const.lua`; phase 0 verifies them on Forever.
- Forever is a modern client (1.60.x, build 70959+): many classic globals are gone (e.g. `GetItemCount`;
  use `C_Item.GetItemCount`). Prefer `C_` namespace APIs and resolve uncertain ones at runtime with a fallback.
