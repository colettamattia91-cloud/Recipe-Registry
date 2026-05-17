# Recipe Registry — Sync Rewrite Call-Site Migration Inventory

**Status:** preserved call-site inventory compiled from the chat-approved inventory.  
**Purpose:** protect the rewrite from dangling references while migrating away from manifest/coordinator/revision sync.  
**Rule:** do not replace this with a phase-specific plan. Update only when new call-sites are discovered.

---

## 1. Inventory summary

The live manifest/coordinator/revision sync surface must be migrated before legacy modules are removed from `.toc` or from the local test loader.

Primary legacy modules:

- `DataManifest.lua` — delete after migration pass.
- `SyncManifest.lua` — delete after migration pass; Phase 1 may keep inert compatibility stubs.
- `TrickleSync.lua` — delete after migration pass.

Primary replacement direction:

- `DataIndex.lua` for active-owner index, content-only fingerprints, summaries, and index diff support.
- `SyncProtocol.lua` for HELLO, SUMMARY, INDEX_DIFF, BLOCK_PULL and legacy no-op routing.
- `SyncRequests.lua` for one-seed wanted-block orchestration.
- `SyncTransfer.lua` for live block snapshot serving and immediate block apply.

---

## 2. Legacy module inventory

### DataManifest.lua — delete

Still loaded by:

- `RecipeRegistry.toc`;
- `local-tests/harness/load-addon.lua`.

Runtime callers / dependents:

- `Core.lua` via `DumpManifestCacheStatus`, `DumpManifestSummary`;
- `BootstrapSync.lua` bootstrap completeness helpers;
- `SyncProtocol.lua` manifest fingerprint path;
- `TrickleSync.lua` manifest build/cache;
- manifest-era specs.

Target disposition:

- delete after call-site migration;
- no active runtime behavior should depend on it after migration.

### SyncManifest.lua — delete after migration

Still loaded by:

- `RecipeRegistry.toc`;
- `local-tests/harness/load-addon.lua`.

Live callers / dependents:

- `SyncProtocol.lua` for `MANI/MREQ` dispatch;
- `SyncRuntime.lua` for `SendManifestToPeer`, `RequestManifestRefresh`, `ShouldRequestManifestRefresh`;
- `SyncRequests.lua`;
- `Core.lua` slash commands;
- `MockSync.lua`;
- manifest tests.

Target disposition:

- Phase 1: keep loaded with inert no-op compatibility stubs.
- Later: delete after all call-sites are migrated.

### TrickleSync.lua — delete

Still loaded by:

- `RecipeRegistry.toc`;
- `local-tests/harness/load-addon.lua`.

Live callers / dependents:

- `DataManifest.lua`;
- `SyncManifest.lua`;
- `SyncDiagnostics.lua`;
- `SyncRuntime.lua`;
- `MockSync.lua`;
- `p2_integrity_spec.lua`;
- manifest specs.

Target disposition:

- remove manifest comparison, manifest chunk generation, peer manifest state, and manifest-based missing-block detection.

---

## 3. Message handler inventory

### AD / IDX handlers in SyncProtocol.lua

Current behavior:

- legacy advertise/index routing;
- `BroadcastIndex` and related index/coordinator fan-out;
- revision hint routing;
- potential request seeding.

Current producers:

- `Core.lua` scan/rescan flows;
- `Sync.lua` startup;
- `BroadcastIndex`.

Current consumers:

- `SyncProtocol.lua`;
- `sync_reliability_spec.lua` and related tests.

Target disposition:

- outbound delete;
- inbound deprecated no-op;
- increment `legacyMessageIgnored` or equivalent;
- never enqueue work or send replies.

### MANI / MREQ handlers

Current behavior:

- manifest send/receive/retry/recovery/catch-up;
- partial manifest state;
- comparison and request generation.

Current producers:

- `SyncRuntime.lua`;
- `SyncRequests.lua`;
- `Core.lua`;
- `MockSync.lua`.

Current consumers:

- `SyncManifest.lua`;
- `SyncProtocol.lua` dispatch;
- manifest-era specs;
- reliability/reload tests.

Target disposition:

- outbound delete;
- inbound deprecated no-op;
- no recovery, no refresh, no partial reopen, no request generation.

---

## 4. Coordinator inventory

Coordinator logic appears in or affects:

- `SyncRuntime.lua`;
- `SyncProtocol.lua`;
- `SyncDiagnostics.lua`;
- `SyncTransfer.lua`;
- manifest comm-bus tests;
- soak tests.

Legacy functions/state to remove:

- `RecomputeCoordinator`;
- `IsCoordinator`;
- `coordinatorKey`;
- coordinator-gated `IDX`;
- coordinator churn expectations.

Target disposition:

- delete from active sync behavior;
- no seed election may depend on old coordinator state;
- new seed election is local and per-cycle.

---

## 5. Revision-driven inventory

Revision-driven helpers appear across:

- `SyncRuntime.lua`;
- `SyncProtocol.lua`;
- `SyncRequests.lua`;
- `SyncTransfer.lua`;
- `DataSnapshot.lua`;
- `MergeEngine.lua`;
- `MockSync.lua`;
- `SyncCodec.lua`.

Legacy fields/functions:

```text
RecordRevisionHint
GetKnownRevision
localRev
remoteRev
knownRev
wantRev
ownerRevision
blockRevision
revision-derived merge/session logic
```

Target disposition:

- rewrite or delete;
- no active sync behavior may read revision to decide routing, equality, priority, merge precedence, freshness, retry, or diagnostics that affect behavior.

---

## 6. QueueRequest inventory

Legacy behavior:

```text
QueueRequest(..., rev, ...)
```

Current call-sites include:

- `SyncRequests.lua`;
- `SyncProtocol.lua`;
- `SyncManifest.lua`;
- `SyncRuntime.lua`;
- tests.

Target disposition:

- delete behavior;
- replace with selected seed plus ordered wanted-`blockKey` queue;
- Phase 1 may convert to deprecated no-op that creates no pending work.

---

## 7. Slash command inventory

`Core.lua` requires rewrite.

Legacy or affected surfaces:

- `/rr manifest`;
- `/rr publish`;
- `/rr pull`;
- `/rr rescan`;
- help text;
- debug scopes;
- manifest counter reset text;
- `syncreset` manifest-state clearing.

Target disposition:

- `/rr rescan` remains a local scan/rescan command;
- after rescan, mark sync index dirty and schedule HELLO path;
- stop calling `AdvertiseLocalRevision` or manifest/revision/coordinator paths;
- manifest/pull surfaces become new index/sync diagnostics or deprecated aliases.

---

## 8. Diagnostics inventory

Affected files:

- `SyncDiagnostics.lua`;
- `Core.lua`.

Legacy diagnostics still report:

- manifest queues;
- partial manifest receive state;
- trickle state;
- coordinator role;
- manifest capabilities;
- manifest recovery telemetry.

Target disposition:

- rewrite to hello/summary/index-diff/block-pull/session diagnostics;
- include trusted roster state;
- distinguish dirty live global state from committed published global fingerprint;
- include `legacyMessageIgnored` and `revisionPathRemoved` or equivalent.

---

## 9. Mock and harness inventory

### MockSync.lua — rewrite

Current legacy behavior:

- emits `MANI`;
- records revision hints;
- synthesizes manifest blocks;
- checks `knownRev`;
- prunes `TrickleSync` runtime.

Target disposition:

- simulate HELLO;
- simulate direct SUMMARY;
- simulate explicit `INDEX_DIFF_REQUEST/RESPONSE`;
- simulate sequential `BLOCK_PULL_REQUEST/BLOCK_SNAPSHOT`;
- remove manifest and revision paths.

### local-tests/harness/load-addon.lua — rewrite

Current risk:

- hard-loads `DataManifest.lua`, `TrickleSync.lua`, and `SyncManifest.lua`.

Target disposition:

- add `DataIndex.lua`;
- stop loading removed modules only after final call-site migration.

### local-tests/harness/comm-bus.lua — rewrite

Current legacy metrics:

- `MANI/MREQ/IDX`;
- coordinator convergence;
- manifest catch-up state.

Target disposition:

- count explicit new message kinds;
- expose one-seed cycle state;
- expose sequential block-pull metrics;
- expose live inbound service behavior.

### Soak helpers — rewrite

Replace manifest-loop and catch-up assumptions with:

- SUMMARY storm checks;
- single-seed cycles;
- sequential block pulls;
- immediate block apply;
- trusted-roster behavior;
- no mid-cycle HELLO publication.

---

## 10. Test migration inventory

### Delete and replace

```text
local-tests/spec/manifest_*
manifest_comm_bus_spec.lua
manifest_transport_pressure_spec.lua
p3_manifest_diagnostics_spec.lua
```

### Rewrite

```text
p2_integrity_spec.lua
p4_scan_opportunistic_spec.lua
build_channel_isolation_spec.lua
version_compatibility_spec.lua
sync_reliability_spec.lua
sync_resilience_spec.lua
reload_recovery_spec.lua
slash_output_spec.lua
specialization_sync_spec.lua
chunk_pipeline_spec.lua
transfer_identity_spec.lua
snapshot_identical_metadata_spec.lua
support/sync-soak-helpers.lua
sync_soak_spec.lua
sync_soak_heavy_spec.lua
```

### Neutral reuse

Non-sync UI/catalog specs may remain, except for shared fixture/helper adjustments.

### Add

```text
sync_massive_spec.lua
sync_legacy_grep_gate_spec.lua or equivalent
```

---

## 11. Documentation inventory

Rewrite:

- `README.md`;
- `local-tests/README.md`;
- `docs/CODEBASE_ANALYSIS.local.md`.

Keep canonical:

- `docs/sync-rewrite-roadmap.md`.

Archive or rewrite duplicate root roadmap/plan docs to avoid drift.

---

## 12. Risky dangling references before `.toc` removal

Do not remove `DataManifest.lua`, `SyncManifest.lua`, or `TrickleSync.lua` from `.toc` until these are addressed:

- `RecipeRegistry.toc` and `local-tests/harness/load-addon.lua` still hard-load legacy modules.
- `Core.lua` still calls legacy manifest/revision/debug APIs unless migrated.
- `SyncProtocol.lua` still dispatches real `AD`, `IDX`, `MANI`, and `MREQ` unless converted to no-op.
- `SyncRuntime.lua` still owns coordinator recompute, manifest refresh/send paths, and revision auto-tick request generation unless cut.
- `SyncTransfer.lua` still uses `knownRev/wantRev`, revision-keyed sessions, `FinalizeIncomingSnapshot(..., rev, ...)`, and post-merge `BroadcastIndex` unless rewritten.
- `SyncDiagnostics.lua` still traverses manifest queues, partial manifests, trickle resident manifests, and coordinator role unless migrated.
- `MockSync.lua` and manifest-era specs still invoke removed APIs/message kinds unless rewritten.

---

## 13. Locked assumptions

- `INDEX_DIFF_REQUEST` and `INDEX_DIFF_RESPONSE` are new explicit kinds; legacy `IDX` is never reused.
- Fingerprints are discovery-only.
- Wanted-block state is `blockKey`-driven.
- `BLOCK_PULL_REQUEST` stays `blockKey`-only.
- Inbound seed service serves live working block data even while `globalFingerprintDirty` is true.
- Revision-bearing fields may remain in SavedVariables as ignored historical metadata only.
