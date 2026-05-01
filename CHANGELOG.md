# Changelog

All notable changes to this project are documented in this file.

## [1.5.1] - 2026-05-01
### Fixed
- Improved sync reliability for offline guildmates so their profession data is more likely to be discovered and filled in from other already-synced guild members.

## [1.5.0] - 2026-04-28
### Added
- Automatic guild recipe sync now fills in missing data progressively, including recipes belonging to guildmates who are currently offline when another synced guildmate already knows them.
- New `Roster Cleanup` button in the main window to refresh guild membership data locally and remove old ex-guild entries over time.

### Changed
- Guild sync now runs more quietly in the background, applying data in smaller steps instead of larger bursts.
- Sync automatically pauses in combat, raids, and instances, then resumes when it is safe again.
- Roster cleanup is manual-only for now and runs entirely in the background.

### Fixed
- Mock/test data no longer leaks into normal profession and recipe views.
- Recipe and profession lists remain stable after running internal sync tests.

## [1.4.0] - 2026-04-16
### Added
- Character-based favorites system: click the star icon in the recipe list to add or remove favorites.
- Favorite toggle is also available in the detail panel header for the selected recipe.
- New `Favorites` filter at the top of the left profession list to show only favorite recipes.
- Right-click on a recipe row now toggles favorite state as a shortcut.
- Hovering a recipe row in the center list now shows the related item or spell tooltip at the cursor.
- Global recipe search can now run without selecting a profession first.

### Changed
- Herbalism and Skinning are hidden from the left profession list in TBC, since they do not provide recipe entries.
- Favorite state now persists per character.
- The minimap button behavior and saved position handling have been modernized.
- The recipe browser now starts without forcing the `All` profession view, encouraging profession-first browsing or global search.
- Global search waits for a short minimum query before searching the full recipe index, with updated empty-state messaging and headers.
- Recipe browsing and crafter updates are now more responsive, especially in larger guild datasets.
- Item name and icon refreshes now feel smoother and avoid unnecessary redraws while data is still loading.
- Window refresh behavior has been refined to reduce unnecessary work while the UI is open.

## [1.3.0] - 2026-04-03
### Added
- Offline crafters are now grouped in a collapsible accordion; collapsed by default when at least one crafter is online, expanded when all are offline.
- Hovering the recipe title in the detail panel shows the full item or enchant tooltip at the cursor.
- Item names now auto-refresh when WoW populates its cache, fixing `item:12345` placeholders on cold login.

### Changed
- Default window size increased to `1200x750` (minimum `1000x620`) for better detail panel readability.
- Shift-click on the recipe title now links the crafted item first instead of the spell, reducing missing-icon cases for recipients.
- Added spacing between icon and recipe name in the detail panel title.

### Fixed
- Fixed recipe labels stuck as `item:12345` placeholders when the real item name became available later.
- Fixed Beast Training (Hunter) spells being scanned as Enchanting recipes.
- Invalid non-craft spells are now filtered out more reliably during scanning and sync.

## [1.2.3] - 2026-04-02
### Changed
- Profession scans now avoid disturbing the native profession window when local recipe data is already current.
- Hidden addon UI refresh work is reduced during sync bursts.

### Fixed
- Fixed the native profession window losing filters and context on reopen.
- Fixed recipe lists appearing empty in some cases, especially Cooking after a forced scan.

## [1.2.0] - 2026-04-01
### Added
- Optional market pricing integration with TradeSkillMaster first and Auctionator as fallback.
- Recipe material unit and total cost display, plus overall cost estimate.
- Shift-click support for linking the selected recipe and materials into chat.
- One-click quick-request action for online crafters.
- In-game options panel for addon settings.

### Changed
- Improved detail panel formatting for readability, especially around materials and cost summary.
- Added rarity-based coloring for the selected recipe product title.
- Refined money formatting and coin icon spacing.

### Fixed
- Removed a live CPU and memory monitor that could cause lag.
- Reduced unnecessary UI refresh pressure.
- Prevented self auto-whispers from the crafter request action.
- Improved tooltip behavior for material rows.
