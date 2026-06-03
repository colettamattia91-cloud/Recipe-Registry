-- Backend coverage for Store:RecordBatchReceipt — the material
-- ledger writer that the Mail Scanner's results land in. Verifies
-- the ledger shape (confirmed/missing/sender/integrity flags), the
-- MaterialsReceiptRecorded event, and the additional TamperDetected
-- event that fires when integrity checks failed.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
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
    Loader.Wow.SetPlayer("Bob", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin)
    return plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" } },
    })
end

local function countEventKind(plugin, orderId, kind)
    local count = 0
    local events = plugin.Store:GetRecentEvents(100)
    for index = 1, #events do
        if events[index].orderId == orderId and events[index].kind == kind then
            count = count + 1
        end
    end
    return count
end

io.write("Craft Orders store ledger\n")

Test.it("RecordBatchReceipt requires a known order and a valid batch number", function()
    local plugin = freshPlugin()
    local ok, err = plugin.Store:RecordBatchReceipt("rr-ord-ghost", 1,
        { expected = {}, observed = {} })
    Test.eq(ok, false)
    Test.eq(err, "unknown-order")

    local order = draftOrder(plugin)
    local ok2, err2 = plugin.Store:RecordBatchReceipt(order.id, 0,
        { expected = {}, observed = {} })
    Test.eq(ok2, false)
    Test.eq(err2, "invalid-batch")
end)

Test.it("RecordBatchReceipt writes confirmed/missing from expected vs observed", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    local ok, slot = plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 4, [765] = 4 },
        observed = { [2447] = 4, [765] = 1 },
        sender   = "Mattia-TestRealm",
        senderMatch = true, hashMatch = true,
        itemsMatch  = false, batchMatch = true,
        tamperFlags = { "item-count-mismatch:765" },
        valid       = false,
        source      = "scanner",
    })
    Test.truthy(ok)
    Test.eq(slot.confirmed[2447], 4)
    Test.eq(slot.confirmed[765],  1)
    Test.eq(slot.missing[765],    3, "expected 4 - observed 1 = 3 missing")
    Test.eq(slot.missing[2447],   nil, "fully-confirmed items should not appear in missing")
    Test.eq(slot.sender, "Mattia-TestRealm")
    Test.eq(slot.source, "scanner")
end)

Test.it("RecordBatchReceipt appends one MaterialsReceiptRecorded event per call", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 2 },
        observed = { [2447] = 2 },
        senderMatch = true, hashMatch = true,
        itemsMatch = true, batchMatch = true,
        valid = true,
    })

    -- The receipt fires an OrderUpdated event with change=receipt-recorded.
    local events = plugin.Store:GetRecentEvents(100)
    local match
    for index = 1, #events do
        if events[index].orderId == order.id
            and events[index].kind == "OrderUpdated"
            and events[index].payload
            and events[index].payload.change == "receipt-recorded" then
            match = events[index]
        end
    end
    Test.truthy(match, "should emit an OrderUpdated event with change=receipt-recorded")
    Test.eq(match.payload.batchNumber, 1)
    Test.eq(match.payload.valid, true)
end)

Test.it("RecordBatchReceipt appends TamperDetected only when flags are present", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)

    -- Clean receipt: no TamperDetected.
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 2 }, observed = { [2447] = 2 },
        senderMatch = true, hashMatch = true,
        itemsMatch = true, batchMatch = true, valid = true,
        tamperFlags = {},
    })
    Test.eq(countEventKind(plugin, order.id, "TamperDetected"), 0)

    -- Flagged receipt: TamperDetected appended.
    plugin.Store:RecordBatchReceipt(order.id, 2, {
        expected = { [2447] = 2 }, observed = { [2447] = 0 },
        senderMatch = false, hashMatch = true,
        itemsMatch = false, batchMatch = true, valid = false,
        tamperFlags = { "sender-mismatch", "item-missing:2447" },
        sender = "Stranger-TestRealm",
    })
    Test.eq(countEventKind(plugin, order.id, "TamperDetected"), 1)
end)

Test.it("RecordBatchReceipt does not advance the order's status", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 2 }, observed = { [2447] = 2 },
        senderMatch = true, hashMatch = true,
        itemsMatch = true, batchMatch = true, valid = true,
    })
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent",
        "the crafter must manually transition to MaterialsReceived")
end)
