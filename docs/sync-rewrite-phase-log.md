# Recipe Registry — Sync Rewrite Phase Log

**Status:** refreshed from actual code and test inspection on 2026-05-17.  
**Rule:** this is a phase report, not the architecture source of truth. `docs/sync-rewrite-roadmap.md` remains canonical.

---

## Current implementation state

The completed rewrite now runs on the modern wire-3 model only:

```text
HELLO
-> SUMMARY
-> one selected outbound seed
-> INDEX_DIFF_REQUEST
-> INDEX_DIFF_RESPONSE
-> sequential BLOCK_PULL_REQUEST
-> BLOCK_SNAPSHOT
-> immediate additive merge
-> immediate local block fingerprint recompute
-> committed global fingerprint recompute on complete or abort
```

The old manifest, revision, and coordinator sync system has been removed from active runtime code. Legacy inbound `AD`, `IDX`, `MANI`, and `MREQ` remain only as a quarantined no-op path in `SyncProtocol.lua`.

Deleted runtime files:

- `DataManifest.lua`
- `SyncManifest.lua`
- `TrickleSync.lua`

---

## Phase 3 — INDEX_DIFF

### Status

Completed.

### Changed files

- `DataIndex.lua`
- `SyncProtocol.lua`
- `SyncRequests.lua`
- `SyncRuntime.lua`
- `SyncCodec.lua`
- `BuildInfo.lua`
- `local-tests/spec/sync_phase2_summary_foundation_spec.lua`
- `local-tests/spec/sync_phase34_block_pull_spec.lua`

### Behavior implemented

- `INDEX_DIFF_REQUEST` uses the new explicit kind and sends only `requestId` plus requester block digests.
- `INDEX_DIFF_RESPONSE` uses the new explicit kind and returns only `requestId` plus offered blocks.
- Seed selection is local and summary-driven; no coordinator or revision registry participates.
- Requester digests compare `blockKey -> { count, fingerprint }` only.
- Equal-count fingerprint mismatches offer the seed block.
- Lower-count local blocks are not offered back to a richer requester.

### Tests added or updated

- `sync_phase2_summary_foundation_spec.lua`
- `sync_phase34_block_pull_spec.lua`

### Test results

- `sync_phase2_summary_foundation_spec.lua`: 8 passed
- `sync_phase34_block_pull_spec.lua`: 6 passed

### Deviations from the roadmap

- The requester now accepts a `SUMMARY` that matches its active `helloId` even before the peer has emitted its own `HELLO`, then primes provisional peer version/capability state from the local build metadata so the current cycle can continue. This keeps the payload minimal while preserving the one-hello summary flow.

### Remaining blockers

- No active Phase 3 blockers remain in the supported backend suites.

---

## Phase 4 — BLOCK_PULL / BLOCK_SNAPSHOT / immediate merge

### Status

Completed.

### Changed files

- `DataSnapshot.lua`
- `MergeEngine.lua`
- `SyncRequests.lua`
- `SyncTransfer.lua`
- `SyncProtocol.lua`
- `local-tests/spec/sync_phase34_block_pull_spec.lua`

### Behavior implemented

- `BLOCK_PULL_REQUEST` is `requestId + blockKey` only.
- `BLOCK_SNAPSHOT` serves live block data and carries only block payload fields needed for merge.
- Every received block is normalized and merged additively immediately.
- Local block fingerprint is recomputed immediately after merge.
- Global fingerprint is marked dirty after each block-level change.
- Block N+1 is never requested before block N is fully merged and recomputed.
- Final block completion no longer waits on an unnecessary extra delay tick.

### Tests added or updated

- `sync_phase34_block_pull_spec.lua`

### Test results

- `sync_phase34_block_pull_spec.lua`: 6 passed

### Deviations from the roadmap

- `BLOCK_SNAPSHOT` still carries non-authoritative metadata for UI completeness inside `blockPayload.metadata`, but that metadata does not participate in diffing, equality, routing, or merge precedence.

### Remaining blockers

- No active Phase 4 blockers remain in the supported backend suites.

---

## Phase 5 — timeouts, diagnostics, reset, pacing, runtime cache hardening

### Status

Completed for the rewrite path.

### Changed files

- `DataIndex.lua`
- `DataScan.lua`
- `Sync.lua`
- `SyncRuntime.lua`
- `SyncRequests.lua`
- `SyncTransfer.lua`
- `SyncDiagnostics.lua`
- `SyncPausePolicy.lua`
- `Core.lua`
- `local-tests/spec/p4_scan_opportunistic_spec.lua`
- `local-tests/spec/slash_output_spec.lua`

### Behavior implemented

- Added in-memory runtime sync index caching with block-scoped dirtiness.
- Full rebuilds now happen only on cache miss, full invalidation, or trusted-roster state changes.
- Dirty block rebuilds update only affected blocks when possible.
- Added telemetry:
  - `syncIndexCacheHit`
  - `syncIndexCacheMiss`
  - `syncIndexBlockRebuilt`
  - `syncIndexFullRebuild`
  - `syncIndexGlobalRecomputed`
  - `syncIndexDirtyBlockCount`
- Added internal pacing constant:
  - `BLOCK_PULL_DELAY_SECONDS = 1.0`
- The next block pull is scheduled only after the previous block is merged and recomputed.
- Committed global fingerprint updates only on outbound session completion or abort.
- Diagnostics and slash output now report sync-index/cache/runtime state instead of manifest/coordinator state.

### Tests added or updated

- `sync_phase2_summary_foundation_spec.lua`
- `sync_phase34_block_pull_spec.lua`
- `p4_scan_opportunistic_spec.lua`
- `slash_output_spec.lua`

### Test results

- `sync_phase2_summary_foundation_spec.lua`: 8 passed
- `sync_phase34_block_pull_spec.lua`: 6 passed
- `p4_scan_opportunistic_spec.lua`: 13 passed
- `slash_output_spec.lua`: 9 passed

### Deviations from the roadmap

- Runtime cache rebuilds are still synchronous in backend tests. The worker/timer-based deferral requirement for expensive full rebuilds remains a practical in-game follow-up rather than a blocker for the current backend hardening pass.

### Remaining blockers

- The expensive in-game full-rebuild deferral path is still intentionally documented as a follow-up implementation concern rather than a backend-test blocker.

---

## Phase 6 — legacy removal and final gate

### Status

Completed for active runtime code and the supported backend suite surface.

### Changed files

- `Data.lua`
- `Core.lua`
- `MockSync.lua`
- `SyncProtocol.lua`
- `SyncRuntime.lua`
- `BuildInfo.lua`
- `RecipeRegistry.toc`
- `local-tests/harness/load-addon.lua`
- `local-tests/spec/sync_phase1_legacy_noop_spec.lua`
- `local-tests/spec/sync_legacy_grep_gate_spec.lua`
- `local-tests/spec/build_channel_isolation_spec.lua`

### Behavior implemented

- Removed active manifest/revision/coordinator runtime code from the sync path.
- Removed `maniReliable` and `manifestShards` from active capability advertisement.
- Removed manifest slash/debug surfaces from `Core.lua`.
- Replaced the old mock sync implementation with a smaller modern-only helper.
- Deleted the old legacy sync files physically from the repository.
- Added a hard grep gate for active runtime code and load order.

### Tests added or updated

- `sync_phase1_legacy_noop_spec.lua`
- `sync_legacy_grep_gate_spec.lua`
- `build_channel_isolation_spec.lua`

### Test results

- `sync_phase1_legacy_noop_spec.lua`: 4 passed
- `sync_legacy_grep_gate_spec.lua`: 3 passed
- `build_channel_isolation_spec.lua`: 13 passed

### Deviations from the roadmap

- Historical backend specs that still assert removed manifest/revision/coordinator behavior remain in-tree for reference, but they are no longer part of the active backend suite definitions.

### Remaining blockers

- No active Phase 6 blockers remain in the supported backend suites.

---

## Final hardening pass

### Status

Completed for the requested scope on 2026-05-17.

### Changed files

- `BuildInfo.lua`
- `Core.lua`
- `Data.lua`
- `DataCatalog.lua`
- `DataIndex.lua`
- `DataScan.lua`
- `DataSnapshot.lua`
- `MockSync.lua`
- `Sync.lua`
- `SyncCodec.lua`
- `SyncDiagnostics.lua`
- `SyncPausePolicy.lua`
- `SyncProtocol.lua`
- `SyncRequests.lua`
- `SyncRuntime.lua`
- `SyncTransfer.lua`
- `UI/MainFrame.lua`
- `local-tests/spec/build_channel_isolation_spec.lua`
- `local-tests/spec/p4_scan_opportunistic_spec.lua`
- `local-tests/spec/slash_output_spec.lua`
- `local-tests/spec/sync_legacy_grep_gate_spec.lua`
- `local-tests/spec/sync_phase1_legacy_noop_spec.lua`
- `local-tests/spec/sync_phase2_summary_foundation_spec.lua`
- `local-tests/spec/sync_phase34_block_pull_spec.lua`

### Behavior implemented

- Removed dead legacy sync surfaces from active runtime code.
- Removed coordinator state entirely.
- Reduced `INDEX_DIFF_REQUEST` and `BLOCK_PULL_REQUEST` payloads to the minimum live fields.
- Kept debug/telemetry local instead of adding debug-only wire fields.
- Removed inactive snapshot-codec capability advertisement from the active wire capability set.
- Added paced block-pull sequencing with a one-second internal delay.
- Replaced repeated live index rebuilds with an in-memory runtime cache.
- Standardized the internal fingerprint schema on `bf3` / `gf3`.
- Preserved build/version/build-channel compatibility logic and notices.

### Documentation updated

- `docs/sync-rewrite-phase-log.md`
- `docs/recipe_registry_shard_sync_rewrite_plan.md`
- `docs/CODEBASE_ANALYSIS.local.historical.md`
- `local-tests/README.md`
- `local-tests/run-backend-tests.ps1`

### Focused test results

- `.\local-tests\run-syntax.ps1`: passed
- `.\local-tests\run-backend-tests.ps1`: passed after updating the active backend runner to an explicit supported-spec baseline
- `sync_phase1_legacy_noop_spec.lua`: 4 passed
- `sync_phase2_summary_foundation_spec.lua`: 8 passed
- `sync_phase34_block_pull_spec.lua`: 6 passed
- `sync_legacy_grep_gate_spec.lua`: 3 passed
- `build_channel_isolation_spec.lua`: 13 passed
- `p4_scan_opportunistic_spec.lua`: 13 passed
- `slash_output_spec.lua`: 9 passed

### Remaining blockers

- No active blocker remains for the requested hardening scope.
- Historical pre-rewrite sync specs still exist in-tree and should be either rewritten against the modern protocol or moved to a dedicated historical location in a later cleanup pass.
