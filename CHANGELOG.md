# Changelog

All notable changes to this project are documented in this file.

## [1.7.0] - 2026-05-09
### Added
- Debug-only sync and manifest diagnostics now expose richer internal counters and communication telemetry when troubleshooting larger guild scenarios.

### Changed
- Internal system and guardrail chat messages are now kept quiet by default and shown only while debug mode is enabled, reducing chat spam for normal users.
- Manifest catch-up requests from large peer manifests are now capped and drained progressively to avoid request bursts in larger guilds.
- The manifest catch-up path now avoids building peer-side diff work it does not consume, reducing comparison overhead during heavier sync traffic.
- Repeated unchanged manifests are no longer re-announced to the same peer unless the manifest changes or a forced refresh is requested, reducing background sync noise in larger guilds.
- The first `HELLO` seen from a peer in a local session now triggers one targeted manifest refresh request, helping unchanged peers repair missing metadata after reloads or updates.
- Manifest-driven block requests now keep the expected block fingerprint locally, so same-revision metadata upgrades such as profession specializations are not skipped as already satisfied.
- Wiping the local database now clears in-memory sync session state and immediately requests fresh guild manifests again, avoiding slow partial catch-up when a wipe happens mid-session.
- Tooltip crafter indexes now rebuild in background and keep using the previous index while fresh data is prepared, reducing hitching on the first hover after sync or roster changes.
- Instances now pause non-essential addon work much more aggressively, including sync protocol traffic, manifest cache work, maintenance jobs, and background UI rebuilds, while raid groups outside instances no longer block background sync.
- Concurrent guild sync now drops already-satisfied requests sooner and handles coordinator handoff more cleanly during heavier background traffic.
- Replica sync is now stricter around stale local owners, so in-flight peer data does not accidentally reactivate records that were already marked stale locally.

## [1.6.0] - 2026-05-07
### Added
- Profession specializations are now tracked and shared with guildmates when they are first discovered or actually changed.
- Existing guild data can now pick up newly available profession specialization details without asking users to wipe and rebuild their local database.
- Recipe Registry now includes a saved-data cleanup flow, plus a lightweight automatic repair pass after login for clearly invalid local records.
- Sync and scan status output is clearer when checking whether your guild recipe database is up to date.

### Changed
- Learned recipes are less likely to be missed if the profession window is not ready yet or another profession is opened first.
- More complete profession data is protected from being replaced by empty or incomplete data received from another guildmate.
- Guildmates who wipe or rebuild their local data can catch up from already synced peers more reliably.
- Profession specialization updates from other guildmates are now received more reliably, even when the recipe list itself did not change.
- Enchanting and spell-based recipes are kept more reliably when optional recipe metadata is incomplete.
- Guild roster cleanup is less likely to hide active guildmates while the roster is still loading.
- Guild sync no longer pauses just because you are in a raid group outside combat or an instance.
- Guild sync now spreads some background work more smoothly, which helps larger guild databases stay responsive.
- Manual profession refreshes now make better use of currently available profession data and report more clearly when a refresh still needs the profession window.
- Long sync summaries are now kept shorter by default, with detailed output reserved for troubleshooting.

## [1.5.3] - 2026-05-03
### Added
- Tooltips for craftable items, recipe items, and spell/enchant links now show known crafters, preferring online guildmates when available.

### Changed
- The main search box now releases focus on Enter/Escape or outside clicks, allowing chat to open normally after searching.
- The main window close button now uses the addon's direct close path and the title bar can be dragged, with placement saved per profile.
- Tooltip crafter indexing now avoids automatic full background rebuilds and skips dirty rebuilds in combat to prevent gameplay stutter after data changes.

## [1.5.2] - 2026-05-01
### Changed
- Improved offline guildmate sync so already-synced online guild members can share known offline crafter data more reliably during catch-up.

## [1.5.1] - 2026-05-01
### Changed
- Improved sync reliability for offline guildmates so their profession data is more likely to be discovered and filled in from other already-synced guild members.

## [1.5.0] - 2026-04-28
### Added
- Automatic guild recipe sync now fills in missing data progressively, including recipes belonging to guildmates who are currently offline when another synced guildmate already knows them.
- New `Roster Cleanup` button in the main window to refresh guild membership data locally and remove old ex-guild entries over time.

### Changed
- Guild sync now runs more quietly in the background, applying data in smaller steps instead of larger bursts.
- Sync automatically pauses in combat, raids, and instances, then resumes when it is safe again.
- Roster cleanup is manual-only for now and runs entirely in the background.
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
- Recipe labels now recover cleanly from `item:12345` placeholders when the real item name becomes available later.
- Beast Training (Hunter) spells are no longer scanned as Enchanting recipes.
- Invalid non-craft spells are now filtered out more reliably during scanning and sync.

## [1.2.3] - 2026-04-02
### Changed
- Profession scans now avoid disturbing the native profession window when local recipe data is already current.
- Hidden addon UI refresh work is reduced during sync bursts.
- The native profession window now keeps its filters and context more reliably on reopen.
- Recipe lists now stay populated more reliably, especially Cooking after a forced scan.

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
- Removed a live CPU and memory monitor that could cause lag.
- Reduced unnecessary UI refresh pressure.
- Prevented self auto-whispers from the crafter request action.
- Improved tooltip behavior for material rows.
