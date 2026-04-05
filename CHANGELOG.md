# Changelog

All notable changes to this project are documented in this file.

## [1.3.1] - 2026-04-05
### Added
- Character-based favorites system: click the star icon in the recipe list to add/remove favorites.
- New `Favorites` filter at the top of the left profession list to show only favorite recipes.
- Right-click on a recipe row now toggles favorite state as a shortcut.

### Changed
- Herbalism and Skinning are hidden from the left profession list in TBC, since they do not provide recipe entries.
- Favorite state is stored in profile data (`profile.favorites`) and persists per character.

### Notes
- Profession subcategories UI was reverted for now and is not part of this release.

## [1.2.0] - 2026-04-01
### Added
- Slash command namespace moved to `/rr` and help text updated.
- Optional market pricing integration (TSM first, Auctionator fallback).
- Recipe material unit/total cost display and overall cost estimate.
- Shift-click support for linking selected recipe/materials into chat.
- Crafter quick-request action for online crafters.
- Options panel module and `/rr options` shortcut.

### Changed
- Improved detail panel formatting for readability (materials and cost summary).
- Added rarity-based coloring for selected recipe product title.
- Refined money formatting and coin icon spacing.

### Fixed
- Removed CPU/memory live monitor polling that could cause lag.
- Reduced UI refresh pressure (search debounce and related optimizations).
- Prevented self auto-whisper from crafter request action.
- Tooltip behavior improved for material rows (cursor-anchored item tooltips).

## [1.2.3] - 2026-04-02
### Changed
- Profession scan now skips the native UI entirely when recipe data is already current; a full scan only runs on the first open or after a recipe-change event, eliminating filter/state interference during routine open/close cycles.
- `RequestRefresh` skips scheduling when the addon UI frame is hidden, reducing background work during sync bursts.

### Fixed
- Fixed native profession window losing filters and context on reopen.
- Fixed recipe list appearing empty (notably Cooking) after a forced scan.

## [1.3.0] - 2026-04-03
### Added
- Offline crafters are now grouped in a collapsible accordion; collapsed by default when at least one crafter is online, expanded when all are offline.
- Hovering the recipe title in the detail panel shows the full item/enchant tooltip at the cursor.
- Item names now auto-refresh when WoW populates its cache (`GET_ITEM_INFO_RECEIVED`), fixing "item:12345" placeholders on cold login.
- `/rr clean` command removes invalid non-craft spells from the saved database for all known members.
- Debug logging for blocked sync recipes (visible with `/rr debug`).

### Changed
- Default window size increased to 1200×750 (minimum 1000×620) for better detail panel readability.
- Shift-click on the recipe title now links the crafted item first (instead of the spell), fixing "?" icons for recipients.
- Added spacing between icon and recipe name in the detail panel title.

### Fixed
- Fixed recipe labels stuck as "item:12345" placeholders; `refreshDetailAssets` now updates `info.label` when the resolved name becomes available.
- Fixed Beast Training (Hunter) spells being scanned as Enchanting recipes: `ScanCraft` now skips any CraftFrame that is not Enchanting.
- Non-craft spells (e.g. Backstab, Blizzard, pet abilities) are now blocked at scan, outgoing sync, and incoming sync level via AtlasLoot validation with a spell-subtext fallback for clients without AtlasLoot.
