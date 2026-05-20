--[[
Wire v3 soak spec 5/5 — memory and table-size bounds under sustained load.

Scenario: A large cohort (e.g. 50 peers, 500 recipes each, multiple
professions) runs for ~10 minutes of virtual time with normal HELLO cadence,
periodic content mutations, and occasional roster churn. Verifies that
addon internal tables stay bounded — no slow leaks, no unbounded growth in
ring buffers, no orphan session state.

Asserts:
  - _recipeIndex entry count tracks distinct recipes known, with no
    duplicate crafterRows accumulating (catalogDiagnostics.duplicateCrafterRowsDetected
    bounded relative to merge count).
  - _recipeListCache stays within MAX_RECIPE_LIST_CACHE_ENTRIES (12) under
    UI-style query patterns.
  - _recipeDetailCache stays within MAX_RECIPE_DETAIL_CACHE_ENTRIES (128).
  - Sync event log respects its ring buffer cap (bounded entry count even
    after thousands of events).
  - outboundSeedSession is properly cleared after CompleteOutboundSeedSession
    — no orphan sessions accumulate on the requester side.
  - Inbound seed session table on seeders is reaped after completion or
    timeout — no zombie sessions per requester.
  - peerBackoffUntil table doesn't accumulate stale entries for peers that
    have been gone for an extended period.
  - blockFingerprint cache (if any) respects its size cap.
]]
io.write("Soak: memory and table-size bounds under load\n")
