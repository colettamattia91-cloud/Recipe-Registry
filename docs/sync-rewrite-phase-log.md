# Recipe Registry — Sync Rewrite Phase Log

**Status:** append-only phase log.  
**Rule:** add phase-specific plans and reports here. Do not overwrite the canonical roadmap or call-site inventory.

---

## Phase 1 — Containment pass

### Phase 1 execution plan summary

Scope:

- Add `DataIndex.lua` skeleton and wire it into addon load order.
- Keep `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` loaded.
- Convert inbound `AD`, `IDX`, `MANI`, and `MREQ` behavior into deprecated no-op handlers.
- Stop all reachable outbound `AD`, `IDX`, `MANI`, and `MREQ` traffic.
- Cut revision/coordinator request seeding.
- Keep `/rr rescan` as a local scan/rescan command.
- After scan/rescan, mark sync index dirty and schedule the HELLO-cycle path.
- Do not implement SUMMARY, INDEX_DIFF, BLOCK_PULL, seed election, or full new protocol behavior yet.

### Phase 1 files expected to change

- `DataIndex.lua`
- `RecipeRegistry.toc`
- `local-tests/harness/load-addon.lua`
- `SyncProtocol.lua`
- `Sync.lua`
- `SyncRuntime.lua`
- `SyncRequests.lua`
- `SyncManifest.lua`
- `Core.lua`
- focused Phase 1 test files

### Phase 1 tests expected

- Inbound `AD`, `IDX`, `MANI`, and `MREQ` are ignored safely with no queued work and no Lua errors.
- Scan/rescan/startup no longer emit new legacy outbound traffic.
- No coordinator/revision path still seeds request generation.
- HELLO does not trigger `MANI`, `MREQ`, `IDX`, or `AD` traffic during Phase 1.

### Phase 1 completion status

Implemented.

### Phase 1 implementation summary

- Added `DataIndex.lua` as a skeleton `Data` extension and wired it into addon load order.
- Kept `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` intentionally loaded.
- Converted inbound `AD`, `IDX`, `MANI`, and `MREQ` handling into deprecated no-op behavior.
- Disabled reachable outbound `AD`, `IDX`, `MANI`, and `MREQ` generation.
- Cut revision-driven request generation and coordinator/index fan-out as behavior-driving paths.
- Kept `/rr rescan` as a local scan/rescan command, then redirected post-scan sync signaling to “mark sync index dirty + schedule HELLO cycle.”
- Did not implement `SUMMARY`, `INDEX_DIFF_REQUEST`, `INDEX_DIFF_RESPONSE`, `BLOCK_PULL_REQUEST`, `BLOCK_SNAPSHOT`, or additive block merge in Phase 1.

### Phase 1 changed files

- `DataIndex.lua`
- `RecipeRegistry.toc`
- `local-tests/harness/load-addon.lua`
- `Core.lua`
- `Sync.lua`
- `SyncProtocol.lua`
- `SyncRuntime.lua`
- `SyncRequests.lua`
- `SyncManifest.lua`
- `local-tests/spec/sync_phase1_legacy_noop_spec.lua`
- `local-tests/spec/p4_scan_opportunistic_spec.lua`
- `local-tests/spec/slash_output_spec.lua`
- `local-tests/spec/build_channel_isolation_spec.lua`

### Phase 1 legacy behavior disabled

- Startup no longer emits `AD`.
- Scan/rescan flows no longer emit `AD`.
- `HELLO` no longer triggers `MANI`, `MREQ`, `IDX`, or revision-driven request work.
- `BroadcastIndex(...)` is a deprecated no-op.
- `QueueRequest(..., rev, ...)` is a deprecated no-op.
- `AutoSyncTick()` no longer seeds revision-driven requests from registry hints.
- `SendManifestToPeer(...)`, `RequestManifestRefresh(...)`, and `BroadcastManifestToOnlinePeers(...)` are outbound no-ops.
- `KickoffDatabaseResync()` now marks sync index dirty and schedules HELLO only.
- `/rr pull` no longer creates legacy catch-up work.

### Phase 1 focused tests added/updated

- Added `local-tests/spec/sync_phase1_legacy_noop_spec.lua`
- Updated `local-tests/spec/p4_scan_opportunistic_spec.lua`
- Updated `local-tests/spec/slash_output_spec.lua`
- Updated `local-tests/spec/build_channel_isolation_spec.lua`

### Phase 1 focused test results

- `sync_phase1_legacy_noop_spec.lua`: 4 passed
- `p4_scan_opportunistic_spec.lua`: 13 passed
- `slash_output_spec.lua`: 15 passed
- `build_channel_isolation_spec.lua`: 9 passed

### Phase 1 explicit confirmations

- Phase 1 did not implement `SUMMARY`.
- Phase 1 did not implement `INDEX_DIFF_REQUEST`.
- Phase 1 did not implement `INDEX_DIFF_RESPONSE`.
- Phase 1 did not implement `BLOCK_PULL_REQUEST`.
- Phase 1 did not implement `BLOCK_SNAPSHOT`.
- Phase 1 did not implement additive block merge.
- Outbound `AD` / `IDX` / `MANI` / `MREQ` were disabled.
- Inbound `AD` / `IDX` / `MANI` / `MREQ` were deprecated no-op only.
- No revision/coordinator path seeded sync work after Phase 1.

---

## Phase 2 — DataIndex + HELLO/SUMMARY + seed election

### Goal

Build the real discovery foundation for the new sync model:

- real `DataIndex.lua` behavior;
- trusted-roster-gated active owner/block indexing;
- content-only block/global fingerprints;
- HELLO summary payload;
- direct SUMMARY responses;
- summary collection and one-seed election.

Do not implement `INDEX_DIFF_REQUEST`, `INDEX_DIFF_RESPONSE`, `BLOCK_PULL_REQUEST`, or `BLOCK_SNAPSHOT` in Phase 2.

### Phase 2 scope

#### 1. DataIndex.lua

Implement:

- trusted-roster-gated active owner discovery;
- active block enumeration using `blockKey = ownerCharacter::professionKey`;
- normalized content key extraction;
- runtime-only synthetic specialization content keys;
- content-only `blockFingerprint`;
- content-only `globalFingerprint`;
- `activeOwnerCount`;
- `activeBlockCount`;
- `activeContentCount`;
- `BuildLocalSummary()`;
- dirty vs committed global fingerprint state.

Rules:

- fingerprints must ignore revision, timestamp, `sourceType`, online state, skill metadata, and transport metadata;
- specialization keys must never be persisted as real recipes;
- specialization keys must never appear in UI/search/export as craftable recipes;
- metadata may exist for UI completeness only and must not affect sync identity.

#### 2. Trusted roster behavior

Implement conservative trusted-roster gating:

- if roster is trusted, absent owners may be purged/excluded according to roadmap rules;
- if roster is incomplete, unavailable, warming up, or unstable, do not destructively purge persisted owners;
- in uncertain states, owners may be excluded from active publication if needed, but data must not be deleted.

#### 3. HELLO payload

Update HELLO so it publishes only the new lightweight summary fields:

- `wireVersion = 3`;
- `syncModel = "index-diff-block-pull"`;
- `indexStatus = "ready"` only after roster/index preflight succeeds;
- `activeOwnerCount`;
- `activeBlockCount`;
- `activeContentCount`;
- `globalFingerprint`.

HELLO must not trigger `AD`, `IDX`, `MANI`, `MREQ`, revision requests, coordinator fan-out, or manifest refresh.

#### 4. SUMMARY

Add direct SUMMARY response behavior:

- respond to HELLO with SUMMARY only if ready, not paused, not saturated, and `globalFingerprint` differs;
- send SUMMARY directly to the HELLO sender;
- include `helloId`/correlation if available, active counts, and `globalFingerprint`;
- do not include revision fields;
- do not trigger INDEX_DIFF yet in Phase 2.

#### 5. Seed election

Implement summary collection and seed selection state only:

- collect SUMMARY responses for a short configurable window;
- select at most one outbound seed per cycle;
- rank by:
  1. different `globalFingerprint`;
  2. higher `activeContentCount`;
  3. higher `activeBlockCount`;
  4. higher `activeOwnerCount`;
  5. peer not in cooldown/backoff;
  6. peer health/responsiveness if already available;
  7. deterministic tie-break by `peerKey`.
- after seed selection, stop;
- do not send `INDEX_DIFF_REQUEST` yet.

#### 6. Diagnostics

Add/update diagnostics for:

- index ready/not ready;
- trusted roster state;
- local summary;
- `helloSent`;
- `summarySent`;
- `summaryReceived`;
- `seedSelected`;
- `legacyMessageIgnored`;
- `globalFingerprintDirty`;
- `globalFingerprintCommitted`.

Remove or suppress manifest/coordinator/revision diagnostics as active operational signals where Phase 2 touches them.

### Phase 2 focused tests

Add/update tests proving:

- DataIndex fingerprints ignore revision, timestamps, `sourceType`, online state, skill metadata, and metadata;
- synthetic specialization keys affect fingerprint but are not persisted or exposed as recipes;
- trusted-roster gating does not destructively purge owners when roster trust is false;
- HELLO publishes the new summary fields only;
- HELLO does not trigger `AD`, `IDX`, `MANI`, `MREQ`, `QueueRequest`, manifest refresh, or coordinator work;
- SUMMARY is sent only when both peers are ready and fingerprints differ;
- SUMMARY is not sent when fingerprints match;
- at most one outbound seed is selected per cycle;
- seed selection uses counts and deterministic tie-breaks;
- Phase 2 still sends no `INDEX_DIFF_REQUEST`, `INDEX_DIFF_RESPONSE`, `BLOCK_PULL_REQUEST`, or `BLOCK_SNAPSHOT`.

### Phase 2 implementation summary

Implemented the real discovery foundation for the wire-3 rewrite without starting Phase 3.

- `DataIndex.lua` now builds the real active-owner index foundation.
- HELLO now publishes the new lightweight summary payload only.
- SUMMARY now exists as a direct response path.
- Summary collection and one-seed selection state now exist.
- No `INDEX_DIFF_REQUEST`, `INDEX_DIFF_RESPONSE`, `BLOCK_PULL_REQUEST`, `BLOCK_SNAPSHOT`, or additive block merge were implemented in this phase.

### Phase 2 changed files

- `DataIndex.lua`
- `BuildInfo.lua`
- `Sync.lua`
- `SyncCodec.lua`
- `SyncProtocol.lua`
- `SyncRuntime.lua`
- `SyncDiagnostics.lua`
- `local-tests/spec/sync_phase2_summary_foundation_spec.lua`

### DataIndex behavior implemented

- Trusted-roster-gated active owner discovery.
- Active block enumeration using `blockKey = ownerCharacter::professionKey`.
- Normalized content key extraction from real recipe keys.
- Runtime-only synthetic specialization content keys.
- Content-only `blockFingerprint`.
- Content-only `globalFingerprint`.
- `activeOwnerCount`.
- `activeBlockCount`.
- `activeContentCount`.
- `BuildLocalSummary()`.
- Dirty vs committed global fingerprint state.

Rules satisfied in implementation:

- Fingerprints ignore revision, timestamps, `sourceType`, online state, skill metadata, and transport metadata.
- Synthetic specialization keys are generated only at runtime for index/fingerprint identity.
- Synthetic specialization keys are never persisted as real recipe rows.
- Synthetic specialization keys are never exposed as craftable recipe rows by the sync identity layer.
- Metadata remains non-authoritative for sync identity.

### Trusted-roster behavior implemented

- Conservative roster-trust evaluation is now part of `DataIndex`.
- If roster trust is false because roster is stale, empty, warming up, or world-transition gated, persisted owners are not deleted.
- In uncertain states, non-local owners may be excluded from active publication.
- Local owner data remains publishable even when roster trust is not yet established.

### HELLO / SUMMARY behavior implemented

HELLO now publishes:

- `wireVersion = 3`
- `syncModel = "index-diff-block-pull"`
- `indexStatus`
- `activeOwnerCount`
- `activeBlockCount`
- `activeContentCount`
- `globalFingerprint`
- `helloId` correlation

HELLO no longer publishes or triggers:

- `rev`
- `updatedAt`
- manifest fingerprint fields
- manifest request fields
- `AD`
- `IDX`
- `MANI`
- `MREQ`
- revision-driven requests
- coordinator fan-out
- manifest refresh

SUMMARY behavior implemented:

- SUMMARY is sent directly to the HELLO sender.
- SUMMARY is sent only if local peer is ready, not paused, not saturated, and fingerprint differs.
- SUMMARY includes `helloId`, active counts, and `globalFingerprint`.
- SUMMARY does not include revision fields.
- SUMMARY does not trigger `INDEX_DIFF_REQUEST` in Phase 2.

### Seed-election behavior implemented

- Added hello-cycle state with correlation id and summary collection window.
- Collected SUMMARY responses per active hello cycle.
- Selected at most one outbound seed per cycle.
- Ranked candidates by:
  1. different `globalFingerprint`
  2. higher `activeContentCount`
  3. higher `activeBlockCount`
  4. higher `activeOwnerCount`
  5. peer not in backoff
  6. peer health score when available
  7. deterministic tie-break by `peerKey`
- Stopped after seed selection.
- Did not send `INDEX_DIFF_REQUEST`.

### Diagnostics added/updated

- Added/updated index readiness reporting.
- Added trusted-roster state reporting.
- Added local summary reporting.
- Added/updated telemetry counters for:
  - `helloSent`
  - `summarySent`
  - `summaryReceived`
  - `seedSelected`
  - `legacyMessagesIgnored`
  - `globalFingerprintDirty`
  - `globalFingerprintCommitted`
- Added selected-seed visibility in runtime debug state.
- Suppressed coordinator role as an active operational signal where Phase 2 touched the diagnostics surface.

### Focused Phase 2 tests added/updated

- Added `local-tests/spec/sync_phase2_summary_foundation_spec.lua`
- Re-ran `local-tests/spec/sync_phase1_legacy_noop_spec.lua`
- Re-ran `local-tests/spec/build_channel_isolation_spec.lua`

### Focused Phase 2 test coverage

The focused Phase 2 spec proved:

- DataIndex fingerprints ignore revision and metadata-only fields.
- Synthetic specialization keys affect fingerprint but are not persisted as recipes.
- Trusted-roster gating does not destructively purge owners when roster trust is false.
- HELLO publishes the new summary fields only.
- HELLO does not trigger legacy outbound or request work.
- SUMMARY is sent only when both peers are ready and fingerprints differ.
- SUMMARY is not sent when fingerprints match.
- At most one outbound seed is selected per cycle.
- Seed selection uses counts and deterministic tie-breaks.
- Phase 2 still sends no `INDEX_DIFF_REQUEST`, `INDEX_DIFF_RESPONSE`, `BLOCK_PULL_REQUEST`, or `BLOCK_SNAPSHOT`.

### Focused Phase 2 test results

- `sync_phase2_summary_foundation_spec.lua`: 7 passed
- `sync_phase1_legacy_noop_spec.lua`: 4 passed
- `build_channel_isolation_spec.lua`: 9 passed

### Remaining legacy modules intentionally still loaded

- `DataManifest.lua`
- `SyncManifest.lua`
- `TrickleSync.lua`

These remain loaded intentionally at the end of Phase 2 and were not removed from `.toc`.

### Phase 2 explicit confirmations

- Phase 2 did not implement `INDEX_DIFF_REQUEST`.
- Phase 2 did not implement `INDEX_DIFF_RESPONSE`.
- Phase 2 did not implement `BLOCK_PULL_REQUEST`.
- Phase 2 did not implement `BLOCK_SNAPSHOT`.
- Phase 2 did not implement additive block merge.
- Outbound `AD` / `IDX` / `MANI` / `MREQ` remain disabled.
- Inbound `AD` / `IDX` / `MANI` / `MREQ` remain deprecated no-op only.
- No revision/coordinator path seeds sync work.
- Legacy `IDX` was not reused for new protocol traffic.

### Unresolved blockers

- No Phase 2 blocker remained at completion.
- Broader manifest-era suites and Phase 3+ protocol work remain intentionally deferred.

---

## Phase 3 — INDEX_DIFF

Pending.

---

## Phase 4 — BLOCK_PULL / BLOCK_SNAPSHOT / immediate merge

Pending.

---

## Phase 5 — timeout/reset/diagnostics/soak stabilization

Pending.

---

## Phase 6 — legacy module removal and final gate

Pending.
