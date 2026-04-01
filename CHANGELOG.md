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

## [1.2.1] - 2026-04-01
### Added
- 

### Changed
- UI refresh now skips hidden frames and runs when the window is visible.

### Fixed
- Prevented profession scan side effects while idle by scanning only when Blizzard profession windows are actually open.
- Reduced background UI churn that could contribute to perceived focus/input interruptions when the addon window is closed.
