# Craft Orders & Mail Assistant — Roadmap

Branch: `feature/craft-orders-mail-assistant` (forked from `develop`).
Source requirement: [`docs/Craft Orders & Mail Assistant - roadmap.md`](Craft%20Orders%20%26%20Mail%20Assistant%20-%20roadmap.md).
Owner of this doc: the implementation plan for the feature. The source requirement document is the authoritative spec; this doc translates it into a concrete plan grounded in the actual codebase.

This roadmap is the working plan. It must not be overwritten without a follow-up commit explaining what changed and why.

**Distribution model (decided 2026-05-22):** Craft Orders ships as a **separate addon** (`RecipeRegistry_Orders`) inside the **same git repo** and the **same CurseForge project** as Recipe Registry. Both addon folders are produced from one ZIP at package time (AtlasLoot pattern). The CurseForge release cadence is coordinated: any tag bumps both addons together. Independent CurseForge release cycles (separate project, separate version stream) are deferred until Craft Orders reaches stability — see §3.8 for the migration trigger. See §3.5 and §11 Phase 0 for the repo restructure work this implies.

---

## 1. Scope and constraints

A Craft Orders subsystem that lets guild members create craft requests, ship materials by mail, track receipt, deliver outputs, and cancel with material return. Best-effort coordination, not an escrow.

**Hard constraints inherited from the source spec** (sections 5, 29):

- Logically independent from recipe sync. Separate prefix, separate event log, separate runtime state, separate cache lifecycle.
- Must not invalidate recipe `blockFingerprint`/`globalFingerprint` from order activity.
- No gold/COD/automatic-mailing in v1.
- No silent destructive actions.
- Postal is optional; OpenAll/QuickAttach must not produce false negatives.
- Lua 5.1, TBC 2.5.x API only.

**Hard constraints inherited from the existing repo:**

- AceAddon-3.0 module pattern. New modules go through `Addon:NewModule(...)`.
- Wire protocol versioning lives in [`Core/BuildInfo.lua`](../Core/BuildInfo.lua). Dev vs release isolation is enforced via comm prefix — the order protocol must respect the same `BUILD_CHANNEL` split (dev clients only talk to dev clients).
- Sync pause policy ([`Sync/SyncPausePolicy.lua`](../Sync/SyncPausePolicy.lua)) pauses categories like `sync-outbound`, `sync-inbound`, `ui` in combat/instances; the order subsystem must register its own categories with that policy so it's silent in raids/instances/BG/arena.
- Persistent storage uses AceDB-3.0; current schema lives in [`Data/Data.lua` `DB_DEFAULTS`](../Data/Data.lua#L49).

---

## 2. Architecture review — what already exists

Findings from reading the codebase on `feature/craft-orders-mail-assistant` (base: `develop`):

### Recipe and material data
- [`Data/DataCatalog.lua`](../Data/DataCatalog.lua) → `Data:GetRecipeDisplayInfo(recipeKey)` returns full per-recipe info including `reagents` (array of `{ itemID, count, name, icon, quality }`), `createdItemID`, `numCreated`, `professionID/Name`, `directEnchant`. This is the canonical material lookup the order planner will call.
- [`Data:GetRecipeCrafters(recipeKey)`](../Data/DataCatalog.lua#L945) returns the known crafters for a recipe with `memberKey`, `profession`, `skillRank`, `skillMaxRank`, `specialization`, `online`. This is the canonical crafter-selection source for an order line.
- [`Data:GetCraftersForItem(itemID)`](../Data/DataCatalog.lua#L211) is an output-item lookup. Useful when the requester only knows what they want produced, not which recipe.
- AtlasLoot integration ([`Data/DataAtlasLoot.lua`](../Data/DataAtlasLoot.lua)) is optional; reagents come through `GetRecipeDisplayInfo` so the order planner does not need to call AtlasLoot directly.

### Generic infrastructure that the order subsystem reuses
Allowed reuse per source spec §5:

| Infrastructure | Path | Reuse |
|---|---|---|
| Wire codec (AceSerializer + LibDeflate framing) | [`Sync/SyncCodec.lua`](../Sync/SyncCodec.lua) (`Sync:EncodeWirePayload` / `Sync:DecodeWirePayload`) | Logic is generic; will be extracted into a shared helper or duplicated minimally. See §3.4 below. |
| Pause policy (combat/instance gating) | [`Sync/SyncPausePolicy.lua`](../Sync/SyncPausePolicy.lua) (`ShouldPauseProtocolTraffic`, `ShouldPauseHeavyUI`, `IsSensitiveSyncContext`) | Order subsystem registers its own Performance categories with the same policy. |
| Performance scheduler | [`Core/Performance.lua`](../Core/Performance.lua) (`Addon.Performance:ScheduleJob`, `PauseCategory`, `ResumeCategory`) | Order subsystem schedules its own jobs under new category names (e.g., `order-sync-outbound`, `order-sync-inbound`). |
| Debug log + traces | [`Core/Core.lua`](../Core/Core.lua) (`Addon:Trace`, `Addon:Tracef`, `Addon:WriteDebugLog`) | New trace scope: `orders` (must be added to `DEBUG_LOG_DEFAULTS.scopes` and `DEBUG_LOG_SCOPE_NAMES`). |
| Roster meta + online cache | [`Data/Data.lua`](../Data/Data.lua) (`Data:GetGuildMemberMeta`, `Data:IsMemberOnline`, `Data:GetPlayerKey`) | Crafter resolution & whisper-target derivation. |
| BuildInfo dev/release split | [`Core/BuildInfo.lua`](../Core/BuildInfo.lua) (`Addon.COMM_PREFIX`, `Addon.BUILD_CHANNEL`) | Order protocol prefix derives from the same channel. |

### Not reusable / explicitly forbidden
- Recipe `Sync.lua` state machine (HELLO/SUMMARY/INDEX_DIFF/BLOCK_PULL/BLOCK_SNAPSHOT) — independent protocol.
- `MergeEngine.lua` — content-only additive merge for recipes; orders use an event-log reducer instead.
- `DataIndex.lua` block/global fingerprint lifecycle — orders never touch this.
- `Sync` module's `peerCaps`, `onlineNodes`, `outboundSeedSession`, `inboundSeedSessions` — separate ownership.

### Mailbox APIs — unknown, needs validation
Nothing in the current codebase touches the mailbox. The full Mailbox API surface (`MAIL_SHOW`/`MAIL_INBOX_UPDATE` events, `SendMail`, `ClickSendMailItemButton`, `GetInboxText`, `GetInboxItemLink`, attachment limits) is unverified for TBC Classic 2.5.x in this repo. This is Phase 0 work.

### UI conventions
- Single main frame built lazily on enable ([`Core/Core.lua:393-396`](../Core/Core.lua#L393-L396)).
- Profession tabs are listed in [`UI/MainFrame.lua` `PROF_ORDER`](../UI/MainFrame.lua#L9) — adding an "Orders" tab is the least invasive UI placement (decision deferred to §10).
- Minimap button: [`UI/MinimapButton.lua`](../UI/MinimapButton.lua).
- AceGUI is loaded but the main frame is hand-built with `CreateFrame`. Order UI should match this style.
- Options panel: [`UI/Options.lua`](../UI/Options.lua), AceGUI-3.0.

### Test harness
- Plain Lua 5.1 specs under [`local-tests/spec/`](../local-tests/spec/).
- [`local-tests/harness/load-addon.lua`](../local-tests/harness/load-addon.lua) loads backend files; [`local-tests/harness/wow.lua`](../local-tests/harness/wow.lua) mocks the WoW API; [`local-tests/harness/comm-bus.lua`](../local-tests/harness/comm-bus.lua) intercepts addon comms.
- **Blocker**: `Loader.BackendFiles` at [load-addon.lua:11](../local-tests/harness/load-addon.lua#L11) still expects flat paths (e.g., `"Core.lua"`), but the recent reorg (commit `d16fef4`) moved sources into `Core/`, `Data/`, `Sync/`, `UI/`, `Integrations/`. Tests likely fail until this is reconciled. Two options: update `BackendFiles` to use subdir paths, or fix at the spec file callsites. **Open question §13.**
- WoW mock has no mailbox simulation yet — must be added before Phase 2 specs.

---

## 3. Proposed module layout

Craft Orders ships as `RecipeRegistry_Orders`, a separate WoW addon with its own TOC, its own SavedVariables, and its own embedded libs. It declares Recipe Registry as a hard dependency and consumes a small public API surface on the `_G.RecipeRegistry` table (§3.6).

All new sources live under `RecipeRegistry_Orders/`. The naming style inside that folder matches the existing `Sync*.lua` / `Data*.lua` patterns.

```
RecipeRegistry_Orders/
  RecipeRegistry_Orders.toc      -- ## Dependencies: RecipeRegistry
  Libs/embeds.xml                -- embedded libraries (see §3.4)
  Libs/...
  Core/CraftOrders.lua           -- AceAddon module skeleton, slash registration
  Core/Performance.lua?          -- (not needed — reuses RR's Performance scheduler)
  Store/CraftOrdersStore.lua     -- AceDB-backed store: orders, ledger, event log
  Store/CraftOrdersStateMachine.lua -- Lifecycle states + transition rules + actor authorization
  Planner/CraftOrdersPlanner.lua -- Material aggregation across order lines (calls RR public API)
  Mail/CraftOrdersMailAssistant.lua -- Outgoing: subject/body/attachment prep, batch split, send tracking
  Mail/CraftOrdersMailScanner.lua   -- Incoming: parse inbox for RR markers, record receipts, build replies
  Mail/CraftOrdersPostalCompat.lua  -- Postal/QuickAttach detection, early-scan, assumed-receipt fallback
  Sync/CraftOrdersProtocol.lua   -- Wire dispatch (HELLO_ORDERS, SUMMARY_ORDERS, EVENTS_REQUEST/RESPONSE)
  Sync/CraftOrdersRuntime.lua    -- Peer tracking, pacing, backoff, pause integration, scheduled HELLO
  UI/CraftOrdersBoard.lua        -- Board UI (registered as an RR tab via public hook — see §10)
  Diagnostics/CraftOrdersDiagnostics.lua -- Observability: peer state, event log stats, mail scan stats
```

### 3.1 RecipeRegistry_Orders.toc

```
## Interface: 20505
## Title: Recipe Registry — Craft Orders
## Notes: Guild craft order board with mail-assisted material and delivery flow
## Author: Mattia
## Version: 0.1.0
## X-Build-Channel: dev
## X-Build-ID: dev
## Dependencies: RecipeRegistry
## SavedVariables: RecipeRegistry_OrdersDB,RecipeRegistry_OrdersLogDB
## SavedVariablesPerCharacter: RecipeRegistry_OrdersCharDB
## X-Category: Guild

Libs\embeds.xml

Core\CraftOrders.lua
Store\CraftOrdersStore.lua
Store\CraftOrdersStateMachine.lua
Planner\CraftOrdersPlanner.lua
Mail\CraftOrdersMailAssistant.lua
Mail\CraftOrdersMailScanner.lua
Mail\CraftOrdersPostalCompat.lua
Sync\CraftOrdersProtocol.lua
Sync\CraftOrdersRuntime.lua
UI\CraftOrdersBoard.lua
Diagnostics\CraftOrdersDiagnostics.lua
```

`## Dependencies: RecipeRegistry` (hard) guarantees load order: RR's `OnInitialize` runs before any `RecipeRegistry_Orders` file is parsed. The plugin can therefore safely assume `_G.RecipeRegistry`, `Addon.Data`, `Addon.SyncPausePolicy`, `Addon.Performance` exist at module load time.

### 3.2 SavedVariables (separate from RR)

```
RecipeRegistry_OrdersDB.global = {
  schemaVersion   = 1,
  orders          = { [orderId] = orderRecord },
  ledger          = { [orderId] = ledgerRecord },
  events          = {                       -- append-only event log
    seq           = 0,
    log           = { ... },                -- array of event objects, pruned by retention
    tombstones    = { [orderId] = { at = ts, reason = ... } },
  },
  peers           = { ... },                -- compact per-peer high-water-mark state
  options         = { ... },                -- retention windows, assumed-receipt grace, etc.
}

RecipeRegistry_OrdersCharDB = {
  drafts          = { ... },                -- per-character unsent drafts
}

RecipeRegistry_OrdersLogDB = {              -- debug log ring buffer, same shape as RecipeRegistryLogDB
  enabled = false, entries = {}, ...
}
```

Recipe Registry's `RecipeRegistryDB` is **never** touched by the plugin. Corruption blast radius stays per-addon.

### 3.3 Slash command

The plugin registers its own slash, not a subcommand of `/rr`:

```
/rrord                     -- toggle board
/rrord new                 -- start draft
/rrord status [id]         -- show order(s)
/rrord diag                -- diagnostics dump
/rrord debug [log ...]     -- mirror of /rr debug for the plugin's own log
```

Rationale: a separate addon should not silently extend another addon's slash surface. Users disabling RecipeRegistry_Orders should not see `/rr orders` go dead while `/rr` still works.

Optional convenience: RR's `/rr` slash handler can detect the plugin and add a one-line hint (`Craft orders available via /rrord`) to its help output. No hard coupling — it's an `if Addon.OrdersBridge then` check.

### 3.4 Library embedding

Two options for the libs the plugin needs (`AceAddon-3.0`, `AceEvent-3.0`, `AceTimer-3.0`, `AceConsole-3.0`, `AceComm-3.0`, `AceDB-3.0`, `AceSerializer-3.0`, `AceBucket-3.0`, `AceGUI-3.0`, `LibDeflate`, `LibStub`, `CallbackHandler-1.0`):

**A. Embed in plugin's own `Libs/`** (safe, ~700 KB extra in the ZIP). Each LibStub-registered library short-circuits if a newer version is already loaded by RR, so duplication has no runtime cost — only download size.

**B. Skip embedding, rely on RR's libs via LibStub.** Lighter ZIP, but if RR ever drops a lib the plugin breaks. Tightens the cross-addon contract beyond the public API listed in §3.6.

**Recommendation: A**. The disk cost is negligible and it keeps the plugin's contract with RR limited to the explicit public API.

### 3.5 Repo packaging structure

**CurseForge integration constraint (verified 2026-05-22):** the repo currently uses CurseForge's native GitHub integration, which only supports "build on every commit" or "build on every tag" with no tag pattern filtering. A single CurseForge project is therefore the only feasible model without migrating off the native integration. See §3.8 for the future migration trigger.

Current repo layout has `RecipeRegistry.toc` at root and `package-as: RecipeRegistry` in [`.pkgmeta`](../.pkgmeta). To ship two addons from one repo we restructure into addon-folder-per-subdirectory:

```
repo-root/                                 (git root, NOT a WoW addon)
  .pkgmeta                                 (updated)
  CHANGELOG.md
  README.md
  CLAUDE.md
  .gitignore
  .claude/
  docs/                                    (excluded from package)
  local-tests/                             (excluded from package)
  RecipeRegistry/                          (addon 1 — current root contents moved here)
    RecipeRegistry.toc
    Core/
    Data/
    Sync/
    UI/
    Integrations/
    Libs/
  RecipeRegistry_Orders/                   (addon 2 — new)
    RecipeRegistry_Orders.toc
    Libs/
    Core/, Store/, Planner/, Mail/, Sync/, UI/, Diagnostics/
```

Updated `.pkgmeta` (sketch — to be validated against BigWigs Packager docs in Phase 0):

```yaml
package-as: RecipeRegistry
manual-changelog:
  filename: CHANGELOG.md
  markup-type: markdown
ignore:
  - .claude
  - .gitignore
  - CLAUDE.md
  - docs
  - local-tests
  - RecipeRegistry_Orders                  # exclude from the main addon's folder copy
move-folders:
  RecipeRegistry/RecipeRegistry_Orders: RecipeRegistry_Orders
```

The `move-folders` directive (or equivalent — exact syntax to verify in Phase 0) hoists the plugin folder out as a sibling addon in the packaged ZIP. Both addons end up at the top level of the release ZIP.

**Dev workflow:** symlink (or use `mklink /D` on Windows) two entries into WoW's AddOns directory:
```
WoW\Interface\AddOns\RecipeRegistry        → repo-root\RecipeRegistry\
WoW\Interface\AddOns\RecipeRegistry_Orders → repo-root\RecipeRegistry_Orders\
```

A small `scripts/dev-link.ps1` helper script will be added in Phase 0 to automate the symlink creation.

**Versioning model under single CurseForge project:**
- `RecipeRegistry/RecipeRegistry.toc` `## Version` is the **CurseForge-visible** version — what users see on the project page, in update notifications, in `_G.GetAddOnMetadata("RecipeRegistry", "Version")`.
- `RecipeRegistry_Orders/RecipeRegistry_Orders.toc` `## Version` is the **plugin-internal** version — visible in WoW's addon list and consumed by the plugin's own diagnostics, but not surfaced on CurseForge.
- Tags follow RR's existing scheme (no prefix). Every tag releases both addons together. Even an Orders-only bugfix bumps RR's CurseForge version cosmetically — accepted trade-off (see §3.8).
- CHANGELOG.md stays at repo root and uses sections per addon, e.g.:
  ```
  ## 2.1.0 — 2026-06-15

  ### RecipeRegistry (no functional changes)

  ### RecipeRegistry_Orders 0.2.0
  - Added cancellation flow
  - Fixed inbox scanner double-counting on Postal pre-loot
  ```

**Migration concerns:**
- The `local-tests/` harness needs path updates ([`Loader.BackendFiles`](../local-tests/harness/load-addon.lua#L11) — currently broken anyway, see §2 and §13.1).
- The existing [`.pkgmeta`](../.pkgmeta) `ignore: Sync/MockSync.lua` line moves to `RecipeRegistry/Sync/MockSync.lua`.

### 3.6 Public API contract (RecipeRegistry → RecipeRegistry_Orders)

The plugin **only** consumes methods listed below. Anything else is internal to RR and may break without notice. RR must keep this surface stable; breaking changes require a deprecation cycle and a coordinated version bump in both TOCs.

Initial v1 surface (to be hardened in Phase 0):

```
-- Identity
RecipeRegistry.ADDON_VERSION                       -- string
RecipeRegistry.BUILD_CHANNEL                       -- "dev" | "release"
RecipeRegistry.BuildInfo.GetLocalVersionInfo()     -- table

-- Recipe lookup (read-only)
RecipeRegistry.Data:GetRecipeDisplayInfo(recipeKey)  -- table with reagents, createdItemID, ...
RecipeRegistry.Data:GetRecipeCrafters(recipeKey)     -- array of crafter rows
RecipeRegistry.Data:GetCraftersForItem(itemID)       -- array of crafter rows by output item
RecipeRegistry.Data:GetRecipeList(profName, query, sortMode, searchMode, categoryName)
                                                     -- optional; for browse-and-pick UI

-- Roster
RecipeRegistry.Data:GetPlayerKey()                   -- "Char-Realm"
RecipeRegistry.Data:GetGuildMemberMeta(memberKey)    -- { name, classFile, rankName, online, ... }
RecipeRegistry.Data:IsMemberOnline(memberKey)        -- bool

-- Pause policy (the plugin registers its own Performance categories,
-- but reads the same overall pause signal)
RecipeRegistry.SyncPausePolicy:IsSensitiveSyncContext()  -- bool
RecipeRegistry.SyncPausePolicy:ShouldPauseHeavyUI()      -- bool

-- Scheduler (shared budget pool)
RecipeRegistry.Performance:ScheduleJob(jobType, fn, opts)
RecipeRegistry.Performance:PauseCategory(category)
RecipeRegistry.Performance:ResumeCategory(category)

-- Debug log (the plugin gets its own log DB but can mirror traces)
RecipeRegistry:Tracef(scope, fmt, ...)              -- optional convenience

-- UI integration hook (NEW — see §10)
RecipeRegistry.UI:RegisterExternalTab(spec)         -- to be designed in Phase 3
```

The plugin must never reach into `RecipeRegistry.Data._private`, `RecipeRegistry.Sync.*` internals, `RecipeRegistryDB.*`, or any module not listed above.

### 3.7 Codec reuse

The plugin embeds AceSerializer + LibDeflate in its own `Libs/`. It implements its own thin codec rather than calling `RecipeRegistry.Sync:EncodeWirePayload` — keeps the public API surface smaller and avoids cross-addon coupling on a method that conceptually belongs to the recipe sync. The actual implementation can be copy-pasted from [`Sync/SyncCodec.lua`](../Sync/SyncCodec.lua) (~120 lines, no external deps beyond the libs).

### 3.8 Future migration to separate CurseForge projects

The current single-project model accepts that every release bumps both addons. This is fine while Craft Orders is in active development (Phase 0-8 in §11) because:

- API changes between RR and the plugin will land in coordinated commits and want to ship together.
- Frequent plugin iterations mean the cosmetic "RR updated" notifications are unavoidable noise either way.
- Coordinated releases are easier to support and debug ("which version pair are you on?").

**Migration trigger** — split into two CurseForge projects (one repo still) when **all** of these hold:

1. Craft Orders has shipped a stable `1.0.0` release (post Phase 8).
2. The public API contract in §3.6 has been frozen for at least one minor RR release cycle.
3. The plugin's release cadence has visibly diverged from RR's (e.g., Orders ships 3+ patches between two RR releases).

**Migration path** when the trigger fires:

1. Disconnect CurseForge's native GitHub integration on the RR project.
2. Add `.github/workflows/release.yml` using `BigWigsMods/packager` action.
3. Tag prefixes: `rr/v*` triggers the RR job, `orders/v*` triggers the Orders job.
4. Create a second CurseForge project ("Recipe Registry — Craft Orders"), configure its own API key.
5. Update each addon's `.pkgmeta` (or use one per subdirectory) to restrict packaging scope.
6. Document the migration in `CHANGELOG.md` and on both CurseForge project pages.

This is a one-time investment (~half a day) deferred until the benefit (independent versioning) is worth the cost. Until then, the single-project model holds.

---

## 4. Data model (draft)

### 4.1 Order record

```lua
order = {
  id              = "rr-ord-<timestamp>-<random>",   -- locally generated, globally unique
  schemaVersion   = 1,
  requester       = "Char-Realm",
  crafter         = "Char-Realm",
  createdAt       = <epoch>,
  updatedAt       = <epoch>,
  status          = "draft",                         -- see §5
  deliveryMode    = "mail"|"manual"|"service"|"unsupported",
  lines           = {
    { recipeKey = <int>, outputItemID = <int>, quantity = <int>, recipeLabel = <string> },
    ...
  },
  materials       = {
    -- Aggregated, deduped by itemID. Computed by Planner, refreshed if lines change.
    [itemID] = {
      itemID      = <int>,
      required    = <int>,           -- total quantity
      requesterProvided = <int>,     -- portion shipped by requester
      crafterProvided   = <int>,     -- portion supplied by crafter (excluded from mail)
      mailable    = <bool>,
      excluded    = <bool>,          -- non-mailable or service-only
    },
  },
  batches         = {
    -- Plan computed by MailAssistant; updated as the requester sends.
    { batchNumber = 1, totalBatches = N, items = { { itemID=..., count=... }, ... }, sentAt = nil|ts },
    ...
  },
  notes           = "",                              -- free-text (requester or crafter)
  expiresAt       = nil,                             -- set when transitioning to a terminal-bound state
}
```

### 4.2 Material receipt ledger

Strictly separate from `order.materials` so confirmed vs assumed vs missing stays auditable.

```lua
ledger = {
  orderId         = "...",
  batches         = {
    [batchNumber] = {
      expected    = { [itemID] = count, ... },
      confirmed   = { [itemID] = count, ... },      -- seen in incoming mail
      assumed     = { [itemID] = count, ... },      -- mail not seen but order arrived after grace window
      missing     = { [itemID] = count, ... },      -- computed; expected - (confirmed+assumed)
      seenMailId  = nil|<inbox identifier>,
      receivedAt  = nil|<epoch>,
      source      = "scanner"|"assumed"|"manual",
    },
  },
  returned        = { [itemID] = count, ... },      -- updated by cancellation flow
  delivered       = { [itemID] = count, ... },      -- delivery mail attachments confirmed
  manualNotes     = "",
}
```

### 4.3 Event log

Append-only, used both for local persistence and for peer sync. Each event has a `seq` that is monotonically increasing per producer.

```lua
event = {
  seq          = <int>,                             -- producer-local sequence
  producer     = "Char-Realm",                      -- who appended this event
  orderId      = "...",
  kind         = "OrderCreated" | "OrderUpdated" | "MaterialsSent" | "MaterialsReceived"
              | "MaterialsAssumed" | "MaterialsMissing" | "Accepted" | "DeliverySent"
              | "DeliveryConfirmed" | "CancelRequested" | "Returned" | "Cancelled"
              | "Expired" | "Failed" | "Pruned",
  at           = <epoch>,
  payload      = { ... },                           -- kind-specific
  schemaVersion= 1,
}
```

Reducer rules:
- Same `(producer, seq)` arriving twice → idempotent, second instance ignored.
- Events are sorted within (producer, orderId) by `seq` before being applied.
- Invalid transitions (per §5) cause the event to be recorded as rejected with a diagnostics counter, but never partially applied.
- `Pruned` for an `orderId` keeps a tombstone; subsequent events for the same orderId from any producer are dropped.

---

## 5. State machine (draft)

Refined from source §7. v1 deliberately collapses some intermediate states the spec lists but does not require, to keep UI complexity manageable. Final list to be confirmed in Phase 1 review.

```
            ┌──────────────┐
            │    Draft     │  (requester only, local until first mail send)
            └──────┬───────┘
                   │ requester sends batch 1
                   ▼
        ┌──────────────────────┐
        │  MaterialsPartial    │◀───────── (more batches still to send)
        └──────┬───────────────┘
               │ all batches sent
               ▼
        ┌──────────────────────┐
        │  MaterialsSent       │
        └──────┬───────────────┘
       crafter│ inbox scan
               ▼
   ┌──────────────────────────────────────┐
   │ MaterialsReceived | MaterialsAssumed │
   │            | MaterialsMissing        │
   └──────┬───────────────────────────────┘
          │ crafter accepts
          ▼
   ┌──────────────────────┐    crafter cancels
   │      Accepted        │────────┐
   └──────┬───────────────┘        │
          │ crafter sends delivery │
          ▼                        ▼
   ┌──────────────────────┐  ┌──────────────────────┐
   │   DeliverySent       │  │   ReturnPending      │
   └──────┬───────────────┘  └──────┬───────────────┘
          │ requester confirms       │ crafter sends return mail
          ▼                          ▼
   ┌──────────────────────┐  ┌──────────────────────┐
   │     Completed        │  │     Cancelled        │
   └──────────────────────┘  └──────────────────────┘
```

Plus terminal states `Expired` (system-triggered after retention) and `Failed` (manual or unrecoverable error). Tombstones for all terminal orders enter the prune queue per §9.

Actor authorization rules per source §7 are enforced inside `CraftOrdersStateMachine:CanTransition(order, fromState, toState, actor)`. The protocol layer rejects events whose `producer` is not the authorized actor for the proposed transition.

---

## 6. Sync protocol (draft)

### 6.1 Wire identity

- Comm prefix: `RRORD` (release) / `RRORDDEV` (dev). Mirrors the recipe prefix split in [`Core/BuildInfo.lua:95-98`](../Core/BuildInfo.lua#L95-L98).
- Wire version field: `Addon.ORDER_WIRE_VERSION = 1`, `Addon.ORDER_MIN_SUPPORTED_WIRE_VERSION = 1`. Independent of recipe `WIRE_VERSION`.
- Build channel isolation: dev clients ignore order traffic from release clients and vice versa (same rule as recipe sync).

### 6.2 Message kinds

| Kind | Direction | Purpose |
|---|---|---|
| `HELLO_ORDERS` | guild | "I'm online for orders, here is my high-water-mark per producer". Broadcast at a low cadence, never inline on login. |
| `SUMMARY_ORDERS` | direct reply to HELLO | Compact `{ producer → highSeq }` table the requester compares against. |
| `EVENTS_REQUEST` | direct | "Send me events for producer X from seq A to B (capped)." Always bounded. |
| `EVENTS_RESPONSE` | direct | Bounded batch of events, ordered by `(producer, seq)`. |
| `ORDER_LOOKUP` | direct | Optional fast-path used only when an incoming mail references an `orderId` we have no events for yet. |

No "BLOCK_PULL"-style large transfer. Bulk catch-up is paginated `EVENTS_REQUEST/RESPONSE` cycles with per-peer pacing.

### 6.3 Sync flow

```
boot → wait for orderSyncReady gate (see §6.5)
     → schedule HELLO_ORDERS with jitter
     → on receiving SUMMARY_ORDERS:
        compute diff = peers' highSeq[producer] - my highSeq[producer]
        for each producer with diff > 0:
          enqueue bounded EVENTS_REQUEST (cap N events per request, configurable)
     → on EVENTS_REQUEST: serve from local event log, capped
     → on EVENTS_RESPONSE: validate, reduce, append to local log, bump highSeq
     → at low cadence: prune events past retention, write tombstones
```

### 6.4 Pacing and caps (initial values, tunable)

- HELLO_ORDERS cadence: 90s stable, 45s when local events are dirty. Jittered.
- Max events per `EVENTS_REQUEST`: 50.
- Max payload bytes per response (after compression): 4 KB.
- Per-peer in-flight cap: 1 request at a time.
- Per-peer backoff on timeout: 30s → 60s → 120s.
- Suspend all order sync when `SyncPausePolicy:IsSensitiveSyncContext()` is true. Categories registered with `Addon.Performance`: `order-sync-outbound`, `order-sync-inbound`.

### 6.5 Readiness gates

The recipe `syncReady` gate (SavedVariables, player, world transition, trusted roster, sync index, pause, pressure) is documented in [`CLAUDE.md`](../CLAUDE.md). Orders introduce `orderSyncReady` requiring:

- SavedVariables initialized (reuse the recipe gate signal).
- Player key known.
- World-transition warmup complete (reuse the recipe gate signal).
- Pause policy inactive.
- Order store schema migrated.

Trusted-roster preflight is **not** required for order sync — orders address peers individually, not the guild-wide INDEX.

---

## 7. Mail Assistant — outgoing flow

### 7.1 Subject and body

Subject: `[RR] Order <shortId> (<n>/<N>)` — under 50 chars to leave headroom for the in-game subject limit (to be verified in Phase 0).

Body:
- Lines 1-N: human-readable summary (recipe name, quantity, batch info, list of attached items with counts).
- Last block: machine-readable marker, single line, JSON-like minimal format.
  ```
  --RR-ORDER--
  {id="...",req="Char-Realm",cra="Char-Realm",b=1,bt=3,sv=1,h="<short hash>",items={[itemID]=count,...}}
  --RR-END--
  ```

The hash is a checksum of the items table to detect corrupted bodies.

### 7.2 Attachment plan

Phase 0 must measure the real TBC Classic attachment limit. Until verified, the planner targets **12 attachments per mail** (the retail limit), and the unit test for the planner is parameterized so changing this constant updates the entire test set.

Splitting rules:
- Group items first by mailability (skip non-mailable, route them to manual/service flow).
- Pack greedily by remaining bag stack splits; each line in `batch.items` corresponds to one attachment slot.
- Preserve order ID across batches; record `(batchNumber, totalBatches)` in body marker.
- Never re-pack a batch once `sentAt` is set; partial-batch corrections become a new order or a manual addendum.

### 7.3 Send tracking

WoW does not expose a reliable "mail sent successfully" event in TBC. The assistant relies on:
- `MAIL_SEND_INFO_UPDATE` / `MAIL_SEND_SUCCESS` — to be verified in Phase 0.
- Falling back to: detect that `ClickSendMailItemButton` cleared the attachment slot, then optimistically mark `sentAt`; if subsequent inbox scan finds the mail returned, transition to a "send failed, returned" branch.

---

## 8. Postal compatibility plan

### 8.1 Detection

`CraftOrdersPostalCompat:DetectPostal()` checks `_G.Postal` and `_G.Postal_OpenAll` presence at OnEnable plus on `ADDON_LOADED`. No version assumption.

### 8.2 Risk

Postal's OpenAll can loot a mail before the order scanner reads it. If that happens, the order ledger never sees the attachments → would otherwise mark them missing.

### 8.3 Strategy

- Register a `MAIL_SHOW` handler with a higher-priority callback than Postal where possible (Postal exposes hooks in some versions — Phase 0 to verify).
- On `MAIL_SHOW`, immediately walk the inbox once and tag any RR order mail with a `seen` flag in the ledger, *before* Postal's OpenAll can fire.
- If a known `orderId` from board sync arrives with `MaterialsSent` but no scan ever fired and the configured grace window (default 30 minutes) has passed, downgrade missing → assumed received with a clear UI distinction. Source spec §14.

### 8.4 Fallback

If Postal hooks are unavailable or unstable, rely on `MAIL_INBOX_UPDATE` (fires on every change) to grab the mail headers as soon as the inbox is open. Assumed-receipt grace window is the safety net.

---

## 9. Retention and pruning

| Class | Default retention | Pruning rule |
|---|---|---|
| Active orders (non-terminal) | indefinite | never auto-pruned |
| Completed orders | 14 days after `DeliveryConfirmed` | prune order + ledger, keep tombstone |
| Cancelled orders | 14 days after `Cancelled` | prune order + ledger, keep tombstone |
| Failed / Expired | 30 days for diagnostics | prune order + ledger, keep tombstone |
| Tombstones | 60 days | drop tombstone after this; safe because all peers should have converged |
| Event log entries | 60 days OR after all known peers have ack'd the producer's seq (whichever later) | prune |

Pruning runs as a Performance job (category `order-maintenance`) at most once per session-day.

---

## 10. UI placement proposal

Three options considered:

**A — New "Orders" tab in the main frame.** Least invasive, matches the `PROF_ORDER` pattern. Discoverability is good. Order detail panel can reuse the right-side panel area used by recipe detail. Recommended.

**B — Separate `CraftOrdersFrame` window.** More room to design a richer board, but invents a new top-level UI surface and a new toggle. Users must remember a second slash command or icon.

**C — Compact widget on the recipe detail panel.** Lets users start an order from the recipe they're viewing, but provides no way to browse all orders.

**Recommendation: A**, implemented via a new public hook `RecipeRegistry.UI:RegisterExternalTab(spec)` (listed in §3.6). The hook takes a tab name, icon, and a `Build(parent)` callback; the plugin's `CraftOrdersBoard.lua` calls it during its own OnEnable. RR's main frame iterates registered external tabs and inserts them at the end of `PROF_ORDER`.

C remains a Phase 8 ergonomic add (a "Request craft" button on the recipe detail that opens the Orders tab pre-populated). The minimap right-click menu can list "Open Orders" if (and only if) the plugin is loaded — checked via `if _G.RecipeRegistry_Orders then`.

**Open question §13.3** — Mattia to confirm tab-vs-window before designing the public hook in Phase 0.

---

## 11. Phase plan

Each phase produces an artifact reviewable before the next phase starts. Don't skip Phase 0.

### Phase 0 — Branch + repo restructure + API validation
**Goal:** confirm what the WoW client actually allows; restructure the repo so both addons can coexist; no production code for the feature itself.

Work items:

- **Branch** created (done — `feature/craft-orders-mail-assistant`).
- **Repo restructure** (per §3.5):
  - Move all current RR sources (`Core/`, `Data/`, `Sync/`, `UI/`, `Integrations/`, `Libs/`, `RecipeRegistry.toc`) into a new `RecipeRegistry/` subfolder.
  - Create empty `RecipeRegistry_Orders/` skeleton with a minimal `RecipeRegistry_Orders.toc` that loads a single "hello world" `Core/CraftOrders.lua` (just an `Addon = LibStub("AceAddon-3.0"):NewAddon("RecipeRegistry_Orders", "AceConsole-3.0")` with an `OnInitialize` print). This proves the load-order + dependency chain works.
  - Embed required Libs in `RecipeRegistry_Orders/Libs/` (per §3.4).
  - Update `.pkgmeta` to use `move-folders` per §3.5. Validation path: push a throwaway tag (e.g., `v2.0.5-test1`) to a scratch branch and let CurseForge's native integration run; inspect the published ZIP to confirm both addon folders are at the top level. Delete the test tag and the scratch release after verification. **Coordinate with Mattia before pushing test tags — CurseForge users will see the test release.**
  - Add `scripts/dev-link.ps1` for symlinking both addons into WoW AddOns.
- **Fix test harness** (currently broken — see §2 and §13.1):
  - Update `Loader.BackendFiles` to use `RecipeRegistry/Core/Core.lua` style paths.
  - Update spec callsites that use bare `loadfile("Options.lua")`.
  - Verify `.\local-tests\run-backend-tests.ps1` green again before any new specs.
- **Public API draft** (per §3.6):
  - Stub out the documented surface in RR. For methods that already exist (`Data:GetRecipeDisplayInfo`, etc.) no change beyond marking them in code as "public — consumed by RecipeRegistry_Orders".
  - Design `RecipeRegistry.UI:RegisterExternalTab` (signature, lifecycle, error handling).
  - Document the contract in a new doc `docs/recipe-registry-public-api.md`.
- **WoW API validation** — write `docs/craft-orders-mail-api-findings.md` after testing in-game:
  - Mailbox subject and body length limits.
  - Exact attachment count limit on TBC 2.5.x.
  - Which mail events fire reliably (`MAIL_SHOW`, `MAIL_INBOX_UPDATE`, `MAIL_SEND_INFO_UPDATE`, `MAIL_SEND_SUCCESS`, `MAIL_FAILED`, `MAIL_INBOX_PAGE`?).
  - Whether `GetInboxText`, `GetInboxItemLink`, `GetInboxItem` work for unread mail without triggering "open".
  - Whether `SendMail` requires hardware event.
  - Postal hook surface (if Postal is available for testing).
- A short throwaway Lua snippet to test each API (kept under `docs/scratch/` or discarded).

**Exit criteria** (all must hold):
- The repo restructure is merged into the feature branch in a single commit, with the test harness green and the existing addon still loading in-game.
- The packaged ZIP (manually produced via BigWigs Packager) contains both `RecipeRegistry/` and `RecipeRegistry_Orders/` as siblings.
- API findings doc reviewed by Mattia.

### Phase 1 — Local drafts + material planner
- `CraftOrders.lua`, `CraftOrdersStore.lua`, `CraftOrdersStateMachine.lua`, `CraftOrdersPlanner.lua`.
- Slash subcommand `/rr orders new`.
- No mail send, no guild sync.
- Specs: planner aggregation (single line, multi-line, repeated lines, multi-recipe), state machine valid/invalid transitions, store persistence + migration.
- **Exit criterion:** all Phase 1 specs green.

### Phase 2 — Outgoing Mail Assistant
- `CraftOrdersMailAssistant.lua`.
- Requires mailbox open; rejects otherwise.
- Batch planning, subject/body generation, attachment click sequence, send tracking.
- WoW mock harness extended with a mailbox simulator (new file under `local-tests/harness/`).
- Specs: subject/body format stable, batch split at limit boundary, partial send recovery, non-mailable item skip.
- **Exit criterion:** Phase 2 specs green + manual mailbox dry-run in game (no sync yet).

### Phase 3 — Local board UI
- `CraftOrdersBoard.lua` adds an "Orders" tab to the main frame.
- Filters per source §20.
- Detail panel per source §20.
- No guild sync yet — board shows only locally-known orders.
- **Exit criterion:** UI usable with seeded test data, no console errors.

### Phase 4 — Inbox recognition + assumed receipt
- `CraftOrdersMailScanner.lua`.
- Parses inbox on `MAIL_SHOW`, matches RR-ORDER marker, records ledger.
- Generates missing-material reply draft (does not send).
- Assumed-receipt fallback after configurable grace window.
- Specs: scanner against mocked inbox states (matching mail, mismatched mail, mail with wrong checksum, missing items, duplicate batches).
- **Exit criterion:** Phase 4 specs green + manual two-character roundtrip in game with a single mail.

### Phase 5 — Postal compatibility
- `CraftOrdersPostalCompat.lua`.
- Detection, early-scan strategy, assumed-receipt verification with simulated Postal pre-loot.
- Specs: scanner runs before Postal hook, ledger correct if Postal already looted.
- **Exit criterion:** Phase 5 specs green + manual test with Postal installed.

### Phase 6 — Separate order sync
- `CraftOrdersProtocol.lua`, `CraftOrdersRuntime.lua`, `CraftOrdersDiagnostics.lua`.
- Wire identity `RRORD`/`RRORDDEV`.
- HELLO_ORDERS / SUMMARY_ORDERS / EVENTS_REQUEST / EVENTS_RESPONSE.
- Pause integration with `SyncPausePolicy`.
- Pruning + tombstones.
- Specs: event reducer idempotence, duplicate event ignored, invalid transition rejected, tombstone resurrection prevention, large-guild login does not flood, paused in instance, dev/release isolation.
- **Exit criterion:** Phase 6 specs green + multi-character soak test (5+ peers) shows no traffic in raid.

### Phase 7 — Cancellation + return
- Cancel flow, returnable computation from ledger (never from bag totals), batch split on return.
- Specs: returnable matches confirmed minus already-returned; crafter-provided excluded; assumed-receipt shows warning; manual override path.
- **Exit criterion:** Phase 7 specs green + manual end-to-end cancel.

### Phase 8 — Delivery + completion
- Delivery mail prep, detection of delivery mail in requester inbox, completion transition.
- Service-craft / manual-delivery modes get a clearly labeled "manually confirmed" transition.
- Specs: mailable delivery happy path; non-mailable items rejected; service-craft path requires manual confirm.
- **Exit criterion:** Phase 8 specs green + manual end-to-end deliver + confirm.

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| TBC mailbox APIs behave differently than retail | Phase 0 hard gate. No code beyond planner until findings doc exists. |
| Postal taint or pre-loot | Early-scan + assumed-receipt fallback. Postal stays optional. |
| Event log unbounded growth | Hard caps on event size, hard caps on retention, prune job. |
| Sync storms on large-guild login | Jittered HELLO_ORDERS, bounded EVENTS_REQUEST, per-peer backoff, instance pause. |
| Stale peer resurrects pruned orders | Tombstones with 60-day window; reducer rejects events for tombstoned orderIds. |
| User loses materials due to false-positive completion | All destructive actions stay manual + reviewable. UI distinguishes confirmed/assumed/missing. |
| Test harness path mismatch (existing repo issue) | Fix `Loader.BackendFiles` in Phase 0 alongside the repo restructure — without it no new specs run. |
| Recipe-side sync regression caused by accidental coupling | The separate-addon split makes coupling physically harder. Add a grep gate spec that fails if `RecipeRegistry_Orders/` references any RR symbol not listed in §3.6 (the public API contract). |
| Public API surface drift | The contract in §3.6 is documented in `docs/recipe-registry-public-api.md` (Phase 0 output). Changes require coordinated version bumps in both TOCs and a CHANGELOG entry calling out the consumer. |
| Plugin loaded without RR (e.g., user disables RR but leaves plugin enabled) | `## Dependencies: RecipeRegistry` is hard — WoW refuses to load the plugin if RR is missing or disabled. No defensive coding needed. |
| Two addons drift out of sync on CurseForge | Single CurseForge project + single repo + single packager run guarantees they ship together. No two-pipeline coordination. |
| Wire prefix collision with future addons | `RRORD` / `RRORDDEV` are 5-8 chars and project-specific; no known collision. |
| Mail attachment limit assumption wrong | Constant lives in one place; specs are parameterized. |

---

## 13. Open questions for Mattia

These are blocking decisions I will not make alone. Sorted by phase impact.

**Resolved on 2026-05-22:**
- Distribution model → separate addon (`RecipeRegistry_Orders`), same repo, same CurseForge project (§3.5, §1).
- Codec → plugin owns its own copy of the codec, no cross-addon call (§3.7).
- Slash command → plugin owns `/rrord`, not a subcommand of `/rr` (§3.3).
- Library embedding → plugin embeds its own Libs (§3.4 recommendation A).
- CurseForge model → single project, ship together, RR's `## Version` leads on CF, plugin tracks its own internal version. Migration to two projects deferred per §3.8 trigger.
- CHANGELOG strategy → single `CHANGELOG.md` at repo root with per-addon sections (§3.5).
- `.pkgmeta` validation → via scratch-tag test release on CurseForge, coordinated with Mattia.

**Still open:**

1. **Test harness scope (blocks Phase 1 specs).** The repo restructure (§3.5) will move RR sources into a subdirectory. The harness path fix becomes mandatory — confirm I should do it as part of Phase 0 alongside the restructure, in one commit (Option A: update `Loader.BackendFiles` to `RecipeRegistry/Core/Core.lua` etc.; Option B: also fix the `loadfile("Options.lua")` bare reads in specs). Recommendation: both, in the same commit.

2. **UI placement (blocks Phase 3).** Option A (Orders tab via `RecipeRegistry.UI:RegisterExternalTab` hook on the main frame), B (plugin owns a separate window), or C (compact widget on recipe detail)? Recommendation: A. A also requires designing the public hook in Phase 0.

3. **Wire prefix string (blocks Phase 6).** `RRORD`/`RRORDDEV` proposed. Any preference?

4. **Default retention windows (blocks Phase 6).** Proposed 14 days completed/cancelled, 30 days failed/expired, 60 days tombstones. Acceptable?

5. **Assumed-receipt grace window (blocks Phase 4).** Proposed 30 minutes from `MaterialsSent` event timestamp. Too short / too long?

6. **Public API doc owner (blocks Phase 0).** I propose adding `docs/recipe-registry-public-api.md` on this branch so the contract is reviewable before Phase 1 starts. Confirm or push back.

7. **Mock data + dev tooling parity.** Recipe sync has `MockSync.lua` for scenario testing. Should Phase 6 ship a similar `RecipeRegistry_Orders/Sync/CraftOrdersMock.lua` from the start (parallel with the protocol), or defer it?

8. **Localization of mail body.** Source spec §11 says "human-readable first". Should the body honor a future locale system, or hardcode English for v1?

9. **Plugin version number at launch.** Proposed `0.1.0` while in pre-release on the feature branch. Confirm or pick differently. RR keeps `2.0.4`.

10. **Doc language.** This roadmap is in English (matches repo convention). Should follow-up findings docs (Phase 0 output) be English or Italian?

---

## 14. Not in scope

Explicitly excluded from this branch, per source spec §29 + project hygiene:

- No changes to RR's `Sync/`, `Data/`, `MergeEngine.lua`, `DataIndex.lua`, `SyncPausePolicy.lua` **logic**. The only RR-side changes are: (a) the repo restructure that moves sources into `RecipeRegistry/`, (b) marking methods listed in §3.6 as "public API", (c) adding `RecipeRegistry.UI:RegisterExternalTab` if Option A wins for UI placement.
- No bump of RR's `## Version` until the plugin's first stable release (RR ships unchanged from the user's perspective during Phase 0-5).
- No gold/COD/automatic-mail-trade automation in v1.
- No retail-style auto craft order acceptance.
- No automatic craft-success detection.
- No modification of recipe wire version, prefix, or capabilities table.

---

## 15. How to advance

After Mattia reviews this doc:

1. Resolve open questions §13.
2. Commit this doc plus the inherited working-tree changes as the first feature-branch commit.
3. Start Phase 0: API validation in-game + write findings doc.
4. Loop back here for Phase 1 plan refinement once findings are confirmed.
