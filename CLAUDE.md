# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Recipe Registry is a World of Warcraft: The Burning Crusade Classic Anniversary addon (Interface `20505`, Lua 5.1). It builds a shared guild crafting directory by scanning local professions and syncing them with guildmates who use the addon.

## Commands

**Run all active backend tests:**
```powershell
.\local-tests\run-backend-tests.ps1
```

**Run a single spec:**
```powershell
.\local-tests\run-backend-tests.ps1 -Spec sync_phase34_block_pull_spec.lua
```

**Run only the sync rewrite suite:**
```powershell
.\local-tests\run-backend-tests.ps1 -Suite sync
```

**Syntax check all Lua files:**
```powershell
.\local-tests\run-syntax.ps1
```

Tests require Lua 5.1 at `C:\Program Files (x86)\Lua\5.1\lua.exe`. Tests run from the repo root.

Suites: `all` (active baseline), `quick` (same as all), `sync` (HELLO/SUMMARY/INDEX_DIFF/BLOCK_PULL coverage), `soak` (no active specs).

## Architecture

### Addon structure

The addon uses **AceAddon-3.0** with modules registered via `Addon:NewModule("Name")` and stored as `Addon.Name`. Load order is defined in `RecipeRegistry.toc`.

**Core bootstrap** (`Core.lua`): Creates the addon with `AceConsole-3.0`, `AceEvent-3.0`, `AceTimer-3.0`, `AceBucket-3.0`. Sets up debug log, slash commands (`/rr`), and SavedVariables initialization.

**BuildInfo.lua**: Wire protocol version (`WIRE_VERSION = 3`, `MIN_SUPPORTED_WIRE_VERSION = 3`), capabilities (`indexDiffSync`, `blockPullSync`), build channel (`dev` vs `release`), and comm prefix (`RRDEV` vs `RecipeRegistry`). Dev and release clients do not sync with each other.

### Data cluster

| File | Role |
|---|---|
| `Data.lua` | Core saved-variables model, roster management, online cache, sync-facing index helpers, global/block fingerprint dirty state |
| `DataScan.lua` | Scans local profession windows via WoW TradeSkill/Craft API |
| `DataSnapshot.lua` | Block-scoped snapshot build and apply; additive merge per block |
| `DataCatalog.lua` | Searchable recipe catalog, favorites |
| `DataIndex.lua` | Active-owner index, content-only block/global fingerprint computation, runtime-only synthetic specialization keys |
| `DataCleanup.lua` | Sanitation and corruption-repair; signals index dirty instead of manifest paths |
| `DataAtlasLoot.lua` | Optional AtlasLoot integration for richer recipe metadata |
| `MergeEngine.lua` | Content-only additive merge; metadata allowed for completeness but never affects equality or routing |

### Sync cluster

| File | Role |
|---|---|
| `Sync.lua` | Hello-cycle state, SUMMARY collection, selected outbound seed, wanted-block list, inbound seed service |
| `SyncRuntime.lua` | Online peer tracking, pause/warmup/saturation gating, queue caps, delayed/coalesced HELLO scheduling, discovery retry backoff |
| `SyncProtocol.lua` | Message dispatch: HELLO (guild-wide), SUMMARY, INDEX_DIFF_REQUEST/RESPONSE, BLOCK_PULL_REQUEST, BLOCK_SNAPSHOT |
| `SyncCodec.lua` | Transport-neutral serialization helpers |
| `SyncRequests.lua` | Seed selection, ordered wanted-block ledger, sequential block pull orchestration |
| `SyncTransfer.lua` | Serves BLOCK_SNAPSHOT from current live block data |
| `SyncDiagnostics.lua` | Runtime observability: readiness gates, HELLO scheduling, discovery retry, session state, fingerprint cache |

**Support:**
- `SyncPausePolicy.lua`: pauses sync in raids/instances/specific states
- `GuildLifecycleMaintenance.lua`: trusted-roster preflight; conservative around incomplete roster
- `BootstrapSync.lua`: debug/diagnostics bootstrap only
- `MockSync.lua`: simulates HELLO/SUMMARY/INDEX_DIFF/BLOCK_PULL for local tests

### Sync protocol (Wire v3)

The sync model is **pull-based, content-only, additive**. The flow is:

```
HELLO (guild-wide)
→ SUMMARY (direct, from each ready peer whose fingerprint differs)
→ seed elected (highest content count, deterministic tie-break)
→ INDEX_DIFF_REQUEST (requester's compact block digest → seed)
→ INDEX_DIFF_RESPONSE (seed's offered block list → requester)
→ BLOCK_PULL_REQUEST (one block at a time)
→ BLOCK_SNAPSHOT (live block content)
→ additive merge + local block fingerprint recompute + global fingerprint marked dirty
→ next block
```

**Block key**: `ownerCharacter::professionKey`

**Fingerprints**:
- `blockFingerprint = bf3:<count>:<hash(sorted content keys)>`
- `globalFingerprint = gf3:<ownerCount>:<blockCount>:<contentCount>:<hash(sorted blockKey=blockFingerprint)>`
- Exactly one `globalFingerprint` — no committed/published split.
- Fingerprints are for discovery/diff only; never a merge gate or pull contract.

**Critical invariants** (enforced by `sync_legacy_grep_gate_spec.lua`):
- No revision fields (`rev`, `revision`, `blockRevision`, `knownRev`, `wantRev`, `ownerRevision`, etc.) in active sync code.
- `BLOCK_PULL_REQUEST` contains no fingerprint fields.
- Unknown inbound message kinds are ignored generically — no explicit handlers for `IDX`, `AD`, `MANI`, `MREQ`.
- Metadata may travel in payloads but must never affect content equality, routing, priority, or merge precedence.
- Runtime-only synthetic specialization keys (`spec:<professionKey>:<specializationKey>`) must never be persisted or shown in UI.

**Startup readiness** (`syncReady`) requires all of: SavedVariables initialized, player identity ready, world-transition warmup complete, trusted-roster preflight done, sync index ready, pause policy inactive, pressure below saturation gate. HELLO is never broadcast inline from login/reload/world-entry handlers — always via the delayed/coalesced scheduler.

### SavedVariables

- `RecipeRegistryDB`: global guild data, sync state, options
- `RecipeRegistryCharDB`: per-character data (favorites, local scan)
- `RecipeRegistryLogDB`: debug log ring buffer

Managed by AceDB-3.0. Schema version is in `DB_DEFAULTS.global.meta.schemaVersion`.

### UI

- `UI/MainFrame.lua`: main addon frame (recipe browser, profession tabs, detail panel)
- `Tooltip.lua`: adds known crafters to item/recipe/spell/enchant tooltips
- `MinimapButton.lua`: minimap icon via LibDBIcon-1.0
- `Options.lua`: AceGUI-3.0 options panel
- `Market.lua`: TSM/Auctionator price lookup

## Test harness

Tests run as plain Lua 5.1 scripts — no external test framework. Each spec file `dofile`s the harness directly.

- `local-tests/harness/wow.lua` (`Wow`): full WoW API mock — timers, events, guild roster, comm bus, GetItemInfo, etc. `Wow.Reset()` clears state between tests. `Wow.RunDueTimers(seconds)` advances virtual time.
- `local-tests/harness/load-addon.lua` (`Loader`): loads all backend Lua files in order, runs `OnInitialize`/`OnEnable` lifecycle. `Loader.PrimeSyncReady(addon)` drives all readiness gates to `true` for sync tests.
- `local-tests/harness/comm-bus.lua` (`CommBus`): intercepts addon comms, allows simulating multi-peer scenarios.
- `local-tests/harness/test.lua` (`Test`): minimal assertion library (`Test.it`, `Test.eq`, `Test.ne`, `Test.gte`, `Test.lte`, `Test.ok`, `Test.isNil`, `Test.deepEq`, `Test.contains`).

Spec pattern:
```lua
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")
local addon, wow = Loader.Load()
Test.it("description", function() Test.eq(actual, expected) end)
```

## Branch strategy

- `develop` — the active development branch. All work happens here: code, tests, docs, tooling.
- `main` — release-only. Its tree must contain ONLY the addon runtime files (`RecipeRegistry.toc`, `Core/`, `Data/`, `Integrations/`, `Libs/`, `Sync/` without `MockSync.lua`, `UI/`) plus `README.md`, `CHANGELOG.md`, `LICENSE`, `.pkgmeta`, `.gitignore`. Never commit or edit directly on `main`.

### Release procedure (version X.Y.Z)

Never `git merge develop` into `main`: a true merge drags develop's commit history (tests, tooling, unrelated work) into main even when the final tree is clean. A release is exactly ONE squash commit:

1. On `develop`: update `CHANGELOG.md`, bump `## Version:` in `RecipeRegistry.toc`, run the full test suite, commit.
2. `git checkout main && git merge --squash develop` — resolve `CHANGELOG.md` with develop's version.
3. `git rm -rf --ignore-unmatch local-tests docs CLAUDE.md .claude .vscode .github artifacts build tools RecipeRegistry_OrdersCore Sync/MockSync.lua`
4. Verify before committing: `git status --short` must list only runtime files + `CHANGELOG.md` + `RecipeRegistry.toc`.
5. Commit as `Release X.Y.Z`, tag `vX.Y.Z`, check out `develop` again (and verify the checkout happened).
6. Commit messages are plain text — no `Co-Authored-By` or any AI-attribution trailer, anywhere in this repo.
7. Pushes are done by the maintainer (SSH key is passphrase-protected) — never attempt them.

## Active rewrite context

The `sync-rewrite` branch is mid-rewrite per `docs/sync-rewrite-roadmap.md`. Legacy modules `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` are no longer loaded. The roadmap is the canonical source of truth and must not be overwritten.

**Current active test specs** are listed in `local-tests/run-backend-tests.ps1` under `$activeAllSpecs`. Historical manifest-era specs remain in-tree but are not part of any active suite.

## WoW API constraints

The addon targets the **TBC Classic 2.5.x API** — not retail WoW. The available profession APIs are `GetTradeSkillInfo`/`GetNumTradeSkills` (for most professions) and `GetCraftInfo`/`GetNumCrafts` (for Enchanting). Lua 5.1 only — no `goto`, no bitwise operators, no integer division `//`.
