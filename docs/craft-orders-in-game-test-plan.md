# Craft Orders — In-Game Test Plan

In-game smoke tests pending on `feature/craft-orders-mail-assistant`. The backend is 83/83 spec green; these tests catch what specs can't (real WoW client + mailbox + guildmate interactions).

**Why this list:** the autonomous work batch deferred everything that needs a real client. This is the gate before merging to `develop` / cutting a release.

## Single-character flow (you alone, with the addon)

1. **Cart → checkout → board:** open RR, pick a recipe, click the "Add to order cart" action button, set quantity, choose yourself as crafter, checkout. Verify an order appears in the Craft Orders tab.
2. **Tab badge live counter:** create a draft order; verify the tab label becomes "Craft Orders (1)". Cancel it; verify it goes back to "Craft Orders". Switch between RR tabs while doing this — badge must update from any tab.
3. **Detail panel action strip:** select an order. Verify the bottom of the detail panel shows the valid transitions (e.g. as requester on a Draft: Materials partial / Mark materials sent / Cancel — Cancel in red). Click one; verify the order state advances and the strip re-renders with the next valid set.
4. **Recent events tail:** after a few transitions, the "Recent events" section in the detail panel should list them as `state Draft -> MaterialsSent` etc.
5. **Scope filter:** create three orders — two where you're requester, one where you're crafter (use a second char if needed). Toggle the Scope button: Everyone (3) / I requested (2) / I craft (1).
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

## What to do if a test fails

Log the symptom + `/rrord diag` output + relevant `/rrord events <id>` slice. Tamper-flag failures land as `TamperDetected` events; scan with `/rrord events <id> 50`.
