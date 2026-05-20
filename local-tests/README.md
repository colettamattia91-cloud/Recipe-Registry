# Local Recipe Registry Tests

This folder contains the local Lua harness and is excluded from release zips through `.pkgmeta`.

## Commands

Syntax:

```powershell
.\local-tests\run-syntax.ps1
```

Backend runner:

```powershell
.\local-tests\run-backend-tests.ps1
```

Focused spec:

```powershell
.\local-tests\run-backend-tests.ps1 -Spec sync_phase34_block_pull_spec.lua
```

Active soak coverage:

```powershell
.\local-tests\run-backend-tests.ps1 -Suite soak
```

## Current backend load order

`harness/load-addon.lua` mirrors the active backend load order:

### Data cluster

- `Data.lua`
- `DataAtlasLoot.lua`
- `DataScan.lua`
- `DataSnapshot.lua`
- `DataCatalog.lua`
- `DataIndex.lua`
- `DataCleanup.lua`

### Sync cluster

- `Sync.lua`
- `SyncRuntime.lua`
- `SyncProtocol.lua`
- `SyncCodec.lua`
- `SyncRequests.lua`
- `SyncTransfer.lua`
- `SyncDiagnostics.lua`

Legacy runtime modules are no longer loaded:

- `DataManifest.lua`
- `SyncManifest.lua`
- `TrickleSync.lua`

## Current focused coverage

- generic unsupported inbound message ignore path
- event-driven startup/readiness gating for network sync
- HELLO / SUMMARY discovery
- 6 second SUMMARY collection window
- seed selection
- INDEX_DIFF minimal payloads
- sequential BLOCK_PULL / BLOCK_SNAPSHOT flow
- block-pull pacing
- runtime sync index cache behavior
- single globalFingerprint lifecycle
- delayed / coalesced HELLO scheduling
- progressive discovery retry backoff (`20s +20s`, capped at `300s`, with jitter)
- inbound seed session caps and pause clearing
- roster invalidation scoped to known sync owners only
- trusted-roster cleanup throttle and roster no-op coverage
- build-channel and wire compatibility isolation
- opportunistic profession scans
- slash/debug/perf output for the modern sync path
- runtime observability snapshots and alpha-debug export coverage
- bounded recent sync event log coverage
- inbound seed session debug counters and pause clearing diagnostics
- cached recipe consultation during warm-up and instance pause
- active soak coverage for HELLO storms, seed election, block-pull saturation, and discovery backoff

## Alpha tester workflow

For alpha sync reports, ask testers for:

1. Screenshot or copy of:
   - `/rr sync`
   - `/rr sync debug`
   - `/rr version`
2. `RecipeRegistry.lua` only if the compact debug output is not enough.
3. Repro steps:
   - login or reload
   - wait 2 minutes
   - open `/rr sync`
   - if no sync progress appears, run `/rr sync debug`
   - if sync stalls during block pulls, run `/rr sync sessions`

## Backend suite governance

The active backend suites now use an explicit supported-spec baseline. Historical pre-rewrite manifest/coordinator/request-chunk specs and other not-yet-migrated auxiliary specs may still remain in-tree for reference, but they are not part of the active backend status.

Current supported sync suite coverage is the rewrite path only:

- `HELLO`
- `SUMMARY`
- seed selection
- `INDEX_DIFF_REQUEST`
- `INDEX_DIFF_RESPONSE`
- sequential `BLOCK_PULL_REQUEST`
- `BLOCK_SNAPSHOT`
- runtime cache / diagnostics / compatibility gates

Legacy sync compatibility is intentionally removed from the active runtime baseline. Unknown inbound kinds are ignored generically; the supported suites no longer expect explicit `AD` / `IDX` / `MANI` / `MREQ` handling, manifest/revision/coordinator state, or published/current fingerprint split behavior.

The active runtime baseline also assumes:

- exactly one `globalFingerprint`;
- passive-only `lastGlobalFingerprintAt` / `lastGlobalFingerprintReason` diagnostics;
- event-driven `syncReady` gating for all sync network traffic;
- deferred/coalesced sync-index preparation;
- delayed/coalesced HELLO publication and discovery retry;
- dirty active outbound pull sessions may continue block-to-block without republishing HELLO;
- fixed startup timers are watchdogs only, not readiness source of truth.

Historical specs that still target removed runtime concepts are not part of the active `all`, `quick`, or `sync` suites until they are either rewritten or formally archived elsewhere.

If you need to exercise only the active rewrite path explicitly, use:

```powershell
.\local-tests\run-backend-tests.ps1 -Suite sync
```

If you need the focused active soak checks only, use:

```powershell
.\local-tests\run-backend-tests.ps1 -Suite soak
```
