# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Recipe Registry is a World of Warcraft: The Burning Crusade Classic Anniversary addon (Interface `20505`, Lua 5.1). It builds a shared guild crafting directory by scanning local professions and syncing them with guildmates who use the addon.

## Commands

> On `feat/forever` only the Forever commands below work. The TBC addon and its
> `local-tests/` are not in this branch's tree (see **Branch strategy**); the
> TBC commands are kept here because this file merges back, and they run on
> `develop`.

**Run the Forever specs:**
```powershell
.\RecipeRegistry_Forever\local-tests\run-tests.ps1
```

**Syntax check the Forever tree:**
```powershell
.\RecipeRegistry_Forever\local-tests\run-syntax.ps1
```

**Rebuild the Forever recipe database from the local dumps:**
```powershell
.\RecipeRegistry_Forever\Tools\import-dumps.ps1
```

### On `develop` (TBC addon)

**Run all active backend tests:**
```powershell
.\RecipeRegistry\local-tests\run-backend-tests.ps1
```

**Run a single spec:**
```powershell
.\RecipeRegistry\local-tests\run-backend-tests.ps1 -Spec sync_phase34_block_pull_spec.lua
```

**Run only the sync rewrite suite:**
```powershell
.\RecipeRegistry\local-tests\run-backend-tests.ps1 -Suite sync
```

**Syntax check all Lua files (TBC tree):**
```powershell
.\RecipeRegistry\local-tests\run-syntax.ps1
```

Tests require Lua 5.1 at `C:\Program Files (x86)\Lua\5.1\lua.exe`. The runner enters the addon folder itself, so it can be called from anywhere. Every path in the harness and in the specs is relative to `RecipeRegistry/`.

Suites: `all` (active baseline), `quick` (same as all), `sync` (HELLO/SUMMARY/INDEX_DIFF/BLOCK_PULL coverage), `soak` (no active specs).

## Architecture

### Addon structure

The addon uses **AceAddon-3.0** with modules registered via `Addon:NewModule("Name")` and stored as `Addon.Name`. Load order is defined in `RecipeRegistry/RecipeRegistry.toc`.

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

- `local-tests/harness/wow.lua` (`Wow`): full WoW API mock — timers, events, guild roster, comm bus, GetItemInfo, etc. `Wow.Reset()` clears state between tests. `Wow.AdvanceTime(seconds)` moves the virtual clock; `Wow.RunDueTimers(maxRuns)` then fires whatever has come due (its argument is a run cap, not seconds, and it does not advance time by itself).
- `local-tests/harness/load-addon.lua` (`Loader`): loads all backend Lua files in order, runs `OnInitialize`/`OnEnable` lifecycle. `Loader.PrimeSyncReady(addon)` drives all readiness gates to `true` for sync tests.
- `local-tests/harness/comm-bus.lua` (`CommBus`): intercepts addon comms, allows simulating multi-peer scenarios.
- `local-tests/harness/test.lua` (`Test`): minimal assertion library (`Test.it`, `Test.eq`, `Test.ne`, `Test.gte`, `Test.lte`, `Test.truthy`, `Test.falsy`, `Test.hasKey`, `Test.noKey`, `Test.countKeys`). There is no `isNil`/`deepEq`/`contains` — use `Test.eq(value, nil)` and friends.

Spec pattern:
```lua
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")
local addon, wow = Loader.Load()
Test.it("description", function() Test.eq(actual, expected) end)
```

## Two addon trees, one repo

Since 2026-09-18 the repo carries two separate addons, and they share no Lua:

| tree | what it is |
|---|---|
| `RecipeRegistry/` | the TBC Classic addon, in production on CurseForge, with its own tests and tooling |
| `RecipeRegistry_Forever/` | the World of Warcraft: Forever addon, its own copy of all of the above |

The repo root holds only what belongs to neither: `docs/`, `.github/`, `README.md`, `LICENSE`, `CLAUDE.md`.

Why copies instead of shared files with a flavor switch: the two clients share
content, not APIs — Forever is vanilla content behind a retail-shaped API. Code
that is only correct on one of them is not inert on the other, it is a Lua
error. Forever will also keep changing while TBC is effectively frozen. The
price is accepted knowingly: a fix that matters to both is applied twice, and
applied to TBC only if it still matters there.

Rules that follow from it:

- **Never edit both trees in one sweep** because a change "looks the same". They
  are different addons; touch the one the task is about.
- **Each addon folder carries its own `.pkgmeta`**, and the packager is pointed
  at it: `release.sh -t RecipeRegistry`. That is what lets the repo keep a folder
  per game version. Do not put a `.pkgmeta` back in the repo root.
- **`package-as` is the addon's identity, not the repo folder's name.** It stays
  `RecipeRegistry` for the TBC addon whatever its folder is called, because the
  folder name in the zip is the TOC name and the SavedVariables file that holds
  every user's guild data. Renaming it would give every existing user an empty
  addon.
- The TOC filename must match `package-as`, so `RecipeRegistry/` contains
  `RecipeRegistry.toc`. To install that tree by hand, copy the folder into
  `AddOns` — it already has the right name.
- `.github/workflows/release.yml` builds one package per addon folder, from a
  matrix. A tag builds the TBC addon alone; Forever joins the default when its
  `## Interface` comes from the client instead of a formula.
- Tests and tooling belong to their tree. `local-tests/` is TBC's, and its
  harness mocks the classic APIs. Forever's gate today is
  `RecipeRegistry_Forever/local-tests/run-syntax.ps1`; it gets a harness and
  specs of its own when it has adapted code to test.
- Docs are split the same way: `docs/tbc/`, `docs/forever/`.
- The Forever dataset is a placeholder with `flavor = "forever"`. Never fill it
  with the TBC dataset: Forever changes vanilla recipes as well as adding them,
  so TBC rows would be wrong about reagents and outputs while looking
  authoritative.

## Branch strategy

- `develop` — the active development branch. All work happens here: code, tests, docs, tooling.
- `feat/forever` — the World of Warcraft: Forever adaptation, forked from `develop` for the duration of the Forever beta (2026-09-17 to 2026-10-21). Retail-shaped API work goes here, not on `develop`, because the client churns weekly and most of the API mapping is still deduction; it merges back into `develop` once the unknowns in `docs/forever/api-adaptation.md` are closed on real data. Rebase it on `develop` rather than merging `develop` into it.
- `main` — release-only. Its tree must contain ONLY the addon folders with their runtime files (each with its own `.toc`, `Core/`, `Data/`, `Integrations/`, `Libs/`, `Sync/` without `MockSync.lua`, `UI/`, plus its own `CHANGELOG.md`, `LICENSE` and `.pkgmeta`) plus `README.md`, `LICENSE`, `.gitignore` at the root. **No `CHANGELOG.md` at the root**: there is one per addon, it lives beside the `.toc` it describes, and a root one would be a third copy nobody updates. Never commit or edit directly on `main`.

**On `feat/forever` the TBC addon is not in the tree.** It was removed there on
purpose: this branch is about Forever, and carrying 250 files of an addon it
never touches only invites edits to the wrong copy. `develop` is the collector
for every line of development and keeps the TBC addon; `main` ships it.

That makes the merge back a selective one, and it has to be, because this branch
carries BOTH the folder-per-client restructure (the addon moved from the repo
root into `RecipeRegistry/`) AND the deletion of what that move produced. The
restructure belongs on `develop`. The deletion does not. Merging the branch
wholesale would replay move-then-delete and take the CurseForge addon with it.

So: bring the Forever tree, the restructure and the tooling across, then make
sure `RecipeRegistry/` is present and intact before committing the merge --
`git checkout develop -- RecipeRegistry` after a squash merge is enough, and
`git ls-files RecipeRegistry | wc -l` should read 250, not 0.

Check the changelogs in the same breath, because this merge is exactly where
they go wrong: `develop` still keeps the TBC one at the repo root, and the
restructure this branch carries moves it into `RecipeRegistry/`. After the merge
`git ls-files | grep -i changelog` must list two paths, both inside an addon
folder. Three means the old root copy survived the move and is now a stale file
nothing will ever update; one means the TBC addon came across without its own.

Flavors do not get a branch each: `main` carries them all and
`.github/workflows/release.yml` builds one zip per TOC in the tag, sending each
where its `## Interface` belongs. What a flavor does get is **its own addon
folder** — see below.

### Release procedure (version X.Y.Z)

Never `git merge develop` into `main`: a true merge drags develop's commit history (tests, tooling, unrelated work) into main even when the final tree is clean. A release is exactly ONE squash commit:

1. On `develop`: update the CHANGELOG of the addon you are releasing and bump `## Version:` in that addon's `.toc` — `RecipeRegistry/CHANGELOG.md` and `RecipeRegistry/RecipeRegistry.toc` for TBC, the `RecipeRegistry_Forever/` pair for Forever. Leave the other addon's two files alone: they are a different release. Run the full test suite, commit.
2. `git checkout main && git merge --squash develop` — resolve conflicts in the CHANGELOG **of the addon being released** with develop's version, and leave the other addon's CHANGELOG at whatever main already had.
3. `git rm -rf --ignore-unmatch docs CLAUDE.md .claude .vscode .github build RecipeRegistry/local-tests RecipeRegistry/tools RecipeRegistry/artifacts RecipeRegistry/Sync/MockSync.lua RecipeRegistry_Forever/local-tests RecipeRegistry_Forever/Tools RecipeRegistry_Forever/Sync/MockSync.lua`
4. Verify before committing: `git status --short` must list only runtime files under the addon folders, plus the `CHANGELOG.md` and `.toc` of the addon being released.
5. Commit as `Release X.Y.Z`, tag `vX.Y.Z`, check out `develop` again (and verify the checkout happened).
6. Commit messages are plain text — no `Co-Authored-By` or any AI-attribution trailer, anywhere in this repo.
7. Pushes are done by the maintainer (SSH key is passphrase-protected) — never attempt them.

**One changelog per addon, none at the root.** This is easy to get wrong because
of where the repo came from: before the folder-per-client restructure there was
a single `CHANGELOG.md` at the root, and that restructure moves it into
`RecipeRegistry/`. If a merge ever leaves the old root copy behind, the tree has
three changelogs and the root one goes stale without anyone noticing, because
nothing reads it and nothing fails.

The check is one line, and it is worth running on `develop` and on `main` after
any merge that touches the layout:

```powershell
git ls-files | Select-String -Pattern 'CHANGELOG'
```

It must list exactly two paths, both inside an addon folder. A root
`CHANGELOG.md` in that output is the bug.

### Releasing the Forever addon

It has its own folder, its own `.pkgmeta` and its own `CHANGELOG.md`, so steps 1
to 5 are the same against `RecipeRegistry_Forever/`. Three things are not.

**The build channel.** `## X-Build-Channel: dev` puts the addon on the `RRDEV`
comm prefix, and dev clients do not sync with release clients. That is right for
a beta being handed around; it is wrong the moment it reaches CurseForge, where
everyone who installs it would be talking on a prefix no released build uses.
Flip it to `release` in the same commit as the version bump, or decide on
purpose to ship a dev build and say so in the changelog.

**Which addons a tag builds.** The workflow's default is the TBC addon alone.
Forever is built by dispatching the workflow with `addons:
RecipeRegistry_Forever`, which is also how it gets a version number of its own:
the packager takes the version from the tag, so one tag driving both addons
would give Forever whatever number TBC happens to be on. Two addons, two
histories -- so two tags, and a dispatch per addon.

**Two projects, not multi-TOC, and the reason is not taste.** CurseForge lets one
project serve several flavors through Multi-TOC, and it is the model it
recommends. It does not fit here. Multi-TOC requires every TOC to sit in ONE
addon folder and be named after it (`Addon.toc`, `Addon_Camelot.toc`), and our
two trees hold different files at the same paths -- `Core/Core.lua` exists in
both with different content -- so one folder cannot hold them without moving one
tree into a subfolder and shipping both codebases to everyone. The version
settles it anyway: one project, one packager run, one version number, and these
two addons are meant to have separate histories.

So the TOC stays `RecipeRegistry_Forever.toc` in `RecipeRegistry_Forever/`,
matching `package-as`. Do NOT rename it to `RecipeRegistry_Camelot.toc`: the
`_Camelot` suffix is the Multi-TOC flavor marker, and it only means anything
inside a folder named `RecipeRegistry`. Here it would just break `package-as`.

**The flavor is detected, not declared.** The packager maps interface `16???` to
the `forever` game type (`camelot` is its alias), so `## Interface: 16001` is
enough and `-g forever` is not needed. CurseForge has the flavor --
`gameVersionTypeId=88568` -- and addons already ship on it. Checked 2026-09-20.

One caveat with a short fuse: Forever support landed in packager **v2.6.0, on
2026-09-18**. The workflow uses `BigWigsMods/packager@v2`, the moving major tag,
which already carries it. Pinning an exact older version would silently lose the
flavor, so if anyone pins, pin v2.6.1 or later.

**Where it can go.** The workflow reads the CurseForge project id from the
`CF_PROJECT_ID_FOREVER` repository variable. Without it the build still runs and
stops at GitHub with a warning rather than failing, which is the useful
behaviour while the project page does not exist yet.

## Active rewrite context

The `sync-rewrite` branch is mid-rewrite per `docs/sync-rewrite-roadmap.md`. Legacy modules `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` are no longer loaded. The roadmap is the canonical source of truth and must not be overwritten.

**Current active test specs** are listed in `RecipeRegistry/local-tests/run-backend-tests.ps1` under `$activeAllSpecs`. Historical manifest-era specs remain in-tree but are not part of any active suite.

## WoW API constraints

The addon targets the **TBC Classic 2.5.x API** — not retail WoW. The available profession APIs are `GetTradeSkillInfo`/`GetNumTradeSkills` (for most professions) and `GetCraftInfo`/`GetNumCrafts` (for Enchanting). Lua 5.1 only — no `goto`, no bitwise operators, no integer division `//`.
