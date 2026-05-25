# Recipe Registry Public API

This document describes stable surfaces intended for sibling Recipe Registry addons.

## RecipeMetadata

The metadata library is **part of the Recipe Registry addon itself** — it is no longer a separate `RecipeRegistry_Metadata` sibling addon. Consumers reach the public API through `_G.RecipeRegistry.RecipeMetadata`.

For the TBC `2.5.5` data flavor, metadata records cover both supported recipe
expansions: `vanilla` and `tbc`. A release-candidate dataset must not omit
Vanilla recipes just because the runtime client is TBC.

Identity fields:

- `RecipeRegistry.RecipeMetadata.metadataVersion` — data snapshot version (e.g. `2026.05.23.2`)
- `RecipeRegistry.RecipeMetadata.schemaVersion` — runtime schema version
- `RecipeRegistry.RecipeMetadata.flavor` — `"tbc"`

Stable lookup contract:

```lua
RecipeMetadata:GetRecipeInfo(recipeKey)                 -- normalized record or nil
RecipeMetadata:NormalizeRecipeKey(recipeKey)            -- normalized key table
RecipeMetadata:GetRecipeExpansion(recipeKey, info)      -- "vanilla", "tbc", or nil
RecipeMetadata:GetProfession(recipeKey, info)           -- canonical profession key or nil
RecipeMetadata:GetCategory(recipeKey, info)             -- { category, subcategory, sortOrder } or nil
RecipeMetadata:GetCategoriesForProfession(profession)   -- ordered category rows with cloned subcategories
RecipeMetadata:GetSubcategoriesForProfession(profession, category)
RecipeMetadata:GetCreatedItemId(recipeKey, info)        -- item id or nil
RecipeMetadata:GetRecipeItemId(recipeKey, info)         -- recipe item id or nil
RecipeMetadata:GetReagents(recipeKey, info)             -- cloned reagent rows or nil
RecipeMetadata:IsOutputlessSelfOnly(recipeKey, info)    -- boolean
RecipeMetadata:IsBopOutput(recipeKey, info)             -- true, false, or nil when unknown
RecipeMetadata:GetMetadataResolutionStatus(recipeKey, info)
RecipeMetadata:GetUnresolvedRecords(severity)
RecipeMetadata:GetRecordCounts()
```

`recipeKey` accepts Recipe Registry's stored key shape: negative spell IDs for spell-based crafts and positive item IDs for item-based recipe entries. `info` is optional for all helper lookups; callers may pass a record returned by `GetRecipeInfo` to avoid a second lookup.

Category rows have stable `key`, user-facing `label`, numeric `order`, and optional `subcategories` rows with the same `key` / `label` / `order` shape. Recipe Registry uses these rows for UI navigation; callers should store keys, not labels.

The metadata library is read-only at runtime except for its committed override table. It does not participate in guild sync, does not write SavedVariables, and does not replace Recipe Registry's saved recipe ownership data.

Since the library now lives inside the RR addon, it is always available when Recipe Registry is loaded. The defensive `if not Addon.RecipeMetadata then ...` guards in consumer code only fire if the metadata Lua files fail to load for an unexpected reason; they no longer represent a "plugin not installed" scenario. AtlasLoot is not part of the public contract and is not consulted as a fallback.
