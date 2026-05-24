# Recipe Registry Public API

This document describes stable surfaces intended for sibling Recipe Registry addons.

## RecipeMetadata

`RecipeRegistry_Metadata` is a separate addon distributed with Recipe Registry. Recipe Registry declares it as an optional dependency and reads the public API from `_G.RecipeRegistry_Metadata.RecipeMetadata` when the addon is installed.

Identity fields:

- `RecipeRegistry_Metadata.ADDON_VERSION`
- `RecipeRegistry_Metadata.RecipeMetadata.metadataVersion`
- `RecipeRegistry_Metadata.RecipeMetadata.schemaVersion`
- `RecipeRegistry_Metadata.RecipeMetadata.flavor`

Stable lookup contract:

```lua
RecipeMetadata:GetRecipeInfo(recipeKey)                 -- normalized record or nil
RecipeMetadata:NormalizeRecipeKey(recipeKey)            -- normalized key table
RecipeMetadata:GetRecipeExpansion(recipeKey, info)      -- "vanilla", "tbc", or nil
RecipeMetadata:GetProfession(recipeKey, info)           -- canonical profession key or nil
RecipeMetadata:GetCategory(recipeKey, info)             -- { category, subcategory, sortOrder } or nil
RecipeMetadata:GetCategoriesForProfession(profession)   -- ordered category rows
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

The metadata addon is read-only at runtime except for its committed override table. It does not participate in guild sync, does not write SavedVariables, and does not replace Recipe Registry's saved recipe ownership data.

When `RecipeRegistry_Metadata` is absent, Recipe Registry must load cleanly and use conservative visible-all behavior for UI prefilters. AtlasLoot is not part of the public contract and is not consulted as a fallback.
