# Changelog

All notable changes to this project are documented in this file.

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

## [1.2.2] - 2026-04-02
### Changed
- UI refresh now skips hidden frames and runs when the window is visible.
- `RequestRefresh` now skips timer scheduling entirely when the addon UI frame isn't shown, reducing unnecessary background work during sync bursts.
- Profession scan now skips touching the native UI entirely when recipe data is already current. A full scan (snapshot → clear → scan → restore) only runs on the first open or after a recipe-change event (`NEW_RECIPE_LEARNED`, `SPELLS_CHANGED`), eliminating all filter/state interference during routine profession-window open/close cycles.

### Fixed
- Fixed native profession context loss on reopen by avoiding scan-side UI mutations during routine open/close cycles.
- Fixed native profession recipe list intermittently appearing empty (notably Cooking) when a forced scan is required.
