# Recipe Registry — Craft Orders & Mail Assistant
## Detailed solution design and pre-analysis for Codex

## 0. First required action

Create a dedicated feature branch before doing any implementation work.

Recommended branch name:

feature/craft-orders-mail-assistant

This feature must not be developed directly on main, master, or develop.

The branch must remain isolated from unrelated work:
- no unrelated sync rewrite;
- no unrelated recipe database changes;
- no unrelated UI redesign;
- no unrelated pricing or AtlasLoot changes;
- no unrelated release/packaging cleanup.

The first branch milestone must be an analysis and API-validation branch, not a production-ready implementation.

---

## 1. Feature objective

Add a new Recipe Registry module that allows guild members to create, send, track, receive, cancel, and complete guild craft orders using a shared Craft Board and a mailbox-assisted workflow.

The feature should extend Recipe Registry beyond “who can craft this?” and introduce a lightweight guild crafting order system.

The target experience is:

1. A requester selects one or more craftable items/recipes.
2. The requester chooses quantities.
3. The requester selects a known crafter.
4. Recipe Registry computes the required materials.
5. Recipe Registry distinguishes requester-provided materials from crafter-provided materials.
6. The requester opens a mailbox.
7. Recipe Registry prepares one or more mail batches to the selected crafter.
8. The requester reviews and sends the mail.
9. The order appears on a shared guild Craft Board.
10. The crafter opens the mailbox.
11. Recipe Registry detects the order mail and records received materials.
12. The board status is updated.
13. The crafter either completes the craft and returns the output, or cancels and returns the received materials.

This feature should behave as a “Craft Request Board + Mail Assistant”, not as a fully automated retail crafting-order clone.

---

## 2. Non-goals for the first implementation

Do not implement full automatic background mailing.

Do not implement gold, fee, tip, or COD automation in the first release.

Do not treat craft success as authoritative in the first release.

Do not assume all crafted outputs are mailable.

Do not force service crafts, such as enchants, into a mail-output workflow.

Do not merge Craft Orders sync into the existing recipe sync system.

Do not invalidate recipe fingerprints when craft order state changes.

Do not modify the existing recipe sync protocol unless an explicit adapter is required.

Do not make Postal a hard dependency.

Do not claim that the board is a secure escrow system.

---

## 3. Core design principle

The module must be designed as a best-effort guild coordination tool.

It can help players:
- create order records;
- calculate required materials;
- prepare mail;
- attach materials;
- identify order mails;
- track received materials;
- display missing materials;
- prepare return mails;
- prepare delivery mails;
- share order state with the guild.

It cannot guarantee fairness, enforce trades, or prove item ownership after materials have been taken from the mailbox and mixed with existing bag contents.

The system must clearly distinguish:
- confirmed material receipt;
- assumed material receipt;
- missing materials;
- manually corrected order state.

---

## 4. High-level module boundaries

Add a new Craft Orders subsystem separate from recipe sync.

Suggested module areas:

- Craft Orders core
- Craft Orders store
- Craft Orders state machine
- Craft Orders material planner
- Craft Orders mail assistant
- Craft Orders mailbox scanner
- Craft Orders Postal compatibility layer
- Craft Orders sync protocol
- Craft Orders sync runtime
- Craft Orders board UI
- Craft Orders diagnostics

Codex should propose exact file names after inspecting the existing project structure.

The implementation must use Recipe Registry conventions, naming style, logging style, and existing module patterns where appropriate.

---

## 5. Required architecture separation

Craft Orders must not be stored inside recipe data structures.

Craft Orders must not reuse recipe block fingerprints.

Craft Orders must not participate in recipe index rebuilds.

Craft Orders must not trigger recipe global fingerprint dirty state.

Craft Orders sync must be logically and operationally independent from:
- recipe HELLO/SUMMARY;
- recipe INDEX_DIFF;
- recipe BLOCK_PULL;
- recipe BLOCK_SNAPSHOT;
- recipe MergeEngine;
- recipe DataIndex/DataCatalog rebuilds.

Allowed reuse:
- generic serialization helpers;
- generic compression helpers;
- generic addon-message send wrapper;
- generic pacing/throttling helper;
- generic pause policy checks;
- generic debug/diagnostics infrastructure.

Not allowed:
- sharing recipe sync runtime state;
- sharing recipe peer sessions;
- sharing recipe block queues;
- sharing recipe fingerprint lifecycle.

---

## 6. Craft Board sync model

The Craft Board should use an event-driven delta sync model.

Craft order data is smaller and more time-sensitive than recipe data. It should not use large full-state broadcasts.

Recommended sync concept:
- local order changes produce append-only events;
- each client maintains a compact local event log;
- peers exchange summaries of known event sequence ranges;
- missing events are pulled in small batches;
- duplicate events are ignored;
- invalid events are rejected by the reducer;
- stale completed/cancelled orders are pruned after a retention period.

The board sync should support large guilds:
- no full board broadcast loops;
- no sync storms on login;
- no expensive reconciliation during raids/instances/BG/arena;
- no UI blocking while board sync catches up;
- no heavy work during combat-sensitive moments;
- strict payload size caps;
- strict event batch caps;
- per-peer backoff;
- pacing between outgoing sync batches;
- pruning of completed/cancelled order history.

The Craft Board protocol must have its own message namespace and must not reuse recipe sync message names.

---

## 7. Order lifecycle

The first implementation should use a simplified but deterministic lifecycle.

Recommended states:

- Draft
- Materials pending
- Materials sent
- Materials partially sent
- Materials received
- Materials assumed received
- Materials missing
- Accepted
- Delivery pending
- Delivery sent
- Completed
- Cancel requested
- Cancelled return pending
- Cancelled return sent
- Cancelled
- Failed
- Expired

Codex should refine the final state list after reviewing UI complexity and implementation risk.

State transitions must be actor-aware.

Requester may:
- create an order;
- prepare material mail;
- mark material batches as sent;
- cancel a draft before materials are sent;
- confirm returned materials;
- confirm completed delivery when detected or manually verified.

Crafter may:
- confirm material receipt;
- accept the order;
- report missing materials;
- cancel and return received materials;
- prepare delivery mail;
- mark manual/service completion where appropriate.

System may:
- detect stale orders;
- expire orders;
- mark assumed receipt after configured conditions;
- prune old completed/cancelled data;
- reject invalid transitions.

---

## 8. Multi-line order support

The board must support:
- one recipe requested multiple times;
- multiple different recipes in a single order;
- repeated output items;
- different quantities per line;
- material aggregation across all lines;
- multiple mail batches for the same order.

Examples:
- 10 Haste Potions in one order;
- 10 Haste Potions and 5 Super Mana Potions in one order;
- multiple outputs from the same crafter in one order.

If different crafters are required, create separate orders.

If the same output can be produced by multiple recipes, the order should preserve the selected recipe identity where possible, not only the output item.

---

## 9. Material planning

The material planner must compute the complete material requirement for all order lines.

Materials must be grouped by item identity, not by localized text.

The planner must distinguish:
- total required materials;
- requester-provided materials;
- crafter-provided materials;
- non-mailable materials;
- missing materials at send time;
- materials excluded from mail;
- materials relevant only for service/manual delivery.

Crafter-provided materials are not expected in incoming order mail.

Crafter-provided materials must not be treated as missing if absent from mail.

Crafter-provided materials must not be returned on cancellation.

Requester-provided materials are the only materials expected in outgoing order mail.

The first implementation may allow the requester to decide which materials are requester-provided versus crafter-provided.

Later versions may add presets or guild policies.

---

## 10. Material receipt ledger

Material receipt must be based on order mail evidence, not generic bag contents.

The module must maintain a material ledger per order.

The ledger should track:
- expected material batches;
- confirmed material batches;
- confirmed item quantities;
- missing item quantities;
- assumed receipt state;
- returned material quantities;
- delivered output quantities;
- manual corrections.

Confirmed received materials are those Recipe Registry saw in an order mail and recorded before or during mailbox processing.

Assumed received materials are those that Recipe Registry did not see, but which are likely to have been collected while the addon was disabled or before it could inspect the mail.

Returnable materials must be computed from the order receipt ledger.

Returnable materials must not be computed from total bag contents alone.

Important limitation:
Once materials are taken from mail and mixed with existing bag stacks, the addon cannot prove physical provenance. It can only track quantities owed based on the order ledger.

On cancellation, return logic should use:
- confirmed received quantities;
- minus quantities already returned;
- minus quantities explicitly marked consumed if that feature is added later;
- excluding crafter-provided materials;
- excluding non-mailable or bound materials.

For assumed receipt, the return flow must show a warning that exact quantities were not confirmed by Recipe Registry.

---

## 11. Mail Assistant — outgoing requester flow

The requester must be at an open mailbox to prepare and send order mail.

The assistant should:
- validate that mailbox UI is available;
- prepare recipient from selected crafter;
- generate a compact order subject;
- generate a human-readable body;
- include a machine-readable order marker in the body;
- prepare required material attachments;
- split attachments across multiple mails if needed;
- allow the requester to review before sending;
- track each planned batch;
- update local order state after successful send attempt;
- publish order event to the Craft Board.

Mail subject must be short and stable.

Mail body should be human-readable first, machine-readable second.

The system must not rely on localized item names alone.

The machine-readable section should include:
- order ID;
- requester;
- crafter;
- batch number;
- batch count;
- expected material identity and quantities;
- order manifest hash or checksum;
- schema version.

Codex must determine exact format after validating subject/body length limits.

---

## 12. Mail attachment limit

The implementation must validate the real TBC Classic attachment limit in-game.

Do not assume the limit without testing.

If material attachments exceed the limit:
- split into multiple mail batches;
- preserve the same order ID;
- include batch number and total batch count;
- track each batch separately;
- reconcile partial batch receipt;
- avoid duplicate material counting if the same batch is processed twice.

The assistant must also handle:
- stack splitting;
- partial stacks;
- insufficient material quantities;
- non-mailable items;
- bags with multiple stacks of the same item;
- user cancellation during batch send.

---

## 13. Incoming mail recognition

When the crafter opens the mailbox, Recipe Registry should scan inbox mail for Craft Order markers.

The scanner should detect:
- sender;
- subject;
- order ID;
- batch number;
- total batch count;
- body marker;
- expected material manifest;
- visible attachments;
- received quantities.

If all expected requester-provided materials are present:
- mark the order as materials received;
- update the shared board;
- show the order as ready for crafter action.

If only some materials are present:
- mark partial receipt;
- calculate missing quantities;
- update the board;
- prepare a reply mail to the requester listing missing materials.

If the order is unknown locally:
- create or hydrate a local order stub from the mail data;
- request missing order events from board sync if needed;
- avoid blocking mailbox processing.

---

## 14. Missing mail and assumed receipt

The module must support the case where the crafter opened or looted the mail while Recipe Registry was disabled, outdated, not loaded, or unable to scan the mailbox.

Scenario:
1. Requester sends order mail.
2. Crafter receives the mail.
3. Crafter opens and loots the mail while Recipe Registry is disabled or before the addon records it.
4. Later, Recipe Registry runs and sees the order board entry but cannot find the original mail.

In this case, after expected mail delivery delay plus a grace period:
- do not mark materials missing automatically;
- mark the order as materials assumed received;
- show this as lower-confidence than confirmed receipt;
- do not automatically generate a missing-material reply;
- allow manual correction.

The board must clearly show the difference between:
- materials received;
- materials assumed received;
- materials missing;
- materials not yet seen.

This distinction is essential for avoiding false negatives caused by addon-disabled mailbox activity.

---

## 15. Postal compatibility

Recipe Registry must include a Postal compatibility plan.

Postal must not be a hard dependency.

The module should work with:
- default Blizzard mailbox only;
- Postal enabled;
- Postal disabled;
- Postal installed but not active;
- other mailbox addons;
- Postal-like OpenAll behavior.

Postal may introduce race conditions because it can open or loot mail quickly or in bulk.

Risk:
Postal may take attachments before Recipe Registry has recorded the order mail and attachment manifest.

Required compatibility strategy:
- detect whether Postal is loaded;
- scan order mails as early as possible when mailbox opens;
- detect Recipe Registry order mail before bulk-loot where possible;
- prevent duplicate receipt counting;
- avoid falsely marking materials as missing if Postal already looted the mail;
- fall back to assumed receipt if mail is no longer visible after delivery window;
- avoid hard reliance on Postal internals unless verified.

Codex should inspect Postal’s current TBC-compatible behavior and determine whether:
- it exposes stable hooks;
- it allows mail filtering;
- it allows order mails to be excluded from OpenAll;
- it can conflict with QuickAttach;
- it can loot mail before Recipe Registry scans;
- it creates taint or protected-action risks.

If safe Postal hooks are not available, Recipe Registry should still remain compatible through early mailbox scan and assumed-receipt fallback.

---

## 16. Missing materials reply

If the crafter receives an order mail but required requester-provided materials are missing, the addon should prepare a reply mail.

The reply should include:
- order ID;
- missing material list;
- expected quantities;
- received quantities;
- instructions to resend missing materials;
- batch reference if applicable.

The reply should not be sent silently.

The crafter should review before sending.

The board should update to materials missing.

Requester should be able to prepare a resend mail containing only missing materials.

---

## 17. Cancellation flow

Crafter cancellation follows the reverse mail flow.

If the crafter cancels:
1. crafter opens mailbox;
2. crafter selects the order;
3. addon computes returnable materials from the receipt ledger;
4. addon prepares return mail to requester;
5. addon excludes non-returnable and crafter-provided materials;
6. addon splits return materials across batches if attachment limit is exceeded;
7. crafter reviews and sends;
8. board updates to cancellation return sent.

Returnable materials are only those sent through Recipe Registry order mail and confirmed in the order ledger.

If materials were assumed received but not confirmed:
- show warning;
- require manual verification;
- allow manual adjustment;
- never silently claim exact provenance.

If the crafter already consumed or lost some materials:
- show shortage;
- allow manual note;
- do not fabricate replacement quantities.

---

## 18. Completion and delivery flow

The first implementation should treat delivery mail as the authoritative completion signal for mailable outputs.

When the crafter completes a craft:
1. crafter opens mailbox;
2. crafter selects order;
3. addon prepares delivery mail to requester;
4. addon attaches crafted output where mailable;
5. addon sends delivery batch;
6. board updates to delivery sent;
7. requester opens mailbox;
8. addon detects delivery mail;
9. board updates to completed.

Do not rely on automatic craft-success detection in the first release.

Craft detection can be explored later, but should not be required for correctness.

Reasons:
- output may stack with existing items;
- output may be non-mailable;
- craft events may be hard to reconcile;
- enchants are service crafts;
- failed or cancelled casts may produce confusing events.

---

## 19. Delivery modes

The board must support different delivery modes.

Recommended conceptual delivery modes:
- mail output;
- trade/manual delivery;
- service craft;
- unsupported output.

Mail output:
- normal mailable crafted item;
- completion can be based on delivery mail detection.

Trade/manual delivery:
- output exists but cannot or should not be mailed;
- completion requires manual confirmation.

Service craft:
- enchant or similar service;
- materials may be mailed;
- final application requires direct trade or manual confirmation.

Unsupported:
- item or recipe cannot be handled safely by the board.

The UI should warn the requester before creating orders that cannot be completed via mail.

---

## 20. Craft Board UI

Add a new Orders area to Recipe Registry.

Possible UI placements:
- new tab in the existing main window;
- separate Craft Orders window;
- compact board accessible from recipe detail.

Codex should inspect the current UI and propose the least invasive option.

The Orders board should show:
- status;
- requested item(s);
- quantity;
- requester;
- crafter;
- material state;
- delivery state;
- last update;
- available actions.

Filters:
- all active orders;
- my requests;
- assigned to me;
- waiting for materials;
- materials missing;
- ready to craft;
- delivery pending;
- completed;
- cancelled;
- expired.

Order detail panel should show:
- order lines;
- selected crafter;
- required materials;
- requester-provided materials;
- crafter-provided materials;
- confirmed received materials;
- assumed received warning;
- missing materials;
- mail batches;
- status history;
- available actions.

Normal UI should not expose raw event IDs or sync internals.

Diagnostics may expose raw sync/event data.

---

## 21. Order sync performance requirements

Craft Orders sync must be lightweight.

Requirements:
- no full board broadcast on login;
- no recipe sync invalidation;
- no recipe index rebuild;
- no large payload spam;
- no board sync storm in large guilds;
- no heavy work during raids, instances, BGs, arenas, or combat-sensitive moments;
- no UI freeze when opening the board;
- no mailbox scan outside mailbox context;
- no Postal compatibility polling loops.

Use:
- low-frequency summaries;
- event deltas;
- bounded event batches;
- per-peer pacing;
- backoff for noisy peers;
- compression only when useful;
- pruning for completed/cancelled orders;
- tombstones for recently pruned orders.

---

## 22. Retention and pruning

Orders should not live forever.

Suggested retention policy to refine:
- active orders retained until terminal state or expiration;
- completed orders retained for a configurable short period;
- cancelled orders retained for a configurable short period;
- failed/expired orders retained for diagnostics for a limited period;
- tombstones retained long enough to prevent resurrection from stale peers;
- old event log entries pruned after all relevant peers have had reasonable time to sync.

Do not prune active orders.

Do not prune orders with unresolved material or delivery state.

Do not allow stale peer data to resurrect completed/cancelled orders after pruning.

---

## 23. Reliability and trust model

This system is not cryptographically secure.

Guild addon messages can be spoofed by malicious clients.

Mailbox state can be affected by:
- addon disabled;
- Postal/OpenAll;
- manual looting;
- expired mail;
- returned mail;
- mailbox pagination;
- disconnected clients;
- partial sends;
- failed sends;
- player mistakes.

Therefore:
- display confidence states;
- distinguish confirmed from assumed;
- keep status history;
- allow manual correction;
- avoid irreversible automation;
- do not hide destructive actions;
- do not overclaim certainty.

---

## 24. Edge cases to handle

Required edge cases:

1. Requester creates an order but never sends mail.
2. Requester sends only some mail batches.
3. Mail exceeds attachment limit and is split.
4. Mail contains wrong or missing materials.
5. Crafter opens mailbox with addon disabled.
6. Crafter uses Postal OpenAll before Recipe Registry scans.
7. Crafter has no bag space to retrieve attachments.
8. Crafter receives duplicate batches.
9. Requester sends duplicate order mails.
10. Order mail arrives after delay.
11. Mail expires or is returned.
12. Crafter leaves guild.
13. Requester leaves guild.
14. Crafter does not have Recipe Registry enabled.
15. Recipe output is non-mailable.
16. Recipe is an enchant/service craft.
17. Same output is requested through multiple recipes.
18. Same item is requested multiple times in one order.
19. Materials stack with existing bag items.
20. Crafter cancels after receiving materials.
21. Crafter cancels after consuming some materials.
22. Delivery mail is sent but requester opens it with addon disabled.
23. Board sync receives events out of order.
24. Board sync receives duplicate events.
25. Board sync receives invalid state transitions.
26. Completed order is pruned but stale peer still has old events.
27. Large guild login causes many order summaries at once.

---

## 25. API validation phase

Before implementation, Codex must produce an API validation plan.

The validation must cover:

Mailbox send:
- whether the addon can prepare recipient, subject, and body;
- whether the addon can attach materials reliably;
- whether the addon can split stacks;
- whether send success/failure events are available and reliable;
- whether repeated sends need pacing;
- exact attachment limit;
- subject and body length limits.

Mailbox receive:
- whether inbox headers are available after mailbox open;
- whether inbox body can be read safely;
- whether attachments can be inspected without taking;
- whether attachment item IDs/counts are available;
- whether mailbox update events are sufficient;
- whether inbox pagination exists or matters in TBC Classic;
- whether returned mail can be identified.

Postal compatibility:
- whether Postal exposes public APIs or stable hooks;
- whether OpenAll can be filtered;
- whether RR order mails can be detected before Postal loots them;
- whether QuickAttach interferes with planned attachments;
- whether Postal creates timing or duplicate-count risks.

Client constraints:
- whether any required action is protected;
- whether any action requires hardware event;
- whether combat lockdown affects mailbox operations;
- whether Classic/TBC differs from later clients.

The output of Phase 0 must be a short findings document before any production implementation.

---

## 26. Implementation phases

### Phase 0 — Branch and API validation

Create the dedicated feature branch.

Inspect current Recipe Registry architecture.

Inspect existing material lookup, AtlasLoot, Market, UI, sync, pause policy, diagnostics, and codec utilities.

Validate mailbox APIs.

Validate Postal compatibility risk.

Produce an implementation plan before writing the feature.

### Phase 1 — Local order drafts and material planner

Implement local-only draft creation.

Support one recipe and multiple recipes.

Support quantity.

Support crafter selection.

Compute total materials.

Split requester-provided vs crafter-provided materials.

Plan mail batches.

No guild sync.

No real mail sending unless API validation is complete.

### Phase 2 — Outgoing Mail Assistant

Prepare order mail from a draft.

Require mailbox open.

Generate subject/body.

Attach materials.

Split across mail batches.

Track send attempts and send results.

Keep all actions reviewable by the user.

### Phase 3 — Local Craft Board

Add local Orders UI.

Display order status.

Display material status.

Display mail batch status.

Display available actions.

No guild-wide sync yet.

### Phase 4 — Incoming mailbox recognition

Scan inbox for Recipe Registry order mail.

Parse order metadata.

Record confirmed received materials.

Detect missing materials.

Generate missing-material reply draft.

Support assumed received fallback.

### Phase 5 — Postal compatibility layer

Detect Postal.

Validate interaction with OpenAll and QuickAttach.

Add early scan behavior.

Prevent duplicate material counting.

Support assumed received if Postal has already looted mail.

### Phase 6 — Separate Craft Orders sync

Implement event-based board sync.

Use separate protocol namespace.

Use vector summaries and event deltas.

Add pacing, backoff, pruning, and diagnostics.

Keep entirely separate from recipe sync.

### Phase 7 — Cancellation and return flow

Compute returnable materials from receipt ledger.

Prepare return mail batches.

Track returned material state.

Allow requester confirmation.

### Phase 8 — Delivery and completion flow

Prepare delivery mail.

Detect delivery receipt.

Mark completed.

Add manual confirmation for service/manual delivery modes.

---

## 27. Acceptance criteria

Functional:
- requester can create a single-recipe order;
- requester can create a multi-recipe order;
- material aggregation is correct;
- crafter-provided materials are excluded from mail expectations;
- mail batches split when attachments exceed limit;
- incoming order mails are detected;
- confirmed materials are recorded in ledger;
- missing materials are identified;
- assumed receipt is used only when appropriate;
- crafter can cancel and return confirmed materials;
- crafter can deliver mailable outputs;
- requester can confirm completion.

Sync:
- Craft Orders sync is separate from recipe sync;
- order changes do not dirty recipe fingerprints;
- order events sync incrementally;
- duplicate events are ignored;
- invalid transitions are rejected;
- completed/cancelled orders are pruned safely;
- large guild login does not cause full board flooding.

Mailbox:
- no mail action occurs unless mailbox is open;
- user can review mail before sending;
- attachment count limit is respected;
- stack splitting is handled;
- send failures are visible;
- inbox scan does not falsely duplicate materials;
- Postal does not cause false missing-material reports.

Safety:
- no gold/COD automation in first release;
- no hidden destructive action;
- no automatic trust claim;
- non-mailable outputs are not treated as normal delivery;
- service crafts are handled separately.

Performance:
- no UI freeze when opening the board;
- no heavy scan outside mailbox;
- no recipe index rebuild from order changes;
- no sync spam in raids/instances/BG/arena;
- no mailbox polling loops.

---

## 28. Deliverables requested from Codex before implementation

Codex must first produce:

1. Branch creation confirmation.
2. Repository architecture review.
3. Proposed module layout.
4. Mailbox API validation plan.
5. Postal compatibility validation plan.
6. Draft data model.
7. Draft order state machine.
8. Draft board sync protocol.
9. UI placement proposal.
10. Implementation phase plan.
11. Risk list.
12. Test plan.
13. Minimal Phase 1 patch proposal.

Codex must not implement the full feature until the validation plan and architecture plan have been reviewed.

---

## 29. Hard constraints for Codex

Do not implement directly on develop/main/master.

Do not change recipe sync behavior.

Do not change recipe data model unless explicitly approved.

Do not mix order board sync with recipe sync.

Do not invalidate recipe fingerprints from order events.

Do not implement gold/COD automation in the first release.

Do not implement fully silent mail automation.

Do not assume Postal internals without validation.

Do not treat assumed receipt as confirmed receipt.

Do not compute returnable materials from generic bag contents.

Do not rely on automatic craft success detection for completion in the first implementation.

Do not assume all crafted outputs are mailable.

Do not expose raw sync internals in the normal user-facing board.

Do not introduce release packaging changes in this branch unless required for the new modules.

---

## 30. Success definition

The first useful release of this module should allow a guild to:

- create craft requests from Recipe Registry;
- calculate and send required materials through guided mail;
- track whether materials were confirmed, missing, or assumed received;
- show active orders on a shared guild board;
- allow crafters to return materials or deliver outputs through guided mail;
- avoid interfering with recipe sync performance;
- remain safe under Postal/default mailbox usage;
- handle large guilds without sync storms.

The feature should make Recipe Registry evolve from a guild recipe lookup addon into a lightweight guild craft operations tool.