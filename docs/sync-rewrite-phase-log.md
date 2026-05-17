# Recipe Registry — Sync Rewrite Phase Log

**Status:** refreshed from actual code and active test inspection on 2026-05-17.  
**Rule:** this is a phase report, not the architecture source of truth. `docs/sync-rewrite-roadmap.md` remains canonical.

---

## Current implementation state

The active runtime now supports only the modern protocol:

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
-> delayed/coalesced HELLO scheduling after sync/local-change recovery
```

The legacy manifest/revision/coordinator protocol is intentionally removed from active runtime code. Unknown inbound message kinds are ignored generically; there is no explicit legacy-message quarantine path.

Deleted runtime files:

- `DataManifest.lua`
- `SyncManifest.lua`
- `TrickleSync.lua`

Active runtime shape:

- one `globalFingerprint` value
- dirty-block runtime sync index cache
- delayed/coalesced `ScheduleHello(reason, delay?)`
- capped `inboundSeedSessions`
- build-channel / wire compatibility preserved

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

- `INDEX_DIFF_REQUEST` sends only `requestId` plus requester block digests.
- `INDEX_DIFF_RESPONSE` sends only `requestId` plus `offeredBlocks`.
- Seed selection is summary-driven and local; there is no coordinator.
- Requester digests compare `blockKey -> { count, fingerprint }` only.
- Lower-count local blocks are not offered back to a richer requester.

### Tests added or updated

- `sync_phase2_summary_foundation_spec.lua`
- `sync_phase34_block_pull_spec.lua`

### Test results

- `sync_phase2_summary_foundation_spec.lua`: 10 passed
- `sync_phase34_block_pull_spec.lua`: 10 passed

### Deviations from the roadmap

- `SUMMARY` can still arrive before the peer emits its own `HELLO`; the runtime primes provisional peer metadata from local build information so the active cycle can continue without widening payloads.

### Remaining blockers

- None in the active backend baseline.

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
- `SyncRuntime.lua`
- `local-tests/spec/sync_phase34_block_pull_spec.lua`

### Behavior implemented

- `BLOCK_PULL_REQUEST` is `requestId + blockKey` only.
- `BLOCK_SNAPSHOT` carries only block payload data needed for merge.
- Every received block is normalized and merged additively immediately.
- The pulled block fingerprint is recomputed immediately after merge.
- The in-memory block index is refreshed for the merged block.
- `globalFingerprintDirty` is set after block-level sync changes.
- Block `N+1` is never requested before block `N` is merged and recomputed.
- Final block completion does not wait on an unnecessary extra delay tick.

### Tests added or updated

- `sync_phase34_block_pull_spec.lua`

### Test results

- `sync_phase34_block_pull_spec.lua`: 10 passed

### Deviations from the roadmap

- `blockPayload.metadata` is still carried for UI/data completeness, but it remains non-authoritative and does not participate in diffing, equality, routing, or merge precedence.

### Remaining blockers

- None in the active backend baseline.

---

## Phase 5 — runtime cache, timeout, pacing, diagnostics

### Status

Completed for the supported rewrite path.

### Changed files

- `DataIndex.lua`
- `DataScan.lua`
- `DataSnapshot.lua`
- `Sync.lua`
- `SyncRuntime.lua`
- `SyncRequests.lua`
- `SyncTransfer.lua`
- `SyncDiagnostics.lua`
- `SyncPausePolicy.lua`
- `Core.lua`
- `MockSync.lua`
- `local-tests/spec/p4_scan_opportunistic_spec.lua`
- `local-tests/spec/slash_output_spec.lua`
- `local-tests/spec/sync_phase2_summary_foundation_spec.lua`
- `local-tests/spec/sync_phase34_block_pull_spec.lua`

### Behavior implemented

- Added in-memory runtime sync index caching with block-scoped dirtiness.
- Dirty block rebuilds update only affected blocks when possible.
- The runtime keeps exactly one `globalFingerprint`.
- `BuildLocalSummary()` is read-only from a sync lifecycle perspective.
- `BLOCK_PULL_DELAY_SECONDS = 1.0` paces sequential block pulls.
- Post-sync, post-abort, post-scan, reset, and recovery HELLOs flow through delayed/coalesced scheduling.
- Diagnostics and slash output now report sync-index/cache/runtime state instead of manifest/coordinator state.

### Tests added or updated

- `sync_phase2_summary_foundation_spec.lua`
- `sync_phase34_block_pull_spec.lua`
- `p4_scan_opportunistic_spec.lua`
- `slash_output_spec.lua`

### Test results

- `sync_phase2_summary_foundation_spec.lua`: 10 passed
- `sync_phase34_block_pull_spec.lua`: 10 passed
- `p4_scan_opportunistic_spec.lua`: 13 passed
- `slash_output_spec.lua`: 9 passed

### Deviations from the roadmap

- Full rebuild deferral still relies on existing timer/scheduler behavior rather than a separate new worker design. That is acceptable for the current backend baseline because the runtime no longer forces full rebuilds on every protocol step.

### Remaining blockers

- None in the active backend baseline.

---

## Phase 6 — legacy removal and final gate

### Status

Completed for active runtime code and active backend suites.

### Changed files

- `BuildInfo.lua`
- `Core.lua`
- `Data.lua`
- `MockSync.lua`
- `SyncCodec.lua`
- `SyncProtocol.lua`
- `SyncRuntime.lua`
- `SyncTransfer.lua`
- `local-tests/harness/comm-bus.lua`
- `local-tests/spec/build_channel_isolation_spec.lua`
- `local-tests/spec/sync_legacy_grep_gate_spec.lua`
- `local-tests/spec/sync_phase1_unsupported_message_spec.lua`
- `local-tests/run-backend-tests.ps1`

### Behavior implemented

- Removed active manifest/revision/coordinator runtime code from the sync path.
- Removed explicit legacy sync-kind handling from active runtime dispatch.
- Removed `maniReliable`, `manifestShards`, `chunkWindow`, and old snapshot-codec surfaces from active capability advertisement.
- Removed old outbound pump / chunk remnants from active runtime.
- Added a hard grep gate for active runtime code.
- Replaced legacy-noop coverage with generic unsupported-message coverage.

### Tests added or updated

- `sync_phase1_unsupported_message_spec.lua`
- `sync_legacy_grep_gate_spec.lua`
- `build_channel_isolation_spec.lua`

### Test results

- `sync_phase1_unsupported_message_spec.lua`: 2 passed
- `sync_legacy_grep_gate_spec.lua`: 3 passed
- `build_channel_isolation_spec.lua`: 13 passed

### Deviations from the roadmap

- Historical pre-rewrite specs remain in-tree for reference but are excluded from the active `all`, `quick`, and `sync` baselines.

### Remaining blockers

- None in the active backend baseline.

---

## Final correction pass

### Status

Completed for the requested scope on 2026-05-17.

### Changed files

- `BuildInfo.lua`
- `Core.lua`
- `DataIndex.lua`
- `MockSync.lua`
- `Sync.lua`
- `SyncCodec.lua`
- `SyncDiagnostics.lua`
- `SyncPausePolicy.lua`
- `SyncProtocol.lua`
- `SyncRequests.lua`
- `SyncRuntime.lua`
- `SyncTransfer.lua`
- `local-tests/harness/comm-bus.lua`
- `local-tests/spec/build_channel_isolation_spec.lua`
- `local-tests/spec/slash_output_spec.lua`
- `local-tests/spec/sync_legacy_grep_gate_spec.lua`
- `local-tests/spec/sync_phase1_unsupported_message_spec.lua`
- `local-tests/spec/sync_phase2_summary_foundation_spec.lua`
- `local-tests/spec/sync_phase34_block_pull_spec.lua`
- `docs/sync-rewrite-roadmap.md`
- `docs/sync-rewrite-phase-log.md`
- `docs/recipe_registry_shard_sync_rewrite_plan.md`
- `docs/CODEBASE_ANALYSIS.local.historical.md`
- `local-tests/README.md`

### Behavior implemented

- Active runtime has no explicit legacy protocol compatibility code.
- Active runtime uses exactly one `globalFingerprint`.
- HELLO scheduling is delayed/coalesced and no longer fires inline after local changes or sync completion/abort.
- Inbound seed sessions are tracked, capped, and cleared on pause-sensitive state changes.
- Abort-before-merge schedules retry discovery without treating the session as a data-changing sync result.
- Abort-after-partial-merge keeps merged data, refreshes `globalFingerprint`, and schedules recovery HELLO.

### Focused verification

- `.\local-tests\run-syntax.ps1`: passed
- `.\local-tests\run-backend-tests.ps1 -Suite sync`: passed

### Remaining blockers

- None for the active rewrite baseline.
