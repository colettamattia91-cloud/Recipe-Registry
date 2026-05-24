local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", icon = "s", quality = 1 },
        },
    },
    [858] = {
        label         = "Lesser Mana Potion",
        createdItemID = 3385,
        reagents = {
            { itemID = 785, count = 2, name = "Mageroyal",  icon = "m", quality = 1 },
            { itemID = 765, count = 1, name = "Silverleaf", icon = "s", quality = 1 },
        },
    },
}

local function makeStub()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end,
        },
    }
end

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function lineFor(recipeKey, quantity)
    local info = RECIPES[recipeKey]
    return {
        recipeKey    = recipeKey,
        quantity     = quantity,
        recipeLabel  = info and info.label,
        outputItemID = info and info.createdItemID,
    }
end

-- A foreign producer's events use a `producer` key that doesn't match
-- the local player. The seq counter is producer-local.
local FOREIGN_PEER = "Bob-OtherRealm"

local function makeCreateEvent(orderId, seq, requester, crafter, lines)
    return {
        kind     = "OrderCreated",
        orderId  = orderId,
        producer = FOREIGN_PEER,
        seq      = seq,
        actor    = requester,
        at       = 1700000000 + seq,
        payload  = {
            requester    = requester,
            crafter      = crafter,
            deliveryMode = "mail",
            notes        = "",
            lines        = lines,
            lineCount    = #lines,
            createdAt    = 1700000000 + seq,
        },
    }
end

local function makeTransitionEvent(orderId, seq, fromState, toState, actor)
    return {
        kind     = "OrderUpdated",
        orderId  = orderId,
        producer = FOREIGN_PEER,
        seq      = seq,
        actor    = actor,
        at       = 1700000000 + seq,
        payload  = {
            change    = "state-transition",
            fromState = fromState,
            toState   = toState,
            details   = { source = "spec" },
        },
    }
end

local function makePrunedEvent(orderId, seq, reason)
    return {
        kind     = "Pruned",
        orderId  = orderId,
        producer = FOREIGN_PEER,
        seq      = seq,
        actor    = "system",
        at       = 1700000000 + seq,
        payload  = { reason = reason or "remote-prune" },
    }
end

io.write("Craft Orders reducer\n")

Test.it("ApplyEvent rejects malformed envelopes without throwing", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Reducer:ApplyEvent(nil).reason,             "invalid-event")
    Test.eq(plugin.Reducer:ApplyEvent({}).reason,              "missing-kind")
    Test.eq(plugin.Reducer:ApplyEvent({ kind = "X" }).reason,  "missing-producer")
    Test.eq(plugin.Reducer:ApplyEvent({ kind = "X", producer = "P" }).reason, "missing-seq")
end)

Test.it("OrderCreated materializes an order from the snapshot payload", function()
    local plugin = freshPlugin()
    local outcome = plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-remote-1", 1,
        "Mattia-Remote", "Bob-Remote", { lineFor(929, 2) }))
    Test.truthy(outcome.applied)

    local order = plugin.Store:GetOrder("rr-ord-remote-1")
    Test.truthy(order)
    Test.eq(order.requester, "Mattia-Remote")
    Test.eq(order.crafter, "Bob-Remote")
    Test.eq(order.status, "Draft")
    Test.eq(#order.lines, 1)
    Test.eq(order.lines[1].recipeKey, 929)
    -- The planner ran via stub, so materials are populated.
    Test.eq(order.materials[2447].required, 2)
end)

Test.it("OrderCreated tracks the producer on the materialized order", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-x", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    local order = plugin.Store:GetOrder("rr-ord-x")
    Test.eq(order._producer, FOREIGN_PEER)
end)

Test.it("same (producer, seq) twice deduplicates and bumps no state", function()
    local plugin = freshPlugin()
    local event = makeCreateEvent("rr-ord-dup", 1, "A-Realm", "B-Realm", { lineFor(929, 1) })
    Test.truthy(plugin.Reducer:ApplyEvent(event).applied)

    local second = plugin.Reducer:ApplyEvent(event)
    Test.falsy(second.applied)
    Test.eq(second.reason, "duplicate")
    Test.eq(plugin.Reducer.telemetry.duplicates, 1)
end)

Test.it("peer high-water-mark advances on apply and blocks lower seqs", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-hwm", 5, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    Test.eq(plugin.Reducer:GetPeerHighWaterMark(FOREIGN_PEER), 5)

    local older = makeTransitionEvent("rr-ord-hwm", 3, "Draft", "MaterialsSent", "requester")
    local outcome = plugin.Reducer:ApplyEvent(older)
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "duplicate")
end)

Test.it("OrderUpdated state-transition applies via the state machine", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-st", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    local outcome = plugin.Reducer:ApplyEvent(
        makeTransitionEvent("rr-ord-st", 2, "Draft", "MaterialsSent", "requester")
    )
    Test.truthy(outcome.applied)
    Test.eq(plugin.Store:GetOrder("rr-ord-st").status, "MaterialsSent")
end)

Test.it("state-transition with mismatched fromState rejects without partial apply", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-mm", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    local outcome = plugin.Reducer:ApplyEvent(
        makeTransitionEvent("rr-ord-mm", 2, "Accepted", "DeliverySent", "crafter")
    )
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "from-state-mismatch")
    -- Order should still be Draft, unchanged.
    Test.eq(plugin.Store:GetOrder("rr-ord-mm").status, "Draft")
    Test.eq(plugin.Reducer.telemetry.invalidTransition, 1)
end)

Test.it("state-transition with unauthorised actor is rejected", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-au", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    local outcome = plugin.Reducer:ApplyEvent(
        makeTransitionEvent("rr-ord-au", 2, "Draft", "MaterialsSent", "crafter")
    )
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "actor-not-authorized")
    Test.eq(plugin.Store:GetOrder("rr-ord-au").status, "Draft")
end)

Test.it("Pruned tombstones the order and drops subsequent events for it", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-pr", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    Test.truthy(plugin.Reducer:ApplyEvent(makePrunedEvent("rr-ord-pr", 2, "user-delete")).applied)

    Test.eq(plugin.Store:GetOrder("rr-ord-pr"), nil, "order removed from store")
    local tomb = plugin.db.global.events.tombstones["rr-ord-pr"]
    Test.truthy(tomb)
    Test.eq(tomb.producer, FOREIGN_PEER)

    -- Any subsequent event for this orderId must be dropped, even if
    -- the peer claims a higher seq.
    local later = makeTransitionEvent("rr-ord-pr", 3, "Draft", "MaterialsSent", "requester")
    local outcome = plugin.Reducer:ApplyEvent(later)
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "tombstoned")
    -- HWM should advance so we don't keep re-evaluating it.
    Test.eq(plugin.Reducer:GetPeerHighWaterMark(FOREIGN_PEER), 3)
end)

Test.it("OrderCreated for an already-tombstoned order is dropped", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-tr", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    plugin.Reducer:ApplyEvent(makePrunedEvent("rr-ord-tr", 2))
    -- Now a NEW producer tries to resurrect the same id.
    local resurrect = {
        kind = "OrderCreated", orderId = "rr-ord-tr",
        producer = "Eve-OtherRealm", seq = 1, actor = "Eve-OtherRealm",
        at = 1800000000,
        payload = {
            requester = "Eve-OtherRealm", crafter = "Bob",
            lines = { lineFor(858, 1) }, lineCount = 1, deliveryMode = "mail",
        },
    }
    local outcome = plugin.Reducer:ApplyEvent(resurrect)
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "tombstoned")
    Test.eq(plugin.Store:GetOrder("rr-ord-tr"), nil)
end)

Test.it("unknown event kinds are dropped with telemetry, not crashed on", function()
    local plugin = freshPlugin()
    local outcome = plugin.Reducer:ApplyEvent({
        kind = "ZZ_FUTURE_KIND", orderId = "x", producer = FOREIGN_PEER,
        seq = 1, actor = "?", at = 0, payload = {},
    })
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "unknown-kind")
    Test.eq(plugin.Reducer.telemetry.unknownKind, 1)
    -- HWM still advances so the peer doesn't keep re-sending it.
    Test.eq(plugin.Reducer:GetPeerHighWaterMark(FOREIGN_PEER), 1)
end)

Test.it("OrderCreated idempotent for same (id, producer); rejects collision from different producer", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-id", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))

    -- Same producer, different seq → idempotent (no state change, but
    -- the envelope is still consumed/HWM-bumped).
    local repeated = makeCreateEvent("rr-ord-id", 2, "A-Realm", "B-Realm", { lineFor(929, 1) })
    Test.truthy(plugin.Reducer:ApplyEvent(repeated).applied)

    -- Different producer with same orderId → producer-mismatch.
    local collision = {
        kind = "OrderCreated", orderId = "rr-ord-id",
        producer = "Eve-OtherRealm", seq = 1, actor = "Eve-OtherRealm",
        at = 1800000000,
        payload = {
            requester = "Eve-OtherRealm", crafter = "Bob",
            lines = { lineFor(929, 1) }, lineCount = 1, deliveryMode = "mail",
        },
    }
    local outcome = plugin.Reducer:ApplyEvent(collision)
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "producer-mismatch")
end)

Test.it("OrderUpdated for an unknown order is rejected", function()
    local plugin = freshPlugin()
    local outcome = plugin.Reducer:ApplyEvent(
        makeTransitionEvent("rr-ord-missing", 1, "Draft", "MaterialsSent", "requester"))
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "unknown-order")
end)

Test.it("line-added applied via reducer extends the order and recomputes materials", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-la", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }))
    local outcome = plugin.Reducer:ApplyEvent({
        kind = "OrderUpdated", orderId = "rr-ord-la",
        producer = FOREIGN_PEER, seq = 2, actor = "A-Realm", at = 0,
        payload = {
            change      = "line-added",
            recipeKey   = 858,
            quantity    = 2,
            recipeLabel = "Lesser Mana Potion",
        },
    })
    Test.truthy(outcome.applied)
    local order = plugin.Store:GetOrder("rr-ord-la")
    Test.eq(#order.lines, 2)
    Test.eq(order.materials[785].required, 4, "mageroyal: 2 reagent x 2 crafts")
end)

Test.it("provider-set applied via reducer matches Store.SetProvider math", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-ps", 1, "A-Realm", "B-Realm", { lineFor(929, 4) }))
    local outcome = plugin.Reducer:ApplyEvent({
        kind = "OrderUpdated", orderId = "rr-ord-ps",
        producer = FOREIGN_PEER, seq = 2, actor = "A-Realm", at = 0,
        payload = {
            change            = "provider-set",
            itemID            = 2447,
            provider          = "crafter",
            quantity          = 1,
            previousRequester = 4,
            previousCrafter   = 0,
            newRequester      = 3,
            newCrafter        = 1,
        },
    })
    Test.truthy(outcome.applied)
    local bucket = plugin.Store:GetOrder("rr-ord-ps").materials[2447]
    Test.eq(bucket.requesterProvided, 3)
    Test.eq(bucket.crafterProvided, 1)
end)

Test.it("provider-set with inconsistent split (req + cra != required) is rejected", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent(makeCreateEvent("rr-ord-bad", 1, "A-Realm", "B-Realm", { lineFor(929, 2) }))
    local outcome = plugin.Reducer:ApplyEvent({
        kind = "OrderUpdated", orderId = "rr-ord-bad",
        producer = FOREIGN_PEER, seq = 2, actor = "A-Realm", at = 0,
        payload = {
            change = "provider-set", itemID = 2447,
            newRequester = 5, newCrafter = 5,
        },
    })
    Test.falsy(outcome.applied)
    Test.eq(outcome.reason, "split-mismatch")
end)

Test.it("ApplyEvents batches and sorts within (producer, orderId) by seq", function()
    local plugin = freshPlugin()
    -- Submit events out of order; ApplyEvents must reorder before
    -- applying so the state-transition isn't rejected for "unknown-order".
    local summary = plugin.Reducer:ApplyEvents({
        makeTransitionEvent("rr-ord-batch", 2, "Draft", "MaterialsSent", "requester"),
        makeCreateEvent("rr-ord-batch", 1, "A-Realm", "B-Realm", { lineFor(929, 1) }),
    })
    Test.eq(summary.applied, 2)
    Test.eq(plugin.Store:GetOrder("rr-ord-batch").status, "MaterialsSent")
end)

Test.it("ResetTelemetry clears all counters", function()
    local plugin = freshPlugin()
    plugin.Reducer:ApplyEvent({})  -- missing-kind
    plugin.Reducer:ResetTelemetry()
    for _, value in pairs(plugin.Reducer.telemetry) do
        Test.eq(value, 0)
    end
end)

io.write(string.format("Craft Orders reducer: %d test(s) passed\n", Test.count))
