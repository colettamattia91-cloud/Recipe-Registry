-- Backend coverage for the §8.3 assumed-receipt grace window.
-- After the crafter's mailbox opens and the scanner finds no receipt
-- for a MaterialsSent order whose materials were sent more than
-- GRACE_WINDOW_SECONDS ago, the order downgrades to MaterialsAssumed
-- via the state machine.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom" },
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
    Loader.Wow.SetPlayer("Bob", "TestRealm")  -- crafter scans
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

-- Helper: backdate the most recent MaterialsSent transition event so
-- the order looks like it's been in flight longer than the grace
-- window. Without this we'd need to wait real wall-clock time.
local function backdateMaterialsSent(plugin, orderId, secondsAgo)
    local events = plugin.Store:GetDB().events.log
    for index = 1, #events do
        local event = events[index]
        if event.orderId == orderId
            and event.kind == "OrderUpdated"
            and event.payload
            and event.payload.change == "state-transition"
            and event.payload.toState == "MaterialsSent" then
            event.at = (time and time() or 0) - secondsAgo
        end
    end
end

local function shippedOrder(plugin)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    return order
end

io.write("Craft Orders assumed-receipt grace window\n")

Test.it("GetMaterialsSentAt returns the timestamp of the most recent transition", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 3600)  -- 1 hour ago
    local sentAt = plugin.Mailbox:GetMaterialsSentAt(plugin.Store:GetOrder(order.id))
    Test.truthy(sentAt)
    local now = time and time() or 0
    Test.gte(now - sentAt, 3600)
end)

Test.it("NeedsAssumedReceipt is false inside the grace window", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 30 * 60)  -- 30 min ago, under 2h
    Test.eq(plugin.Mailbox:NeedsAssumedReceipt(plugin.Store:GetOrder(order.id)), false)
end)

Test.it("NeedsAssumedReceipt is true past the grace window with no observed receipt", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 3 * 3600)  -- 3 hours ago, past 2h
    Test.eq(plugin.Mailbox:NeedsAssumedReceipt(plugin.Store:GetOrder(order.id)), true)
end)

Test.it("NeedsAssumedReceipt is false when a scanner receipt was recorded", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 3 * 3600)
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 1 }, observed = { [2447] = 1 },
        source = "scanner", senderMatch = true, hashMatch = true,
        itemsMatch = true, batchMatch = true, valid = true,
    })
    Test.eq(plugin.Mailbox:NeedsAssumedReceipt(plugin.Store:GetOrder(order.id)), false,
        "an observed receipt — even tampered — means the crafter has visibility")
end)

Test.it("NeedsAssumedReceipt is false when the order isn't in MaterialsSent", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 3 * 3600)
    -- Manually mark received: the order is no longer in MaterialsSent.
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsReceived", "crafter"))
    Test.eq(plugin.Mailbox:NeedsAssumedReceipt(plugin.Store:GetOrder(order.id)), false)
end)

Test.it("ApplyAssumedReceipts transitions eligible orders to MaterialsAssumed", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 3 * 3600)
    local summary = plugin.Mailbox:ApplyAssumedReceipts()
    Test.eq(summary.eligible, 1)
    Test.eq(summary.transitioned, 1)
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsAssumed")
end)

Test.it("ApplyAssumedReceipts skips orders where local player isn't the crafter", function()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")  -- local is the requester now
    local plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub() })
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    backdateMaterialsSent(plugin, order.id, 3 * 3600)

    local summary = plugin.Mailbox:ApplyAssumedReceipts()
    Test.eq(summary.eligible, 0,
        "the requester's mailbox shouldn't trigger assumed-receipt on their own order")
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent")
end)

Test.it("ApplyAssumedReceipts is idempotent on already-assumed orders", function()
    local plugin = freshPlugin()
    local order = shippedOrder(plugin)
    backdateMaterialsSent(plugin, order.id, 3 * 3600)
    plugin.Mailbox:ApplyAssumedReceipts()
    -- Second call: nothing left to do.
    local summary2 = plugin.Mailbox:ApplyAssumedReceipts()
    Test.eq(summary2.eligible, 0)
    Test.eq(summary2.transitioned, 0)
end)
