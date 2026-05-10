# Local Recipe Registry Tests

This folder is intentionally excluded through `.git/info/exclude`.

Planned use:

- keep local-only WoW API mocks here;
- run backend-oriented addon simulations with Lua 5.1;
- keep experimental test fixtures out of the public repo.

Current quick check:

```powershell
.\local-tests\run-syntax.ps1
```

Backend harness:

```powershell
.\local-tests\run-backend-tests.ps1
```

The backend runner loads WoW/Ace mocks from `harness/`, then executes each
`spec/*.lua` file in a fresh Lua process.

`harness/load-addon.lua` mirrors the addon load order for the split backend
modules. The current `Data` load cluster is:

- `Data.lua`
- `DataAtlasLoot.lua`
- `DataManifest.lua`
- `DataScan.lua`
- `DataSnapshot.lua`
- `DataCatalog.lua`
- `DataCleanup.lua`

The current `Sync` load cluster is:

- `Sync.lua`
- `SyncRuntime.lua`
- `SyncProtocol.lua`
- `SyncRequests.lua`
- `SyncTransfer.lua`
- `SyncManifest.lua`
- `SyncDiagnostics.lua`

If a local refactor changes shard boundaries or load order, update both the
TOC and `harness/load-addon.lua` before trusting backend results.

Current coverage:

- P2 owner/snapshot/roster integrity guardrails, including requested block
  filtering and smaller-replica rejection;
- P4 opportunistic owner scan behavior for hidden profession frames, not-ready
  data, recipe pending retention, non-Enchanting CraftFrame skips, and
  one-shot specialization sync behavior;
- manifest cache behavior for background-ready manifests, dirty block deltas,
  chunk reuse, stale removals, deferred manifest sends, and paced MANI delivery;
- Step 8 sync hardening: bounded concurrent `REQ` dispatch, same-second session
  identity collisions, stale runtime prune, deferred manifest compare replay,
  bounded peer-manifest diagnostic queues, stale-roster routing guardrails, and
  instance or pause gating on background sync work;
- comm-bus scale simulation with 200 isolated addon peers, routed GUILD/WHISPER
  traffic, coordinator convergence/churn, conflicting offline replicas,
  reordered/lost snapshot chunks with RESUME, stale-owner races, real
  REQ/SNAP/DONE flow, bounded multi-owner concurrency, and manifest catch-up
  caps under concurrent load;
- every `MockSync` scenario, including direct snapshots, traffic/offline
  manifest catch-up, roster cleanup, roster guardrail, integrity, slash command
  surface, and cleanup;
- slash command output for help, perf/dump/reset diagnostics, manual rescan,
  compact/verbose manifest output, offline/sync status, and mock usage.
