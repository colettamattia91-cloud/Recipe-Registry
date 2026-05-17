# Recipe Registry — Wire-3 Summary / Index-Diff / Block-Pull Rewrite Roadmap

**Status:** canonical rewrite roadmap compiled from the chat-approved v3 plan and later clarifications.  
**Branch target:** `develop`.  
**Protocol decision:** keep `WIRE_VERSION = 3`; break semantic compatibility with the old manifest/revision/coordinator sync behavior.  
**Rule:** this document is the canonical source of truth. Do not overwrite it with phase-specific plans.

---

## 1. Objective

Replace the automatic sync path with:

```text
HELLO
→ direct SUMMARY responses
→ one selected outbound seed
→ INDEX_DIFF_REQUEST
→ INDEX_DIFF_RESPONSE
→ sequential BLOCK_PULL_REQUEST / BLOCK_SNAPSHOT
→ immediate additive merge per block
→ immediate local block fingerprint recompute
→ global fingerprint marked dirty
→ single globalFingerprint recomputed only through explicit lifecycle refresh points
→ dirty index may continue one active outbound pull session but cannot publish HELLO
→ single globalFingerprint refreshed at outbound completion, partial-abort, or HELLO send-time validation
→ delayed/coalesced HELLO scheduling after readiness or sync-state changes
→ progressive HELLO discovery retry when no useful seed is found
```

The new sync model must be:

- active-owner based;
- content-only;
- data-driven;
- pull-based;
- incremental by block;
- additive and non-destructive during normal sync;
- independent from coordinator logic;
- independent from revision freshness;
- not a renamed manifest protocol.

---

## 2. Non-negotiable protocol constraints

### 2.1 Wire version

Keep:

```lua
Addon.WIRE_VERSION = 3
Addon.MIN_SUPPORTED_WIRE_VERSION = 3
```

Do not introduce wire `4` during this rewrite.

### 2.2 Capabilities

Use explicit new-model capabilities:

```lua
Addon.CAPABILITIES.indexDiffSync = true
Addon.CAPABILITIES.blockPullSync = true
```

Do not advertise removed legacy capabilities such as `manifestShards` or `maniReliable`.

### 2.3 Legacy message kinds

New protocol traffic must use explicit message kinds:

```text
SUMMARY
INDEX_DIFF_REQUEST
INDEX_DIFF_RESPONSE
BLOCK_PULL_REQUEST
BLOCK_SNAPSHOT
```

Legacy `IDX` must not be reused for new index-diff traffic. Active runtime code must not explicitly recognize or quarantine legacy sync kinds. Unknown inbound kinds are ignored generically.

### 2.4 Revision model removal

Revision-driven sync behavior must be eliminated completely.

Do not use `rev`, `revision`, `blockRevision`, `knownRev`, `wantRev`, `remoteRev`, `localRev`, `ownerRevision`, or revision-derived hints for:

- routing;
- seed selection;
- block comparison;
- pull priority;
- merge precedence;
- freshness decisions;
- equality checks;
- retry logic;
- diagnostics that influence behavior.

Persisted revision fields may remain in SavedVariables only as ignored historical metadata. Active sync code must not read them to make decisions.

### 2.5 Fingerprints

Fingerprints are for discovery/diff only.

- `globalFingerprint` indicates whether peers appear aligned or disaligned.
- `blockFingerprint` indicates whether a block appears equal or different.
- There is exactly one `globalFingerprint`; there is no committed/published/current split.
- `BLOCK_PULL_REQUEST` must not contain `expectedFingerprint`, `offeredFingerprint`, `knownFingerprint`, or equivalent transfer contracts.
- After receiving `BLOCK_SNAPSHOT`, the receiver merges additively, recomputes the local block fingerprint, marks global dirty, and continues.
- HELLO and SUMMARY are the only protocol publication points for the current local `globalFingerprint`.

### 2.6 Metadata

Metadata may travel in payloads for UI/data completeness, but it is non-authoritative for sync behavior.

Metadata must not affect:

- content equality;
- block fingerprint;
- global fingerprint;
- routing;
- priority;
- merge precedence;
- retry decisions;
- freshness decisions.

Revision must never be read, even indirectly through metadata merge helpers.

---

## 3. Data model

### 3.1 Block key

The atomic comparison and pull unit is:

```text
blockKey = ownerCharacter::professionKey
```

The block contains content keys, not transport metadata.

### 3.2 Content keys

Content keys include:

- normalized real recipe keys;
- runtime-only synthetic specialization keys.

Specialization is represented as a synthetic content key, for example:

```text
spec:<professionKey>:<specializationKey>
```

Synthetic specialization keys:

- are generated only at index/fingerprint time;
- are never persisted as recipe records;
- are never shown in UI/search/export as craftable recipes.

### 3.3 Block fingerprint

Conceptual formula:

```text
blockFingerprint = bf3:<contentCount>:<hash(sorted(contentKeys))>
```

`contentCount` includes real recipe keys plus synthetic specialization keys.

### 3.4 Global fingerprint

Conceptual formula:

```text
globalFingerprint = gf3:<activeOwnerCount>:<activeBlockCount>:<activeContentCount>:<hash(sorted(blockKey=blockFingerprint))>
```

`activeContentCount` includes real recipe keys plus synthetic specialization keys.

Hashing must be calculated from canonical sorted content, not compressed payloads or non-deterministic serialization.

---

## 4. Trusted roster and active owner rules

Active applies to owners, not recipes.

Before building local summaries, block indexes, or fingerprints, run trusted-roster-gated preflight.

Rules:

- If the roster is trusted, absent owners may be purged/excluded according to the cleanup policy.
- If the roster is incomplete, unavailable, warming up, or unstable after login/reload/instance transition, do not destructively purge persisted owners.
- In uncertain roster states, owners may be excluded from active publication if needed, but persisted data must not be deleted.
- Do not use `lastSeen` as the primary criterion when a trusted current roster is available.
- If the WoW API exposes reliable last-online data for members still in roster, a 14-day absence gate may be evaluated later, but must be tested in-game before destructive use.

---

## 5. Protocol messages

### 5.1 HELLO

Guild-wide, lightweight. Sent only when:

- warmup is complete;
- roster/index preflight has completed;
- local index is ready;
- not paused by instance/raid/runtime state;
- not saturated.

Payload concept:

```text
HELLO:
  kind
  sender
  wireVersion = 3
  syncModel = "index-diff-block-pull"
  indexStatus = "ready"
  activeOwnerCount
  activeBlockCount
  activeContentCount
  globalFingerprint
```

HELLO must not trigger `AD`, `IDX`, `MANI`, `MREQ`, revision requests, coordinator fan-out, manifest refresh, or legacy request queues.

HELLO is the publication mechanism for the single local `globalFingerprint`. Peers only learn the current fingerprint from HELLO/SUMMARY payloads.

### 5.2 SUMMARY

Direct response to the HELLO sender.

A peer responds only if:

- it is ready;
- it is not paused;
- it is not saturated;
- its `globalFingerprint` differs from the HELLO sender's fingerprint;
- jitter/cooldown allows it.

Payload concept:

```text
SUMMARY:
  kind
  sender
  target
  helloId
  activeOwnerCount
  activeBlockCount
  activeContentCount
  globalFingerprint
```

SUMMARY must not contain revision fields.

### 5.3 INDEX_DIFF_REQUEST

Direct from requester to selected seed.

Payload concept:

```text
INDEX_DIFF_REQUEST:
  kind
  requestId
  sender
  target
  blocks:
    blockKey -> {
      count
      fingerprint
    }
```

Do not use legacy `IDX`.

### 5.4 INDEX_DIFF_RESPONSE

The seed compares the requester's index with its own current working index and returns only blocks the requester can pull from that seed.

Payload concept:

```text
INDEX_DIFF_RESPONSE:
  kind
  requestId
  sender
  target
  offeredBlocks:
    - blockKey
      count
      fingerprint
      reason
```

The fingerprint here is discovery/debug information only. It is not a pull contract or merge gate.

### 5.5 BLOCK_PULL_REQUEST

Always one block at a time.

```text
BLOCK_PULL_REQUEST:
  kind
  requestId
  sender
  target
  blockKey
```

No fingerprint fields.

### 5.6 BLOCK_SNAPSHOT

Direct response containing the current live content of the requested block.

```text
BLOCK_SNAPSHOT:
  kind
  requestId
  sender
  target
  blockKey
  blockPayload
```

The seed must serve from current live block data / working block index, not from stale cached summary state.

A peer with `globalFingerprintDirty = true` may still serve updated live block content inbound.

---

## 6. Seed election

After HELLO, collect SUMMARY responses during a short configurable window.

Initial target values:

```text
SUMMARY_COLLECTION_WINDOW = 5-8 seconds
MAX_OUTBOUND_SEEDS_PER_CYCLE = 1
```

Ranking:

1. different `globalFingerprint`;
2. higher `activeContentCount`;
3. higher `activeBlockCount`;
4. higher `activeOwnerCount`;
5. peer not in cooldown/backoff;
6. better peer health/responsiveness if already available;
7. deterministic tie-break by `peerKey`.

Select at most one outbound seed per cycle. Do not parallelize multiple seeds in the first implementation.

---

## 7. INDEX_DIFF rules

When seed C receives requester A's index:

```text
1. A does not have blockKey, C has it:
   C offers the block to A.

2. A has blockKey, C does not:
   C does not reverse-pull during this inbound seed session.
   Future HELLO cycles handle eventual reverse convergence.

3. A.fingerprint == C.fingerprint:
   no action.

4. A.count == C.count and fingerprint differs:
   C offers its block to A.
   C does not reverse-pull immediately from A.

5. A.count < C.count and fingerprint differs:
   C offers its block to A.

6. A.count > C.count and fingerprint differs:
   C does not offer its lower-count block.
   Any delta is handled by future HELLO cycles.
```

The edge case where the lower-count block contains a unique key is handled by future cycles and tests, not by complicating the first protocol.

---

## 8. Pull scheduling and merge

Per outbound session:

```text
MAX_OUTBOUND_PULL_SESSIONS = 1
MAX_BLOCK_PULL_IN_FLIGHT_PER_SESSION = 1
BLOCK_PULL_DELAY_NORMAL = 1-2 seconds
```

Rules:

1. Request one `blockKey`.
2. Wait for `BLOCK_SNAPSHOT`.
3. Clean/normalize payload.
4. Merge additively immediately.
5. Recompute local block fingerprint immediately.
6. Update in-memory block index.
7. Mark global fingerprint dirty.
8. Request the next block only after the current block has been applied and recomputed.

The runtime keeps one `globalFingerprint` value plus dirty/cache state. HELLO is the publication mechanism; it carries the current `globalFingerprint` at send time.

Passive diagnostics such as `lastGlobalFingerprintAt` or `lastGlobalFingerprintReason` are allowed only for debug output and tests. They must not affect readiness, HELLO eligibility, routing, retry, merge, equality, or seed selection.

---

## 9. Timeout, reset, and cycle completion

If the seed does not respond within the timeout, or responds as paused/unavailable:

1. abort/reset the session toward that seed;
2. clear pending requests toward that seed;
3. keep already applied blocks;
4. recompute the single globalFingerprint if sync changed local data;
5. schedule a delayed/coalesced future HELLO through the common scheduling path.

If a HELLO completes its SUMMARY collection window without any useful ready summary:

1. treat that outcome as a discovery miss, not as an error;
2. do not start a pull session;
3. do not apply heavy peer cooldown;
4. schedule a future HELLO through progressive retry backoff.

The periodic HELLO interval may remain as a watchdog only. It must not override or short-circuit discovery retry backoff after a real discovery miss.

Initial target values:

```text
BLOCK_PULL_RESPONSE_TIMEOUT = 15-30 seconds
POST_SYNC_HELLO_JITTER = 5-15 seconds
POST_SYNC_HELLO_COOLDOWN = 30-60 seconds
DISCOVERY_RETRY = 20s +20s per miss, capped at 300s, with jitter
```

---

## 10. Startup readiness

Network sync readiness is event-driven, not driven by a fixed login/reload timer. In this addon lifecycle, SavedVariables readiness is established from addon initialization, player readiness from `PLAYER_LOGIN`, and world-transition gating from `PLAYER_ENTERING_WORLD`; fixed timers remain watchdogs only.

`syncReady` becomes true only when all of the following are satisfied:

- SavedVariables are initialized;
- player identity is ready;
- world transition / warmup has completed;
- trusted-roster preflight is ready;
- the runtime sync index is ready;
- protocol pause policy is inactive;
- runtime pressure is below the sync saturation gate.

When `syncReady` transitions from false to true, schedule one delayed/coalesced HELLO through the common scheduling path. Do not broadcast HELLO inline from login, reload, world entry, local scan, sync completion, sync abort, or reset handlers.

During an active outbound pull session, a dirty index may remain usable only for continuing the already-selected seed session from block `N` to block `N+1`. That dirty state must not count as general `syncReady`, must not publish HELLO, and must not start unrelated seed selection or inbound seed service.

---

## 11. Concurrency

Each peer may have:

- at most one outbound pull session;
- multiple inbound seed sessions within a low cap;
- inbound reads while outbound writes are applying.

Rules:

- If A is pulling from C, A cannot choose another outbound seed.
- If A is pulling from C, A may serve B as seed.
- If B pulls from A a block just updated by C, B receives the updated live block.
- A does not reverse-pull from B based on the inbound B→A session.
- Reverse deltas are handled by future HELLO cycles.

---

## 12. File-by-file target plan

### BuildInfo.lua — rewrite

Keep `WIRE_VERSION = 3` and `MIN_SUPPORTED_WIRE_VERSION = 3`; advertise `indexDiffSync` and `blockPullSync`; do not advertise removed legacy capability aliases.

### RecipeRegistry.toc — rewrite

Add `DataIndex.lua`. Remove `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` from active load order once runtime, slash, diagnostics, mock, harness, and tests are clean.

### Data.lua — rewrite

Move sync-facing truth away from manifest/revision helpers. Keep persisted historical metadata ignored by active sync logic. Add sync-facing helpers for trusted roster state, active owner filtering, single-global-fingerprint dirty/cache state, and metadata storage that cannot influence sync behavior.

### DataIndex.lua — add

Own trusted-roster-gated active index construction, runtime-only synthetic specialization keys, content-only block/global fingerprints, local summary generation, requester index export, and in-memory dirty-block cache management.

### DataSnapshot.lua — rewrite

Replace whole-owner snapshot flow with block-scoped snapshot build/apply. Apply each received block immediately, merge additively, recompute local block fingerprint immediately, and mark global fingerprint dirty. No transfer or merge step may consult revision fields.

### DataCleanup.lua — neutral-reuse

Keep sanitation and corruption-repair helpers, but detach them from manifest/revision/coordinator behavior. If cleanup needs sync signaling, it must mark the new index dirty instead of feeding manifest-era paths.

### MergeEngine.lua — rewrite

Define sync merge as content-only additive merge. Metadata merge is allowed for completeness, but must never affect equality, routing, priority, merge precedence, retry, or freshness. Revision must never be read.

### GuildLifecycleMaintenance.lua — rewrite

Add trusted-roster sync preflight. If roster is incomplete, unavailable, warming up, or unstable, do not destructively purge persisted owners. Uncertain owners may be excluded from active publication until trust is confirmed.

### BootstrapSync.lua — debug-only

Keep only if bootstrap UI/diagnostics still matter. It must not influence seed election, dataset trust, or normal sync routing.

### DataManifest.lua — delete after migration pass

Remove manifest cache, manifest serial/fingerprint logic, manifest delta builds, and manifest summary/debug surfaces.

### TrickleSync.lua — delete after migration pass

Remove manifest comparison, manifest chunk generation, peer manifest state, and manifest-based missing-block detection.

### Sync.lua — rewrite

Replace manifest/coordinator/request-revision state with hello-cycle state, summary collection, selected outbound seed, ordered wanted-block list, active outbound session, inbound seed service state, and new telemetry.

### SyncRuntime.lua — rewrite

Keep version/build-channel eligibility, online peer tracking, pause/warmup handling, queue caps, and worker orchestration. Remove coordinator state, revision registry behavior, manifest catch-up queues, and auto-tick revision pulls. Enforce one outbound seed per cycle, delayed/coalesced HELLO scheduling, and capped inbound seed session tracking.

### SyncProtocol.lua — rewrite

Broadcast HELLO, whisper SUMMARY, handle `INDEX_DIFF_REQUEST`, `INDEX_DIFF_RESPONSE`, `BLOCK_PULL_REQUEST`, and `BLOCK_SNAPSHOT`. Unknown inbound message kinds are ignored generically with no reply and no sync side effects.

### SyncRequests.lua — rewrite

Remove `QueueRequest(..., rev, ...)` and all member/revision queues. Replace with seed selection, ordered wanted-block ledger, sequential next-block orchestration, and timeout/reset handling. Wanted-block state stores `blockKey` plus optional diff/debug reason only; no expected fingerprint contract.

### SyncTransfer.lua — rewrite

Serve `BLOCK_SNAPSHOT` from current live block data / working block index, not from stale summary state. Remove `knownRev`, `wantRev`, revision-derived identities, expected/offered fingerprint semantics, and old chunk-pipeline remnants.

### SyncCodec.lua — neutral-reuse / rewrite

Keep only transport-neutral serializer helpers actually used by the modern protocol. Remove legacy snapshot-codec naming and capability surfaces that no longer participate in `INDEX_DIFF_RESPONSE` or `BLOCK_SNAPSHOT`.

### SyncManifest.lua — delete after migration pass

Remove `MANI/MREQ` send, receive, retry, cache, recovery, and catch-up logic after all call sites are migrated. During early phases it may remain loaded with inert compatibility stubs.

### SyncDiagnostics.lua — rewrite

Replace manifest/coordinator/revision diagnostics with hello/summary/index-diff/block-pull/session diagnostics. Add bounded runtime observability for readiness gates, HELLO scheduling, SUMMARY collection, discovery retry, seed selection, outbound pull progress, inbound seed session caps, cache/fingerprint state, compatibility skips, and generic unsupported-message counts. `lastGlobalFingerprintAt` and `lastGlobalFingerprintReason` remain passive diagnostics only and must not affect runtime behavior.

### SyncPausePolicy.lua — neutral-reuse

Keep pause semantics, retargeted to sequential block pulls and trusted-roster gating.

### Core.lua — rewrite

Replace `AdvertiseLocalRevision` triggers with “mark sync index dirty + schedule HELLO.” `/rr rescan` remains a local scan/rescan command. Other manifest/pull slash surfaces migrate to new index/sync diagnostics or deprecated aliases. `syncreset` clears hello/summary/index-diff/block-pull runtime only.

### MockSync.lua — rewrite

Simulate HELLO, direct SUMMARY, explicit `INDEX_DIFF_REQUEST/RESPONSE`, and sequential `BLOCK_PULL_REQUEST/BLOCK_SNAPSHOT`. Remove manifest and revision paths.

### local-tests/harness/load-addon.lua — rewrite

Add `DataIndex.lua`. Stop loading removed modules only after final call-site migration.

### local-tests/harness/comm-bus.lua — rewrite

Track explicit new message kinds, one-seed cycle state, sequential block pulls, and live inbound service. Remove coordinator/manifest metrics.

### Tests — delete/rewrite/add

Delete and replace manifest-era tests:

```text
local-tests/spec/manifest_*
manifest_comm_bus_spec.lua
manifest_transport_pressure_spec.lua
p3_manifest_diagnostics_spec.lua
```

Rewrite affected sync/runtime tests:

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

Add:

```text
sync_massive_spec.lua
sync_legacy_grep_gate_spec.lua or equivalent hard gate
```

### Docs — rewrite

Rewrite:

```text
README.md
local-tests/README.md
docs/CODEBASE_ANALYSIS.local.md
```

Keep this roadmap as the canonical source of truth.

---

## 12. Legacy functions to remove or disable

Remove behavior and call sites for:

```text
AdvertiseLocalRevision
BroadcastIndex
HandleIndex
HandleAdvertise
RecordRevisionHint
GetKnownRevision
QueueRequest(..., rev, ...)
RequestGuildCatchup
RecomputeCoordinator
IsCoordinator
SendManifestToPeer
RequestManifestRefresh
ProcessPeerManifestComparison
manifest catch-up helpers
manifest recovery helpers
```

Remove sync use of:

```text
rev
revision
blockRevision
knownRev
wantRev
remoteRev
localRev
ownerRevision
any revision-derived retry, priority, equality, or freshness logic
```

Do not keep explicit inbound handlers for `IDX`, `AD`, `MANI`, or `MREQ`. Unknown inbound message kinds are ignored generically and must not enqueue sync work.

---

## 13. Hard completion gate

Add `local-tests/spec/sync_legacy_grep_gate_spec.lua` or equivalent harness check.

The gate must fail if active sync code still contains behavior-driving references to:

```text
rev
revision
blockRevision
knownRev
wantRev
remoteRev
localRev
ownerRevision
RecordRevisionHint
GetKnownRevision
QueueRequest(..., rev, ...)
AdvertiseLocalRevision
BroadcastIndex
HandleIndex
HandleAdvertise
SendManifestToPeer
RequestManifestRefresh
ProcessPeerManifestComparison
```

Allowed exceptions must be isolated to:

- SavedVariables historical metadata migration;
- tests proving unknown kinds are ignored generically;
- documentation explaining removed behavior.

This is a final rewrite completion gate, not necessarily a Phase 1 gate.

---

## 14. Risk points

- Additive merge is intentionally non-destructive; downward convergence requires a future tombstone/reset design and must not be smuggled into this rewrite.
- Runtime-only specialization keys must never leak into persisted recipe sets or UI/export code paths.
- Removed legacy capability names can confuse tests and diagnostics unless they are eliminated from active capability advertisement.
- Deleting manifest modules too early risks dangling slash/debug/mock/test references, so call-site migration must precede `.toc` removal.
- Trusted-roster gating must be conservative; unstable roster state must not cause destructive purge.
- Diagnostics must distinguish dirty cache state from the single live `globalFingerprint`.

---

## 15. Implementation phases

### Phase 1 — containment only

- Add `DataIndex.lua` skeleton and wire it into load order.
- Keep `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` loaded.
- Remove explicit inbound legacy-kind handling and keep only generic unsupported-message ignore behavior.
- Stop outbound legacy traffic.
- Cut revision/coordinator request seeding.
- Keep `/rr rescan` local, then mark sync index dirty and schedule HELLO path.
- Do not implement SUMMARY, INDEX_DIFF, or BLOCK_PULL.

### Phase 2 — DataIndex + HELLO/SUMMARY + seed election

- Implement real active-owner index foundation.
- Implement content-only block/global fingerprints.
- Implement trusted-roster gating.
- Update HELLO payload to publish new summary fields.
- Add direct SUMMARY responses.
- Add summary collection and one-seed selection.
- Do not send INDEX_DIFF yet.

### Phase 3 — INDEX_DIFF

- Implement `INDEX_DIFF_REQUEST` and `INDEX_DIFF_RESPONSE`.
- Use requester compact block digest.
- Use seed current working index.
- Return offered block list only.
- Do not implement block snapshots yet unless Phase 3 is explicitly expanded.

### Phase 4 — BLOCK_PULL / BLOCK_SNAPSHOT / immediate merge

- Implement sequential `BLOCK_PULL_REQUEST` and `BLOCK_SNAPSHOT`.
- Serve from live block data.
- Apply every block immediately.
- Recompute local block fingerprint immediately.
- Mark global dirty.
- Request next block only after merge/recompute.

### Phase 5 — timeouts, reset, diagnostics, soak/massive tests

- Implement abort/reset behavior.
- Refresh the single globalFingerprint on completion or partial-abort when local sync changed data.
- Schedule post-sync HELLO through the delayed/coalesced scheduler when needed.
- Rewrite diagnostics and runtime status around readiness, HELLO scheduling, discovery retry, inbound/outbound sessions, and cache/fingerprint observability.
- Stabilize soak/heavy/massive tests.

### Phase 6 — legacy module removal and final gate

- Remove `DataManifest.lua`, `SyncManifest.lua`, and `TrickleSync.lua` from `.toc` and test loader only after call-site migration is clean.
- Apply hard grep/fail gate.
- Rewrite docs and README.
- Run full test suite.
