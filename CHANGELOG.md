# Changelog

All notable changes to this project are documented in this file.

## [2.2.1] - 2026-07-20

### Fixed

- **Crafter rows are back on item and spell tooltips.** Since 2.1.1 the Recipe Registry section no longer appeared on any tooltip. Hovering a craftable item, recipe, spell, or enchant shows the known crafters again.

## [2.2.0] - 2026-07-19

### Added

- **The main window is now resizable.** Drag the grip in the bottom-right corner to resize the window, from the 1000×620 minimum up to your screen size. The size is remembered per profile and restored at login, and the recipe list and details panel re-flow to fit.
- **Window scale slider.** A new "Main window scale" slider in `/rr options` (60%–120%) shrinks or enlarges the whole window — useful on smaller screens where the minimum window size takes up too much room.

### Changed

- **The details panel now uses its full width.** Recipe details (materials, crafters, cost estimates) previously wrapped at a fixed 420px no matter how much room the panel had; the text now follows the real panel width, including the extra space gained by resizing.

### Fixed

- **Expansion filter now covers multi-recipe transmute items.** Essence of Water and Essence of Earth — items that two different Alchemy transmutes can create — stayed visible in the recipe browser even with Vanilla content hidden. The browser now recognizes when every possible source recipe belongs to the same hidden expansion and filters these entries correctly. Entries whose sources span professions (e.g. Gold Bar via Mining and Alchemy) remain visible as before.
- **Reagents no longer show placeholders on first selection.** Selecting a recipe whose reagent items were not yet in the local item cache used to show raw "item:1234" entries in the materials list until the recipe was selected again. The details panel now refreshes itself as soon as the item data arrives from the server.

## [2.1.1] - 2026-07-16

### Added

- **Tooltip crafters can now be turned off.** A new checkbox in `/rr options` ("Show known crafters on item and spell tooltips") hides the Recipe Registry section on tooltips for players who prefer leaner tooltips. Enabled by default.

### Fixed

- **Multi-source recipes now show their materials.** Items that more than one recipe can create — Gold Bar, Truesilver Bar, and the elemental Essence/Primal transmutes — used to show "No material mapping available" in the recipe details. The browser now resolves them through their profession context (Smelt Gold under Mining, Transmute: Iron to Gold under Alchemy), so reagents, categories, and cost estimates work for these entries.

### Changed

- **Compatibility with TBC Anniversary patch 2.5.6.** The 2.5.6 client moved to the modern addon API (aligned with Classic Era 1.15.9). Crafter rows on item and spell tooltips now use the modern tooltip pipeline (`TooltipDataProcessor`) — on the old client they would have thrown a Lua error on login. Item and spell lookups (`GetItemInfo`, `GetSpellInfo`, and friends) now go through a compatibility layer that prefers the new `C_Item`/`C_Spell` APIs and falls back to the classic globals where they still exist. TOC interface version bumped to 20506.
- **Profession scans now record exact transmute variants.** When the same item can come from two recipes of one profession (e.g. Primal Fire via Primal Air or via Primal Mana), the scan now additionally stores the precise recipe, so guildmates can see exactly which transmute a crafter knows, with the right reagents and costs. Existing guild data stays valid; the extra detail appears after each crafter's next profession scan with this version.

## [2.1.0] - 2026-06-03

A big quality-of-life release for the recipe browser. Recipe Registry now ships its own recipe knowledge base, so AtlasLoot is no longer needed for categories, reagents, or cost estimates. The browser focuses on TBC content by default, filters can be tweaked per profession, and a friendly banner tells you when something is being hidden from view.

Guild sync also gets a new safety net that keeps stale or mismatched peers from trapping your client in retry loops, and a smarter rescan reminder tells you exactly which profession needs attention — only when it actually does.

### Highlights

- **Built-in recipe knowledge base.** Recipe categories, subcategories, reagents, crafted outputs, and remote-craft eligibility now come from a metadata library shipped with the addon. No AtlasLoot required — and no extra companion addon either.
- **Smart recipe filters.** A new prefilter system lets you focus on the recipes that matter. The browser now defaults to TBC content; Vanilla can be turned back on globally or per profession from the options panel. Bind-on-Pickup output recipes you don't know are hidden by default to cut down on noise, while your own known crafts stay visible.
- **Hidden-expansion banner.** When a filter is hiding part of the current profession's recipes, a small banner above the list lets you know — one click reveals them for the rest of the session, without changing your saved filters.
- **Sidebar categories with real labels.** Profession sidebars now show proper category names and subcategory rows for fast drill-down, all sourced from the new metadata library.

### Improvements

- **Smarter rescan reminder.** Recipe Registry can now tell you when a profession actually needs a rescan — for example, right after you learn a new recipe or step out of an instance — and which profession it is. It stays quiet during ordinary `/reload`s.
- **Stronger guild sync convergence.** A new safety net tracks specific block versions that keep failing to add new recipes and stops pulling them from any peer, while productive sources continue normally. Stale or mismatched peers can no longer trap your client in retry loops.
- **Snappier recipe browser.** Applying the new prefilters, switching professions, and refreshing the recipe list now stay responsive even on guilds with broad recipe coverage. Filter changes no longer cause noticeable hitches on large databases.
- **Recipes that teach across professions.** `/rr clean` now correctly handles items like the Goblin Mortar (an Engineering item that teaches an Alchemy recipe) instead of flagging them as profession mismatches.
- **Conservative bind-type display.** Newly seen recipes whose item bind type hasn't loaded yet stay visible until the local item cache can confirm them, so brand-new recipes don't briefly disappear from the browser.

### Fixed

- A rare startup race that could leave guild sync blocked until a manual `/reload` if the addon enabled after `PLAYER_LOGIN` had already fired. The player-ready signal is now replayed automatically.

### Removed

- **AtlasLoot is no longer a Recipe Registry dependency.** It is no longer listed in `OptionalDeps`, and the legacy AtlasLoot resolver module is no longer shipped. Existing AtlasLoot installations continue to work normally alongside Recipe Registry — they are just no longer used to power recipe details, categories, or reagent data.

## [2.0.8] - 2026-05-26
### Changed
- Switching profession in the left menu is significantly faster, especially on large guild rosters. The recipe list builder now iterates only the slice of the catalog that belongs to the selected profession instead of walking the entire guild index on every click.

## [2.0.7] - 2026-05-23
### Added
- Added `/rr share reply` and `/rr share r` to share the selected recipe to a whisper target, preferring the active whisper edit box before falling back to the most recent whisper.

### Changed
- Recipe sharing now offers only the available Guild, Say, Party, Raid, and Reply channels, with Reply labelled by target when available.
- Shared recipe messages now use chat-safe plain money text, preserve real item and spell links, and escape plain-text pipe characters.
- The crafter Ask button is clearer and more consistent with the recipe detail panel.

### Fixed
- Enchanting and other spell-based local scans no longer store transient profession row indexes when recipe item links are unavailable.

## [2.0.6] - 2026-05-22
### Added
- Added a `Guild Addons` view in the main window that compares the live guild roster with locally observed Recipe Registry peers, using a 30-day "not seen recently" threshold without implying uninstall status.
- The Guild Addons view now uses a full-width table with top-right search plus sortable and filterable headers for presence, addon visibility, and version checks.
- Added `/rr adoption` and `/rr addonstatus` diagnostics for a quick roster/addon adoption summary.

## [2.0.5] - 2026-05-22
### Changed
- Documentation/licensing: added GuildCrafts acknowledgment and third-party MIT notice.

## [2.0.4] - 2026-05-21
### Changed
- The recipe browser's background data builders now keep progressing with a tiny budget even while heavier UI work is paused, preventing the window from getting stuck on `Loading...` if it is opened during combat or other paused moments.
- AtlasLoot category indexing now uses the same lightweight background path, so first-load browsing stays responsive while category labels catch up.
- Corrupt-data cleanup now marks only the affected sync blocks dirty when possible instead of forcing a broader sync index rebuild after every repair.
- Older clients no longer receive repeated "newer version detected" notices when several different newer release versions are present in the guild at the same time.
- Version update notices now use a shorter 4-hour cooldown instead of 12 hours, while still reporting the highest newer guild version seen.

## [2.0.3] - 2026-05-21
### Changed
- The Recipe Registry window now opens without freezing the client, even on the first try after a `/reload`. The recipe list, the underlying recipe index, and the AtlasLoot category index all build progressively in the background while the window stays responsive, with a brief "loading" indicator until the data is ready.
- Profession buttons now appear labelled in the sidebar during sync warmup instead of as empty rows, so the addon window looks usable as soon as it opens.

## [2.0.2] - 2026-05-20
### Changed
- Recipe Registry is smoother while guild recipe data is syncing, especially when the addon window is open.
- Recipe tooltips now refresh their guild crafter data more calmly after sync activity, reducing small pauses during larger updates.

## [2.0.1] - 2026-05-20
### Changed
- Guild recipe sync is smoother when receiving several recipe groups in a row, reducing short pauses while your local recipe database catches up.
- Recipe sharing now batches more of its behind-the-scenes refresh work, keeping the addon responsive during larger guild sync updates.

## [2.0.0] - 2026-05-20
### Added
- A redesigned guild sync experience for `2.0.0`: guildmates can share recipe data more reliably after login, reloads, database wipes, and addon updates.
- Clearer update boundaries: regular release builds now sync only with compatible release builds, while development and test builds stay isolated from live guild data.
- New recipe browser controls, including an easier sort switch, improved search clearing, material-search control, and a more readable options panel.
- A quicker way to ask guildmates for a craft, with better whisper behavior when you are in a raid.
- More helpful sync status and troubleshooting output when debug tools are enabled, while normal play stays quiet.

### Changed
- Important: `2.0.0` uses a new guild sync model and does not exchange sync data with Recipe Registry `1.x`. Existing saved recipe data is preserved, but guildmates should update together for guild sharing to work.
- Background sync now waits for safer moments around login, reloads, combat, instances, and busy roster loading instead of trying to do everything at once.
- Startup, reload, update, and database-wipe recovery now handle guild data sharing more smoothly, with less need for manual refreshes.
- Recipe data requests are more tolerant of slow or unavailable guildmates and version changes during sync.
- When many guildmates refresh around the same time, sync now spreads requests across good sources more evenly and backs off cleanly from already-busy peers.
- Recipe lists, searches, tooltips, and Auction House lookups are smoother in larger guild databases and reuse more work instead of rebuilding the same view repeatedly.
- Profession scans are quieter: automatic checks no longer announce unchanged or unrelated skill events, while manual refreshes still tell you what happened.
- Guildmate presence is handled more conservatively during startup, so active players are less likely to disappear from recipe results while the roster is still warming up.
- Large data sharing remains deliberately paced to avoid stalls or memory spikes in real guild use.
- Remaining in-game help text and option labels have been cleaned up for a more consistent addon experience.

## [1.8.1] - 2026-05-10
### Added
- Local backend coverage now includes a bounded catalog cache regression spec for the recipe list and recipe detail caches.

### Changed
- Recipe catalog list and detail caches are now bounded, which reduces steady-state addon memory growth when many distinct searches and recipe detail lookups are opened over time.
- Recipe index rows are now sorted once during index build and reused directly, avoiding an extra crafter cache copy for every recipe lookup.
- Tooltip crafter indexing now stores recipe keys instead of duplicating full crafter rows per item/spell bucket, lowering the UI memory footprint while keeping the same visible tooltip results.

## [1.8.0] - 2026-05-10
### Added
- Additional sync diagnostics and guarded runtime reset tooling are now available for targeted troubleshooting of stalled local sync sessions.

### Changed
- Direct sync requests now use bounded retries, temporary peer backoff, and healthier source selection so one silent peer does not keep the single-flight queue stuck for minutes.
- Direct sync can now keep a small bounded set of owner requests active at once, immediately backfilling freed slots instead of waiting for the next global queue tick.
- The new bounded parallelism improves catch-up throughput while reducing wasted work through deduplication, queue caps, stale-state pruning, deferred manifest fallback, and cache reuse instead of increasing background aggressiveness across the board.
- Snapshot transfer session IDs are now collision-safe under same-second burst traffic, and stale outgoing, partial snapshot, partial manifest, and peer-manifest runtime state is pruned more aggressively.
- Targeted manifest refreshes now retry on later `HELLO` sessions until a peer manifest is actually received, and manual manifest pulls clear temporary peer backoff so stalled peers can be probed again without waiting out a long timeout window.
- Login, reload, combat-exit, and instance-exit recovery now use a short warm-up window that defers heavier manifest fan-out, catch-up drain, and background tooltip rebuild work instead of resuming everything at once.
- Direct sync now pumps the next queued request immediately after a transfer finishes or fails, and deferred manifest catch-up no longer waits on an unrelated in-flight request before making progress.
- Periodic `HELLO` and auto-tick flows no longer proactively rebroadcast manifests to every peer, relying instead on targeted `HELLO` replies and explicit refresh paths to reduce manifest queue growth and background memory pressure.
- Peer-manifest comparison no longer forces synchronous local manifest fallback builds during warm-up or other busy windows, and replay is retried automatically once the cache is ready.
- Diagnostic `TrickleSync` outbound queues are now bounded and replaced per compare pass instead of growing forever across repeated peer manifests.
- Sync routing now refreshes stale guild roster metadata before making harder viability decisions, so live online peers are less likely to be ignored because of stale local roster state.
- Combat and instance pause gates remain authoritative for the heavier background work, so the new sync behavior stays transparent for normal users and does not bypass safety pauses in sensitive contexts.

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
