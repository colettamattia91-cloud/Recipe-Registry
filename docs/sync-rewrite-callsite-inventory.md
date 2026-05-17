# Recipe Registry — Sync Rewrite Call-Site Migration Inventory

**Status:** refreshed from the working tree on 2026-05-17.  
**Purpose:** track what legacy sync migration work is complete, what remains intentionally quarantined, and what stale non-focused test coverage still needs rewrite.  
**Rule:** this remains the migration inventory source of truth. `docs/sync-rewrite-roadmap.md` remains the architecture source of truth.

---

## 1. Current migration summary

Completed in active runtime code:

- `DataManifest.lua` removed
- `SyncManifest.lua` removed
- `TrickleSync.lua` removed
- no manifest send/receive path
- no coordinator state
- no revision-driven routing
- no `QueueRequest(..., rev, ...)`
- no manifest slash/debug command surface

Remaining intentional legacy surface:

- `SyncProtocol.lua` still recognizes inbound `AD`, `IDX`, `MANI`, and `MREQ`
- those kinds go directly to a removed-message quarantine path
- the quarantine increments telemetry only and performs no work, replies, merge, transfer, request, or seed state mutation

Remaining migration work outside the focused hardening pass:

- non-focused backend specs and harness helpers that still assert removed manifest/revision behavior
- broad comm-bus and chunk-pipeline suites
- optional historical docs cleanup beyond the rewrite governance files

---

## 2. Runtime module status

### Data layer

Current active files:

- `Data.lua`
- `DataScan.lua`
- `DataSnapshot.lua`
- `DataCatalog.lua`
- `DataIndex.lua`
- `DataCleanup.lua`

Resolved migration points:

- active member/profession sync state no longer uses manifest helpers
- active sync behavior no longer uses `rev` or `blockRevision`
- sync-facing indexing lives in `DataIndex.lua`
- additive block apply lives in `DataSnapshot.lua`

Remaining notes:

- historical revision fields may still exist in old SavedVariables, but active sync code does not read them for routing or equality

### Sync runtime

Current active files:

- `Sync.lua`
- `SyncRuntime.lua`
- `SyncProtocol.lua`
- `SyncCodec.lua`
- `SyncRequests.lua`
- `SyncTransfer.lua`
- `SyncDiagnostics.lua`
- `SyncPausePolicy.lua`

Resolved migration points:

- one selected outbound seed per cycle
- `HELLO` / `SUMMARY` discovery
- `INDEX_DIFF_REQUEST` / `INDEX_DIFF_RESPONSE`
- sequential `BLOCK_PULL_REQUEST` / `BLOCK_SNAPSHOT`
- immediate additive merge
- runtime sync index cache telemetry and diagnostics
- build-channel / wire-version compatibility preserved

Resolved legacy removals:

- `RecomputeCoordinator`
- `IsCoordinator`
- `coordinatorKey`
- `AdvertiseLocalRevision`
- `BroadcastIndex`
- legacy request queues
- manifest refresh/send/compare paths

---

## 3. Load order status

### Addon load order

Current `.toc` load order includes:

- `DataIndex.lua`
- no `DataManifest.lua`
- no `SyncManifest.lua`
- no `TrickleSync.lua`

### Test harness load order

`local-tests/harness/load-addon.lua` now includes:

- `DataIndex.lua`
- no `DataManifest.lua`
- no `SyncManifest.lua`
- no `TrickleSync.lua`

---

## 4. Slash, diagnostics, and mock status

### Core slash surface

Resolved:

- `/rr manifest` removed as an active command
- `/rr publish` removed as an active command
- perf/debug output now reports sync-index/runtime state instead of manifest state
- `/rr pull` now schedules the modern hello/index-diff path only

### Diagnostics

Resolved:

- runtime diagnostics no longer report coordinator state
- runtime diagnostics no longer report manifest queues or manifest caches
- debug log scopes now use `sync`, `request`, `transfer`, `offline`, and `version`

### MockSync

Resolved:

- no manifest message synthesis
- no revision hint recording
- no `TrickleSync` pruning logic
- scenarios now seed mock data and modern discovery state only

---

## 5. Compatibility guardrails still required

These must remain active and are intentionally not legacy:

- `BuildInfo.CompareSemver`
- `BuildInfo.IsRemoteNewer`
- `BuildInfo.GetLocalVersionInfo`
- `Addon.ADDON_VERSION`
- `Addon.DISPLAY_VERSION`
- `Addon.WIRE_VERSION`
- `Addon.MIN_SUPPORTED_WIRE_VERSION`
- `Addon.BUILD_CHANNEL`
- `Addon.BUILD_ID`
- `Addon.COMM_PREFIX`
- `Sync:GetLocalVersionInfo`
- `Sync:ComputePeerCompatibility`
- `Sync:IsInboundBuildChannelAllowed`
- `Sync:RegisterBuildChannelDrop`
- `Sync:ObservePeerVersion`
- `Sync:GetPeerVersionInfo`
- `Sync:GetPeerVersionRelation`
- `Sync:RecordLatestRemoteVersion`
- `Sync:ShouldAcceptInboundPayload`
- `Sync:MaybeNotifyPeerVersion`
- `Data:GetUpdateNoticeState`

Capability cleanup completed:

- `maniReliable` removed from active local capability advertisement
- `manifestShards` removed from active local capability advertisement
- compatibility decisions now depend on real modern capabilities only

---

## 6. Focused migration gate status

Passing focused gate:

- `sync_phase1_legacy_noop_spec.lua`
- `sync_phase2_summary_foundation_spec.lua`
- `sync_phase34_block_pull_spec.lua`
- `sync_legacy_grep_gate_spec.lua`
- `build_channel_isolation_spec.lua`
- `p4_scan_opportunistic_spec.lua`
- `slash_output_spec.lua`

The focused grep gate now proves:

- deleted legacy modules are absent
- active runtime code is free of removed manifest/revision/coordinator symbols
- removed inbound message handling remains isolated to the protocol quarantine path

---

## 7. Remaining non-focused blockers

The broader backend runner is not yet fully migrated.

Current first failing broad-suite command:

```powershell
.\local-tests\run-backend-tests.ps1 -Suite sync
```

Current first failing spec:

- `chunk_pipeline_spec.lua`

Current first failure:

- `attempt to call method 'ComputeRecipeSignature' (a nil value)`

This is a stale legacy-suite migration issue, not an active runtime regression in the focused rewrite path.
