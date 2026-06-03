# Recipe Registry — Public API for Plugin Addons

**Status:** draft skeleton. The contract is finalized during Phase 0 of `feature/craft-orders-mail-assistant` (see `docs/craft-orders-roadmap.md` §3.6 and §3.8). Methods listed here are the *intended* public surface; any change to internals not on this list is permitted without notice.

## Audience

Plugin addons that ship alongside Recipe Registry and want to consume its data, hooks, or utilities. The first such plugin is `RecipeRegistry_Orders` (Craft Orders). Future plugins (e.g., addon-adoption-status tab) consume the same contract.

## Contract guarantees

1. Methods listed below are stable across **patch** releases of Recipe Registry (e.g., 2.0.5 → 2.0.6). Breaking changes happen only at **minor or major** releases (e.g., 2.0.x → 2.1.0) and are called out in `CHANGELOG.md`.
2. Anything not on this list is internal. Plugins reaching into `_private`, `Sync.peerCaps`, `RecipeRegistryDB.*`, or any module not enumerated here may break at any release.
3. RR will provide a deprecation cycle of at least one minor release before removing or changing a method on this list.
4. RR does not guarantee return-value identity across calls (don't store references and expect them to stay valid past the next refresh).

## Identity and metadata

| Symbol | Description |
|---|---|
| `_G.RecipeRegistry` | Top-level addon object. Existence implies RR is loaded. |
| `RecipeRegistry.ADDON_VERSION` | string, e.g. `"2.0.5"`. |
| `RecipeRegistry.BUILD_CHANNEL` | `"dev"` or `"release"`. Plugins must respect the same channel — a dev plugin must not talk to release peers. |
| `RecipeRegistry.BuildInfo.GetLocalVersionInfo()` | Returns `{ addonVersion, wireVersion, buildChannel, commPrefix, capabilities }`. |

## Recipe and material data (read-only)

| Method | Returns | Notes |
|---|---|---|
| `RecipeRegistry.Data:GetRecipeDisplayInfo(recipeKey)` | table with `reagents`, `createdItemID`, `createdItemName`, `numCreated`, `professionID`, `professionName`, `directEnchant`, etc. | Canonical material lookup. `reagents` is an array of `{ itemID, count, name, icon, quality }`. |
| `RecipeRegistry.Data:GetRecipeCrafters(recipeKey)` | array of crafter rows | Each row: `{ memberKey, profession, skillRank, skillMaxRank, specialization, updatedAt, online }`. |
| `RecipeRegistry.Data:GetCraftersForItem(itemID)` | array of `{ memberKey, profession, online }` | Output-item lookup when the caller doesn't know the recipeKey. |
| `RecipeRegistry.Data:GetRecipeList(profName, query, sortMode, searchMode, categoryName)` | array of recipe rows | For browse-and-pick UIs. Cached and chunked internally. |
| `RecipeRegistry.Data:GetProfessionSummary()` | `{ [profName] = { members, recipes } }` | Per-profession aggregates. |

## Roster

| Method | Returns | Notes |
|---|---|---|
| `RecipeRegistry.Data:GetPlayerKey()` | `"Char-Realm"` string | Canonical local-player identity used across the addon family. |
| `RecipeRegistry.Data:GetGuildMemberMeta(memberKey)` | `{ name, classFile, rankName, rankIndex, level, zone, online, status, ... }` or nil | Cached per guild-roster update cycle. |
| `RecipeRegistry.Data:IsMemberOnline(memberKey)` | bool | Cached. |
| `RecipeRegistry.Data:GetSortedMemberKeys(includeStale)` | array of `"Char-Realm"` strings | User-visible members, sorted. |

> **TODO (Phase 0, depends on `feature/guild-addon-adoption-status`):** add `GetPeerLastSeen(memberKey)` and any "addon-seen" telemetry method that branch defines. Align stale-peer parameters (`KNOWN_OWNER_OFFLINE_STALE_DAYS`) with plugin retention windows. See craft-orders roadmap §3.8.

## Pause policy

Plugins must respect the same combat/instance pause signal RR uses, and register their own Performance categories with it.

| Method | Returns | Notes |
|---|---|---|
| `RecipeRegistry.SyncPausePolicy:IsSensitiveSyncContext()` | bool | True in combat or sensitive instance. |
| `RecipeRegistry.SyncPausePolicy:ShouldPauseHeavyUI()` | bool | Use to gate UI rebuilds during raids/dungeons. |
| `RecipeRegistry.SyncPausePolicy:ShouldPauseProtocolTraffic(kind)` | bool | Use to gate outbound addon messages. |

## Performance scheduler (shared)

The same scheduler runs jobs for all addons. Plugins register their own categories (e.g., `"order-sync-outbound"`) so they can be paused/resumed independently and their queue depth is reported in diagnostics.

| Method | Notes |
|---|---|
| `RecipeRegistry.Performance:ScheduleJob(jobType, fn, opts)` | `opts.category` is required and should be plugin-prefixed (e.g., `"order-*"`). |
| `RecipeRegistry.Performance:PauseCategory(category)` | Idempotent. |
| `RecipeRegistry.Performance:ResumeCategory(category)` | Idempotent. |
| `RecipeRegistry.Performance:HasPendingJobs(category)` | bool. |

## Debug log (optional)

Plugins are expected to keep their own log DB, but RR's `Trace`/`Tracef` is available for cross-addon trace correlation in shared diagnostics dumps.

| Method | Notes |
|---|---|
| `RecipeRegistry:Tracef(scope, fmt, ...)` | `scope` is the trace scope; new scopes must be registered in RR's `DEBUG_LOG_SCOPE_NAMES` before use. |

## UI integration hook

> **STATUS: implemented on `feature/craft-orders-mail-assistant`.** Lives in [`UI/ExternalTabs.lua`](../UI/ExternalTabs.lua) with minimal additive touches to [`UI/MainFrame.lua`](../UI/MainFrame.lua). The "Guild Addons" tab introduced in RR 2.0.6 remains inline; only **new** external tabs go through this hook.

Signature:

```lua
local ok, err = RecipeRegistry.UI:RegisterExternalTab({
    id         = "orders",                     -- unique string; must not start with "ext:" (reserved)
    label      = "Craft Orders",               -- shown on the nav button
    icon       = nil,                          -- optional texture path (reserved for future use)
    build      = function(panel) ... end,      -- called once with a Frame to populate
    onSelect   = function(panel) ... end,      -- called when the tab becomes visible
    onDeselect = function(panel) ... end,      -- called when leaving the tab
})
```

Returns `true` on success, or `nil, <reason>` for validation failures. Reason codes: `invalid-spec`, `missing-id`, `reserved-prefix`, `missing-label`, `invalid-build`, `invalid-onselect`, `invalid-ondeselect`.

Lifecycle:

1. Plugin calls `RegisterExternalTab` during its own `OnEnable` (RR's `Dependencies` ordering guarantees RR's UI module exists by then).
2. RR creates a tab button anchored to the right of the built-in tabs and a full-width panel anchored inside the main frame.
3. The first time the tab is shown, RR calls `build(panel)`. The plugin populates the panel however it likes.
4. On every subsequent activation, RR calls `onSelect(panel)`. On leaving the tab, `onDeselect(panel)`.
5. Re-registration with the same `id` replaces the spec but preserves the existing panel/button (idempotent).
6. Callbacks are invoked under `pcall`; a throw is logged via `Tracef("ui", ...)` but does not crash the host UI.

Query helpers:

```lua
RecipeRegistry.UI:HasExternalTab(id)         -- bool
RecipeRegistry.UI:GetExternalTabSpec(id)     -- spec table or nil
RecipeRegistry.UI:ListExternalTabs()         -- array of ids in registration order
RecipeRegistry.UI:GetExternalTabId()         -- id of the currently active external tab, or nil
RecipeRegistry.UI:IsExternalView()           -- bool
RecipeRegistry.UI:SelectExternalTab(id)      -- programmatic activation
RecipeRegistry.UI:SetExternalTabLabel(id, label) -- rewrite label (badge counter etc.)
```

`SetExternalTabLabel(id, label)` returns `true` on success or `nil, reason` on failure (`"unknown-tab"`, `"missing-id"`, `"missing-label"`). It is the supported way for a plugin to keep a live counter or status in its tab button (e.g. `"Craft Orders (3)"` when there are 3 orders awaiting the local player's action). Idempotent and cheap: an unchanged label short-circuits without touching the underlying button.

Internal view-id encoding: external tab selections are stored in `UI.selectedProfession` with the `ext:` prefix to avoid collisions with profession names or the `ADDON_STATUS_VIEW` sentinel. Plugins should never construct that prefix themselves — use `SelectExternalTab(id)` (raw id, no prefix).

## Per-recipe action hook

> **STATUS: implemented on `feature/craft-orders-mail-assistant`.** Lives in [`UI/RecipeActions.lua`](../UI/RecipeActions.lua) with a single call site inside [`UI/MainFrame.lua`](../UI/MainFrame.lua)'s `RefreshDetailPanel`.

Lets sibling addons add an 18×18 icon button to the recipe detail panel, anchored to the left of the existing favorite button. Multiple actions stack right-to-left in registration order.

Signature:

```lua
local ok, err = RecipeRegistry.UI:RegisterRecipeAction({
    id        = "order",                                -- unique string; required
    label     = "Add to order cart",                    -- tooltip text; required
    icon      = "Interface\\Icons\\INV_Misc_Bag_08",    -- texture path; optional
    onClick   = function(recipeKey, info) ... end,      -- optional
    isVisible = function(recipeKey, info) return ... end, -- optional; default true
    isEnabled = function(recipeKey, info) return ... end, -- optional; default true
})
```

Returns `true` on success, or `nil, <reason>`. Reason codes: `invalid-spec`, `missing-id`, `missing-label`, `invalid-icon`, `invalid-onclick`, `invalid-isvisible`, `invalid-isenabled`.

Lifecycle:

1. Plugin calls `RegisterRecipeAction` during its own `OnEnable`. RR's `RefreshDetailPanel` picks the action up on the next render.
2. When a recipe is selected, RR walks the registered actions in registration order and:
   - Calls `isVisible(recipeKey, info)` if provided. A falsy result hides the button.
   - Realizes/reuses the icon button anchored to the previous action (or the favorite button for the first action).
   - Calls `isEnabled(recipeKey, info)` if provided. A falsy result dims the icon and disables clicks.
3. Click handler receives `(recipeKey, info)` where `info` is the result of `Data:GetRecipeDetail(recipeKey)` (the same structure RR uses internally).
4. Re-registration with the same `id` replaces the spec; the underlying widget is reused so there's no flicker.

Query helpers:

```lua
RecipeRegistry.UI:HasRecipeAction(id)         -- bool
RecipeRegistry.UI:GetRecipeActionSpec(id)     -- spec table or nil
RecipeRegistry.UI:ListRecipeActions()         -- array of ids in registration order
RecipeRegistry.UI:UnregisterRecipeAction(id)  -- removes spec; hides widget; idempotent
```

Callbacks run under `pcall`; a throw is swallowed (the icon stays visible, the click is silently dropped). A future revision may route exceptions to `Tracef("ui", ...)` once Phase 4 emits other kinds of UI-level diagnostics.

## Stability boundary

Plugins **must not**:

- Read from `RecipeRegistryDB.*` directly. Use `Data:*` getters.
- Reach into `Sync.peerCaps`, `Sync.onlineNodes`, `Sync.outboundSeedSession`, `Sync.inboundSeedSessions`, or any session/runtime state in the `Sync` module.
- Reach into `Data._private` (intra-module helpers).
- Call `Data:MarkSyncIndexDirty`, `Data:RefreshSyncBlockRecord`, or any method that mutates recipe sync state.
- Hook RR's slash command handler (`SlashHandler`). Use the plugin's own slash command surface.
- Hook RR's main frame internals (search box, profession tab buttons, etc.). Use `RegisterExternalTab` only.

A grep gate spec (to be added in Phase 0) will fail if any `RecipeRegistry_Orders/*.lua` file references a symbol not on this list.

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
