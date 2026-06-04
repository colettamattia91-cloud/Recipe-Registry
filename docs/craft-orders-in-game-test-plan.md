# Craft Orders — In-Game Test Plan

In-game smoke tests pending on `feature/craft-orders-mail-assistant`. The backend is 85/85 spec green; these tests catch what specs can't (real WoW client + mailbox + guildmate interactions).

**Why this list:** the autonomous work batch deferred everything that needs a real client. This is the gate before merging to `develop` / cutting a release.

## Status legend

- **§A** — Phase 2-8 features already shipped on the branch; tests below verify they work end-to-end.
- **§B** — Phase 9 UX redesign (see `docs/craft-orders-roadmap.md` §11 Phase 9). Tests live here as a forward-looking checklist; do not run until the matching feature lands.

---

## §A Phase 2-8 shipped features

## Single-character flow (you alone, with the addon)

1. **Cart → checkout → board:** open RR, pick a recipe, click the "Add to order cart" action button, set quantity, choose yourself as crafter, checkout. Verify an order appears in the Craft Orders tab.
2. **Tab badge live counter:** create a draft order; verify the tab label becomes "Craft Orders (1)". Cancel it; verify it goes back to "Craft Orders". Switch between RR tabs while doing this — badge must update from any tab.
3. **Detail panel action strip:** select an order. As requester on a Draft, expect to see only **Cancel** (red) and **Compose mail** — the "Materials partial" / "Mark materials sent" buttons have been removed because the mail flow drives those transitions automatically (commit `0f26a5e`). As crafter on MaterialsSent, expect "Mark received" / "Mark missing".
4. **Recent events tail:** after a few transitions, the "Recent events" section in the detail panel should list them as `state Draft -> MaterialsSent` etc.
5. **Scope filter:** create three orders — two where you're requester, one where you're crafter (use a second char if needed). Toggle the Scope button: Everyone (3) / I requested (2) / I craft (1). NB: Phase 9.3 will replace this with Outgoing / Incoming sub-views — for now the scope axis remains.
6. **Mail planner:** `/rrord mail plan <id>` should print the batch plan. With a small order it's one batch.

## Cross-character flow (you + alt OR you + guildmate)

7. **Sync handshake:** with two chars online (one as you, one as alt) and both running the addon, create an order on char A. Within a couple minutes char B's Craft Orders tab should populate. Watch `/rrord sync` for HELLO/SUMMARY/EVENTS_REQUEST counters.
8. **Reducer broadcast refresh (bugfix in commit `44627cb`):** make a state change on char A. On char B, without touching anything, the UI should refresh — order moves to the new state, badge counter updates if it now needs your action. This used to require a local edit to refresh.
9. **Outgoing mail send (real mailbox required):** go to a mailbox, open an order's detail panel as the requester, click the **Compose mail** button in the action strip. Verify:
    - WoW's SendMail tab switches into view.
    - Recipient = crafter (Char-Realm), subject = `[RR] Order <shortId> (1/N)`, body contains both the human header and the `--RR-ORDER--` marker.
    - Drag attachments into the slots, click Send. `MAIL_SEND_SUCCESS` should fire and the order's `batches[1].sentAt` should populate (check with `/rrord events <id>` for the `change=batch-sent` entry).
    - The order status does NOT auto-advance — you still click "Mark materials sent" manually when all batches are out.
    - Wait 120+ seconds after Compose without sending and verify a later unrelated send does NOT misattribute (pending TTL).
10. **Incoming mail scan (real mailbox required):** alt opens the mailbox after receiving the materials mail. Verify:
    - The MAIL_SHOW handler auto-scans.
    - `/rrord mail scan` shows `recognized=1 recorded=1 tampered=0`.
    - The order's ledger now has a `batches[1]` entry with `confirmed` matching the attached items.
    - The order status is **still** MaterialsSent (per §7.4 — crafter manually marks received).

## Tamper-detection sanity checks (requires manually-edited mail body)

11. **Sender mismatch:** have a non-requester send a body with the marker. Scanner should flag `sender-mismatch`, RecordBatchReceipt should append a `TamperDetected` event, order status unchanged.
12. **Item count short:** sender attaches fewer items than the marker promises. Scanner flags `item-count-mismatch:<id>`, ledger `missing` reflects the shortfall.
13. **Tamper warning band:** after either failure above, open the order's detail panel and verify the red `[!] Tamper detected on this order` band appears above the Lines/Materials sections, listing the offending batch + flag names + sender. Clean orders must NOT show the band.

## Delivery flow (crafter → requester)

14. **Compose delivery button visibility:** as the crafter, after walking an order to `Accepted`, the detail panel should expose a `Compose delivery` button in the action strip. The requester should never see it.
15. **Delivery auto-attach:** with the finished outputs in your bags, click `Compose delivery`. The SendMail UI should pre-fill with recipient = requester, subject = `[RR] Delivery <id> (1/1)`, body contains `--RR-ORDER--` with `k="delivery"` and the output items auto-attached.
16. **Delivery send tracking:** click Send. MAIL_SEND_SUCCESS fires, and `order.delivered[<itemID>]` should now hold the sent count (verify with `/rrord events <id>` for the `change=delivery-recorded` entry, source=self-sent).
17. **Delivery receipt on requester:** the requester opens their mailbox. MAIL_SHOW scan should flag the mail as `recognized=1 delivered=1`, and the requester's `order.delivered[<itemID>]` should also populate. The requester then manually transitions `DeliverySent -> Completed`.
18. **Delivery sender mismatch:** edit a delivery body to come from someone other than the order's crafter — scanner must flag `sender-mismatch` (crafter-side check is symmetric to materials-side).

## Postal + assumed-receipt grace window

19. **Postal detection:** with Postal installed, run `/rrord mail status`. It should report `Postal: detected v<version>`. Without Postal, `Postal: not detected`. Either way, RR mails should still land in the ledger via MAIL_INBOX_UPDATE re-scans even after Postal's OpenAll fires.
20. **Assumed-receipt grace window:** as crafter, with an order in `MaterialsSent` whose `MaterialsSent` transition is older than 2 hours, and no batches[*] receipt: open the mailbox without the materials mail in it. After MAIL_SHOW, the order should auto-transition to `MaterialsAssumed` (verify via `/rrord status <id>` — state moves to MaterialsAssumed; via `/rrord events <id>` the transition payload carries `reason=grace-window`). Orders within the 2h window must NOT auto-downgrade.

## Auto-compose (bag scan)

21. **Auto-attach happy path:** as requester at the mailbox, click `Compose mail`. The SendMail UI should appear with subject/body/recipient pre-filled AND every batch item already attached in the slots (no manual drag needed).
22. **Auto-attach with missing items:** as requester with an empty bag, click `Compose mail`. The subject/body still pre-fill but no items attach; check the message that lists what was missing (or use `/rrord` chat output). You can drag the missing items manually then Send.
23. **Auto-attach with split stacks:** put 3+2 Peacebloom across two slots, with a recipe needing 4. The bag scanner currently fails (`split-across-stacks`) and surfaces it as missing — you split manually. v1 limitation, documented; v2 will add stack consolidation.

## Pause policy (already proven in RR — re-test optional)

24. **Raid silence:** with two peers online, enter a raid. `/rrord sync` should report queued = 0 and no traffic on `RRORD*` until you leave. The Orders subsystem registers on the same `SyncPausePolicy` as RR's recipe sync.

---

## §B Phase 9 UX redesign — forward-looking checklist

Do not run until the matching subsection lands. Roadmap reference: `docs/craft-orders-roadmap.md` §11 Phase 9.

### 9.1 Aggregated shopping list (Auctionator-aware)

25. **Open window:** with 0 outgoing orders, `/rrord shopping` (or the toggle button) opens the floating Materials window with a single "Nothing to gather" line.
26. **Aggregation across orders:** create two outgoing orders, each needing Peacebloom: ord1 needs 4, ord2 needs 6. The window should list `Peacebloom — 10` and a tooltip on the row should attribute "ord1: 4, ord2: 6".
27. **Item link interaction:** shift-click an item name in the window. Verify it pastes a clickable item link into the chat edit box.
28. **Auctionator handoff (with Auctionator loaded):** click the "Send to Auctionator" button. Auctionator's shopping list / search opens pre-populated with the listed items.
29. **Auctionator absent fallback:** disable Auctionator, click "Send to Auctionator". A paste-box should appear with a newline-joined list of item names ready to copy into Auctionator's import dialog.
30. **Live refresh:** with the window open, cancel one order. The aggregated quantities should update without reopening the window.
31. **Crafter-provided exclusion:** mark some material as crafter-provided via `/rrord set-provider`. That portion should drop out of the aggregated total.

### 9.2 Mail body redesign

32. **Salutation + signature:** Compose a mail. The body should open with "Ciao Bob," (or "Hello Bob,") using the crafter's short name, and close with "— Mattia" (your short name). No order ID in the human header.
33. **Request phrasing:** the body should ask for the craft ("ti chiedo cortesemente di craftarmi" / "could you craft for me"), not assert it as a shipment. Recipe display name visible, no recipeKey.
34. **Marker disclaimer:** the `--RR-ORDER--` block should be preceded by a one-line disclaimer like "tracking auto-generato — ignora se non hai Recipe Registry" so a non-addon recipient knows to skip it.
35. **Locale switch:** flip the WoW client to enUS, Compose a fresh mail, verify the human header is in English. Marker block is byte-identical regardless of locale.
36. **Scanner back-compat:** with the new body, the receiving char's scanner should still decode + verify integrity (zero tamperFlags on a clean mail). Old-style markers from earlier versions still decode.

### 9.3 Board split — Outgoing / Incoming

37. **Sub-view toggle:** the Craft Orders tab opens defaulting to Outgoing. Click Incoming and verify the list switches to orders where you're the crafter.
38. **Counts in headers:** the Outgoing / Incoming pill labels include their respective counts: `Outgoing (2) / Incoming (5)`.
39. **Status filter scoping:** flip to Incoming, set status filter to Active. Verify the list shows only incoming-active orders, not outgoing.
40. **Tab badge math:** the main nav tab still reads `Craft Orders (N)` where N is total action-required across both sub-views.
41. **Debug-all view:** `/rrord list --all` still lists everything (including third-party-observed orders) so the debug path survives the UI removal.

### 9.4 Send queue

42. **Queue surfaces after checkout:** after a cart checkout that produced 3 orders, the cart panel shows "You have 3 mails to send. Open mailbox to start."
43. **MAIL_SHOW toast:** open the mailbox. A small toast in RR's main frame surfaces "Next: send batch 1 of order #abc". Clicking [Send] composes that batch.
44. **Queue advances on MAIL_SEND_SUCCESS:** after sending batch 1, the toast switches to the next order's batch 1 (or order #abc batch 2 if multi-batch).
45. **Persistence:** with a queue in progress, `/reload`. After the reload, the queue resumes at the same position — no orders skipped, no duplicates.
46. **Auto-send is NOT offered:** confirm there is no "auto-send all" button. Each batch keeps the in-game Send-button confirmation step.

### 9.5 Reject delivery on receipt

47. **Reject action visible to recipient on DeliverySent:** as the order's recipient, open the detail panel of an order in `DeliverySent`. Verify the action strip surfaces "Reject delivery — return goods" (red/destructive style).
48. **Reject composes return mail:** click reject. The SendMail UI pre-fills with recipient = crafter, attachments = the received items, body header "Return for order X — declined" + optional reason line.
49. **Order moves to ReturnPending:** after Send, verify the order's status is `ReturnPending`, event log carries `change = delivery-rejected` with the recipient as actor.
50. **Crafter sees return arrive:** crafter alt opens mailbox; scanner records the return with `phase = "return"`; final state moves to `Cancelled` with all goods restored on the crafter side.

### 9.6 Edit recipient (change crafter)

51. **Change-crafter action visible only on Draft / MaterialsPartial:** before any batch has `sentAt`, the requester sees a "Change crafter" action in the strip. After any batch ships, it disappears.
52. **Picker shows crafter list scoped to recipe(s):** click "Change crafter". Dropdown lists everyone who can craft any of the order's recipes.
53. **Confirm rewires the order:** pick a different crafter, confirm. `order.crafter` updates, OrderUpdated event with `change = recipient-changed` appended.
54. **Locked after first send:** repeat #53 right after the first MAIL_SEND_SUCCESS. The action should be gone.

### 9.7 Trade-mode delivery

55. **Enchanting recipe defaults to trade mode:** "Add to cart" an enchant recipe. The order created at checkout should have `deliveryMode = "trade"` (because `directEnchant == true`).
56. **Trade mode action strip:** detail panel shows manual `Mark materials handed over` / `Mark received via trade` / `Mark delivered via trade` actions, no Compose mail button.
57. **State advances via manual clicks:** click through the trade-mode states and verify each click advances the state machine + appends an event with `source = "trade"`.
58. **Mixed-mode order:** create a regular mail-mode order, send batch 1 via mail, then click "Mark delivered (trade)" on the crafter side. Verify the order can close via trade even though it started via mail.
59. **No trade-window parsing:** confirm the addon does NOT auto-detect trade contents — the actions are purely manual confirmations.

### 9.8 Craft + proc tracking

60. **Craft counter starts at zero:** accept an order for 10 Haste Potions. Open the detail panel: `Crafted: 0 / 10`.
61. **Counter ticks per craft:** craft 1 potion via the tradeskill window. Counter updates to `Crafted: 1 / 10`.
62. **Proc detection:** craft 10 attempts. If you got 12 outputs (2 procs), counter should show `Crafted: 12 / 10 (2 procs)`.
63. **Compose-delivery dialog presents 3 choices:** with 35 potions in bags (20 pre-existing + 15 from this order), click Compose delivery. Dialog shows:
    - `Send only the 10 ordered`
    - `Send 15 (include procs)`
    - `Send all 35 (warning: includes 20 pre-existing)`
    Middle option is the default focus.
64. **Choice is honoured in the mail:** pick "Send 15". Verify the mail attachments are exactly 15 potions and the body marker promises 15.

### 9.9 Multi-alt account model

65. **All alts see the same order DB:** create an order on Char-A. Login Char-B (same account). Open Craft Orders tab. The order is visible in Outgoing.
66. **Order with recipient ≠ requester:** when creating an order, the "Send to" dropdown lists known account chars. Pick Char-B (your warehouse alt). The order's `recipient` field is set.
67. **Crafter mails to the recipient char:** crafter (different account, peer) ships delivery. The mail's `To:` is Char-B, not Char-A. Char-B's scanner records the delivery on the shared order DB.
68. **Outgoing / Incoming spans all account chars:** logged on Char-C (a third alt), open Outgoing. Verify orders placed by Char-A AND Char-B show up (because the local actor resolution treats any account char as "me").
69. **Self-account order skips sync:** Char-A orders from Char-B (alt). Verify no `RRORD*` traffic on the wire — the DB is shared locally, sync is not needed.
70. **Account char list updates passively:** login a new alt, open Craft Orders once. Future order-creation dropdowns on other alts should now list this new char.

### 9.10 Saved order templates

71. **Save current order as template:** on a Draft order, click "Save as template". Name it "Raid haste pots". Template persists in per-char DB.
72. **One-click resend:** `/rrord template send "Raid haste pots"` creates a fresh Draft order with the same crafter / lines / recipient.

---

## What to do if a test fails

Log the symptom + `/rrord diag` output + relevant `/rrord events <id>` slice. Tamper-flag failures land as `TamperDetected` events; scan with `/rrord events <id> 50`.
