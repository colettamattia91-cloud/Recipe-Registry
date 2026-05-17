# Historical Local Codebase Analysis

**Status:** archived on 2026-05-17.  
**Reason:** the old local analysis described the removed manifest/revision/coordinator sync system and is no longer accurate for the active codebase.

Use these documents instead:

- `docs/sync-rewrite-roadmap.md` for architecture
- `docs/sync-rewrite-roadmap.md` for the canonical active architecture
- `docs/sync-rewrite-phase-log.md` for the implemented Phase 3-6 and hardening status

The active codebase now uses the wire-3 summary/index-diff/block-pull model with:

- `HELLO`
- `SUMMARY`
- one selected outbound seed
- `INDEX_DIFF_REQUEST`
- `INDEX_DIFF_RESPONSE`
- `BLOCK_PULL_REQUEST`
- `BLOCK_SNAPSHOT`
- runtime sync index caching
- no active manifest/coordinator/revision routing
