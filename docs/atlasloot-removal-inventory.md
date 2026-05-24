# AtlasLoot Removal Inventory

Phase: Recipe Metadata Roadmap Phase 5; updated for Phase 9
Reviewed: 2026-05-23; Phase 8 category review 2026-05-24; Phase 9 final removal 2026-05-24

This inventory follows `docs/recipe-metadata-roadmap.md` section 8.1. Phase 9 completed final deletion of the legacy resolver module and removed AtlasLoot from Recipe Registry's loaded runtime surface.

| File | Function | Current AtlasLoot usage | Runtime path | Replacement source | Migration action | Test coverage | Status |
|------|----------|--------------------------|--------------|--------------------|------------------|---------------|--------|
| `Data/DataCatalog.lua` | `Data:GetRecipeDisplayInfo` | Formerly resolved spell, created item, recipe item, profession, rank, reagents, direct-enchant state. | List/detail/search projection. | `RecipeRegistry_Metadata.RecipeMetadata` plus direct WoW item/spell APIs for cached names and icons. | Legacy resolver removed; plugin-absent behavior keeps conservative direct item/spell labels and no external resolver fallback. | `atlasloot_projection_parity_spec.lua`, existing catalog specs. | removed |
| `Data/DataCatalog.lua` | `Data:ResolveRecipeLabel` | Previously checked AtlasLoot presence and returned no resolver data. | List row label fallback. | `RecipeMetadata` first, direct `GetItemInfo` / `GetSpellInfo` second. | Replaced; no projection-path AtlasLoot reference remains. | `atlasloot_call_site_gate_spec.lua`, list projection specs. | replaced |
| `Data/DataCatalog.lua` | `Data:GetRecipeCategory`, `Data:GetRecipeCategories` | Category lookup came from the AtlasLoot category index via `DataAtlasLoot.lua`. | Profession sidebar and category filtering. | `RecipeMetadata:GetCategory` and `RecipeMetadata:GetCategoriesForProfession`. | Legacy category fallback removed; plugin-absent category list is empty and all-recipes navigation remains available. | `category_metadata_navigation_spec.lua`, `atlasloot_projection_parity_spec.lua`, gate spec. | removed |
| `UI/MainFrame.lua` | `UI:RefreshProfessionButtons` | Comments and call path referenced the AtlasLoot category index. | UI projection/sidebar. | Existing `Data:GetRecipeCategories`, now metadata-backed when the plugin is installed. | Comments updated; runtime call remains provider-agnostic. | `atlasloot_call_site_gate_spec.lua`, backend suite. | replaced |
| `UI/Tooltip.lua` | `Tooltip:GetRowsForItemID`, `Tooltip:GetRowsForSpellID` | Used AtlasLoot recipe/spell lookups to find alternate recipe keys. | Tooltip projection. | `RecipeMetadata:NormalizeRecipeKey`, `GetCreatedItemId`, `GetRecipeItemId`. | Replaced; no tooltip AtlasLoot fallback remains in Phase 5 because metadata covers the alias mapping. | `atlasloot_call_site_gate_spec.lua`, tooltip specs. | replaced |
| `UI/Options.lua` | category checkbox/help text | User-facing text named AtlasLoot categories. | Options UI. | Metadata-backed category provider. | Text updated to generic metadata categories. | `atlasloot_call_site_gate_spec.lua`, options specs. | replaced |
| `Data/Data.lua` | `Private.isValidRecipeKey` | Negative recipe keys preferred AtlasLoot profession data before spell-subtext fallback. | Recipe index build before UI projection. | `RecipeMetadata:GetRecipeInfo` when plugin is present, then direct WoW spell APIs. | Legacy private Atlas helpers removed. | Backend suite, projection parity spec. | removed |
| `Core/Core.lua` | `Addon:OnPlayerLogin` | Scheduled AtlasLoot category-index prewarm. | Login warmup, indirectly affected first UI render. | No replacement needed; metadata category tables are static and cheap. | Removed prewarm. | Syntax and backend suite. | replaced |
| `Core/Core.lua` | slash help and `/rr atlas`, `/rr r`, `/rr s`, `/rr i` command handlers | Legacy resolver diagnostics. | Explicit developer diagnostics. | `/rr filters`, `/rr filters unresolved`, `/rr filters explain <recipeKey>`. | Legacy commands removed. | `slash_output_spec.lua`, backend suite. | removed |
| `Data/DataAtlasLoot.lua` | module functions | Legacy resolver, category index, and diagnostics. | Former plugin-absent fallback and explicit diagnostics. | `RecipeMetadata` plus direct WoW item/spell APIs. | File deleted in Phase 9. | `atlasloot_call_site_gate_spec.lua`. | removed |
| `RecipeRegistry.toc` | load order / optional deps | Loaded `DataAtlasLoot.lua` and declared optional AtlasLoot dependencies before Phase 9. | Addon bootstrap. | Metadata addon is a separate optional addon. | AtlasLoot optional dependencies removed; `DataAtlasLoot.lua` no longer loads. | Backend suite, syntax, gate spec. | removed |

## Release Runtime Surface

The Phase 9 gate reads `RecipeRegistry.toc` and fails if any loaded runtime Lua file or the TOC itself contains an AtlasLoot reference. `Data/DataAtlasLoot.lua` was deleted rather than archived.

## Verification Notes

`local-tests/spec/atlasloot_projection_parity_spec.lua` loads `RecipeRegistry_Metadata`, captures list/category/detail projection output with no AtlasLoot global, then repeats with a deliberately contradictory AtlasLoot stub installed. The output must be byte-identical, proving the metadata-backed projection ignores AtlasLoot when present.

Phase 8 category verification:

- `Data:GetRecipeCategory` and `Data:GetRecipeCategories` were reviewed on 2026-05-24. With `RecipeRegistry_Metadata` installed, both functions resolve exclusively from `RecipeMetadata:GetCategory` / `RecipeMetadata:GetCategoriesForProfession`; the legacy AtlasLoot category provider is reachable only when the metadata addon is absent.
- `local-tests/spec/category_metadata_navigation_spec.lua` exercises every supported v1 profession with AtlasLoot absent and verifies category filtering covers the same recipes as the All view.
- The same spec replaces the AtlasLoot category index and ItemDB entry points with throwing stubs while metadata is installed; category lookup, category list, and category-filtered recipe list still succeed. This is the Phase 8 evidence for zero AtlasLoot category lookups in the new path.

Manual Phase 5 review:

- `Data/DataCatalog.lua`, `UI/MainFrame.lua`, `UI/Tooltip.lua`, and `UI/Options.lua` were reviewed as the projection allowlist.
- The projection allowlist contains no direct `AtlasLoot` or `AtlasLootClassic` references.
- Normal list/category/detail/material projection resolves through `RecipeRegistry_Metadata.RecipeMetadata` when the metadata addon is installed.
- Tooltip alternate-key projection resolves through `RecipeMetadata` normalization and item mapping.
- Phase 9 final removal deleted the legacy resolver module, removed AtlasLoot optional dependencies, removed explicit legacy slash diagnostics, and broadened `atlasloot_call_site_gate_spec.lua` from the projection allowlist to the release runtime surface loaded by `RecipeRegistry.toc`.
