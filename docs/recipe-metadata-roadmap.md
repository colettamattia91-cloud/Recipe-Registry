# Recipe Metadata Library, UI Prefilters & AtlasLoot Removal — Roadmap

Branch: TBD (suggested `feature/recipe-metadata-library`, forked from `develop` after the craft-orders branch lands).
Source requirement: `recipe-ui-prefilters-internal-metadata-scraper-roadmap-superset-audited.md` (in Mattia's Downloads). Esta roadmap è la sua *traduzione operativa*: stessa intent, ridondanze rimosse, scelte architetturali allineate al modello plugin già usato per Craft Orders.

Owner of this doc: the implementation plan for the feature. The source requirement document remains the authoritative spec; this doc is the working plan grounded in the actual codebase and in the modular distribution pattern of RecipeRegistry + RecipeRegistry_Orders.

This roadmap is the working plan. It must not be overwritten without a follow-up commit explaining what changed and why.

**Distribution model (decided 2026-05-23):** the generated metadata library ships as a **separate addon** (`RecipeRegistry_Metadata`) inside the **same git repo** and the **same CurseForge project** as Recipe Registry and Craft Orders. Same AtlasLoot-style `move-folders` packaging pattern documented in [`craft-orders-roadmap.md`](craft-orders-roadmap.md) §3.5. The Python generator stays out of the runtime entirely, in `tools/recipe-metadata/`.

Recipe Registry depends on the metadata addon as **optional** (`## OptionalDeps`): if `RecipeRegistry_Metadata` is not installed, RR falls back to its current behavior (no expansion filter, conservative remote-BoP behavior, AtlasLoot-as-resolver where still wired). With the plugin installed, RR's UI gains expansion filters, BoP filters, owner index, and the AtlasLoot resolver path is fully replaceable.

---

## 1. Scope and non-negotiable constraints

### 1.1 Goals

- Reduce UI runtime workload by filtering recipes **before** row construction.
- Add global and per-profession Vanilla/TBC visibility toggles.
- Hide remote BoP output recipes by default; always show current-player ones.
- Handle outputless self-only recipes (ring enchants, etc.) via explicit metadata.
- Replace AtlasLoot as the resolver for recipe → spell → item → reagent → category.
- Generate Recipe Registry-owned metadata at build time, deterministically, offline.

### 1.2 Hard architectural rule — filters are UI-only

The new filter layer applies **only** to the UI/catalog projection. It must never affect:

- guild sync, merge, block fingerprints, global fingerprints, block indexes;
- wire protocol, saved peer recipe data, recipe ownership data;
- stale-node handling, pruning, SavedVariables with synced recipe knowledge.

Changing a UI filter option must **not** require a resync. Recipes already received from peers must become visible again immediately when filters change.

The UI must build a *filtered runtime projection* from the complete local/synced dataset. Hidden recipes must not enter the runtime list/cache for the relevant view (this is **not** a hide-after-render feature):

- no row construction;
- no sort step;
- no virtualized binding;
- no icon/material enrichment;
- no search hits;
- no detail selection via normal UI paths.

### 1.3 Repo / runtime constraints

- WoW Interface `20505` (TBC Classic Anniversary). Lua 5.1.
- AceAddon-3.0 module pattern. New modules registered via `Addon:NewModule(...)`.
- Wire prefix split (dev vs release) per [`Core/BuildInfo.lua`](../Core/BuildInfo.lua) applies to the metadata addon too — dev metadata and release metadata can coexist locally without conflict.
- No network calls from runtime. The generator is build-time only.
- Lua 5.1 only: no `goto`, no bitwise operators, no `//`.

### 1.4 Supported expansion model

- `vanilla` and `tbc` are the only supported expansion values for v1.
- No user-facing `unknown` expansion toggle. Unresolved-expansion records are a *remediation task*, not a third user category.
- Future expansion records (WotLK and beyond) must be filtered out of the runtime TBC metadata, or reported as out-of-scope by the generator.

---

## 2. Architecture review — what already exists

### 2.1 Recipe + material data already in RR

- [`Data/DataCatalog.lua`](../Data/DataCatalog.lua) → `Data:GetRecipeDisplayInfo(recipeKey)` returns the per-recipe info including `reagents`, `createdItemID`, `numCreated`, `professionID/Name`, `directEnchant`. **This currently mixes AtlasLoot-derived data with scan-derived data**, which is exactly what the new metadata layer must replace.
- `Data:GetRecipeCrafters(recipeKey)` and `Data:GetCraftersForItem(itemID)` are independent of AtlasLoot — they stay as-is.
- [`Data/DataAtlasLoot.lua`](../Data/DataAtlasLoot.lua) is the integration to remove from the new UI/catalog path.

### 2.2 What the filter layer must consume

- `Data:GetPlayerKey()` / `Data:IsMemberOnline(memberKey)` for crafter context.
- A **new** lightweight owner-summary index (see §6.3) so filtering does not call expensive detail builders.
- A **new** `RecipeMetadata` public API exposed by the metadata addon (see §5).

### 2.3 UI conventions

- Main frame hand-built in [`UI/MainFrame.lua`](../UI/MainFrame.lua) with `CreateFrame`.
- Recipe list is virtualized. The filter layer must hook **between** `BuildRecipeListAsync` source and `_FinalizeRecipeList`, before any binding.
- Async flow: any callback into `_FinalizeRecipeList` must validate it is not stale (see §10.1).

### 2.4 Test harness

- Plain Lua 5.1 specs under [`local-tests/spec/`](../local-tests/spec/) using the harness in [`local-tests/harness/`](../local-tests/harness/).
- Harness must be extended with `Loader.LoadMetadata` (analogous to `Loader.LoadOrders`) so metadata addon tests can run against a stubbed `_G.RecipeRegistry`.

---

## 3. Module distribution model

### 3.1 Plugin addon `RecipeRegistry_Metadata`

Sibling of `RecipeRegistry` and `RecipeRegistry_Orders` in the same repo, packaged via the same `.pkgmeta` `move-folders` mechanism. The plugin owns:

- The generated Lua metadata table.
- Manual overrides table.
- The public `RecipeMetadata` API consumed by RR.

```
RecipeRegistry_Metadata/
  RecipeRegistry_Metadata.toc       -- ## Dependencies: RecipeRegistry (hard)
  Libs/embeds.xml                   -- AceAddon-3.0, AceConsole-3.0, LibStub
  Libs/...
  Core/RecipeMetadataAddon.lua      -- AceAddon skeleton, slash /rrmeta
  Data/RecipeMetadata_Generated.lua -- generated; do not hand-edit
  Data/RecipeMetadata_Overrides.lua -- small, manually maintained
  Data/RecipeMetadata.lua           -- public API; merges generated + overrides
  Diagnostics/RecipeMetadataDiagnostics.lua
```

### 3.2 RR side

`RecipeRegistry_Metadata` is declared as `## OptionalDeps: RecipeRegistry_Metadata` in [`RecipeRegistry.toc`](../RecipeRegistry.toc). At runtime:

- RR checks `if _G.RecipeRegistry_Metadata and _G.RecipeRegistry_Metadata.RecipeMetadata then` to detect the plugin.
- If absent: RR uses its current AtlasLoot-or-scan path, filter UI options are hidden, predicate accepts all recipes. No regression for existing users.
- If present: RR exposes the filter options panel, wires the predicate, and consults `RecipeMetadata` for all the fields previously read from AtlasLoot.

```
RecipeRegistry/
  Data/RecipeUiFilters.lua          -- NEW: predicate + cache key + invalidation
  Data/RecipeOwnershipIndex.lua     -- NEW: lightweight owner-summary index
  Data/DataCatalog.lua              -- MODIFIED: accept filter context, drop AtlasLoot from resolver
  UI/MainFrame.lua                  -- MODIFIED: pass filter context, async stale guard
  UI/Options.lua                    -- MODIFIED: filter options panel (only when plugin present)
  Core.lua                          -- MODIFIED: profile defaults `recipePrefilters`
```

The filter logic (`RecipeUiFilters`, `RecipeOwnershipIndex`, options UI) stays in RR because it's intrinsic to RR's UX. The plugin is *pure data + lookup*.

### 3.3 SavedVariables

The plugin **never** modifies `RecipeRegistryDB` or `RecipeRegistryCharDB`. It does not need its own SavedVariables at all (metadata is static, baked at build time). If diagnostics counters are needed they live in a memory-only table, not persisted.

User filter options live in `RecipeRegistryDB.profile.recipePrefilters` (in RR), not in the plugin. This keeps profile portability identical with or without the plugin installed.

### 3.4 Slash commands

- `/rr filters` — current global/profession settings (in RR; works even without plugin, shows "plugin not installed" then).
- `/rr filters unresolved` — list unresolved metadata records by severity (in RR; delegates to plugin if present).
- `/rr filters explain <recipeKey>` — pass/fail trace for a single recipe (in RR; delegates to plugin if present).
- `/rrmeta diag` — plugin diagnostics dump (in plugin; metadata version, record counts, override counts).
- `/rrmeta version` — plugin metadata version string.

### 3.5 Packaging

Update [`.pkgmeta`](../.pkgmeta):

```yaml
package-as: RecipeRegistry
manual-changelog:
  filename: CHANGELOG.md
  markup-type: markdown
ignore:
  - .claude
  - .gitignore
  - CLAUDE.md
  - Sync/MockSync.lua
  - docs
  - local-tests
  - scripts
  - tools                                          # NEW: Python generator excluded from CF ZIP
move-folders:
  RecipeRegistry/RecipeRegistry_Orders: RecipeRegistry_Orders
  RecipeRegistry/RecipeRegistry_Metadata: RecipeRegistry_Metadata   # NEW
```

`scripts/dev-link.ps1` extends to symlink three addon folders into WoW.

### 3.6 Versioning

- `RecipeRegistry_Metadata.toc` `## Version` is the *plugin version* (internal). Same scheme as `RecipeRegistry_Orders.toc`.
- A separate constant **`metadataVersion`** lives inside the generated Lua and identifies the *data snapshot*. Distinct from the plugin code version. See §7.2.

---

## 4. Public API contract (RR ↔ RecipeRegistry_Metadata)

The plugin exposes a stable surface on the global `RecipeRegistry_Metadata` table. RR consumes only the methods listed below. Anything else is internal and can change without notice.

### 4.1 Plugin → RR (consumed by RR)

```lua
-- Identity
RecipeRegistry_Metadata.ADDON_VERSION                       -- plugin code version
RecipeRegistry_Metadata.RecipeMetadata.metadataVersion      -- data snapshot version
RecipeRegistry_Metadata.RecipeMetadata.schemaVersion        -- runtime schema version
RecipeRegistry_Metadata.RecipeMetadata.flavor               -- "tbc"

-- Per-recipe lookup
RecipeMetadata:GetRecipeInfo(recipeKey)         -- normalized record or nil
RecipeMetadata:NormalizeRecipeKey(recipeKey)    -- { spellId, recipeItemId, createdItemId, source }
RecipeMetadata:GetRecipeExpansion(recipeKey, info)         -- "vanilla" | "tbc" | nil
RecipeMetadata:GetProfession(recipeKey, info)              -- canonical key or nil
RecipeMetadata:GetCategory(recipeKey, info)                -- { category, subcategory, sortOrder } or nil
RecipeMetadata:GetCreatedItemId(recipeKey, info)           -- int or nil
RecipeMetadata:GetRecipeItemId(recipeKey, info)            -- int or nil
RecipeMetadata:GetReagents(recipeKey, info)                -- { { itemId, count }, ... } or nil
RecipeMetadata:IsOutputlessSelfOnly(recipeKey, info)       -- bool
RecipeMetadata:IsBopOutput(recipeKey, info)                -- bool | nil ("nil" = unknown, conservative)
RecipeMetadata:GetMetadataResolutionStatus(recipeKey, info) -- "resolved" | "unresolved" | "ambiguous"

-- Diagnostics
RecipeMetadata:GetUnresolvedRecords(severity)              -- array, severity filter optional
RecipeMetadata:GetRecordCounts()                           -- { recipes, vanilla, tbc, unresolved, ... }
```

### 4.2 RR → Plugin (consumed by plugin)

The plugin needs **nothing** from RR beyond the load-order guarantee. It is a pure data addon. This is intentional — keeps the contract one-way and minimizes coupling.

### 4.3 Public API documentation

The contract is documented in [`docs/recipe-registry-public-api.md`](recipe-registry-public-api.md), the same doc that hosts the RR_Orders public surface. Add a new `RecipeMetadata` section.

---

## 5. Data contract (normalized record)

### 5.1 Generator-side normalized record

Defined once in Python, used by all pipeline stages:

```python
@dataclass(frozen=True)
class RecipeRecord:
    spell_id: int                        # primary key — required
    profession_key: str                  # canonical, lowercase, ASCII — required
    expansion: str                       # "vanilla" | "tbc" — required
    recipe_item_id: int | None           # item that teaches the spell, if exists
    created_item_id: int | None          # output item, if exists
    reagents: tuple[ReagentRecord, ...]  # may be empty for outputless
    category_key: str | None             # canonical; falls back to "misc" if unresolved
    subcategory_key: str | None
    sort_order: int                      # required; defaults to 999 for fallback bucket
    required_skill: int | None           # diagnostic; not used for classification
    is_outputless_self_only: bool = False
    bop_output: bool | None = None       # None = unknown, conservative; True/False from static source
    source_notes: tuple[str, ...] = ()   # report-only, never emitted to Lua

@dataclass(frozen=True)
class ReagentRecord:
    item_id: int
    quantity: int
```

### 5.2 Runtime Lua emitted by generator

Compact, deterministic, ordered. Numeric keys preferred. No source notes, no provenance, no comments beyond the schema header.

```lua
RecipeRegistryRecipeMetadata = {
    schemaVersion = 1,
    metadataVersion = "2026.05.23.1",
    flavor = "tbc",

    recipesBySpellId = {
        [28596] = {
            profession = "alchemy",
            expansion = "tbc",
            recipeItemId = 22900,
            createdItemId = 22845,
            category = "flasks",
            subcategory = "guardian_elixirs",
            sortOrder = 120,
            requiredSkill = 300,
            bopOutput = false,
            reagents = {
                { itemId = 22790, count = 7 },
                { itemId = 22791, count = 3 },
            },
        },
    },

    recipeItemToSpellId = { [22900] = 28596 },
    createdItemToSpellIds = { [22845] = { 28596 } },

    categoriesByProfession = {
        engineering = {
            { key = "devices",    label = "Devices",       order = 10 },
            { key = "goggles",    label = "Goggles",       order = 20 },
            { key = "explosives", label = "Explosives",    order = 30 },
            { key = "ammo",       label = "Ammo",          order = 40 },
            { key = "misc",       label = "Miscellaneous", order = 999 },
        },
    },

    subcategoriesByProfession = {
        engineering = {
            devices = {
                { key = "combat",  label = "Combat",  order = 10 },
                { key = "utility", label = "Utility", order = 20 },
            },
        },
    },
}
```

### 5.3 Overrides table

Small, hand-maintained. Generator merges before emitting `RecipeMetadata_Generated.lua`, but a runtime-side `RecipeMetadata_Overrides.lua` is also supported for emergencies that can't wait for a regeneration:

```lua
RecipeRegistryRecipeMetadataOverrides = {
    expansionBySpellId       = { },  -- [spellId] = "vanilla" | "tbc"
    createdItemBySpellId     = { },  -- [spellId] = itemId
    recipeItemBySpellId      = { },  -- [spellId] = itemId
    categoryBySpellId        = { },  -- [spellId] = { category, subcategory, sortOrder }
    selfOnlyOutputlessBySpellId = { },
    bopOutputBySpellId       = { },  -- [spellId] = true | false
    bindTypeByCreatedItemId  = { },  -- [itemId] = bindType
}
```

Runtime override applies on top of generated. Generator-time override (`tools/recipe-metadata/remediation/manual_overrides.yaml`) is baked into the generated Lua. Runtime overrides exist only as an emergency hatch; for normal corrections, edit the YAML and regenerate.

### 5.4 Recipe key normalization

`RecipeMetadata:NormalizeRecipeKey(recipeKey)` returns:

```lua
{
    recipeKey    = recipeKey,
    spellId      = ...,
    recipeItemId = ...,
    createdItemId = ...,
    source       = "spell" | "recipeItem" | "createdItem" | "invalidItem" | "unknown",
}
```

Resolution priority: `spellId` > `recipeItemId` > `createdItemId` > diagnostic-only fallback. Ambiguous `createdItem → spellIds` mappings (multiple recipes producing the same item) **never** pick an arbitrary winner — the predicate must keep the recipe visible conservatively and the ambiguity is reported by `GetMetadataResolutionStatus`.

### 5.5 Required vs conditionally required fields

| Field            | Always required | Conditionally required                              |
|------------------|-----------------|------------------------------------------------------|
| `spellId`        | yes             | —                                                    |
| `profession`     | yes             | —                                                    |
| `expansion`      | yes             | —                                                    |
| `category`       | yes (or `misc`) | —                                                    |
| `sortOrder`      | yes             | —                                                    |
| `createdItemId`  | no              | yes for normal craft outputs                         |
| `recipeItemId`   | no              | yes when a recipe item exists in source data         |
| `reagents`       | no              | yes if UI detail/cost depends on material data       |
| `selfOnlyOutputless` | no          | yes for known outputless self-only spells            |
| `bopOutput`      | no              | informational; static-source preferred when available|

A record missing a *conditionally required* field is reported as `unresolved` of the corresponding severity (§9), not silently dropped.

---

## 6. Filter requirements

### 6.1 Filter options (profile defaults)

```lua
recipePrefilters = {
    showRemoteBopOutputRecipes = false,

    expansionDefaults = {
        vanilla = true,
        tbc     = true,
    },

    professionExpansionOverrides = {
        -- engineering = { inherit = false, vanilla = false, tbc = true }
    },
}
```

### 6.2 Filter predicate

```lua
RecipeUiFilters:RecipePasses(recipeKey, recipeInfo, filterContext)
    -> (passed: bool, reason: string)
```

Evaluation order (each step short-circuits on reject):

1. Resolve normalized metadata (`RecipeMetadata:GetRecipeInfo`).
2. Resolve recipe profession from metadata.
3. Resolve effective Vanilla/TBC visibility for that profession (per-profession override > global default).
4. If recipe expansion is disabled → `hidden-expansion`.
5. Resolve self-only / BoP status.
6. If recipe is BoP/self-only and known by current player → `visible-current-player`.
7. If recipe is BoP/self-only and remote-only and `showRemoteBopOutputRecipes = false` → `hidden-remote-bop` (or `hidden-outputless-self-only`).
8. Unresolved metadata → `visible-unresolved-conservative` with diagnostic log.
9. Otherwise → `visible-normal`.

Reason codes are part of the contract — diagnostics + tests rely on them.

### 6.3 Owner summary index

Required because the predicate runs once per candidate row and cannot afford full detail builders.

```lua
RecipeOwnershipIndex = {
    byRecipeKey = {
        [recipeKey] = {
            knownByCurrentPlayer = true,
            hasRemoteOwners      = true,
            remoteOwnerCount     = 3,
        },
    },
}
```

Maintained by RR's `Data` layer. Updated when local scan completes and when peers add/remove recipes via sync. Helper:

```lua
Data:IsRecipeKnownByCurrentPlayer(recipeKey)  -- O(1) index lookup
```

For v1, "current player" means **only the active character** — no alt aggregation (see §6.5 below).

### 6.4 Empty filter state

If the user disables both Vanilla and TBC (globally or per-profession), the projection is legitimately empty. The UI shows an empty state ("No recipes visible with current filters"). No auto-reset, no sync trigger, no error. The options panel may show an inline warning but must not silently override the user's choice.

### 6.5 Current-player ownership scope

V1 treats "self" as the active character only. Reasons:

- BoP items cannot be traded to alts.
- RR has no reliable account-level alt ownership system.
- Guild roster cannot safely infer alt linkage.
- Alt inference would cause false positives in the remote-BoP filter.

### 6.6 Visibility vs requestability

Recipe visibility and crafter requestability are **separate concerns**:

- A recipe can be visible because the current player knows it, while remote crafters for that same recipe are not requestable (BoP / self-only outputs).
- In the detail panel, remote crafters for non-requestable BoP/self-only recipes must not appear as normal request targets. Either hide them or mark them clearly as `Not requestable`.
- Quick-request actions must not be offered for remote crafters who cannot deliver to the local player.

### 6.7 Global search and Favorites

Both evaluate filters **per-recipe using that recipe's own profession**, never the currently selected profession.

Example: global `vanilla = true`, Engineering override `vanilla = false`, Alchemy inherits global. A global search for "Vanilla" must show Vanilla Alchemy and hide Vanilla Engineering.

For Favorites:

- Hidden favorites do not appear in the visible Favorites view.
- Hidden favorites are **never** removed from saved favorites.
- When filters change, favorites reappear if they become visible again.
- No "favorites ignore filters" mode in v1.

---

## 7. Generator pipeline

### 7.1 Tool layout

```
tools/recipe-metadata/
  generate_recipe_metadata.py        -- CLI entry point
  recipe_sources/
    __init__.py
    db2_provider.py                  -- primary: DB2 game-data snapshots
    secondary_provider.py            -- secondary: scraped/static supplements
    local_snapshot_provider.py       -- offline fixture loader
  recipe_pipeline/
    normalize.py
    classify_expansion.py
    derive_items.py
    derive_reagents.py
    derive_categories.py
    validate.py
    emit_lua.py
    emit_reports.py
  remediation/
    manual_overrides.yaml            -- hand-maintained corrections (small)
    taxonomy/                        -- RR-owned category definitions per profession
      alchemy.yaml
      blacksmithing.yaml
      ...
  fixtures/
    minimal_source_snapshot/
    expected_metadata.lua
    expected_report.json
  artifacts/                         -- gitignored; populated per run
    recipe-metadata/
      coverage.md
      unresolved.json
      source-manifest.json
      category-remediation.md
      reagent-coverage.md
  README.md
```

The generator is a **build-time tool only**. The runtime addon must not perform network calls, scraping, or remote fetching under any circumstance. The `tools/` folder is excluded from the CurseForge ZIP via `.pkgmeta` `ignore`.

### 7.2 CLI contract

```
python tools/recipe-metadata/generate_recipe_metadata.py fetch    [--flavor tbc]
python tools/recipe-metadata/generate_recipe_metadata.py generate [--flavor tbc] [--offline] [--check]
python tools/recipe-metadata/generate_recipe_metadata.py validate [--flavor tbc] [--strict]
python tools/recipe-metadata/generate_recipe_metadata.py report   [--flavor tbc]
```

| Command  | Behavior |
|----------|----------|
| `fetch`     | Refresh external source snapshots into `tools/recipe-metadata/snapshots/`. Updates `source-manifest.json`. Network access allowed. |
| `generate`  | Build the normalized record set from local snapshots and emit `RecipeRegistry_Metadata/Data/RecipeMetadata_Generated.lua`. `--offline` enforces no network. `--check` exits non-zero if the emitted file differs from the committed version (CI gate). |
| `validate`  | Run validation rules over the generated set. `--strict` fails on any release-blocking unresolved record. |
| `report`    | Emit human + machine-readable coverage reports under `artifacts/recipe-metadata/`. |

### 7.3 Source strategy

| Priority | Source | Purpose |
|----------|--------|---------|
| 1 | **wago.tools** DB2 snapshots (TBC 2.5.x build) | spell → profession → required skill, items, reagents, bind types |
| 2 | Secondary static / scraped sources | fields not available in DB2 (e.g., expansion classification helpers) |
| 3 | Local committed snapshots in `tools/recipe-metadata/snapshots/` | deterministic offline regeneration; CI source |
| 4 | Manual remediation (`manual_overrides.yaml`) | known exceptions and corrections |

The DB2 schema reference (`WoWDBDefs` by Marlamin on GitHub) is used to interpret column meanings. If wago.tools becomes unmaintained, switching providers requires only updating `recipe_sources/db2_provider.py` and the `source-manifest.json` entry — the rest of the pipeline is provider-agnostic.

Deterministic priority rules:

- Spell / profession / expansion → primary DB2 snapshots.
- Recipe item, created item → primary, secondary fallback.
- Reagents → primary, secondary fallback.
- Categories → RR taxonomy in `remediation/taxonomy/`, **never** AtlasLoot.
- BoP / static bind type → primary if available, runtime WoW item API as runtime supplement, manual override last.
- **If sources disagree, primary wins and the conflict is reported.**

The scraper must be idempotent: running it twice from the same snapshots produces byte-identical generated Lua and reports.

### 7.4 Expansion classification

- Primary derivation: first supported expansion in which the recipe spell appears, per DB2 source data.
- Required skill is **not** the primary classifier (300 is the Vanilla cap but TBC recipes can require any skill from 300 upward).
- Required skill may be used as: diagnostic cross-check, dev-time fallback, or remediation hint.
- If required skill conflicts with classified expansion, **classified expansion wins** and the conflict is reported in `coverage.md`.

### 7.5 Item resolution priority

Runtime resolution: `spellId` > `recipeItemId` > `createdItemId` > diagnostic-only fallback.

Generator-side mapping rules:

- `recipeItemId` → exactly one `spellId` (collision = error, manual remediation required).
- `createdItemId` → array of `spellIds` (one-to-many is normal).
- Never auto-select a `spellId` from a multi-candidate `createdItem` mapping. Predicate at runtime must handle ambiguity by keeping the recipe visible conservatively.

### 7.6 Category taxonomy ownership

The taxonomy is **RR-owned**, defined in `tools/recipe-metadata/remediation/taxonomy/<profession>.yaml`. Generator reads these files; AtlasLoot taxonomy is never imported. Each profession YAML declares the full category + subcategory tree with canonical keys, English labels, and sort orders. The generator validates that every emitted record references a defined `category` and (when set) `subcategory`.

Unknown / unresolved category → falls back to `misc` with `sortOrder = 999`. Logged as warning, not fatal.

### 7.7 Canonical profession keys

Lowercase ASCII identifiers, used as primary keys in SavedVariables and cache keys:

```
alchemy, blacksmithing, enchanting, engineering, jewelcrafting,
leatherworking, tailoring, cooking
```

`first_aid` and `fishing` are **deferred to a later release** (see §17 decision 5). They have no entry in the generated metadata for v1; RR treats them with conservative visible-all behavior and does not expose filter options for them.

Display labels are resolved separately (stored in `categoriesByProfession[...].label`). Localized profession names from the WoW client are **never** used as primary keys.

### 7.8 Manual remediation file

```yaml
# tools/recipe-metadata/remediation/manual_overrides.yaml
expansionBySpellId:
  12345: tbc

createdItemBySpellId:
  12345: 67890

selfOnlyOutputlessBySpellId:
  27951: true

categoryBySpellId:
  12345:
    category: devices
    subcategory: combat
    sortOrder: 120

bopOutputBySpellId:
  12345: true
```

Each entry should include a short comment with the reason. The generator merges this file before emitting Lua. The generator **never** silently overwrites this file.

### 7.9 Source snapshot policy

- Commit *minimal normalized* snapshots required for reproducible generation.
- Do not commit huge raw dumps.
- Commit `source-manifest.json` listing each source's name, version, and hash.
- The committed `RecipeMetadata_Generated.lua` must be reproducible from the committed generator inputs.

Generated `RecipeMetadata_Generated.lua` is committed; CI's `--check` verifies it matches a fresh `generate --offline` run.

### 7.10 Update workflow

```
1. python tools/recipe-metadata/generate_recipe_metadata.py fetch --flavor tbc
2. python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc
3. Review artifacts/recipe-metadata/{coverage.md, unresolved.json}
4. Edit tools/recipe-metadata/remediation/manual_overrides.yaml if needed
5. python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc
6. python tools/recipe-metadata/generate_recipe_metadata.py validate --flavor tbc --strict
7. Review git diff of RecipeRegistry_Metadata/Data/RecipeMetadata_Generated.lua
8. .\local-tests\run-backend-tests.ps1  (must be green)
9. Manual UI smoke test in WoW (with and without AtlasLoot installed)
10. Commit generated Lua + remediation changes + relevant reports if useful
```

Document this in `tools/recipe-metadata/README.md`.

### 7.11 Metadata versioning

`metadataVersion` follows a **datestamp + counter** scheme: `YYYY.MM.DD.N` where `N` increments for multiple regenerations on the same day. Examples: `2026.05.23.1`, `2026.05.23.2`, `2026.06.01.1`.

Increment `metadataVersion` when:

- Generated metadata changes (any record diff).
- Schema changes (then also bump `schemaVersion`).
- Generator semantics change.
- Category taxonomy changes.
- Remediation overrides change in a way that affects runtime data.

`metadataVersion` is part of the UI projection cache key (see §10.3) so changing it invalidates all projections deterministically.

---

## 8. AtlasLoot removal policy

### 8.1 Inventory phase

Before removing any AtlasLoot resolver call, produce `docs/atlasloot-removal-inventory.md` with a row per call-site:

| File | Function | Current AtlasLoot usage | Runtime path | Replacement source | Migration action | Test coverage | Status |
|------|----------|--------------------------|--------------|---------------------|------------------|---------------|--------|

Every call-site must end up classified as:

- **removed** — call deleted, no replacement needed.
- **replaced by generated metadata** — call rewritten to consult `RecipeMetadata`.
- **replaced by WoW API** — call rewritten to use a runtime WoW API directly.
- **legacy-only** — moved behind an explicitly named legacy/debug path, not used by the new projection.
- **intentionally kept** — for a documented non-filter feature; must be called out in the inventory.

### 8.2 Exit criteria for removing AtlasLoot from `OptionalDeps`

All of the following must hold before dropping `AtlasLootClassic` / `AtlasLoot` from RR's `OptionalDeps`:

- No runtime call-site is required for list / detail / category / material / cost / search / favorites in the new projection path.
- UI works identically with AtlasLoot installed and absent.
- All replacement metadata has tests covering the replaced behavior.
- Cost estimate still works using internal reagents for covered recipes.
- Category/subcategory UI uses internal taxonomy only.
- Diagnostics confirm no AtlasLoot resolver calls during normal UI rendering.

If any of these fail, AtlasLoot stays as an optional dep but is excluded from the new projection path.

### 8.3 What AtlasLoot must never determine after removal

- Recipe visibility
- Expansion classification
- Recipe item or created item mapping
- Reagents / materials for the new UI path
- Profession category or subcategory
- Outputless / self-only status
- Whether a recipe enters the UI runtime projection

### 8.4 Codex guardrails

Codex must not solve missing metadata by reintroducing AtlasLoot fallbacks into UI code. If metadata is missing, the correct fix is: add diagnostics, generator coverage, fixtures, or manual remediation — never runtime guesses scattered through UI code.

---

## 9. Unresolved metadata severity

Unresolved metadata is a **remediation task**, never a user-facing category.

| Class                              | Severity              | Behavior                                  |
|------------------------------------|-----------------------|-------------------------------------------|
| Unresolved expansion               | release-blocking      | strict validation fails                   |
| Unresolved profession              | release-blocking      | strict validation fails                   |
| Unresolved created item (normal)   | error                 | strict validation fails                   |
| Unresolved created item (outputless / enchant) | warning   | report, recipe stays visible              |
| Unresolved recipe item             | warning               | report, recipe stays visible              |
| Unresolved reagents (when UI uses) | error                 | strict validation fails; UI shows pending |
| Unresolved category                | warning               | falls back to `misc`                      |
| Ambiguous created item mapping     | warning               | report, recipe stays visible (conservative)|
| Missing bind type                  | warning               | runtime API fallback acceptable           |
| Out-of-scope expansion             | info                  | ignored / reported, never emitted         |

V1 unresolved display policy:

- Conservative display: show unresolved recipes to avoid false negatives.
- Log + report for remediation.
- **Never** classify as Vanilla or TBC until resolved.
- **Never** expose an `unknown` user option.

Strict release mode (`validate --strict`) fails the build if release-blocking unresolved records remain.

---

## 10. UI integration

### 10.1 Async stale callback protection

`BuildRecipeListAsync` callbacks must capture the generation and filter context at start time:

```lua
context.filterGeneration       -- bumped by RecipeUiFilters on option change
context.projectionGeneration   -- bumped by Data layer on ownership/scan change
context.metadataVersion        -- copied from RecipeMetadata at start
```

`_FinalizeRecipeList` must reject the callback result if any of: selected profession, search text, category, sort mode, filter options, metadata version, or projection generation changed between start and finish. Stale callbacks must not update `currentRecipeRows`, selection, or detail.

### 10.2 BoP item cache policy

Order of preference for BoP detection:

1. Static `bopOutput` from generated metadata (preferred).
2. Manual `bopOutputBySpellId` override.
3. Runtime WoW item API confirmation (`GetItemInfo`).
4. Conservative pending behavior if unresolved.

Rules:

- If static metadata identifies the output as BoP, apply the filter immediately. Do not wait for item cache.
- If item data is missing at projection time, mark item metadata as **pending**, register for `GET_ITEM_INFO_RECEIVED`, rebuild only affected profession projections when info arrives. Do not full-rebuild.
- Map item-info refresh events to affected created item IDs → affected recipe keys → affected profession projections. Rebuild scoped, not global.
- Rate-limit / dedupe repeated missing-item refreshes to avoid projection rebuild loops.

### 10.3 Cache keys

Cache key includes:

- canonical profession key
- search mode (`local`, `global`, `favorites`, ...)
- search text
- sort mode
- category, subcategory
- effective Vanilla visibility for the profession
- effective TBC visibility for the profession
- remote BoP visibility (global)
- `metadataVersion`
- `filterGeneration`

Cache key must **not** include AtlasLoot availability, localized profession labels, unrelated profession overrides, or sync fingerprint generation (unless underlying ownership data changed).

### 10.4 Invalidation rules

- Per-profession override change → invalidate that profession's projection (+ global search + favorites if their result set could include it).
- Global expansion default change → invalidate all UI projections.
- Remote BoP option change → invalidate all UI projections.
- `metadataVersion` change → invalidate all UI projections.
- Item cache update → invalidate only affected profession projections when determinable.
- Sync data change → invalidate affected recipe/profession projections, not filter configuration.

### 10.5 Options UI

- Checkbox: `Show BoP output recipes known only by other guild members`.
- Global expansion: `Show Vanilla recipes`, `Show TBC recipes`.
- Per-profession: `Use global defaults` toggle + custom `Vanilla` and `TBC` checkboxes.
- The panel must visually distinguish *inherited* from *custom* configuration.
- Empty-state warning if the user disables all visibility, but **never** silently override the user's choice.

Option changes must only update profile settings, invalidate UI projections, and refresh the current UI. Never touch sync state, fingerprints, block indexes.

### 10.6 SavedVariables compatibility

Profile migration is non-destructive:

- Missing `recipePrefilters` → create defaults.
- Missing `expansionDefaults` → create defaults.
- Profession override missing `inherit` → treat as inherited unless explicit toggles exist.
- Unknown profession keys → ignore safely + diagnostic.
- Missing expansion keys → default to global or product default.
- Migration must **never** modify synced recipe data.

### 10.7 TOC load order

```
RecipeRegistry_Metadata/RecipeRegistry_Metadata.toc loads first (declared as OptionalDep)
  Data/RecipeMetadata_Generated.lua   -- raw table
  Data/RecipeMetadata_Overrides.lua   -- runtime override table
  Data/RecipeMetadata.lua             -- public API; merges generated + overrides

RecipeRegistry/RecipeRegistry.toc:
  Core.lua                            -- profile defaults
  Data/Data.lua
  Data/DataCatalog.lua
  Data/RecipeOwnershipIndex.lua       -- NEW
  Data/RecipeUiFilters.lua            -- NEW; consults _G.RecipeRegistry_Metadata if present
  UI/MainFrame.lua                    -- consumes filter predicate
  UI/Options.lua                      -- adds filter options panel
```

WoW guarantees `OptionalDeps` load before the dependent addon's first file when both are enabled. RR may safely check `_G.RecipeRegistry_Metadata.RecipeMetadata` in its `OnEnable`.

---

## 11. Phase plan

Each phase produces a reviewable artifact before the next starts. The order is designed so RR addon code and Python generator can progress *in parallel* after Phase 0.

### Phase 0 — Data contract + scaffolds

**Goal:** lock the shape of the data and produce the empty containers on both sides. No real metadata yet.

Work items:

- Branch `feature/recipe-metadata-library` from `develop` (after craft-orders branch lands).
- Update `.pkgmeta` `move-folders` to include `RecipeRegistry_Metadata`.
- Scaffold `RecipeRegistry_Metadata/`:
  - `RecipeRegistry_Metadata.toc` with `## Dependencies: RecipeRegistry`.
  - `Libs/embeds.xml` with AceAddon, AceConsole, LibStub.
  - `Core/RecipeMetadataAddon.lua` with a `Hello world` `OnInitialize`.
- Scaffold `tools/recipe-metadata/`:
  - Python package layout per §7.1.
  - `RecipeRecord` + `ReagentRecord` dataclasses (frozen).
  - Stub CLI with `fetch / generate / validate / report` subcommands.
  - `generate` emits a hand-coded sample of 10-20 recipes covering: 1 Vanilla Alchemy, 1 TBC Alchemy, 1 Vanilla Engineering, 1 TBC Engineering, 1 ring enchant (outputless self-only), 1 BoP-output craft, 1 ambiguous created-item case.
  - Sample emitted to `RecipeRegistry_Metadata/Data/RecipeMetadata_Generated.lua`.
- Add `Loader.LoadMetadata(opts)` to the test harness (analogous to `Loader.LoadOrders`).
- Document the public API in `docs/recipe-registry-public-api.md` under a new `RecipeMetadata` section.

**Exit criteria:**

- `.\local-tests\run-backend-tests.ps1` is green.
- The plugin loads in-game (`/rrmeta diag` prints the sample record count).
- Packaged ZIP (manual BigWigs Packager run) contains all three addon folders at the top level.

### Phase 1 — Plugin runtime API

**Goal:** implement the public API on top of the sample data. Addon side is now consumable.

Work items:

- `RecipeRegistry_Metadata/Data/RecipeMetadata.lua`:
  - Merge `RecipeRegistryRecipeMetadata` (generated) with `RecipeRegistryRecipeMetadataOverrides` (runtime).
  - Implement all methods in §4.1.
  - `NormalizeRecipeKey` handles positive item IDs, negative spell IDs, invalid item IDs, ambiguous mappings.
- `RecipeRegistry_Metadata/Diagnostics/RecipeMetadataDiagnostics.lua`:
  - `/rrmeta diag`, `/rrmeta version` slash commands.
- Specs:
  - `metadata_runtime_lookup_spec.lua` — spell/recipeItem/createdItem lookups.
  - `metadata_normalize_key_spec.lua` — all key sources, ambiguity preserved.
  - `metadata_override_merge_spec.lua` — runtime override beats generated.
  - `metadata_unresolved_spec.lua` — unresolved record reporting.

**Exit criteria:**

- Plugin API matches §4.1 contract.
- ≥ 30 assertions across the four spec files, all green.

### Phase 2 — RR filter integration

**Goal:** filters apply to the UI projection. Sample data is enough to validate the path end-to-end.

Work items:

- `RecipeRegistry/Data/RecipeOwnershipIndex.lua` — owner summary index, rebuilt on scan complete and on sync recipe-add/remove.
- `RecipeRegistry/Data/RecipeUiFilters.lua`:
  - `GetEffectiveExpansionVisibility(professionKey)`.
  - `RecipePasses(recipeKey, info, ctx)` — full predicate per §6.2.
  - `BuildFilterCacheKey(ctx)`.
  - `Explain(recipeKey, ctx)` for `/rr filters explain`.
  - `InvalidateProfessionProjection(professionKey, reason)`.
- `RecipeRegistry/Core.lua` — profile defaults `recipePrefilters` per §6.1.
- `RecipeRegistry/Data/DataCatalog.lua`:
  - Accept `filterContext` in list builders.
  - Apply predicate before row construction.
  - Use `RecipeOwnershipIndex` for current-player check.
  - Extend cache keys per §10.3.
- `RecipeRegistry/UI/MainFrame.lua`:
  - `RefreshRecipeList` builds and passes filter context.
  - `_FinalizeRecipeList` rejects stale callbacks per §10.1.
- Plugin-absent fallback: `RecipeUiFilters:RecipePasses` returns `true, "visible-no-plugin"` when `_G.RecipeRegistry_Metadata` is missing. Cache key includes a `plugin = "absent"` discriminator.
- Specs:
  - `filter_predicate_expansion_spec.lua`.
  - `filter_predicate_bop_spec.lua`.
  - `filter_predicate_outputless_spec.lua`.
  - `filter_cache_invalidation_spec.lua`.
  - `filter_async_stale_callback_spec.lua`.
  - `filter_plugin_absent_fallback_spec.lua`.

**Exit criteria:**

- All Phase 2 specs green.
- In-game smoke test: disable Vanilla → Vanilla recipes disappear from the list immediately, no resync triggered, fingerprints unchanged before/after.

### Phase 3 — Options UI

**Goal:** users can configure filters from the options panel.

Work items:

- `RecipeRegistry/UI/Options.lua`:
  - Global Vanilla/TBC checkboxes.
  - Remote BoP checkbox.
  - Per-profession matrix with inherit/custom + Vanilla/TBC toggles.
  - Empty-state warning when all visibility is disabled.
  - Options panel hidden / shows "Plugin not installed" hint when `_G.RecipeRegistry_Metadata` is absent.
- Specs:
  - `options_profile_migration_spec.lua` — missing keys default safely.
  - `options_per_profession_inheritance_spec.lua`.

**Exit criteria:**

- Options panel usable in-game.
- Profile migration tests green.

### Phase 4 — Generator real data extraction

**Goal:** replace the sample data with a real TBC dataset.

Work items:

- `recipe_sources/db2_provider.py`:
  - Load committed DB2 snapshots from `tools/recipe-metadata/snapshots/`.
  - Document which DB2 tables are used (SkillLineAbility, Spell, SpellEffect, ItemSparse, etc.).
- `recipe_sources/secondary_provider.py`:
  - Fill DB2 gaps for fields not directly available.
- `recipe_pipeline/normalize.py`:
  - Build `RecipeRecord` set from source providers.
- `recipe_pipeline/classify_expansion.py`:
  - First-expansion-of-appearance rule per §7.4.
- `recipe_pipeline/derive_items.py`:
  - Recipe item + created item mapping per §7.5.
- `recipe_pipeline/derive_reagents.py`:
  - Reagent extraction from spell effects.
- `recipe_pipeline/derive_categories.py`:
  - Apply taxonomy from `remediation/taxonomy/<profession>.yaml`.
  - Fallback `misc` with diagnostic.
- `recipe_pipeline/validate.py`:
  - All rules from §9.
  - `--strict` mode.
- `recipe_pipeline/emit_lua.py`:
  - Deterministic ordering (sort all keys).
  - Compact format per §5.2.
- `recipe_pipeline/emit_reports.py`:
  - `coverage.md`, `unresolved.json`, `source-manifest.json`, `category-remediation.md`, `reagent-coverage.md`.
- Generator fixture tests (Python `unittest`):
  - Normal Vanilla craft, normal TBC craft.
  - Recipe with / without recipe item, with / without created item.
  - Ring enchant (outputless self-only).
  - BoP output item.
  - Multiple spells producing the same created item (ambiguity preserved).
  - Missing category → `misc` fallback.
  - Missing reagent data → unresolved report.
  - Out-of-scope WotLK source record → excluded.
  - Determinism: two runs from the same snapshot produce identical Lua + reports.
  - Strict validation fails on unresolved expansion.
  - `--check` mode fails when committed output is stale.

**Exit criteria (100% coverage required for v1, per §17 decision 4):**

- `python ... generate --offline --check` succeeds on committed snapshots.
- `python ... validate --strict` succeeds with **zero** release-blocking unresolved records.
- `coverage.md` shows 100% resolved expansion, profession, and category for every recipe of every supported profession (§7.7).
- `reagent-coverage.md` shows 100% resolved reagents for every recipe whose UI detail / cost path depends on reagent metadata.
- Any gap is closed by either upstream improvement or by adding the missing entry to `manual_overrides.yaml`. No deferred-to-v1.1 entries.

### Phase 5 — AtlasLoot call-site inventory + replacement

**Goal:** every AtlasLoot use is documented and either replaced or moved off the projection path.

Work items:

- Produce `docs/atlasloot-removal-inventory.md` per §8.1.
- For every call-site in the inventory:
  - Replace with `RecipeMetadata` lookup when behavior is in scope.
  - Replace with a direct WoW API call where appropriate.
  - Move legacy paths behind a clearly named guard if intentionally kept.
- Specs:
  - `atlasloot_call_site_gate_spec.lua` — grep-style spec that fails if AtlasLoot is referenced from a path in the new projection allowlist.
  - Existing UI projection specs run with and without AtlasLoot stubbed in the harness.

**Exit criteria:**

- Inventory doc reviewed.
- UI behavior identical with AtlasLoot installed vs absent (manual + spec).

### Phase 6 — Global search + Favorites hardening

**Goal:** per-recipe profession filter for cross-profession views.

Work items:

- Global search applies predicate per-recipe using that recipe's own profession.
- Favorites view filters per-recipe; hidden favorites preserved in saved data.
- Specs:
  - `filter_global_search_per_profession_spec.lua`.
  - `filter_favorites_preserve_hidden_spec.lua`.
  - `filter_favorites_reappear_on_unhide_spec.lua`.

**Exit criteria:**

- Multi-profession scenarios behave per §6.7.

### Phase 7 — Detail panel + requestability hardening

**Goal:** visibility / requestability fully separated.

Work items:

- Detail panel rejects stale selection when filters change.
- Quick-request disabled / hidden for remote crafters of BoP / self-only recipes.
- Material list + cost estimate use internal reagents per §5.2.
- Specs:
  - `detail_requestability_remote_bop_spec.lua`.
  - `detail_cost_estimate_internal_reagents_spec.lua`.
  - `detail_selection_stale_after_filter_change_spec.lua`.

**Exit criteria:**

- Quick-request never offered to non-requestable crafters.
- Cost estimate works for covered recipes without AtlasLoot.

### Phase 8 — Category / subcategory migration

**Goal:** UI categories come from RR taxonomy, not from AtlasLoot.

Work items:

- Replace AtlasLoot category source in `MainFrame.lua` and `DataCatalog.lua` with `RecipeMetadata:GetCategory`.
- Remove runtime patching of AtlasLoot subsections.
- Validate per-profession category UX in-game (every profession).

**Exit criteria:**

- Category navigation works with AtlasLoot absent.
- Inventory shows zero AtlasLoot category lookups in the new path.

**Phase 8 completion note (2026-05-24):**

- Category navigation with AtlasLoot absent is covered by `local-tests/spec/category_metadata_navigation_spec.lua`, which seeds every supported v1 profession and verifies metadata category filtering covers the same recipes as the All view.
- The same spec installs throwing AtlasLoot category/ItemDB stubs while `RecipeRegistry_Metadata` is present; `Data:GetRecipeCategory`, `Data:GetRecipeCategories`, and category-filtered `Data:GetRecipeList` still succeed, proving the new category path performs zero AtlasLoot category lookups.
- `docs/atlasloot-removal-inventory.md` was updated with the Phase 8 category review and records the `DataCatalog.lua` category call-site as metadata-backed, with the legacy AtlasLoot category provider restricted to plugin-absent fallback until Phase 9.

### Phase 9 — AtlasLoot removal + release hardening

**Goal:** AtlasLoot is fully removed from RR. The new path is the only path. Per §17 decision 8, dropping `OptionalDeps: AtlasLoot` is a **release blocker for v1**, not deferred.

Work items:

- Confirm all §8.2 exit criteria are met. If any criterion fails, fix it via metadata generator extension or manual override — **not** by retaining the OptionalDep.
- Remove `AtlasLootClassic` / `AtlasLoot` lines from `RecipeRegistry.toc` `## OptionalDeps`.
- Delete or archive [`Data/DataAtlasLoot.lua`](../Data/DataAtlasLoot.lua). If any historical diagnostic or non-projection path still references it, isolate behind an explicitly named `legacy/` folder excluded from the projection-path test gate.
- Strict generator validation enabled in CI.
- Update `CHANGELOG.md` with the new addon, new filter behavior, and the AtlasLoot removal announcement.
- Update `docs/recipe-registry-public-api.md` with the final `RecipeMetadata` contract.
- Polish diagnostics: `/rr filters`, `/rr filters unresolved`, `/rr filters explain`.

**Exit criteria:**

- Release-grade build passes `--strict` validation + all specs (including `atlasloot_call_site_gate_spec.lua`).
- Manual UI smoke test passes — the "with AtlasLoot installed" scenario now only verifies that *RR ignores AtlasLoot if present*, not that AtlasLoot fills gaps.
- `RecipeRegistry.toc` contains zero AtlasLoot references.
- `git grep -i atlasloot RecipeRegistry/` returns zero matches outside an explicitly archived legacy folder (if any).

**Phase 9 completion note (2026-05-24):**

- §8.2 parity criteria are satisfied by the Phase 5-8 replacement specs plus Phase 9 hardening: list/detail/category/material/cost/search/favorites use `RecipeRegistry_Metadata` or direct WoW item/spell APIs, `atlasloot_projection_parity_spec.lua` verifies identical projection with a contradictory AtlasLoot stub present, and `category_metadata_navigation_spec.lua` verifies metadata-only category taxonomy.
- `RecipeRegistry.toc` now lists `RecipeRegistry_Metadata` as the only recipe metadata optional dependency, contains zero AtlasLoot references, and no longer loads `Data/DataAtlasLoot.lua`.
- `Data/DataAtlasLoot.lua` and the legacy `/rr atlas`, `/rr r`, `/rr s`, `/rr i` diagnostics were removed; `/rr filters`, `/rr filters unresolved`, and `/rr filters explain <recipeKey>` remain the supported metadata/filter diagnostics.
- Strict generator validation is enabled in `.github/workflows/recipe-metadata.yml` through `generate --offline --check` and `validate --strict`.
- `CHANGELOG.md`, `docs/recipe-registry-public-api.md`, and `docs/atlasloot-removal-inventory.md` document the final separate-addon contract, filter behavior, and AtlasLoot removal.
- Release validation evidence: `.\local-tests\run-backend-tests.ps1`, `.\local-tests\run-syntax.ps1`, `python -m unittest discover -s tools/recipe-metadata/tests`, `python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline --check`, `python tools/recipe-metadata/generate_recipe_metadata.py validate --flavor tbc --strict`, `Select-String -Path .\RecipeRegistry.toc -Pattern "AtlasLoot"`, and `git grep -i atlasloot -- RecipeRegistry.toc Core Data Sync UI Integrations Libs` all pass with the final code.
- The manual UI smoke expectation for the "with AtlasLoot installed" case is represented in the harness by `atlasloot_projection_parity_spec.lua` and the throwing-stub category test: AtlasLoot may exist globally, but RR ignores it.

---

## 12. Diagnostics

Required slash commands (registered in RR, delegating to plugin when present):

```
/rr filters                  -- current global + active-profession effective settings, metadata version, unresolved count
/rr filters unresolved       -- unresolved records grouped by severity
/rr filters explain <key>    -- single-recipe pass/fail trace with reason code
/rrmeta diag                 -- plugin diagnostics dump (record counts, override counts, schema version)
/rrmeta version              -- plugin metadata version + schema version + flavor
```

Diagnostics must not be noisy during normal gameplay. The `Trace` scope for the metadata addon is `metadata`; for the filter layer it's `filters`. Both must be silent unless explicitly enabled via `/rr debug`.

---

## 13. Test taxonomy

Single canonical test list. Phase plan references this section instead of restating tests.

### 13.1 Generator (Python `unittest`)

- Source provider loads local snapshots.
- Extractor produces normalized records.
- Expansion classifier emits Vanilla / TBC correctly.
- Future-expansion records excluded from TBC output.
- Recipe item, created item, reagent mappings generated.
- Ambiguous created-item mappings preserved and reported.
- Category normalizer assigns valid categories.
- Manual overrides replace generated values.
- `--strict` fails on unresolved expansion.
- `--strict` fails on unresolved profession.
- Determinism: two runs from same snapshots produce identical Lua + reports.
- `--check` fails when committed output is stale.

### 13.2 Metadata runtime (Lua)

- Spell ID resolves to expansion, profession, category, subcategory.
- Spell ID resolves to created item, recipe item, reagents.
- Recipe item resolves to spell.
- Ambiguous created item is not arbitrarily resolved.
- Override beats generated metadata.
- Unresolved metadata is reported via `GetMetadataResolutionStatus`.
- `NormalizeRecipeKey` handles positive item, negative spell, invalid item, spell-only, item-only keys.

### 13.3 Filter predicate

- Vanilla hidden when disabled.
- TBC visible when enabled.
- Profession override beats global default.
- Inherited profession uses global defaults.
- Global search applies per-recipe profession filter.
- Favorites apply per-recipe profession filter.
- Remote BoP hidden by default.
- Remote BoP visible when option enabled.
- Current-player BoP visible regardless of remote option.
- Outputless self-only remote hidden by default.
- Outputless self-only current-player visible.
- Unresolved metadata → conservative visible + log.

### 13.4 UI projection

- Hidden recipes do not enter projection.
- Hidden recipes are not sorted.
- Hidden recipes do not appear in search.
- Hidden favorites do not appear in Favorites view.
- Per-profession override invalidates only that profession's projection.
- Global defaults change invalidates all projections.
- Stale async callback ignored after filter change.
- Empty filter state produces a clean empty UI state.
- Detail does not offer request action for remote non-requestable crafter.

### 13.5 Sync regression (CRITICAL — must remain green)

- Sync fingerprints unchanged by filter configuration.
- Merge behavior unchanged.
- Block indexes unchanged.
- Saved recipe data unchanged.
- Filter option change does not trigger HELLO / SUMMARY / INDEX_DIFF traffic.

### 13.6 AtlasLoot ignored when present

- UI works with AtlasLoot absent (the default case post-v1).
- UI behavior identical whether the user has AtlasLoot installed or not.
- Cost estimate works using internal reagents only.
- `atlasloot_call_site_gate_spec.lua` fails the suite if AtlasLoot is referenced from the release runtime surface loaded by `RecipeRegistry.toc`.

### 13.7 Plugin-absent fallback

- RR loads cleanly without `RecipeRegistry_Metadata`.
- Filter options panel hidden (or shows a clear "plugin not installed" hint).
- `RecipePasses` returns `true, "visible-no-plugin"` for every key.
- Cache key includes plugin-absence discriminator.

---

## 14. Manual test scenarios

### 14.1 Expansion filters

- Default settings → Vanilla and TBC visible.
- Global Vanilla disabled → Vanilla hidden across inherited professions.
- Engineering custom Vanilla disabled → only Engineering Vanilla hidden.
- Global search shows Vanilla Alchemy but hides Vanilla Engineering when Engineering override disables Vanilla.

### 14.2 Remote BoP + requestability

- Remote-only BoP recipe hidden by default.
- Remote-only BoP recipe visible when option enabled.
- Current-player BoP recipe always visible.
- Current-player BoP detail does not offer remote non-requestable quick-request even if remote owners also know it.

### 14.3 Outputless self-only

- Remote-only ring enchant hidden by default.
- Remote-only ring enchant visible when remote BoP/self-only option enabled.
- Current-player ring enchant always visible.
- Remote ring enchant is not shown as normally requestable.

### 14.4 Favorites

- Favorite a Vanilla recipe.
- Disable Vanilla for that recipe's profession.
- Favorite disappears from visible Favorites.
- Saved favorite remains in DB.
- Re-enable Vanilla → favorite reappears.

### 14.5 AtlasLoot ignored when present

- Run with AtlasLoot still installed by the user (RR no longer declares it as OptionalDep, but the user may still have it for other purposes).
- Verify RR's UI ignores it completely — list, categories, detail, materials, costs come entirely from internal metadata.
- Verify behavior is identical to running without AtlasLoot installed.

### 14.6 Plugin absence

- Disable `RecipeRegistry_Metadata` from the WoW addon list.
- Reload UI.
- RR loads without errors.
- Filter options panel hidden or marked unavailable.
- Recipe list shows everything (current behavior, no filter applied).

### 14.7 Sync separation

- Receive recipes via sync while filters hide them.
- Verify data is saved.
- Verify fingerprints unchanged before/after.
- Disable filter; recipes appear without resync.

### 14.8 Generator workflow

- Run `generate --offline`.
- Inspect `unresolved.json`.
- Add a remediation entry to `manual_overrides.yaml`.
- Regenerate.
- Confirm generated Lua diff is only the expected records.
- Run `validate --strict`.
- Run addon tests.
- Confirm affected recipe resolves correctly in UI.

---

## 15. Performance acceptance criteria

The feature is successful only if it reduces UI workload under filtered configurations:

- Hidden recipes do not enter the UI runtime projection.
- Hidden recipes are not sorted.
- Hidden recipes are not bound to rows.
- Hidden recipes do not trigger icon / material enrichment.
- Per-profession override changes do not rebuild unrelated professions.
- Current-player ownership checks are O(1) (index-based).
- Async stale callbacks cannot overwrite newer UI state.
- Global search applies per-recipe profession filters without building full detail per recipe.
- Favorites filtering does not build full detail for hidden favorites.

Suggested measurement points (exposed via `/rr filters` or a separate diagnostic):

- Number of raw recipes scanned.
- Number of recipes accepted into projection.
- Time to build projection (ms).
- Number of display info resolutions.
- Number of reagent resolutions.
- Projection cache hit / miss count.
- Stale async callbacks ignored.

---

## 16. Risks

| Risk | Mitigation |
|------|------------|
| DB2 snapshot source quality varies per snapshot | Pin specific snapshot versions in `source-manifest.json`. `fetch` is the only step that updates them. |
| Recipe-side sync regression caused by accidental coupling | The filter layer is UI-only by contract. Regression test `filter_sync_isolation_spec.lua` verifies sync fingerprints are unchanged before/after every filter operation. |
| Plugin and RR drift out of sync on release | Single CurseForge project + single repo + single packager run guarantees they ship together. |
| Wire prefix collision with future addons | Plugin uses no wire — it's pure data. No collision possible. |
| AtlasLoot taint reintroduced silently | `atlasloot_call_site_gate_spec.lua` fails the test suite if AtlasLoot is referenced from the release runtime surface loaded by `RecipeRegistry.toc`. |
| Item cache thrash on `GET_ITEM_INFO_RECEIVED` storms | Scoped per-profession invalidation + rate limiting per §10.2. |
| `metadataVersion` drift between committed Lua and what generator emits | CI `generate --offline --check` fails on stale committed output. |
| Coverage gaps per profession block a release | Strict mode fails the build; release blocker is explicit in `coverage.md`. |
| User loses filter settings on profile migration | Migration is purely additive (§10.6); unknown keys preserved. Spec covers each missing-key scenario. |

---

## 17. Decisions locked (2026-05-23)

1. **Branch timing**: parallel to `feature/craft-orders-mail-assistant`, no strict ordering. Whichever feature finishes first merges first; the second handles the `.pkgmeta` `move-folders` merge conflict (additive, trivial — just add the missing line).
2. **DB2 source**: **wago.tools** as primary provider. Reasons: actively tracks Classic-era patches (including TBC 2.5.x), public API for fetching DB2 dumps, the most reliable maintenance signal among Classic-era data providers. Marlamin's wow.tools / WoWDBDefs stays as schema reference. If wago.tools goes stale, the source manifest mechanism (§7.9) makes switching providers a one-file edit.
3. **Snapshot commit policy**: commit **minimal normalized snapshots** in `tools/recipe-metadata/snapshots/`. CI runs fully offline via `generate --offline --check`. `fetch` is a maintainer-only step that updates snapshots when the upstream changes.
4. **Coverage gate for v1 release**: **100% — no partial release**. Strict mode (`validate --strict`) must pass with zero unresolved release-blocking records before the plugin ships v1. Any gap in expansion / profession / reagent / category coverage for a supported profession is fixed by either upstream improvement or manual remediation in `manual_overrides.yaml`. There is no "we'll fix it in v1.1" path for missing data on a supported profession.
5. **Profession scope v1**: primary professions (alchemy, blacksmithing, enchanting, engineering, jewelcrafting, leatherworking, tailoring) **+ cooking**. First aid and fishing deferred to a later release (their recipe model is different enough — no real reagents, no real categories — that bundling them into v1 would slow the primary work). Deferred professions get conservative visible-all behavior, no filter UI options.
6. **Runtime override fate**: keep both. `manual_overrides.yaml` (generator-time) is the normal correction path. `RecipeMetadata_Overrides.lua` (runtime) is an emergency hatch for fixes that can't wait for a regeneration + release cycle.
7. **Plugin's `## Version` start**: `0.1.0`.
8. **AtlasLoot final removal**: **aggressive — drop `OptionalDeps: AtlasLoot` / `AtlasLootClassic` in v1**. The §8.2 exit criteria become a release blocker for Phase 9, not a deferred goal. If parity testing reveals an unsuppressed AtlasLoot dependency, the fix is to extend the metadata generator or add a manual override — not to keep the OptionalDep around as a safety net.

---

## 18. Not in scope

This work does not aim to:

- Change guild sync behavior, merge behavior, recipe ownership semantics.
- Prune saved recipe data.
- Infer account-level alts.
- Expose an `unknown` expansion option.
- Add user-facing recipe counters beyond what already exists.
- Keep AtlasLoot as a metadata authority.
- Create a general-purpose public trade skill library.
- Localize every category label in v1.
- Solve future-expansion support beyond TBC.
- Run any network call from the addon runtime.

---

## 19. Migration trigger: when to split CurseForge projects

Same trigger logic as Craft Orders (see [`craft-orders-roadmap.md`](craft-orders-roadmap.md) §3.9). For the metadata plugin specifically:

Split into a separate CurseForge project when:

- The metadata plugin has shipped a stable `1.0.0` (post-Phase 9).
- The public API contract in §4 has been frozen for at least one minor RR release cycle.
- Metadata regeneration cadence visibly diverges from RR release cadence (e.g., metadata ships 5+ updates between two RR releases — likely after new content patches).

Until then, single CurseForge project, coordinated releases. Cosmetic "RR updated" notifications on metadata-only releases are an accepted trade-off.

---

## 20. How to advance

Decisions §17 are locked. Next steps:

1. Fork `feature/recipe-metadata-library` from `develop` whenever it's convenient (parallel to the craft-orders branch, no strict ordering).
2. Commit this doc as the first feature-branch commit.
3. Start Phase 0: data contract + scaffolds.
4. Loop back here for Phase 1 plan refinement once the sample data + plugin API are in place.
