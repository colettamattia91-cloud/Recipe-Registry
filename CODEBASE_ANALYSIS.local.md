# Recipe Registry - Codebase Analysis Local

Generated: 2026-05-02
Last updated: 2026-05-11
Addon version observed: 1.8.1 in code/TOC and changelog
Wire version observed: 2

This file is intentionally local and gitignored. Use it as the first map when
answering questions such as "come funziona il manifest", "quando viene
inviato", or when starting impact analysis for a new feature. The Lua code is
still the source of truth, so verify the referenced functions before changing
behavior.

## Recent Execution Update

Date: 2026-05-11

- Version compatibility gating execution completed after the sync reliability
  pass.
- `SyncRuntime.lua` now owns addon-version comparison, per-peer version
  observation, timeout tracking, temporary version-audit pending state,
  blacklist state for silent/older peers, and a hard local sync lock when a
  newer peer version is observed. The lock drains in-flight sync state and
  preserves only local/cached read access.
- `SyncProtocol.lua` now carries explicit `VREQ` and `VACK` control traffic.
  Login warmup schedules one delayed version audit, `Sync.lua` runs a periodic
  audit every 15 minutes, and `Core.lua` exposes manual `/rr version` and
  `/rr ver` commands that trigger the same audit path and dump current version
  state.
- Same-version peers remain on the existing sync path with no behavior change.
  Peers that respond with an older version are blacklisted until they answer
  with a compatible version in a later session, while silent peers are
  blacklisted after audit timeout because they are treated as legacy/obsolete
  until proven otherwise.
- If any peer reports a newer addon version than the local install,
  `SyncRuntime.lua` enters a local obsolete-version lock. All normal sync
  traffic is then blocked at protocol, manifest, request, and transfer entry
  points, but UI/data browsing remains available against previously cached
  records. `Addon:SystemPrint(...)` emits a throttled chat warning telling the
  player to update the addon before sync can resume.
- `UI/MainFrame.lua` now reflects version gating in the status bar: blocked
  local state forces a red sync indicator and shows the required upgrade gap,
  while non-fatal peer blacklists are surfaced as a peer-count warning without
  hiding cached content.
- Added focused backend coverage:
  `version_sync_spec.lua`,
  plus targeted updates to existing specs whose assumptions previously treated
  version-mismatched peers as neutral.
- Final verification after implementation:
  `local-tests/run-syntax.ps1` -> `Lua syntax OK`
  `local-tests/run-backend-tests.ps1` -> `Backend tests OK`

- Sync reliability execution completed from
  `RecipeRegistry_Sync_Reliability_Preanalysis_Codex.md`.
- Direct sync now uses a softer timeout envelope and explicit negative
  acknowledgements instead of silent stalls. `Sync.lua` raised
  `REQUEST_TIMEOUT/PROGRESS_TIMEOUT/SESSION_TIMEOUT` to `25/8/60`, while
  `SyncTransfer.lua` now emits `RERR` for invalid requests, paused-instance
  handling, queue pressure, missing data, non-serveable replicas, and empty
  snapshots. `SyncProtocol.lua` routes those rejects back into the requester,
  which clears the matching in-flight request by `requestId`, records reject
  telemetry, and only schedules delayed retry for explicitly retryable cases.
- Peer health is now split between "manifest seems alive" and "snapshot data is
  actually serveable". `SyncRuntime.lua` tracks manifest/snapshot success and
  failure separately, keeps temporary snapshot backoff and quarantine state,
  remembers recent permanent rejects, exposes `CanExchangeDataWithPeer()`, and
  reports eligibility breakdowns through `SyncDiagnostics.lua` and `/rr sync`.
- Pause policy is no longer symmetric between combat and instances.
  `SyncPausePolicy.lua` now keeps protocol traffic (`REQ`, `SNAP`, `HELLO`,
  `AD`, `MREQ`, `MANI`) active during combat outside instances, while real
  instances still pause protocol and inbound apply. Heavy UI/background work
  remains pauseable in both combat and instance contexts, so tooltip/catalog
  rebuilds still yield when the client is in a sensitive UI state.
- Queue eligibility filtering was added without breaking deferred manifest
  catch-up. Automatic requests now skip peers already in backoff or known
  permanently ineligible, but plain "offline" does not block enqueue so
  manifest-driven catch-up can still stage work before normal presence tracking
  catches up. Retryable rejects now use a dedicated `readyAt` deferral instead
  of overloading `queuedAt`, which preserves existing fairness and bounded
  concurrency behavior for normal retries.
- `UI/MainFrame.lua` now degrades to status-only mode in sensitive contexts
  only when no cached recipe data exists; otherwise the addon stays readable in
  a cached read-only state. Detail-panel "Request" actions are hidden when
  `REQ` traffic is protocol-paused. `Tooltip.lua` now defers rebuilds through
  `ShouldPauseTooltipRebuild()` instead of the broader old sync pause check.
- `DataCatalog.lua` now collapses duplicate crafter rows per member during
  recipe-index build, keeps the better row, and records diagnostics exposed by
  `/rr perf dump` and reset by `/rr perf reset`.
- Added focused backend coverage:
  `sync_reliability_spec.lua`,
  plus adjustments to `sync_resilience_spec.lua` for the new timeout values and
  automatic-request backoff behavior.
- Final verification after implementation:
  `local-tests/run-syntax.ps1` -> `Lua syntax OK`
  `local-tests/run-backend-tests.ps1` -> `Backend tests OK` (140 tests)

- AceBucket plus negotiated snapshot codec execution completed from
  `RecipeRegistry_AceBucket_LibSerialize_LibDeflate_Codex_Plan.md`.
- `Core.lua` now buckets the hottest UI-adjacent events through
  `AceBucket-3.0`: `GUILD_ROSTER_UPDATE` flushes every 1.5 seconds into
  `OnGuildRosterBucket()`, while `GET_ITEM_INFO_RECEIVED` flushes every
  0.75 seconds into `OnItemInfoBucket()`. Roster buckets still preserve the
  lifecycle deferral path via `ScheduleRosterUpdate()` when warmup/world
  transition gating wants heavy work postponed, but non-deferred buckets now
  rebuild presence once per flush instead of per raw event. Item-info buckets
  now invalidate only the `list` cache scope and request one UI refresh.
- Snapshot transport gained an optional backward-compatible wire codec only for
  `SNAP`. `SyncCodec.lua` negotiates support through `HELLO`/`AD` caps and
  per-request `REQ.acceptSnapCodec`, then uses `LibSerialize + LibDeflate`
  only when both peers support `snap.lsd1` and the serialized body is at least
  `SNAP_CODEC_MIN_BYTES` (currently 768). Small snapshots remain legacy/raw,
  so no `WIRE_VERSION` bump was needed.
- `SyncTransfer.lua` now encodes outbound snapshot chunks per session/peer and
  decodes inbound codec payloads before `AppendIncomingChunk()`. Codec failures
  release the affected transfer state, increment telemetry, and mark the peer
  failure path instead of appending corrupt partial data.
- `SyncRuntime.lua` now tracks `peerCaps`, and `SyncDiagnostics.lua` plus
  `/rr perf dump` expose both bucket telemetry and snapshot codec telemetry
  such as encoded/decoded counts, small-payload skips, peer-cap fallbacks,
  byte totals, timing maxima, and aggregate errors.
- Added `AceBucket-3.0` and `LibSerialize` to `Libs/embeds.xml`, inserted
  `SyncCodec.lua` in both live and backend-test load order, and extended the
  WoW/Ace harness with `RegisterBucketEvent`, shared `LibSerialize`,
  shared `LibDeflate`, and synthetic event delivery for coalescing tests.
- Added focused backend coverage:
  `acebucket_integration_spec.lua`,
  `snapshot_codec_spec.lua`,
  and extended `slash_output_spec.lua` for bucket diagnostics/reset.
- Final verification after implementation:
  `local-tests/run-syntax.ps1` -> `Lua syntax OK`
  `local-tests/run-backend-tests.ps1` -> `Backend tests OK` (128 tests)

- Preanalysis execution completed from
  `RecipeRegistry_Performance_Sync_Fix_Preanalysis.md`.
- Lifecycle hardening is now broader than the earlier warmup-only model.
  `SyncRuntime.lua` adds a world-transition gate plus a progressive
  `transitionDrainQueue`. Heavy lifecycle work such as `HELLO`, manifest
  replies, targeted `MREQ`, manifest catch-up drain, tooltip rebuild resumes,
  and deferred UI refreshes can now be replayed gradually after warmup or
  world-entry transitions instead of flushing inline.
- Manifest convergence now avoids more useless work. Equivalent peer manifest
  blocks no longer trigger `REQ` or UI refreshes, same-recipe snapshots can be
  classified as metadata-only, and exactly equivalent snapshots increment skip
  telemetry instead of invalidating caches again.
- Runtime queue protection was implemented across outbound chunks, inbound
  chunks, finalize queues, partial receive state, pending requests, and
  manifest catch-up queues. Important follow-up fixes from the execution pass:
  manifest catch-up queue cap raised to 256, manifest chunk queue cap raised to
  256, manifest chunk dedupe now keys on `peer + manifestId + seq`, and grouped
  `REQ` planning uses the full missing-block set instead of the capped
  diagnostic queue.
- Profession block normalization is now canonical for `count` and `signature`.
  This prevents false heavy diffs when callers seed or reload inconsistent
  metadata around a stable recipe set.
- Public slash diagnostics are gated again behind `debugMode` for `/rr dump`,
  `/rr sync`, `/rr offline`, `/rr manifest`, and `/rr perf dump`, while direct
  diagnostic function calls still print so targeted backend diagnostics remain
  testable.
- Tooltip background rebuilds are still deferred for real warmup/transition or
  sensitive pause contexts, but no longer for the simple `ui-hidden` case; the
  tooltip index can rebuild in background even when the main frame is closed.
- Added focused backend coverage:
  `lifecycle_transition_gate_spec.lua`,
  `manifest_identical_skip_spec.lua`,
  `snapshot_identical_metadata_spec.lua`,
  `runtime_queue_caps_spec.lua`.
- Final verification after implementation:
  `local-tests/run-syntax.ps1` -> `Lua syntax OK`
  `local-tests/run-backend-tests.ps1` -> `Backend tests OK` (121 tests)

## Quick Answer Index

- Manifest creation: `Data` keeps an in-memory manifest cache, built in the
  background and updated by dirty `owner::profession` blocks. It is not stored
  as durable state.
- Manifest transport: `TrickleSync:BuildManifestChunks()` splits the cached
  manifest into `MANI` chunks of 24 blocks and reuses cached chunks until the
  manifest changes.
- Manifest send cadence: `Sync:BroadcastHello()` runs every 30 seconds and
  `Sync:AutoSyncTick()` runs every 20 seconds; actual sends are limited by the
  20 second per-peer `MANIFEST_PUSH_COOLDOWN`, except forced replies to `MREQ`.
  Ready MANI chunks are sent through the paced outbound worker, and unchanged
  manifests are not re-announced to the same peer again until the manifest
  state changes or the peer ages out of online-node tracking. The addon no
  longer proactively broadcasts manifests to every peer on each periodic
  `HELLO` or `auto-tick`; instead, manifest distribution relies on targeted
  replies when peers send `HELLO`, explicit `MREQ`, and direct send paths that
  are closer to real need. Outside the short startup/recovery warmup window,
  the first `HELLO` seen from a peer in the current local session still
  triggers one targeted `MREQ` so unchanged peers can repair missing metadata
  after reloads or addon updates. During warmup, that extra `MREQ` is
  intentionally suppressed to avoid login/reload fan-out spikes because the
  normal `HELLO` exchange already causes peer manifest replies. New version
  audits do not alter this flow for compatible peers, but version lock or
  version blacklist state suppresses follow-up manifest traffic entirely.
- Version compatibility gate: `SyncRuntime.lua` compares semantic numeric addon
  versions, drives `VREQ`/`VACK` audit state, blacklists older or silent
  peers, and enters a local hard sync lock if any contacted peer reports a
  newer version. The lock is intentionally stricter than ordinary pause policy:
  normal sync work stops, but cached browsing and diagnostics remain readable.
- Direct request resilience: `SyncRequests.lua` now caps retries, avoids
  endlessly appending `:retry`, tracks temporary per-peer backoff via
  `SyncRuntime.lua`, and prefers healthier sources when choosing the next
  pending request. Direct sync is no longer single-flight: it now runs a small
  bounded set of owner requests concurrently, backfills freed slots
  immediately, keeps fairness and retry caps, and handles explicit `RERR`
  responses for fast-fail cases instead of waiting only on timeouts. Request
  enqueue and transfer start now also respect version lock and peer blacklist
  state before any snapshot traffic is attempted.
- Manifest catch-up cap: large peer manifests are compared immediately, but the
  derived `REQ` requests are capped per flush and the remainder is deferred
  through `manifestCatchupQueue` and the `sync-manifest-catchup` scheduler job.
- Warmup/recovery behavior: login/startup plus combat-exit and instance-exit
  now enter a short warmup window. `HELLO` continues to flow, but broad
  manifest fan-out, catch-up drain, targeted manifest refreshes, and heavy UI
  follow-up work are deferred until the client is back in a steadier state.
  Warmup expiry no longer flushes this work inline; it moves it into a
  progressive transition-drain queue that also covers world-entry transitions.
- Snapshot apply behavior: `DataSnapshot.lua` distinguishes heavy recipe
  changes, metadata-only applies, and equivalent snapshots. Metadata-only
  applies invalidate only detail/index caches plus tooltip rows, while exact
  equivalents increment sync telemetry skips and avoid cache churn entirely.
- Manifest diff behavior: `TrickleSync:ComparePeerManifest()` and
  `SyncManifest.lua` now track equivalent blocks separately from genuinely
  stale/missing blocks, so peers that already match local recipe content do not
  generate redundant `REQ` traffic or unnecessary UI refreshes.
- Local recipe update: recipe-change events call `Data:MarkScanNeeded()`.
  `Core.lua` then attempts opportunistic TradeSkill/Craft scans through
  `Data.lua` readiness helpers, without depending directly on frame visibility.
  Profession scans return a rich result table. If `Data:ApplyScanResult()`
  accepts a changed scan, `Data:TouchLocalRevision()` increments the local
  revision and `Sync:AdvertiseLocalRevision()` advertises it.
- Profession specialization metadata: `Data:DetectProfessions()` now inspects
  supported TBC specialization spells. First discovery or a real specialization
  change bumps the local revision and syncs once; stable relogs do not keep
  incrementing `rev`.
- Owner scan protection: suspicious subset scans are skipped and leave pending
  scan state open so a temporary profession UI/API subset does not publish as
  owner truth.
- Recipe validation diagnostics: invalid recipe filtering increments scan
  telemetry counters for snapshot build, inbound apply, and `/rr clean`.
  Negative spell/enchant keys prefer AtlasLoot mapping but fall back to spell
  metadata if AtlasLoot is present and incomplete.
- Roster cleanup guard: guild cleanup aborts before marking stale when the
  roster snapshot is empty or implausibly small compared with known active DB
  members.
- Internal chat diagnostics: non-essential scan/sync/guardrail output now goes
  through `Addon:SystemPrint(...)` and is visible only when `/rr debug` is on.
- Raid and instance pause policy: being in a raid group outside an instance no
  longer pauses sync by itself. Combat now pauses only heavy UI/background
  work, while real instances still pause protocol traffic, inbound apply,
  manifest/maintenance workers, and other non-essential sync work.
- Cached read-only UI mode: `UI/MainFrame.lua` can still render saved recipe
  data during combat/instance-sensitive states when cached member data exists;
  it falls back to pure status-only mode only when there is nothing useful to
  show locally. The same browsing guarantee is now reused by obsolete-version
  lockout: sync is disabled, but previously downloaded data remains visible.
- Tooltip crafter index: invalidation now schedules an incremental background
  rebuild; hover paths keep using the previous index until the new one is
  committed, instead of rebuilding the whole tooltip index inline.
- Catalog and tooltip memory: `DataCatalog.lua` now bounds the recipe list and
  recipe detail caches, while `Tooltip.lua` stores recipe keys in its lookup
  buckets and resolves crafter rows from `Data:GetRecipeIndex()` on demand.
  This keeps the 1.8.1 memory reduction work on the UI side without changing
  sync payloads or `WIRE_VERSION`.
- Data pull: normal pulls use `REQ`/`SNAP` snapshot chunks. Manifests only say
  which logical blocks exist and whether they look newer/missing.
- Offline owner convergence: a peer can advertise and serve replica blocks for
  offline owners. `Sync:HandleManifestChunk()` queues replica requests when the
  owner is offline or when the sender is the owner. These manifest-driven
  requests now keep the expected block fingerprint locally, so same-revision
  metadata repairs such as specialization upgrades are not treated as already
  satisfied just because the block exists.
- Manual wipe behavior: `Data:WipeDatabase()` now clears in-memory sync session
  state as well as saved members, then immediately broadcasts `MREQ` and
  schedules a fresh `HELLO`. This avoids a same-session dead zone where peers
  already considered their manifests announced and the wiped client considered
  those peers already queried.
- Runtime sync reset: `/rr syncreset` now clears volatile sync queues,
  in-flight state, manifest deferred work, and peer backoff/health without
  deleting saved profession data, then immediately requests a fresh guild
  resync.
- Runtime hardening: peer-manifest compare can now defer inline local manifest
  fallback builds during warmup, busy, or pause windows and replay the compare
  once the cache is ready; `TrickleSync` diagnostic outbound queues are capped
  and replaced per compare pass instead of growing without bound; stale
  roster metadata is refreshed before harder routing decisions so online peers
  are less likely to be skipped on old guild state.
- UI refresh: callers use `Addon:RequestRefresh(reason)`. With
  `Performance.lua` active, refreshes are deferred and scoped by reason.
- Local backend tests: `local-tests/run-backend-tests.ps1` loads WoW/Ace mocks
  and currently covers 145 tests across P2/P4/P5/P6 behavior, AceBucket event
  coalescing, negotiated snapshot codec transport, slash output, specialization
  sync stability, manifest diagnostics, lifecycle transition gating, snapshot
  metadata-only/equivalent merges, runtime queue caps, tooltip async rebuild
  behavior, sync reliability/reject handling, version compatibility gating,
  runtime resilience, comm-boundary delivery, and a multi-node comm-bus
  harness with 200 isolated addon peers.

## Load Order And Modules

`RecipeRegistry.toc` loads the addon in this order:

1. `Core.lua`
2. `Performance.lua`
3. `Data.lua`
4. `DataAtlasLoot.lua`
5. `DataManifest.lua`
6. `DataScan.lua`
7. `DataSnapshot.lua`
8. `DataCatalog.lua`
9. `DataCleanup.lua`
10. `MergeEngine.lua`
11. `BootstrapSync.lua`
12. `TrickleSync.lua`
13. `SyncPausePolicy.lua`
14. `GuildLifecycleMaintenance.lua`
15. `MockSync.lua`
16. `Market.lua`
17. `Sync.lua`
18. `SyncRuntime.lua`
19. `SyncProtocol.lua`
20. `SyncCodec.lua`
21. `SyncRequests.lua`
22. `SyncTransfer.lua`
23. `SyncManifest.lua`
24. `SyncDiagnostics.lua`
25. `Tooltip.lua`
26. `MinimapButton.lua`
27. `Options.lua`
28. `UI/MainFrame.lua`

`Core.lua` creates `_G.RecipeRegistry`, defines `DISPLAY_VERSION`,
`WIRE_VERSION`, and `ADDON_PREFIX`, registers slash commands, handles major game
events, and owns the public `Addon:RequestRefresh(reason)` refresh entry point.

`Data.lua` is now the module shell for saved variables, schema migration,
member visibility/lifecycle, cache invalidation, and shared helper exports via
`Data._private`. The behavior split is:

- `DataAtlasLoot.lua`: AtlasLoot/item/spell resolution helpers and diagnostics.
- `DataManifest.lua`: manifest cache, dirty-block handling, and build
  scheduling.
- `DataScan.lua`: profession detection, scan readiness, scan telemetry, and
  TradeSkill/Craft ingestion.
- `DataSnapshot.lua`: local summary plus snapshot chunk build/apply.
- `DataCatalog.lua`: recipe indexes, lists, crafter lookup, and detail views,
  including bounded list/detail caches to cap UI-side memory retention.
- `DataCleanup.lua`: invalid/corrupt data cleanup and DB wipe helpers.

`Sync.lua` is now the module shell for shared constants/helpers, startup
wiring, member-key validation, mock suppression helpers, and
`IsLocallyStaleOwner()`. The behavior split is:

- `SyncRuntime.lua`: runtime state reset, warmup, peer health/backoff,
  peer capability tracking, online-node tracking, coordinator selection,
  stale-state prune, bounded active-request bookkeeping, and background
  workers.
- `SyncProtocol.lua`: `HELLO`, `AD`, `IDX`, envelope send/receive, top-level
  comm dispatch, and capability advertisement/ingest for optional sync
  features.
- `SyncCodec.lua`: optional `SNAP` codec negotiation plus
  `LibSerialize + LibDeflate` encode/decode helpers and codec telemetry.
- `SyncRequests.lua`: direct request queueing, bounded concurrent dispatch,
  retry policy, backoff-aware arbitration, manual catch-up, and negotiated
  request capabilities such as `acceptSnapCodec`.
- `SyncTransfer.lua`: `REQ`/`SNAP`/`RESUME`/`DONE`, snapshot session transfer,
  collision-safe session ids, per-owner request bookkeeping, pacing, optional
  snapshot block encoding/decoding, and inbound apply queues.
- `SyncManifest.lua`: `MANI`/`MREQ`, manifest send queue, coalesced announce,
  deferred peer-manifest compare replay, and manifest catch-up batching/drain.
- `SyncDiagnostics.lua`: debug snapshots, cleanup helpers, slash/status
  diagnostics, and snapshot-codec telemetry dumps.

`TrickleSync.lua` owns manifest chunking and manifest comparison. It decides
which `owner::profession` blocks are missing or outdated after a peer manifest
arrives.

`MergeEngine.lua` decides whether incoming snapshots can replace local data.
Authority order is `owner > replica > bootstrap`, then higher `rev`, then newer
`updatedAt`. Local owner data is protected from replica/bootstrap overwrite.

`Performance.lua` is a small cooperative scheduler. It runs background jobs on
a 0.05 second ticker with a default 3 ms budget and up to 6 steps per tick. It
also batches UI refreshes.

`SyncPausePolicy.lua` treats combat and real instances as sensitive contexts.
It pauses outbound sync, inbound apply, manifest-cache background work,
bootstrap, maintenance jobs, and UI background jobs until the player is back
in a safe context. Leaving combat or a real instance now also triggers a short
sync warmup window. Being in a raid group outside an instance does not pause
sync.

`GuildLifecycleMaintenance.lua` runs roster cleanup in chunks. Weekly cleanup
is due after 7 days. Stale records are pruned after 28 days. Manual cleanup is
available from the UI.

`BootstrapSync.lua` is mostly scaffolding. It can discover/rank candidate seeds
and expose UI state, but the actual bootstrap wire protocol is still marked as
placeholder.

`MockSync.lua` provides local stress scenarios for direct snapshots, traffic,
offline replicas, roster lifecycle behavior, incomplete roster guards, and
partial snapshot integrity checks. Hard isolation can suppress real addon
traffic during mock runs, but the heaviest concurrent sync simulations now live
in the local comm-bus harness under `local-tests/`.

`Market.lua` resolves material costs through TSM first, then Auctionator, with a
30 second price cache.

`Tooltip.lua` builds item/spell-to-crafter indexes and appends up to 5 crafters
to supported item, recipe, and spell/enchant tooltips. The index now stores
recipe keys per bucket and resolves sorted crafter rows from `Data` when the
tooltip actually needs them, which reduces duplicate UI structures.

`UI/MainFrame.lua` owns the main window, profession tabs, search, favorites,
recipe list, detail panel, share actions, debug panel, and roster cleanup
button.

`Options.lua` exposes basic buttons in the Blizzard options panel.

`MinimapButton.lua` registers the LibDataBroker/LibDBIcon launcher.

## Saved Variables And Data Shape

The TOC declares:

- `RecipeRegistryDB` as account/profile saved variables through AceDB.
- `RecipeRegistryCharDB` as per-character saved variables.

`RecipeRegistryDB.global.meta` contains:

- `schemaVersion`
- `lastWeeklyCleanupAt`
- `bootstrapCompletedAt`

`RecipeRegistryDB.global.members` is the main data store. A member entry is
normalized by `Data:NormalizeMemberEntry()` and contains:

- `owner`: usually the same as the member key.
- `rev`: member-level revision used by sync.
- `updatedAt`: last owner/replica update time.
- `sourceType`: usually `owner`, `replica`, or `bootstrap`.
- `guildStatus`: `active` or `stale`.
- `lastSeenInGuildAt`
- `staleAt`
- `isMock`
- `professions`

Each `professions[professionKey]` block is normalized by
`Data:NormalizeProfessionBlock()` and contains:

- `recipes`: set table keyed by recipe key.
- `count`
- `signature`: stable recipe fingerprint.
- `skillRank`
- `skillMaxRank`
- `specialization`
- `blockRevision`
- `lastUpdatedAt`
- `sourceType`
- `guildStatus`
- `lastSeenInGuildAt`

Recipe key convention:

- Positive key: created item ID or item-based recipe identity.
- Negative key: spell ID stored as `-spellID`.

`RecipeRegistryCharDB.favorites` stores favorite recipe keys per character.

Profile settings include `selectedProfession`, `sortMode`, and `minimap`.

## Runtime Lifecycle

`Addon:OnInitialize()` registers `/rr` and `/reciperegistry`.

`Addon:OnEnable()` registers:

- `PLAYER_ENTERING_WORLD`
- `TRADE_SKILL_SHOW`
- `CRAFT_SHOW`
- `NEW_RECIPE_LEARNED`
- `SPELLS_CHANGED`
- `SKILL_LINES_CHANGED`
- direct events for `PLAYER_ENTERING_WORLD`, profession scan signals, and UI
  lifecycle
- `AceBucket-3.0` buckets for `GUILD_ROSTER_UPDATE` and
  `GET_ITEM_INFO_RECEIVED`

After enable, a 0.2 second timer refreshes the minimap button and creates the
main frame.

`Addon:OnPlayerEnteringWorld()` does nothing if the player is not in a guild.
If the player is in a guild, it requests the guild roster. On login/reload it
schedules `Addon:OnLoginReady()` after 4 seconds. On non-login zone entry it
schedules a sync hello after 2 seconds.

`Addon:OnLoginReady()` detects local professions, starts sync, and requests a
UI refresh. If profession detection discovers a supported specialization for the
first time, local `rev` can advance before startup so the next advertise
includes that metadata exactly once.

Profession windows trigger deferred scans:

- `TRADE_SKILL_SHOW` schedules a 0.3 second `Data:ScanTradeSkill()` and no
  longer checks `TradeSkillFrame:IsShown()` in `Core.lua` before calling data.
- `CRAFT_SHOW` schedules a 0.3 second `Data:ScanCraft()` and no longer checks
  `CraftFrame:IsShown()` in `Core.lua` before calling data.
- Recipe change signals debounce into `Addon:ProcessRecipeSignal()` after 1
  second, call `Data:MarkScanNeeded(nil, "recipe-event")`, and attempt both
  TradeSkill and Craft scans opportunistically. If the profession API is not
  ready, the pending scan state remains open.

Guild roster updates are now coalesced through a 1.5 second bucket. Each flush
updates bucket telemetry, increments sync coalescing counters, then either
rebuilds presence immediately or defers that heavier work through
`ScheduleRosterUpdate()` if lifecycle gating still wants roster/UI work delayed.

Item info updates are now coalesced through a 0.75 second bucket, invalidate
only the list/label cache scope, and request one `item-cache` refresh per
flush.

## Profession Scanning

`Data:DetectProfessions()` reads skill lines and populates local tracked
professions. Tracked professions include crafting and gathering names in
`TRACKED`, but the UI profession order is a separate list in `UI/MainFrame.lua`.
Changing profession support usually requires checking both lists.

For supported TBC professions, `Data:DetectProfessions()` also checks
specialization spell knowledge through `IsSpellKnown()`. Metadata-only changes
flow through `Data:ApplyLocalProfessionMetadata()`, which updates
`skillRank/skillMaxRank/specialization`, bumps the local revision only when the
specialization actually changed, and marks the manifest dirty for that single
`owner::profession` block.

`Data:ScanTradeSkill()`:

- Uses `Data:GetActiveTradeSkillProfession()` and
  `Data:CanScanTradeSkillData()` to find the canonical profession and verify
  that the TradeSkill API has active data.
- Skips untracked professions.
- Skips with `trade-no-title`, `trade-untracked`, `trade-api-missing`, or
  `trade-data-not-ready` before touching owner data when the API is not ready.
- Skips routine scans if the DB already has data and no scan is pending for
  that profession or via the generic recipe-event fallback.
- Saves and clears TradeSkill filters.
- Expands collapsed headers, records recipes, then restores previous state.
- Uses item links when possible; otherwise uses negative spell IDs.
- Calls `Data:ApplyScanResult()` and returns a rich result table with
  `changed`, `valid`, `profession`, `skipReason`, `count`, `previousCount`, and
  `suspectedPartial`.

`Data:ScanCraft()` uses `Data:GetActiveCraftProfession()` and
`Data:CanScanCraftData()`. `GetActiveCraftProfession()` prefers
`GetCraftSkillLine(1)` so Beast Training can be identified even when
`GetCraftDisplaySkillLine()` has no displayable name. Craft scanning is
intentionally limited to Enchanting. This avoids storing non-profession
CraftFrame contents such as Beast Training as recipe data. Non-Enchanting
CraftFrame data skips with `craft-not-enchanting` and does not consume generic
recipe-event pending state.

Core/data split:

- `Core.lua` owns event debounce/timers and sync advertisement after a changed
  scan.
- `Data.lua` owns the "can this API be scanned safely?" decision.
- A hidden Blizzard frame is no longer enough to skip scanning if the API still
  exposes active profession data.
- An empty active API list is treated as not ready, not as an authoritative
  zero-recipe owner snapshot.

Scan pending state:

- `Data:MarkScanNeeded(profession, reason)` stores either
  `_scanNeededByProfession[profession]` or a generic pending marker when the
  changed profession is unknown.
- The legacy `_scanNeeded` boolean is only a compatibility mirror.
- Generic recipe-event pending is kept open through unchanged scans, invalid
  scans, and suspected partial scans. This avoids consuming a real recipe
  change by opening the wrong profession first.
- Manual `/rr rescan` also marks a generic pending scan, immediately tries any
  active TradeSkill/Craft API data, advertises if that scan changes local data,
  and otherwise leaves the manual request pending.

`Data:ApplyScanResult()` computes a stable signature. If the signature changed:

- `Data:TouchLocalRevision()` increments local `rev`.
- The profession block gets the new `blockRevision`.
- Recipe caches are invalidated.
- The UI refreshes.
- `Core.lua` callers advertise the local revision through sync.

If recipes stay the same but the active profession metadata resolves a new
specialization, `Data:ApplyScanResult()` still treats that as a changed owner
block, bumps `rev`, updates `blockRevision`, and prints a specialization update
message. Re-running the same detection later stays stable and does not
re-advertise.

If the signature did not change, the scan prints an unchanged message but does
not increment revision or advertise.

If a scan returns fewer recipes than the current owner block, it is treated as a
suspected partial scan. The existing owner data is kept, the scan is counted in
diagnostics, and the pending scan remains open.

Scan diagnostics:

- `/rr dump` prints scan counters after the DB summary.
- `/rr perf dump` prints scan and manifest cache lines after scheduler/sync
  status.
- `/rr perf reset` resets scan and manifest telemetry along with
  performance/sync telemetry.
- Invalid recipe filtering is counted by context: snapshot build, inbound
  snapshot chunk, and `/rr clean`. The last invalid key/member/profession is
  printed when any invalid recipe was observed.

## Local Backend Test Harness

`local-tests/` is intentionally local/gitignored. The harness is for fast Lua
5.1 checks outside the game client.

Files:

- `local-tests/harness/wow.lua`: minimal WoW API, `LibStub`, AceAddon/AceDB,
  AceSerializer, comm capture, profession API fixtures, guild roster fixtures,
  and timer/scheduler support.
- `local-tests/harness/load-addon.lua`: loads backend modules in TOC order.
- `local-tests/harness/test.lua`: small assertion runner.
- `local-tests/run-syntax.ps1`: syntax check with `luac.exe`.
- `local-tests/run-backend-tests.ps1`: executes every `local-tests/spec/*.lua`.

Current backend specs:

- `p2_integrity_spec.lua`: pending scan retention, unchanged generic pending,
  partial snapshot preservation, and incomplete roster snapshot abort.
- `mock_scenarios_spec.lua`: all declared `MockSync` scenarios, including
  direct snapshot load, bootstrap mock, traffic/offline/offlinewipe/trafficburst
  manifest replica catch-up, roster/rosterheavy, rosterbad, integrity, slash
  command surface, and cleanup.
- `p4_scan_opportunistic_spec.lua`: hidden-frame TradeSkill/Craft scans,
  not-ready API data, recipe-event opportunistic scans, generic pending
  retention, and non-Enchanting CraftFrame skips.
- `manifest_cache_spec.lua`: manifest cache build/reuse, chunk cache reuse,
  dirty-block delta updates, stale block removal, deferred MANI sends until the
  fresh cache is ready, paced same-peer MANI delivery, unchanged-manifest skip
  behavior, and timeout reset of per-peer manifest announce state.
- `manifest_catchup_cap_spec.lua`: large manifest catch-up caps, deferred queue
  draining, malformed candidate rejection, owner priority ordering, and skip
  rules for online or stale owners.
- `manifest_comm_scale_spec.lua`: comm-boundary scale run using
  `Wow.DeliverComm(...)`, serialized `HELLO`/`MANI` delivery, true outbound
  `REQ` generation through `SendCommMessage`, and convergence after real
  `SNAP` responses.
- `manifest_comm_bus_spec.lua`: multi-node comm-bus with 200 isolated addon
  peers, routed `GUILD`/`WHISPER`, coordinator convergence/churn, conflicting
  offline replicas, reordered/lost snapshot chunks with `RESUME`, and stale
  owner races during in-flight replica sync.
- `slash_output_spec.lua`: main help, perf dump/reset diagnostics, manual
  rescan queued/completed output, manifest/offline/sync diagnostics, target
  manifest request output, compact-vs-verbose manifest output, and mock
  help/usage output. It also guards against raw `|` separators in help/usage
  text, because WoW chat treats them as control characters for colors and links.
- `tooltip_index_spec.lua`: stale-index reads during asynchronous rebuild,
  background tooltip index commit, and restart behavior when data changes again
  during an active tooltip rebuild.
- `pause_policy_spec.lua`: regression coverage that raid groups outside
  instances keep syncing, while real instances pause protocol traffic and
  defer manifest-cache work until the player leaves the sensitive context.
- `manifest_cache_spec.lua`: also covers one-shot manifest refresh requests on
  the first `HELLO` of a local session, so unchanged peers can resend metadata
  after reloads or updates. It also covers `/rr wipe`-equivalent database
  resets, proving that sync session state is cleared and a fresh guild-wide
  manifest request plus `HELLO` are sent again in the same login.
- `specialization_sync_spec.lua`: now includes an end-to-end repair path where
  `HELLO` triggers `MREQ`, `MANI` triggers a block `REQ`, and `SNAP` repairs a
  missing specialization at the same remote revision.
As of the last update, `.\local-tests\run-backend-tests.ps1` passes 82 backend
tests. These tests do not replace in-game validation, but they should be run
before changing slash commands, scan, merge, mock, roster, manifest, or sync
queueing behavior.

## Recipe Resolution And Indexes

`Data:BuildRecipeIndex()` builds a recipe-key index from visible, non-mock,
non-stale members. Each row tracks profession names, crafter rows, unique
crafter count, and online count.

`Data:GetRecipeDisplayInfo()` resolves labels, created items, recipe items,
spell IDs, icons, quality, profession metadata, and reagents. It prefers
AtlasLoot data when available and falls back to native item/spell info.

`Data:GetRecipeList(profName, query, sortMode)` filters the recipe index,
resolves display info, searches `searchText`, and sorts by alpha or rarity.

`Data:GetRecipeDetail(recipeKey)` adds crafters and calls
`Market:ApplyRecipeCosts(detail)` when the market module is available.

Important cache invalidation scopes:

- `list`: list rows/labels only.
- `presence`: list, crafters, and recipe index.
- default: list, detail, crafters, and recipe index.

## Sync Protocol Overview

Comm prefix: `RRG1`

Serialization: `AceSerializer-3.0`

Transport:

- Guild-wide messages use AceComm distribution `GUILD`.
- Direct messages use `WHISPER` to the character name parsed from
  `Name-Realm`.

Message kinds:

- `HELLO`: guild broadcast with local summary/version.
- `AD`: guild broadcast when local revision changes.
- `IDX`: coordinator-broadcast revision hint.
- `REQ`: direct request for a member snapshot or selected blocks.
- `SNAP`: direct snapshot chunk.
- `RESUME`: direct request for missing chunk sequence numbers.
- `DONE`: direct acknowledgement that a transfer completed.
- `MANI`: direct manifest chunk.
- `MREQ`: manifest request; reply is forced and bypasses manifest cooldown.

Important sync timers/constants in `Sync.lua`:

- `HELLO_INTERVAL = 30`
- `AUTO_SYNC_INTERVAL = 20`
- `MANIFEST_PUSH_COOLDOWN = 20`
- `OUTGOING_CHUNK_DELAY = 0.20`
- `REQUEST_TIMEOUT = 12`
- `PROGRESS_TIMEOUT = 4`
- `SESSION_TIMEOUT = 35`
- `NODE_TIMEOUT = 95`
- `MAX_RESUME_ATTEMPTS = 3`

`Sync:Startup()` registers comms, schedules:

- first hello after 1 second,
- repeated hello every 30 seconds,
- request queue processing every 1 second,
- prune state every 5 seconds,
- auto-sync every 20 seconds,
- first auto-sync tick after 6 seconds,
- startup revision advertise.

Coordinator behavior:

- `Sync:TouchNode()` records online addon peers.
- `Sync:RecomputeCoordinator()` picks the lexicographically first online guild
  addon node, with self as fallback.
- Coordinators rebroadcast newer revision hints as `IDX`.
- Non-coordinators ignore `IDX` unless it comes from the current coordinator.

Request flow:

1. `HELLO`, `AD`, `IDX`, or manifest comparison notices a newer/missing block.
2. `Sync:QueueRequest()` stores one pending request per member key.
3. `Sync:ProcessRequestQueue()` fills a small bounded window of active direct
  requests instead of a single global in-flight slot.
4. Each active request sends `REQ` with local known revision, wanted revision,
  and optional requested block keys.
5. `Sync:HandleRequest()` builds snapshot chunks from `Data:BuildSnapshotChunks()`.
6. `Sync:SendOutgoingSession()` queues `SNAP` chunks.
7. `Performance.lua` runs `sync-outbound-loop`; `Sync:SendNextLowPriorityChunk()`
   sends one eligible chunk, paced per peer by `OUTGOING_CHUNK_DELAY`.
8. Receiver enqueues chunks in `Sync:HandleSnapshotChunk()`.
9. `sync-inbound-loop` decodes chunks and finalizes complete snapshots through
   `Data:FinalizeIncomingSnapshot()`.
10. `MergeEngine:ApplyIfNewer()` decides whether the incoming snapshot wins.

Resume/timeout behavior:

- If a request has no session after `REQUEST_TIMEOUT`, it is failed/requeued.
- If progress stalls for `PROGRESS_TIMEOUT`, `RESUME` is sent for missing seqs.
- Resume is attempted up to `MAX_RESUME_ATTEMPTS`.
- Total session age is bounded by `SESSION_TIMEOUT`.

## Manifest Deep Dive

The manifest is a compact summary of logical sync blocks. It does not carry the
recipe list. Recipe lists move through snapshot chunks.

Creation:

- `TrickleSync:BuildLocalManifest()` calls `Data:BuildSyncManifest(false)`.
- `Data:BuildSyncManifest(false)` builds a fresh table with `builtAt = time()`.
- `false` means stale members are excluded.
- Mock members are excluded by `Data:GetAllSyncBlocks()`.

Block key:

- `Data:BuildSyncBlockKey(ownerCharacter, professionKey)` returns
  `ownerCharacter::professionKey`.

Each manifest block includes:

- `ownerCharacter`
- `professionKey`
- `revision`
- `lastUpdatedAt`
- `sourceType`
- `guildStatus`
- `lastSeenInGuildAt`
- `count`
- `fingerprint`

Manifest chunking:

- `Data` keeps an in-memory manifest cache. Full builds and dirty-block delta
  updates run through `manifest-cache-build` in the performance scheduler.
- Build cost is measured via `debugprofilestop()` and tracked as
  `totalBuildCostMs`, `maxBuildCostMs`, `lastBuildCostMs` in manifest telemetry.
  Both synchronous `BuildManifestCacheNow()` and background
  `RunManifestBuildStep()` pass timing through `CommitManifestBuild()`.
- `TrickleSync:BuildManifestChunks()` sorts block keys and caches the resulting
  chunks by manifest id, so multiple peer sends can reuse the same chunks.
- `TrickleSync` tracks chunk cache invalidation count and last invalidation
  reason. `InvalidateManifestChunkCache(reason)` records both.
- It sends 24 manifest blocks per `MANI` chunk.
- `manifestId` is `memberKey:builtAt:manifestSerial:blockCount`.
- Even an empty manifest produces one chunk with empty `blocks`.
- When a manifest send is requested while the cache is dirty, `Sync` queues the
  peer in `pendingManifestPeers` and flushes it from `OnManifestCacheReady()`.
- Ready manifest chunks are queued in `Sync.manifestChunkQueue`; the
  `sync-outbound-loop` sends them with peer pacing instead of sending all MANI
  chunks inline.

Send triggers:

- `Sync:BroadcastHello()` sends `HELLO`; manifest propagation now relies
  primarily on targeted replies and explicit refresh paths instead of broad
  periodic manifest rebroadcast.
- `Sync:AdvertiseLocalRevision(reason)` sends `AD` and then broadcasts a
  manifest when local revision changed, or during startup.
- `Sync:AutoSyncTick()` runs every 20 seconds. If online, it queues direct
  catch-up from registry hints until the bounded request window is full and
  uses targeted manifest paths instead of unconditional broad rebroadcast.
- If no online nodes are known, `AutoSyncTick()` sends `HELLO` when the last
  hello is older than 10 seconds.
- `Sync:RequestManifestRefresh(peerKey)` sends `MREQ` to a specific peer.
- `Sync:RequestManifestRefresh()` without a peer sends guild-wide `MREQ`; this
  is used by `/rr pull` after direct catch-up queueing.
- `/rr manifest` with no target prints compact `Data:DumpManifestSummary()`.
- `/rr manifest verbose` prints capped replica/stale detail lines.
- `/rr manifest <target>` sends a direct `MREQ` to that target.

Cooldown:

- `Sync:SendManifestToPeer(peerKey, why)` suppresses sends to the same peer if
  the last send was less than `MANIFEST_PUSH_COOLDOWN` seconds ago. Each call
  increments `manifestBuildRequests` before the cooldown check.
- `why == "force"` bypasses the cooldown. `Sync:HandleManifestRequest()` uses
  `"force"` when replying to `MREQ` and increments `manifestForceReplies`.
- `Sync:HandleManifestChunk()` increments `manifestChunksReceived` for each
  valid incoming chunk.
- `manifestChunksDelivered` was removed as a duplicate of `manifestChunksSent`.
- `/rr perf dump` includes `Manifest cache ...` with readiness, dirty block
  count, background build counts, cache hits, deferred sends, chunk-cache hits,
  chunk invalidations, queued MANI chunks, sent MANI chunks, current MANI queue
  depth, and build cost timing (avgCostMs, maxCostMs, lastCostMs via
  `debugprofilestop`).
- `/rr sync` now includes a second `Manifest requests=...` line with build
  requests, sent/received/queued chunks, cooldown skips, force replies, deferred
  sends, pending flushes, and max queue depth.
- `/rr manifest` now includes a `Manifest builds=...` summary line with build
  count (full/delta split), average and max build cost, build requests, cooldown
  skips, and force replies.

Receive flow:

1. `Sync:HandleManifestChunk()` groups chunks by sender and `manifestId`.
2. It waits until all `seq` values are present.
3. It stores the completed peer manifest with
   `TrickleSync:StorePeerManifest()`.
4. `TrickleSync:QueueMissingBlocksForPeer()` compares peer blocks with a fresh
   local manifest.
5. Missing/outdated local blocks are grouped by owner and prioritized by direct
   owner/sender first, then offline replica candidates, then newer revision,
   then larger block count, then owner key.
6. Sync queues only a capped first batch immediately and moves the rest into
   `manifestCatchupQueue` for deferred draining.
7. For each eligible group, sync queues `REQ` from the manifest sender when:
   - the sender is the owner, or
   - the owner is offline and the sender can serve as replica.
8. Replica telemetry is updated for offline-owner blocks, plus catch-up
   telemetry for candidates/queued/deferred/drained/skipped owners.
9. The UI refresh reason is `manifest`.

Manifest comparison:

- Missing peer block locally -> `missingHere`.
- Local block missing on peer -> `missingThere`.
- Peer revision greater than local -> `outdatedHere`.
- Peer revision lower than local -> `outdatedThere`.
- Same revision but different fingerprint -> `outdatedHere`.
- Stale peer blocks do not drive normal convergence.

## Merge And Authority

`MergeEngine` scores authority as:

- `bootstrap = 1`
- `replica = 2`
- `owner = 3`

If authority is tied, higher `rev` wins. If revision is tied, newer
`updatedAt` wins. Exact equivalent snapshots are skipped and counted in sync
telemetry.

`Data:FinalizeIncomingSnapshot()` has an additional partial-overwrite guard:
when an incoming profession has fewer recipes than the current local copy and
the incoming recipes are a subset with skill rank at least the current rank, it
unions the recipes instead of shrinking the data. This also protects zero-count
subset snapshots.

For non-owner incoming snapshots, `Data:FinalizeIncomingSnapshot()` preserves
current profession blocks that are missing entirely from the incoming snapshot.
This prevents a partial replica/snapshot from deleting known professions.

When finalizing the local player's own entry, `preserveOwner = true` prevents
non-owner incoming data from replacing local owner data.

## Roster Lifecycle

Roster cleanup is local-only maintenance.

`GuildLifecycleMaintenance:StartWeeklyCleanup()` runs only when
`lastWeeklyCleanupAt` is at least 7 days old.

`GuildLifecycleMaintenance:StartManualCleanup()` forces a run. The UI button
uses this path.

Cleanup behavior:

- Builds a guild roster snapshot from `GetGuildRosterInfo()`.
- Validates the snapshot before scheduling cleanup. If known active DB members
  exist and the snapshot is empty or below the minimum plausibility ratio,
  cleanup aborts with `roster-empty` or `roster-too-small`.
- Processes members in chunks of 25.
- Members still in the guild are marked `active`.
- Missing members are marked `stale`, except the local player.
- Stale records older than 28 days are deleted.
- Stale members are excluded from normal UI results and normal manifests.
- Mock cleanup can bypass validation with `opts.mock`; `rosterbad` deliberately
  runs without that bypass to exercise the guard.

## Performance And Pause Model

Background jobs are scheduled through `Performance:ScheduleJob(category, fn,
opts)`. Current important categories:

- `sync-outbound`
- `sync-inbound`
- `sync-manifest-catchup`
- `bootstrap`
- `maintenance`

`Sync:EnsureBackgroundWorkers()` schedules permanent outbound/inbound sync
loops.

`SyncPausePolicy` pauses `sync-outbound`, `sync-inbound`, `sync-manifest`,
`bootstrap`, `maintenance`, and `ui` when the player is in combat or inside a
real instance. Protocol traffic is also short-circuited on both send and
receive paths until the player is back in a safe context. A raid group outside
instances no longer counts as paused by itself.

UI refreshes should go through `Addon:RequestRefresh(reason)`. With
`Performance.lua`, refreshes are queued and then flushed only if the frame is
shown. This avoids redraw bursts during sync.

Known current hotspots to keep in mind before changing behavior:

- `Sync:BroadcastHello()` and `Sync:AutoSyncTick()` still fan manifests out to
  known peers, but same-manifest re-announcements to the same peer are now
  skipped; the remaining cost is the first announce per peer session plus any
  real manifest changes.
- The catch-up path now uses a local-only `TrickleSync:ComparePeerManifest()`
  mode and no longer computes peer-side diffs it does not consume, but full
  manifest comparisons still remain available for diagnostics or future paths.
- Tooltip index rebuilds are now backgrounded, but the underlying
  `Data:GetRecipeIndex()` cost can still matter if presence-heavy invalidations
  happen repeatedly while the UI is active.
- Recipe list rendering is not virtualized; large global searches can still do
  noticeable work in one refresh.

## UI Behavior

The main UI is created once and hidden by default. It has:

- title/status area,
- summary cards,
- search box,
- profession/favorites buttons,
- alpha/rarity sort,
- recipe list rows,
- detail panel,
- optional performance debug panel.

Search behavior:

- Profession tab search debounce: 0.15 seconds.
- Global search debounce: 0.35 seconds.
- Global search requires at least 2 characters.
- With no selected profession and no sufficiently long search, the recipe list
  is intentionally empty.

Favorites:

- Stored per character in `RecipeRegistryCharDB.favorites`.
- UI filters favorites by first fetching all matching rows and then filtering
  with `UI:IsFavorite()`.

Detail panel:

- Shows online crafters first.
- Offline crafters are collapsed by default when at least one online crafter
  exists.
- Online crafters get a request button unless the crafter is self.
- Materials support tooltip links and shift-click insertion.
- Cost estimates appear only when at least one reagent has a price.

## Pricing

`Market:GetMaterialCost()` checks:

1. TSM custom price `dbmarket`
2. TSM custom price `dbminbuyout`
3. Auctionator by item ID
4. Auctionator by item link

Prices are cached for 30 seconds by item ID.

`Market:ResolveItemQuery()` can resolve item ID, item link, exact item name, or
names from the selected recipe/current recipe list.

## Tooltip Integration

`Tooltip:RebuildIndex()` builds a crafter index from `Data:GetRecipeIndex()`.
It maps positive item recipe keys, negative spell/enchant keys, and AtlasLoot
aliases for created items, recipe items, and spells when available. The bucket
payload stores recipe keys instead of full crafter row copies, and the render
path resolves rows from the shared recipe index only when a tooltip is shown.

`Tooltip:AddCraftLines()` prefers online crafters when any are online. If none
are online, it shows visible offline crafters. Tooltip rendering is capped by
`MAX_TOOLTIP_CRAFTERS` and adds a `+N more` line when needed.

`Tooltip:InvalidateIndex()` now schedules a background `tooltip-index-build`
job through `Performance.lua`. `Tooltip:GetRowsForKey()` keeps serving the
previous index while the rebuild is in flight, so the first hover after
sync/roster changes no longer has to pay the full rebuild cost inline. If the
tooltip index is dirty and no scheduler is available, it still falls back to a
direct rebuild outside combat.

## Bootstrap State

Bootstrap currently exposes candidate selection and UI state, but transfer is
not implemented yet.

Important notes:

- `Data:IsBootstrapNeeded()` returns true when there are no local blocks, or
  blocks exist but recipe count is zero.
- `Data:IsBootstrapCandidate()` requires at least one block and one recipe.
- `BootstrapSync:RequestBootstrap()` schedules a placeholder job and returns.
- `BootstrapSync:SendNextBootstrapChunk()` currently returns false.

Any real bootstrap feature must define wire messages, compatibility rules, and
merge authority carefully.

## Slash Commands Useful For Analysis

- `/rr`: open/close UI.
- `/rr help`: print the multiline command list.
- `/rr rescan`: mark a manual generic scan, scan active profession API data
  immediately when available, or leave scan state pending.
- `/rr sync`: print sync status and manifest send/receive telemetry.
- `/rr pull`: queue catch-up requests and request fresh manifests.
- `/rr manifest`: print local manifest summary and build cost/request counters.
- `/rr manifest verbose`: print local manifest summary plus capped
  replica-owner and stale-owner details.
- `/rr manifest <target>`: request fresh manifest from a target peer.
- `/rr offline` or `/rr replica`: print offline/replica sync telemetry.
- `/rr perf dump`: print scheduler, sync counters, scan diagnostics, and
  manifest cache telemetry including build cost timing and chunk invalidations.
- `/rr perf reset`: reset performance, sync, scan, and manifest counters.
- `/rr mock status`: print mock state.
- `/rr mock help`: print all mock scenarios, including `offlinewipe`.
- `/rr mock start traffic`: local HELLO/MANI/REQ/SNAP traffic scenario.
- `/rr mock start offline`: replica/offline-owner convergence scenario.
- `/rr mock start offlinewipe`: wipe-local/offline-owner replica scenario.
- `/rr mock start trafficburst`: heavier replica traffic scenario.
- `/rr mock start roster`: roster cleanup scenario.
- `/rr mock start rosterheavy`: heavier roster cleanup scenario.
- `/rr mock start rosterbad`: incomplete roster snapshot guard scenario.
- `/rr mock start integrity`: partial snapshot/merge integrity scenario.
- `/rr prices <item>`: inspect price provider behavior.
- `/rr atlas`, `/rr r`, `/rr s`, `/rr i`: AtlasLoot diagnostics.
- `/rr clean`: remove invalid recipe keys.
- `/rr wipe`: clear DB and sync cache.

## Invariants To Preserve

- Manifest is summary metadata; snapshot chunks carry recipe payload.
- `ownerCharacter::professionKey` is the logical block identity.
- Local owner data should not be overwritten by replica/bootstrap data.
- Stale and mock members should not appear in normal user-visible results or
  normal manifests.
- Revision increments should happen only when local recipe data actually
  changes.
- A changed scan should advertise local revision; unchanged scans should not
  create sync traffic.
- Frame visibility alone should not decide whether a profession can be scanned;
  `Data.lua` readiness helpers decide from active profession API data.
- Not-ready or wrong-skill profession API data should keep pending recipe-event
  scan state open and must not publish an empty owner snapshot.
- Suspicious partial owner scans should not shrink a profession block or close
  pending recipe-event scan state.
- Replica/bootstrap snapshots should not remove local profession blocks that
  are missing from a partial incoming snapshot.
- Incomplete guild roster snapshots should abort cleanup before marking active
  members stale.
- Invalid recipe filtering should be observable through diagnostics and should
  avoid destructive drops when AtlasLoot is present but lacks a spell mapping.
- Heavy work should run through `Performance.lua` jobs, not directly in UI or
  tooltip paths.
- Inbound and outbound sync should respect `SyncPausePolicy`.
- Item cache updates should refresh labels/icons without rebuilding more than
  needed.
- UI code relies on cache invalidation scopes; pick the narrowest correct
  scope.
- Wire-visible shape changes should consider `WIRE_VERSION` and compatibility.
  Optional negotiated payload upgrades like the `SNAP` codec can stay on the
  current wire version only when both peers can fall back cleanly to the legacy
  payload shape.

## Common Impact Areas

When adding or changing a feature, start by checking these surfaces.

Data model or saved variables:

- `DB_DEFAULTS`
- `Data:MigrateDatabase()`
- `Data:NormalizeMemberEntry()`
- `Data:NormalizeProfessionBlock()`
- `Data:WipeDatabase()`
- Any UI or sync code reading the new field

Recipe identity or recipe scans:

- `TRACKED`
- `PROFESSION_SPELL_IDS`
- `Data:DetectProfessions()`
- `Data:ScanTradeSkill()`
- `Data:ScanCraft()`
- `Data:ApplyScanResult()`
- `isValidRecipeKey()`
- AtlasLoot resolver helpers
- Tooltip index if item IDs are affected

Sync payload or protocol:

- `Addon.WIRE_VERSION`
- `Sync:OnCommReceived()`
- `Sync:SendGuildEnvelope()`
- `Sync:SendDirectEnvelope()`
- `Data:BuildSnapshotChunks()`
- `Data:AppendIncomingChunk()`
- `Data:FinalizeIncomingSnapshot()`
- `MergeEngine`
- Mock traffic scenarios

Manifest behavior:

- `Data:GetSyncBlock()`
- `Data:GetAllSyncBlocks()`
- `Data:BuildSyncManifest()`
- `TrickleSync:BuildManifestChunks()`
- `TrickleSync:ComparePeerManifest()`
- `TrickleSync:GroupBlockRequestsByOwner()`
- `Sync:SendManifestToPeer()`
- `Sync:HandleManifestChunk()`
- `/rr manifest` diagnostics

Performance or background work:

- `Performance:ScheduleJob()`
- category pause behavior in `SyncPausePolicy`
- job budget and chunk size constants
- UI refresh reasons and `buildRefreshPlan()`

Roster or visibility:

- `Data:IsMemberVisible()`
- `Data:IsUserVisibleMember()`
- `Data:MarkMemberActive()`
- `Data:MarkMemberStale()`
- `Data:DeleteMember()`
- `GuildLifecycleMaintenance`
- manifest stale filtering
- recipe index filtering

UI features:

- state init in `UI:OnInitialize()`
- frame construction in `UI:CreateMainFrame()`
- refresh planning in `buildRefreshPlan()`
- `UI:RefreshStatusBar()`
- `UI:RefreshProfessionButtons()`
- `UI:RefreshRecipeList()`
- `UI:RefreshDetailPanel()`
- `UI:ShareSelectedRecipe()`

Market/pricing:

- provider order in `Market:GetMaterialCost()`
- cache TTL and invalidation expectations
- `Market:ApplyRecipeCosts()`
- UI detail rendering of cost fields

## Impact Analysis Template

Use this template before implementing a feature:

Feature:

Primary user flow:

Entry points/events/commands touched:

Data shape changes:

Persistence/migration needed:

Sync-visible changes:

Wire compatibility/WIRE_VERSION impact:

Manifest impact:

Snapshot impact:

Merge/authority impact:

Roster/stale/mock impact:

UI screens and refresh reasons:

Cache invalidation needed:

Performance/job category impact:

Pause policy impact:

Tooltip/market/AtlasLoot impact:

Diagnostics/commands to update:

Mock scenario or manual test to add/run:

Rollback risk:

## Suggested Verification Matrix

Local fast checks:

- `.\local-tests\run-syntax.ps1`
- `.\local-tests\run-backend-tests.ps1`

For narrow local/UI changes:

- Open `/rr`.
- Change profession tab, global search, sort, favorite.
- Select a recipe and verify crafters/materials/cost area.
- Trigger `/rr perf dump` if refresh or jobs changed.

For scan changes:

- Login/reload in guild.
- Open each relevant profession window.
- Verify hidden-frame or freshly closed profession windows do not block scans
  when the API still has active data.
- Verify empty/not-ready TradeSkill/Craft API data does not publish a zero
  recipe owner snapshot.
- Verify changed scans increment local rev once.
- Verify unchanged scans do not advertise.
- Verify recipe-event pending survives opening the wrong profession first.
- Verify recipe-event pending survives no-title/not-ready active API data.
- Verify CraftFrame non-Enchanting data, such as Beast Training, does not
  create Enchanting data or consume generic pending.
- Verify suspicious subset scans keep the existing owner count and appear in
  scan diagnostics.
- Run `/rr dump`.
- Confirm invalid recipe counters remain visible in `/rr dump` and `/rr perf dump`
  after snapshot/inbound/clean filtering.

For sync/manifest changes:

- `/rr sync`
- `/rr manifest`
- `/rr pull`
- `/rr perf dump`
- `/rr mock start traffic`
- `/rr mock start offline`
- `/rr mock start integrity`
- `/rr offline`
- verify `Buckets ...` and `Snapshot codec ...` lines stay coherent under
  both legacy and negotiated transfer paths.

For roster changes:

- `/rr mock start roster`
- `/rr mock start rosterbad`
- manual `Roster Cleanup`
- verify incomplete roster snapshots abort with no stale marking.
- verify stale members disappear from normal UI/manifest.
- verify stale records prune only after retention.

For pricing:

- `/rr prices <item link>`
- selected recipe with priced and unpriced reagents.
- TSM present, Auctionator present, neither present.

For item cache/detail changes:

- Cold login with uncached item info.
- Watch placeholder labels/icons refresh after `GET_ITEM_INFO_RECEIVED`.
- Tooltip rendering should stay responsive.

## Known Sharp Edges

- Bootstrap transfer is placeholder-level, not a complete protocol.
- `TrickleSync.outboundQueue` records missing block diagnostics/state, but the
  actual data transfer is queued through `Sync:QueueRequest()`.
- Global search intentionally waits for 2 characters.
- CraftFrame scanning is limited to Enchanting by design.
- Tooltip spell/enchant mapping depends on available link/API data and is
  richer when AtlasLoot can resolve aliases.
- Profession support appears in multiple places: data tracking, UI order,
  spell icons, AtlasLoot mapping, and scan paths.
- Direct whisper target strips the realm from `Name-Realm`; cross-realm/guild
  behavior should be checked if that ever matters.
