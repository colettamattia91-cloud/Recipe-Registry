# Recipe Registry Public API

This document describes stable surfaces intended for sibling Recipe Registry addons.

## RecipeMetadata

`RecipeRegistry_Metadata` exposes its public API on `_G.RecipeRegistry_Metadata.RecipeMetadata`.
The metadata addon is distributed as a separate addon in the same CurseForge project as Recipe Registry.

Identity fields:

- `RecipeRegistry_Metadata.ADDON_VERSION`
- `RecipeRegistry_Metadata.RecipeMetadata.metadataVersion`
- `RecipeRegistry_Metadata.RecipeMetadata.schemaVersion`
- `RecipeRegistry_Metadata.RecipeMetadata.flavor`

Runtime lookup contract planned for the metadata API:

```lua
RecipeMetadata:GetRecipeInfo(recipeKey)
RecipeMetadata:NormalizeRecipeKey(recipeKey)
RecipeMetadata:GetRecipeExpansion(recipeKey, info)
RecipeMetadata:GetProfession(recipeKey, info)
RecipeMetadata:GetCategory(recipeKey, info)
RecipeMetadata:GetCreatedItemId(recipeKey, info)
RecipeMetadata:GetRecipeItemId(recipeKey, info)
RecipeMetadata:GetReagents(recipeKey, info)
RecipeMetadata:IsOutputlessSelfOnly(recipeKey, info)
RecipeMetadata:IsBopOutput(recipeKey, info)
RecipeMetadata:GetMetadataResolutionStatus(recipeKey, info)
RecipeMetadata:GetUnresolvedRecords(severity)
RecipeMetadata:GetRecordCounts()
```

Phase 0 provides the addon scaffold, generated sample table, runtime override container, and diagnostics count surface. The full lookup method set is implemented in the next roadmap phase.
