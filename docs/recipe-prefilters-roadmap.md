# Recipe UI Prefilters, Internal Metadata Library and AtlasLoot Resolver Removal

## Context and goals

Recipe Registry currently builds a guild-wide recipe directory. The UI shows recipes known locally or received through guild sync, together with available crafters, materials and cost estimates.

This is useful for recipes that can be requested from other players, but it creates unnecessary UI noise and runtime overhead in two major cases:

- recipes that produce bind-on-pickup output items, because other players cannot craft a tradable item for the requester;
- older expansion recipes, especially Vanilla/pre-TBC recipes, when the user wants to focus only on TBC content.

The goal is to introduce configurable UI prefilters that reduce the amount of recipe data projected into the UI runtime layer.

These filters must not change the sync database, peer ownership data, merge behavior, block fingerprints, wire protocol or any shared data structure. They must operate only on the UI/catalog projection.

The intended result is:

- faster UI loading;
- less noise in recipe lists and search results;
- deterministic filtering independent from optional third-party addons;
- user-configurable visibility per expansion and per profession;
- removal of AtlasLoot as a resolver for recipe metadata and profession subsections.

## Mandatory architectural rule: UI-only filtering

All filters described in this roadmap must apply only to the UI/catalog layer.

They must not affect:

- guild sync;
- merge logic;
- block fingerprints;
- global fingerprints;
- block indexes;
- wire protocol;
- saved peer recipe data;
- ownership data;
- pruning or stale-node handling.

The sync layer must continue to store and index all known recipes.

Changing filter options must not require a resync. Recipes already received from peers must become visible again immediately when the user disables or changes a filter.

The UI must build a filtered runtime projection from the full local/synced dataset. Recipes excluded by the active filters should not enter the UI runtime recipe list/cache for the affected profession.

This is not just a visual hide-after-render feature. The objective is to avoid loading, sorting, rendering and caching recipes that are not relevant under the active UI filter configuration.

## Current behavior assumed

The current UI flow in `UI/MainFrame.lua` is approximately:

1. The selected view/profession updates `UI.selectedProfession`, `UI.selectedCategory` and resets `UI.selectedRecipeKey`.
2. `UI:RefreshRecipeList()` computes:
   - effective profession;
   - category filter;
   - global search text;
   - sort mode.
3. The list is built through `Addon.Data:BuildRecipeListAsync(effectiveProfession, searchText, sortMode, searchMode, categoryFilter, callback)`.
4. If the result is not inline, `_ShowRecipeListLoadingState()` shows a loading header.
5. `_FinalizeRecipeList(rows, context, generation)`:
   - currently applies UI-side favorite handling;
   - updates `self.currentRecipeRows`;
   - verifies whether `self.selectedRecipeKey` is still visible;
   - auto-selects the first visible recipe when needed;
   - calls `RenderVisibleRecipeRows()`, `RefreshSummaryCards()` and `RefreshDetailPanel()`.
6. `RenderVisibleRecipeRows()` uses virtualized rows and `BindRecipeRow()`.
7. `BindRecipeRow()` calls lazy `RefreshRecipeRowAssets()`, which uses `Data:GetRecipeDisplayInfo(recipeKey)` for labels, icons, created item, recipe item and visual metadata.
8. `RefreshDetailPanel()` uses `Addon.Data:GetRecipeDetail(self.selectedRecipeKey)` and renders:
   - title and subtitle;
   - online/offline crafters;
   - materials;
   - cost estimate.

In the data layer, `Data/DataCatalog.lua` currently contains the most relevant points:

- `Data:GetRecipeDisplayInfo(recipeKey)`;
- `Data:GetRecipeList(...)`;
- `Data:BuildRecipeListAsync(...)`;
- `Data:GetRecipeDetail(recipeKey)`.

The new implementation must move filter decisions as early as possible into the data/catalog projection path, before expensive UI row construction, sorting and rendering.

## Functional requirements

### RF1 - Remote BoP output filter

The user must be able to choose whether to show recipes from other guild members when the produced output item is bind-on-pickup.

The filter applies to the produced item, not to the recipe item.

Rules:

- if the recipe produces a non-BoP item, it is visible normally;
- if the recipe produces a BoP item and the current player knows the recipe, it must always remain visible;
- if the recipe produces a BoP item and it is known only by another guild member, it is visible only when the user enables the dedicated option;
- if the recipe has no produced item, the BoP output rule does not apply directly.

Default behavior:

- hide remote BoP output recipes;
- always show current-player BoP output recipes.

Suggested option name:

- `showRemoteBopOutputRecipes`.

The reason is practical: if another player’s recipe produces a BoP item, the local user cannot request that item as a tradable craft.

### RF2 - Outputless self-only recipes

Some recipes or profession effects do not produce a normal item but are still effectively self-only. A key example is ring enchants in Enchanting.

These cases cannot be detected through the BoP produced-item rule, because there may be no produced item.

They must be handled through explicit metadata.

Rules:

- outputless self-only recipes must be visible for the current player when known locally;
- outputless self-only recipes known only by other guild members should follow the same user option as remote BoP output recipes;
- these cases must be identified by explicit spell IDs or generated metadata;
- they must not be inferred from AtlasLoot categories.

Suggested metadata table:

```lua
RecipeRegistryRecipeMetadataOverrides = {
    selfOnlyOutputlessBySpellId = {
        -- [spellId] = true
    }
}
```

### RF3 - Expansion visibility filter

The user must be able to choose which supported expansions are visible in the UI.

For TBC Anniversary, the initial supported values are:

- Vanilla;
- TBC.

There should be no user-facing `unknown` expansion option.

If a recipe cannot be classified as Vanilla or TBC, that is a metadata coverage issue, not a valid user-facing classification.

### RF4 - Global expansion defaults

The addon must provide global expansion visibility defaults.

Suggested default:

```lua
recipePrefilters = {
    showRemoteBopOutputRecipes = false,

    expansionDefaults = {
        vanilla = true,
        tbc = true,
    },

    professionExpansionOverrides = {
    },
}
```

With this default, all Vanilla and TBC recipes are visible unless changed by the user.

The user can globally disable Vanilla recipes, TBC recipes, or both.

### RF5 - Per-profession expansion matrix

The addon options must allow free per-profession configuration.

For each profession, the user should be able to choose either:

- use global defaults;
- use custom visibility toggles.

When using custom visibility toggles, the profession has independent options for:

- Vanilla;
- TBC.

Example:

Global defaults:

- Vanilla: true;
- TBC: true.

Alchemy:

- use global defaults;
- result: Vanilla and TBC visible.

Engineering:

- custom;
- Vanilla: false;
- TBC: true;
- result: only TBC Engineering recipes visible.

Suggested structure:

```lua
recipePrefilters = {
    showRemoteBopOutputRecipes = false,

    expansionDefaults = {
        vanilla = true,
        tbc = true,
    },

    professionExpansionOverrides = {
        ["Engineering"] = {
            inherit = false,
            vanilla = false,
            tbc = true,
        },
    },
}
```

A profession with no override or with `inherit = true` must use the global defaults.

The UI must clearly distinguish:

- inherited configuration;
- custom configuration.

### RF6 - Filters must affect UI runtime projection

Recipes excluded by filters must not be inserted into the active UI runtime list/cache for the affected profession.

This is mandatory.

The goal is not only to hide rows visually after the list is built. The filtered recipes should be excluded before list row construction, sorting, virtualized rendering and detail binding.

This applies to:

- profession lists;
- category/subcategory views;
- global search;
- favorites view;
- detail selection;
- any UI-side visible recipe cache.

### RF7 - Favorites behavior

Favorites must respect active filters.

If a favorite recipe is hidden by the current filter configuration:

- it must not appear in the visible Favorites list;
- it must not be removed from the saved favorites data;
- it must reappear when the user changes filters so that it becomes visible again.

There is no separate “favorites ignore filters” behavior in V1.

### RF8 - Global search behavior

Global search must respect active filters.

If the user searches for a Vanilla recipe while Vanilla is disabled for the effective profession, the recipe must not appear in search results.

If the user later enables Vanilla again, the same recipe can appear without requiring a resync.

### RF9 - Summary counters

Recipe counters are not required for V1.

If existing UI counters become misleading after filtering, either:

- remove them from the user-facing UI; or
- make them clearly represent only visible filtered data.

Raw totals may remain available only in diagnostics.

No additional counter feature should be added unless it directly supports debugging or user clarity.

## Addon options requirements

The addon options panel must expose the new filter configuration.

Required options:

- checkbox: `Show BoP output recipes known only by other guild members`;
- global expansion visibility:
  - `Show Vanilla recipes`;
  - `Show TBC recipes`;
- per-profession expansion visibility:
  - `Use global defaults`;
  - custom toggles:
    - `Vanilla`;
    - `TBC`.

Changing any option must:

- invalidate only the affected UI/catalog runtime projection;
- avoid touching sync state;
- avoid rebuilding sync indexes;
- avoid recomputing fingerprints;
- avoid changing saved peer recipe data.

For per-profession option changes, invalidation should be scoped to the affected profession when possible.

Example:

- changing Engineering Vanilla visibility should invalidate the Engineering UI projection;
- it should not invalidate unrelated profession UI projections;
- it should not invalidate sync indexes or global recipe ownership data.

## Internal metadata library

### Decision

Recipe Registry must introduce an internal metadata library generated at build time.

The internal metadata library replaces AtlasLoot as the resolver for:

- recipe-to-spell resolution;
- recipe item resolution;
- created item resolution;
- profession assignment;
- expansion classification;
- profession categories and subcategories;
- outputless self-only recipe classification;
- UI sort order metadata.

AtlasLoot must no longer be required to build the UI recipe catalog.

### Rationale

AtlasLoot is currently used to resolve items and create profession subsections.

However:

- AtlasLoot categories are not suitable enough and are already modified at runtime;
- relying on AtlasLoot makes the UI behavior depend on a local optional addon;
- filtering must be deterministic regardless of the user’s installed addons;
- Recipe Registry needs only a specific subset of metadata;
- a generated internal metadata file gives better control over categories, sorting and remediation.

The internal metadata library should not replicate an entire external recipe library unless necessary. It should contain only the data required by Recipe Registry.

### Suggested files

Suggested structure:

```text
Data/RecipeMetadata.lua
Data/RecipeMetadata_Generated.lua
Data/RecipeMetadata_Overrides.lua
Data/RecipeUiFilters.lua
```

Responsibilities:

- `RecipeMetadata.lua`
  - public API for resolving recipe metadata;
  - merges generated data and manual overrides;
  - exposes normalized metadata to the UI/catalog layer.

- `RecipeMetadata_Generated.lua`
  - generated static metadata;
  - should not be edited manually.

- `RecipeMetadata_Overrides.lua`
  - manual remediation table;
  - explicit corrections for edge cases.

- `RecipeUiFilters.lua`
  - UI-only filter predicate;
  - effective option resolution;
  - profession-scoped filter cache keys.

### Suggested generated metadata shape

```lua
RecipeRegistryRecipeMetadata = {
    recipesBySpellId = {
        [28596] = {
            profession = "Alchemy",
            expansion = "tbc",
            recipeItemId = 22900,
            createdItemId = 22845,
            category = "flasks",
            subcategory = "guardian_elixirs",
            sortOrder = 120,
        },
    },

    recipeItemToSpellId = {
        -- [recipeItemId] = spellId
    },

    createdItemToSpellIds = {
        -- [createdItemId] = { spellId1, spellId2 }
    },

    categoriesByProfession = {
        ["Alchemy"] = {
            { key = "potions", label = "Potions", order = 10 },
            { key = "elixirs", label = "Elixirs", order = 20 },
            { key = "flasks", label = "Flasks", order = 30 },
            { key = "transmutes", label = "Transmutes", order = 40 },
        },
    },

    subcategoriesByProfession = {
        ["Alchemy"] = {
            potions = {
                { key = "healing", label = "Healing", order = 10 },
                { key = "mana", label = "Mana", order = 20 },
                { key = "utility", label = "Utility", order = 30 },
            },
        },
    },
}
```

### Suggested override metadata shape

```lua
RecipeRegistryRecipeMetadataOverrides = {
    expansionBySpellId = {
        -- [spellId] = "vanilla" | "tbc"
    },

    createdItemBySpellId = {
        -- [spellId] = itemId
    },

    recipeItemBySpellId = {
        -- [spellId] = itemId
    },

    categoryBySpellId = {
        -- [spellId] = {
        --     category = "x",
        --     subcategory = "y",
        --     sortOrder = 123,
        -- }
    },

    selfOnlyOutputlessBySpellId = {
        -- [spellId] = true
    },

    bopOutputByCreatedItemId = {
        -- fallback only if item bind type cannot be resolved reliably
        -- [itemId] = true
    },
}
```

Overrides must remain small and focused on remediation.

They must not become the primary data source.

## Metadata generation pipeline

Recipe Registry should include a build-time generator written specifically for this project.

The generator may be conceptually inspired by existing projects such as LibTradeSkillRecipes or WowDbScripts, but it should be implemented as Recipe Registry’s own minimal pipeline.

The generator should produce static Lua metadata files used by the addon.

Suggested location:

```text
tools/recipe-metadata/
  generate_recipe_metadata.py
  README.md
```

Generated output:

```text
Data/RecipeMetadata_Generated.lua
```

The pipeline should aim to derive:

- spell ID;
- recipe item ID;
- created item ID;
- profession;
- expansion;
- category;
- subcategory;
- sort order.

Expansion classification should be generated from reliable recipe/spell metadata, not primarily inferred from required skill rank.

Required skill rank may be used only as:

- a diagnostic cross-check;
- temporary fallback during development;
- a remediation hint.

It should not be the authoritative rule for Vanilla/TBC classification.

## Expansion classification

The metadata library must classify each supported recipe as:

- `vanilla`;
- `tbc`.

There should be no user-facing `unknown` category.

If a recipe cannot be classified, it must be treated as unresolved metadata.

Unresolved metadata behavior:

- log it in diagnostics;
- expose it through a debug command;
- avoid silently treating it as a third expansion;
- avoid exposing it as a user option;
- correct it through generator improvements or explicit overrides.

Suggested diagnostic command:

```text
/rr filters unresolved
```

Suggested diagnostic output:

- recipe key;
- spell ID;
- recipe item ID;
- created item ID;
- profession;
- reason;
- suggested remediation source.

Policy for unresolved recipes in V1:

- show unresolved recipes conservatively to avoid false negatives;
- log them for remediation;
- do not classify them as Vanilla or TBC until resolved.

## BoP and self-only visibility resolution

The UI filter must determine whether a recipe is self-only for other players.

A recipe is self-only when:

- it produces a BoP output item; or
- it is explicitly marked as outputless/self-only by metadata.

### Produced item BoP detection

Primary source:

- WoW item API, using the produced `createdItemId`.

If the item cache is not ready:

- do not permanently hide based only on missing item data;
- use cached metadata or override if available;
- queue/mark for later metadata refresh if needed;
- avoid aggressive flicker.

Fallback source:

- `bopOutputByCreatedItemId` override table.

### Outputless self-only detection

Primary source:

- `selfOnlyOutputlessBySpellId`.

This is required for cases such as ring enchants.

Rules:

- current-player self-only recipes are always visible;
- remote-only self-only recipes are visible only when `showRemoteBopOutputRecipes = true`.

## Current-player definition

For V1, “self” means only the current player character.

Do not treat alts as self.

Reasons:

- BoP outputs cannot be traded to alts;
- Recipe Registry does not have a reliable account-level alt ownership system;
- guild roster information is not sufficient to determine who owns which alt;
- alt inference would create false positives.

Suggested helper:

```lua
Data:IsRecipeKnownByCurrentPlayer(recipeKey)
```

This helper should check whether the current player key is among the owners/crafters of the recipe.

## AtlasLoot removal

### Decision

AtlasLoot must be removed from the resolver path.

It must not be used to decide:

- recipe visibility;
- expansion classification;
- recipe item mapping;
- created item mapping;
- profession category;
- profession subcategory;
- self-only/outputless classification;
- whether a recipe enters the UI runtime projection.

### Transitional policy

During migration, AtlasLoot may remain installed and supported only if there are legacy call-sites that have not yet been migrated.

However, the new filter path must not depend on AtlasLoot.

Acceptance criteria:

- the same Recipe Registry configuration produces the same visible recipe list with or without AtlasLoot installed;
- AtlasLoot does not change Vanilla/TBC classification;
- AtlasLoot does not change BoP/self-only visibility;
- AtlasLoot does not change category/subcategory assignment for the new UI projection;
- AtlasLoot is not part of the filter cache key;
- after all call-sites are migrated, remove `AtlasLootClassic` and `AtlasLoot` from `OptionalDeps`.

### Replacement responsibilities

The internal metadata library replaces AtlasLoot for:

- recipe item resolution;
- created item resolution;
- spell mapping;
- profession categories;
- profession subcategories;
- sort order;
- metadata remediation.

Icons should be resolved through WoW APIs using available IDs:

- created item icon from `createdItemId`;
- recipe item icon from `recipeItemId`;
- spell icon from `spellId`;
- fallback question mark icon.

Suggested icon fallback order:

1. created item icon;
2. recipe item icon;
3. spell icon;
4. internal placeholder icon.

## UI/category model

The new profession category model should be owned by Recipe Registry.

Categories and subcategories should be defined in internal metadata, not imported from AtlasLoot and patched at runtime.

Category design goals:

- stable;
- readable;
- useful for players;
- consistent across installations;
- independent from optional addons;
- easy to override manually.

Suggested category metadata:

```lua
categoriesByProfession = {
    ["Engineering"] = {
        { key = "consumables", label = "Consumables", order = 10 },
        { key = "devices", label = "Devices", order = 20 },
        { key = "goggles", label = "Goggles", order = 30 },
        { key = "ammo", label = "Ammo", order = 40 },
        { key = "misc", label = "Miscellaneous", order = 999 },
    },
}
```

Each recipe should resolve to:

- profession;
- category key;
- optional subcategory key;
- sort order.

If a recipe has no category assignment, it should go to a controlled fallback category such as `misc`, and diagnostics should report it as category remediation.

## UI filter predicate

Introduce a central UI-only predicate.

Suggested API:

```lua
Data:RecipePassesUiPrefilters(recipeKey, detail, uiFilterOptions)
```

or:

```lua
RecipeUiFilters:RecipePasses(recipeKey, recipeInfo, uiFilterOptions)
```

The predicate should evaluate:

1. effective profession expansion visibility;
2. recipe expansion;
3. current-player ownership;
4. remote BoP output visibility;
5. outputless self-only visibility.

Pseudo-flow:

- resolve recipe metadata;
- if expansion is unresolved:
  - log diagnostics;
  - apply unresolved policy;
- check whether expansion is enabled for the effective profession;
- if not enabled, reject;
- check whether recipe is self-only;
- if self-only and known by current player, accept;
- if self-only and only known remotely, accept only if `showRemoteBopOutputRecipes = true`;
- otherwise accept.

This predicate must be used consistently by:

- normal profession list;
- global search;
- category/subcategory views;
- favorites;
- detail selection validation.

## UI runtime projection

The UI should build a filtered runtime projection from full recipe data.

The projection must be scoped by profession where possible.

Suggested concept:

- sync data remains complete;
- data/catalog layer exposes full data internally;
- UI asks for a filtered projection;
- filtered projection is cached by profession and filter options;
- changing filter options invalidates only affected UI projections.

The projection should contain only visible recipes.

This avoids:

- constructing rows for hidden recipes;
- sorting hidden recipes;
- binding hidden rows;
- resolving icons for hidden recipes;
- rendering hidden details;
- unnecessary global search entries.

## Cache key requirements

Recipe list/projection cache keys must include filter-relevant options.

Suggested cache key components:

- profession;
- search text;
- sort mode;
- search mode;
- category;
- subcategory;
- effective Vanilla visibility;
- effective TBC visibility;
- remote BoP output visibility;
- metadata generation version;
- UI filter generation.

Do not include:

- AtlasLoot availability;
- sync generation unless the underlying recipe ownership data changed;
- unrelated profession filter settings.

For per-profession changes, invalidate only:

- that profession’s UI projection;
- global search projection if it includes that profession;
- favorites projection if needed.

Do not invalidate:

- sync fingerprints;
- block indexes;
- merge state;
- peer data;
- saved variables.

## Data layer impact

### Data/DataCatalog.lua

Required changes:

- stop using AtlasLoot as recipe resolver for new UI filter path;
- use `RecipeMetadata` for spell/item/profession/category/expansion;
- extend list building to accept UI filter options;
- apply filter before row construction;
- extend cache keys with effective filter values;
- expose diagnostics for unresolved metadata;
- ensure `GetRecipeDetail` can use internal metadata.

Relevant methods:

- `Data:GetRecipeDisplayInfo(recipeKey)`;
- `Data:GetRecipeList(...)`;
- `Data:BuildRecipeListAsync(...)`;
- `Data:GetRecipeDetail(recipeKey)`.

### Data/RecipeMetadata.lua

New module.

Responsibilities:

- resolve metadata by recipe key;
- normalize generated data and overrides;
- provide recipe expansion;
- provide created item ID;
- provide recipe item ID;
- provide profession;
- provide category/subcategory;
- identify outputless self-only recipes;
- expose metadata diagnostics.

Suggested methods:

- `GetRecipeInfo(recipeKey)`;
- `GetRecipeExpansion(recipeKey, info)`;
- `GetCreatedItemId(recipeKey, info)`;
- `GetRecipeItemId(recipeKey, info)`;
- `GetProfession(recipeKey, info)`;
- `GetCategory(recipeKey, info)`;
- `IsOutputlessSelfOnly(recipeKey, info)`;
- `GetMetadataResolutionStatus(recipeKey, info)`.

### Data/RecipeUiFilters.lua

New module.

Responsibilities:

- compute effective global/per-profession options;
- evaluate recipe visibility;
- expose cache key components;
- keep filter logic out of sync modules.

Suggested methods:

- `GetEffectiveExpansionVisibility(professionName)`;
- `RecipePasses(recipeKey, recipeInfo, filterContext)`;
- `BuildFilterCacheKey(filterContext)`;
- `InvalidateProfessionProjection(professionName, reason)`.

## UI layer impact

### UI/MainFrame.lua

Required changes:

- `UI:RefreshRecipeList()` must build filter context and pass it to the data layer;
- `_FinalizeRecipeList()` must assume rows are already filtered;
- `_FinalizeRecipeList()` must not reinsert hidden recipes;
- `BuildFavoriteRecipeRows()` must use the same filter predicate;
- global search must request filtered projection;
- category/subcategory views must use internal metadata categories;
- detail panel must only show recipes selected from the filtered projection.

### Detail panel

No special link-handling behavior is required for V1.

A recipe hidden by filters should not be selectable through normal addon UI because it should not be present in the filtered runtime list.

If defensive handling is needed, the detail panel may clear selection when the selected recipe is no longer part of `currentRecipeRows`.

### Profession buttons and categories

Profession categories/subcategories should come from internal Recipe Registry metadata.

AtlasLoot categories must no longer be used and then modified at runtime.

Optional future polish:

- small filter-active indicator;
- tooltip explaining that some recipes are hidden by filters.

This is not required for V1.

## Options.lua impact

Required additions:

- checkbox for remote BoP output recipes;
- global Vanilla/TBC toggles;
- per-profession configuration table;
- `Use global defaults` toggle per profession;
- per-profession Vanilla/TBC toggles when custom mode is active.

On option change:

- update profile settings;
- invalidate affected UI projection;
- request UI refresh;
- do not touch sync.

Suggested invalidation examples:

- global expansion default changed:
  - invalidate all UI projections;
  - refresh current UI.

- profession override changed:
  - invalidate only that profession projection;
  - invalidate global search/favorites projections if needed;
  - refresh current UI if that profession is active.

- remote BoP output option changed:
  - invalidate all UI projections, because the rule can affect all professions.

## Core/defaults impact

Add profile defaults:

```lua
recipePrefilters = {
    showRemoteBopOutputRecipes = false,

    expansionDefaults = {
        vanilla = true,
        tbc = true,
    },

    professionExpansionOverrides = {
    },
}
```

Schema migration should be non-destructive.

Do not modify:

- members;
- profession blocks;
- recipe ownership;
- sync state;
- fingerprints;
- wire version.

## Diagnostics

Add diagnostics for metadata coverage and filter behavior.

Suggested command:

```text
/rr filters
```

Possible output:

- active global expansion defaults;
- active profession override for current profession;
- remote BoP output visibility;
- number of unresolved metadata entries;
- number of category remediation entries.

Suggested command:

```text
/rr filters unresolved
```

Possible output:

- unresolved recipe key;
- spell ID;
- recipe item ID;
- created item ID;
- profession if known;
- failure reason;
- suggested remediation type.

Suggested command:

```text
/rr filters explain <recipeKey>
```

Possible output:

- recipe metadata;
- expansion;
- category;
- self-only status;
- current-player ownership;
- effective profession filter;
- final pass/fail reason.

Diagnostics must not be noisy by default.

## Manual test scenarios

### Expansion filters

- default settings:
  - Vanilla enabled;
  - TBC enabled;
  - all recipes visible.

- global Vanilla disabled:
  - Vanilla recipes hidden from profession list;
  - Vanilla recipes hidden from search;
  - Vanilla favorites hidden but not removed;
  - TBC recipes remain visible.

- Engineering override:
  - global Vanilla enabled;
  - Engineering custom Vanilla disabled;
  - Engineering shows only TBC;
  - Alchemy still follows global defaults.

### Remote BoP output

- BoP output recipe known only by guildmate:
  - hidden by default.

- same remote BoP output with option enabled:
  - visible.

- BoP output recipe known by current player:
  - always visible.

- non-BoP recipe known by guildmate:
  - visible normally.

### Outputless self-only

- ring enchant known only by guildmate:
  - hidden by default.

- ring enchant known only by guildmate with remote self-only option enabled:
  - visible.

- ring enchant known by current player:
  - always visible.

### Favorites

- favorite a Vanilla recipe;
- disable Vanilla;
- favorite disappears from visible Favorites;
- re-enable Vanilla;
- favorite reappears;
- saved favorite data remains unchanged.

### Global search

- search for a hidden Vanilla recipe:
  - no result.

- re-enable Vanilla:
  - same search returns the recipe.

### AtlasLoot independence

- run addon with AtlasLoot installed;
- record visible recipe list;
- run addon without AtlasLoot installed;
- same config must produce same visible recipe list;
- category/subcategory assignment must remain stable;
- filter results must not change.

### Sync separation

- receive recipes via sync while filters hide them;
- verify they are saved;
- verify fingerprints are unchanged by UI filters;
- disable filters;
- recipes appear without resync.

## Automated tests

### Metadata tests

- generated metadata resolves spell ID to expansion;
- generated metadata resolves spell ID to profession;
- generated metadata resolves spell ID to created item;
- generated metadata resolves spell ID to recipe item;
- generated metadata resolves category/subcategory;
- override corrects generated value;
- unresolved metadata is reported as remediation.

### Filter predicate tests

- Vanilla hidden when disabled;
- TBC visible when enabled;
- profession override beats global defaults;
- inherited profession uses global defaults;
- remote BoP output hidden by default;
- remote BoP output visible when option enabled;
- current-player BoP output always visible;
- outputless self-only remote hidden by default;
- outputless self-only current-player visible;
- unresolved metadata follows conservative V1 policy and logs remediation.

### UI projection tests

- hidden recipes do not enter UI runtime projection;
- hidden recipes are not sorted;
- hidden recipes are not returned by global search;
- hidden favorites are not shown;
- changing Engineering override invalidates Engineering projection only;
- changing global defaults invalidates all UI projections;
- sync indexes are not invalidated by UI filter changes.

### Regression tests

- sync fingerprints unchanged by filter configuration;
- merge behavior unchanged;
- block indexes unchanged;
- saved recipe data unchanged;
- UI works with AtlasLoot absent;
- UI behavior does not change when AtlasLoot is present.

## Migration strategy

### Phase 1 - Internal metadata module

- introduce `RecipeMetadata.lua`;
- introduce generated metadata file;
- introduce overrides file;
- add metadata diagnostics;
- do not change UI behavior yet.

### Phase 2 - Filter options

- add defaults;
- add options UI;
- implement effective global/per-profession expansion visibility;
- implement remote BoP output option;
- add option-change invalidation hooks.

### Phase 3 - UI filter predicate

- implement `RecipeUiFilters`;
- apply predicate in data/catalog list building;
- ensure hidden recipes do not enter UI runtime projection;
- update cache keys.

### Phase 4 - Category/subcategory migration

- move profession categories/subcategories to internal metadata;
- remove AtlasLoot category usage;
- remove runtime category patching based on AtlasLoot;
- validate category output per profession.

### Phase 5 - BoP and outputless self-only handling

- resolve produced item BoP through item API and overrides;
- add outputless self-only metadata;
- test Enchanting ring cases;
- apply current-player ownership rule.

### Phase 6 - AtlasLoot resolver removal

- remove AtlasLoot from resolver call-sites;
- ensure UI behavior is identical with or without AtlasLoot;
- remove AtlasLoot from filter path completely;
- remove `AtlasLootClassic` / `AtlasLoot` from `OptionalDeps` after no call-sites remain.

### Phase 7 - Metadata generator hardening

- improve build-time generator;
- add coverage reports;
- fail or warn on unresolved metadata depending on release mode;
- document remediation workflow.

## Acceptance criteria

The implementation is complete when:

- Vanilla/TBC visibility is configurable globally;
- Vanilla/TBC visibility is configurable per profession;
- per-profession inheritance from global defaults works;
- remote BoP output visibility is configurable;
- current-player BoP output recipes are always visible;
- outputless self-only recipes are handled explicitly;
- filters apply before UI row construction;
- hidden recipes do not enter the UI runtime projection;
- favorites respect filters without deleting saved favorite data;
- global search respects filters;
- sync data remains complete;
- fingerprints and block indexes are unaffected;
- changing filter options does not trigger sync invalidation;
- AtlasLoot is not used as resolver for recipe metadata or categories;
- UI behavior is deterministic with or without AtlasLoot installed;
- unresolved metadata is treated as remediation, not as a user-facing expansion;
- diagnostics exist for unresolved metadata and filter explanations.

## Non-goals

This work does not aim to:

- change guild sync behavior;
- change merge behavior;
- change recipe ownership semantics;
- prune saved recipe data;
- infer account alts;
- expose an `unknown` expansion option;
- add new user-facing recipe counters;
- keep AtlasLoot as a metadata authority;
- create a full general-purpose replacement for every external trade skill library.

The goal is a focused internal metadata system for Recipe Registry’s own UI/catalog needs.
