# AtlasLoot Removal Inventory

Phase: Recipe Metadata Roadmap Phase 5
Reviewed: 2026-05-23

This inventory follows `docs/recipe-metadata-roadmap.md` section 8.1. The Phase 5 scope is not final deletion of the legacy resolver module; it is removal from the new UI projection path while preserving plugin-absent fallback until Phase 9.

| File | Function | Current AtlasLoot usage | Runtime path | Replacement source | Migration action | Test coverage | Status |
|------|----------|--------------------------|--------------|--------------------|------------------|---------------|--------|
| `Data/DataCatalog.lua` | `Data:GetRecipeDisplayInfo` | Resolved spell, created item, recipe item, profession, rank, reagents, direct-enchant state. | List/detail/search projection. | `RecipeRegistry_Metadata.RecipeMetadata` plus direct WoW item/spell APIs for cached names and icons. | Replaced when metadata plugin is present; legacy resolver kept only as plugin-absent fallback through a clearly named `LEGACY_RESOLVER` table. | `atlasloot_projection_parity_spec.lua`, existing catalog specs. | replaced |
| `Data/DataCatalog.lua` | `Data:ResolveRecipeLabel` | Previously checked AtlasLoot presence and returned no resolver data. | List row label fallback. | `RecipeMetadata` first, direct `GetItemInfo` / `GetSpellInfo` second. | Replaced; no projection-path AtlasLoot reference remains. | `atlasloot_call_site_gate_spec.lua`, list projection specs. | replaced |
| `Data/DataCatalog.lua` | `Data:GetRecipeCategory`, `Data:GetRecipeCategories` | Category lookup came from the AtlasLoot category index via `DataAtlasLoot.lua`. | Profession sidebar and category filtering. | `RecipeMetadata:GetCategory` and `RecipeMetadata:GetCategoriesForProfession`. | Replaced when metadata plugin is present; legacy category provider kept only as plugin-absent fallback. | `atlasloot_projection_parity_spec.lua`, `atlas_category_spec.lua`, gate spec. | replaced |
| `UI/MainFrame.lua` | `UI:RefreshProfessionButtons` | Comments and call path referenced the AtlasLoot category index. | UI projection/sidebar. | Existing `Data:GetRecipeCategories`, now metadata-backed when the plugin is installed. | Comments updated; runtime call remains provider-agnostic. | `atlasloot_call_site_gate_spec.lua`, backend suite. | replaced |
| `UI/Tooltip.lua` | `Tooltip:GetRowsForItemID`, `Tooltip:GetRowsForSpellID` | Used AtlasLoot recipe/spell lookups to find alternate recipe keys. | Tooltip projection. | `RecipeMetadata:NormalizeRecipeKey`, `GetCreatedItemId`, `GetRecipeItemId`. | Replaced; no tooltip AtlasLoot fallback remains in Phase 5 because metadata covers the alias mapping. | `atlasloot_call_site_gate_spec.lua`, tooltip specs. | replaced |
| `UI/Options.lua` | category checkbox/help text | User-facing text named AtlasLoot categories. | Options UI. | Metadata-backed category provider. | Text updated to generic metadata categories. | `atlasloot_call_site_gate_spec.lua`, options specs. | replaced |
| `Data/Data.lua` | `Private.isValidRecipeKey` | Negative recipe keys preferred AtlasLoot profession data before spell-subtext fallback. | Recipe index build before UI projection. | `RecipeMetadata:GetRecipeInfo` when plugin is present, then direct WoW spell APIs. | Replaced the validation authority; legacy private Atlas helpers remain only for `DataAtlasLoot.lua`. | Backend suite, projection parity spec. | replaced |
| `Core/Core.lua` | `Addon:OnPlayerLogin` | Scheduled AtlasLoot category-index prewarm. | Login warmup, indirectly affected first UI render. | No replacement needed; metadata category tables are static and cheap. | Removed prewarm. | Syntax and backend suite. | replaced |
| `Core/Core.lua` | slash help and `/rr atlas`, `/rr r`, `/rr s`, `/rr i` command handlers | Legacy resolver diagnostics. | Explicit developer diagnostics, not normal UI projection. | None for Phase 5. | Intentionally kept and labeled as legacy diagnostics until Phase 9. | Slash specs and inventory review. | intentionally kept |
| `Data/DataAtlasLoot.lua` | module functions | Legacy resolver, category index, and diagnostics. | Plugin-absent fallback and explicit diagnostics only. | `RecipeMetadata` for projection when installed. | Intentionally kept outside the projection allowlist until Phase 9 removes or archives it. | `atlas_category_spec.lua`, `catalog_cache_spec.lua`, gate spec excludes this file. | intentionally kept |
| `RecipeRegistry.toc` | load order / optional deps | Still loads `DataAtlasLoot.lua` and may still declare optional AtlasLoot dependencies before Phase 9. | Addon bootstrap, legacy fallback. | Metadata addon is a separate optional addon. | Intentionally kept for Phase 5; final OptionalDeps removal is Phase 9. | Backend suite. | intentionally kept |

## Projection Allowlist

The Phase 5 gate treats these files as the current UI projection allowlist:

- `Data/DataCatalog.lua`
- `UI/MainFrame.lua`
- `UI/Tooltip.lua`
- `UI/Options.lua`

`local-tests/spec/atlasloot_call_site_gate_spec.lua` fails if those files contain direct `AtlasLoot` or `AtlasLootClassic` references.

## Verification Notes

`local-tests/spec/atlasloot_projection_parity_spec.lua` loads `RecipeRegistry_Metadata`, captures list/category/detail projection output with no AtlasLoot global, then repeats with a deliberately contradictory AtlasLoot stub installed. The output must be byte-identical, proving the metadata-backed projection ignores AtlasLoot when present.

Manual Phase 5 review:

- `Data/DataCatalog.lua`, `UI/MainFrame.lua`, `UI/Tooltip.lua`, and `UI/Options.lua` were reviewed as the projection allowlist.
- The projection allowlist contains no direct `AtlasLoot` or `AtlasLootClassic` references.
- Normal list/category/detail/material projection resolves through `RecipeRegistry_Metadata.RecipeMetadata` when the metadata addon is installed.
- Tooltip alternate-key projection resolves through `RecipeMetadata` normalization and item mapping.
- Remaining legacy resolver entry points are limited to plugin-absent fallback or explicit slash diagnostics and are documented in the inventory table above.
