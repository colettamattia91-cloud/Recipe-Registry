# Local Recipe Registry Tests

This folder is intentionally excluded through `.git/info/exclude`.

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

- legacy inbound `AD` / `IDX` / `MANI` / `MREQ` quarantine
- HELLO / SUMMARY discovery
- seed selection
- INDEX_DIFF minimal payloads
- sequential BLOCK_PULL / BLOCK_SNAPSHOT flow
- block-pull pacing
- runtime sync index cache behavior
- build-channel and wire compatibility isolation
- opportunistic profession scans
- slash/debug/perf output for the modern sync path

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

Historical specs that still target removed runtime concepts are not part of the active `all`, `quick`, or `sync` suites until they are either rewritten or formally archived elsewhere.

If you need to exercise only the active rewrite path explicitly, use:

```powershell
.\local-tests\run-backend-tests.ps1 -Suite sync
```
