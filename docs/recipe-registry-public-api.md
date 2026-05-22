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

> **STATUS: not yet implemented.** Designed jointly with `feature/guild-addon-adoption-status` per craft-orders roadmap §3.8. This section will be filled in during Phase 0 once the hook signature is agreed.

Expected shape:

```lua
RecipeRegistry.UI:RegisterExternalTab({
    id          = "craft-orders",          -- unique string, used as tab key
    title       = "Orders",                -- shown on the tab button
    icon        = "Interface\\...",        -- optional texture path
    order       = 100,                     -- relative position; profession tabs are ~0-99
    onShow      = function(panel) ... end, -- called when tab becomes visible
    onHide      = function(panel) ... end, -- called when tab becomes hidden
    onRefresh   = function(panel, scopes) end, -- called by RR's deferred refresh path
})
```

Lifecycle:

1. Plugin calls `RegisterExternalTab` during its own `OnEnable`.
2. RR adds the tab to its main frame on next refresh.
3. RR creates the `panel` Frame (parented to the main frame's content area) and passes it to the plugin's callbacks.
4. RR forwards refresh scopes (`"presence"`, `"metadata"`, ...) so the plugin's tab can be selectively rebuilt.

Open questions for Phase 0:

- Does the plugin own the panel's CreateFrame call or does RR?
- Can a plugin register more than one tab?
- How does unregistration work on plugin disable / `/reload`?
- What's the error contract if the callback throws?

## Stability boundary

Plugins **must not**:

- Read from `RecipeRegistryDB.*` directly. Use `Data:*` getters.
- Reach into `Sync.peerCaps`, `Sync.onlineNodes`, `Sync.outboundSeedSession`, `Sync.inboundSeedSessions`, or any session/runtime state in the `Sync` module.
- Reach into `Data._private` (intra-module helpers).
- Call `Data:MarkSyncIndexDirty`, `Data:RefreshSyncBlockRecord`, or any method that mutates recipe sync state.
- Hook RR's slash command handler (`SlashHandler`). Use the plugin's own slash command surface.
- Hook RR's main frame internals (search box, profession tab buttons, etc.). Use `RegisterExternalTab` only.

A grep gate spec (to be added in Phase 0) will fail if any `RecipeRegistry_Orders/*.lua` file references a symbol not on this list.
