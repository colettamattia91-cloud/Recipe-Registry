-- Backend coverage for outgoing-mail send tracking: after a Compose
-- stages the SendMail UI, a follow-up MAIL_SEND_SUCCESS event credits
-- the batch on the order's ledger via Store:RecordBatchSent.

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
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

io.write("Craft Orders mail send tracking\n")

Test.it("RecordBatchSent stamps sentAt + sentTo on the ledger slot", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    local ok, slot = plugin.Store:RecordBatchSent(order.id, 1, {
        recipient = "Bob-TestRealm",
        items     = { [2447] = 2 },
        sentBy    = "Mattia-TestRealm",
    })
    Test.truthy(ok)
    Test.truthy(slot.sentAt, "sentAt should be stamped")
    Test.eq(slot.sentTo, "Bob-TestRealm")
    Test.eq(slot.sentBy, "Mattia-TestRealm")
    Test.eq(slot.sentItems[2447], 2)
end)

Test.it("RecordBatchSent emits an OrderUpdated{change=batch-sent} event", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchSent(order.id, 1, { recipient = "Bob-TestRealm", items = { [2447] = 2 } })
    local events = plugin.Store:GetRecentEvents(100)
    local match
    for index = 1, #events do
        if events[index].kind == "OrderUpdated"
            and events[index].orderId == order.id
            and events[index].payload
            and events[index].payload.change == "batch-sent" then
            match = events[index]
        end
    end
    Test.truthy(match)
    Test.eq(match.payload.batchNumber, 1)
end)

Test.it("RecordBatchSent alone does not advance the order's status", function()
    -- RecordBatchSent is the pure ledger write; the lifecycle bump
    -- lives in Mailbox:OnMailSendSuccess so callers who don't go
    -- through the mail flow (e.g. future manual-trade entrypoint)
    -- can record without triggering it.
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchSent(order.id, 1, { recipient = "Bob-TestRealm", items = {} })
    Test.eq(plugin.Store:GetOrder(order.id).status, "Draft")
end)

Test.it("Compose stages a pending send that ConsumePendingSend returns once", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant:SetMailboxOpen(true)
    Test.truthy(plugin.Board:DispatchAction(order.id, { kind = "compose-mail" }))

    local pending = plugin.MailAssistant:ConsumePendingSend()
    Test.truthy(pending)
    Test.eq(pending.orderId, order.id)
    Test.eq(pending.recipient, "Bob-TestRealm")
    Test.eq(pending.batchIndex, 1)

    -- ConsumePendingSend clears the descriptor; a second call returns nil.
    Test.eq(plugin.MailAssistant:ConsumePendingSend(), nil)
end)

Test.it("ConsumePendingSend drops the descriptor after TTL expires", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant:SetMailboxOpen(true)
    Test.truthy(plugin.Board:DispatchAction(order.id, { kind = "compose-mail" }))

    local pending = plugin.MailAssistant:PeekPendingSend()
    Test.truthy(pending)
    -- Force the now-clock past the TTL to simulate a long delay.
    local result = plugin.MailAssistant:ConsumePendingSend(pending.expiresAt + 1)
    Test.eq(result, nil, "expired pending should not be returned")
end)

Test.it("Mailbox:OnMailSendSuccess wires Compose + Store:RecordBatchSent end-to-end", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant:SetMailboxOpen(true)
    Test.truthy(plugin.Board:DispatchAction(order.id, { kind = "compose-mail" }))

    -- Simulate the user clicking the in-game Send button: the
    -- production SendMail handler calls into the WoW API, which
    -- (per the harness) clears the outgoing struct and we then
    -- dispatch MAIL_SEND_SUCCESS so the wired handler credits
    -- the batch.
    local slot = plugin.Mailbox:OnMailSendSuccess()
    Test.truthy(slot)
    Test.truthy(slot.sentAt)
    Test.eq(slot.sentTo, "Bob-TestRealm")
end)

Test.it("Mailbox:OnMailSendSuccess is a no-op when there's no pending send", function()
    local plugin = freshPlugin()
    local ok, err = plugin.Mailbox:OnMailSendSuccess()
    Test.eq(ok, nil)
    Test.eq(err, "no-pending-send")
end)

Test.it("OnMailSendSuccess auto-advances Draft -> MaterialsSent for a single-batch order", function()
    -- One small order fits in a single batch. After the user clicks
    -- Send in WoW and MAIL_SEND_SUCCESS fires, the order should
    -- advance to MaterialsSent without the user manually clicking
    -- the now-removed "Mark materials sent" button.
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant:SetMailboxOpen(true)
    Test.truthy(plugin.Board:DispatchAction(order.id, { kind = "compose-mail" }))
    plugin.Mailbox:OnMailSendSuccess()
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent",
        "single-batch send should advance straight to MaterialsSent")
end)

Test.it("OnMailSendSuccess auto-advances Draft -> MaterialsPartial when more batches remain", function()
    -- A multi-batch order: synthesize a pending descriptor that
    -- claims totalBatches = 3 so the first SendSuccess credits
    -- batch 1 and the auto-advance sees 1 of 3 sent.
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant._pendingSend = {
        orderId      = order.id,
        batchIndex   = 1,
        totalBatches = 3,
        recipient    = "Bob-TestRealm",
        items        = { [2447] = 1 },
        expiresAt    = (time and time() or 0) + 60,
    }
    plugin.Mailbox:OnMailSendSuccess()
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsPartial",
        "first of 3 batches should drop the order into MaterialsPartial")
end)

Test.it("OnMailSendSuccess advances MaterialsPartial -> MaterialsSent on the last batch", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Stamp two batches as already sent (simulating two earlier
    -- compose+send rounds) and move the order to MaterialsPartial,
    -- mirroring what AutoAdvance would have done.
    plugin.Store:RecordBatchSent(order.id, 1, { recipient = "Bob-TestRealm", items = {} })
    plugin.Store:RecordBatchSent(order.id, 2, { recipient = "Bob-TestRealm", items = {} })
    plugin.Store:Transition(order.id, "MaterialsPartial", "requester")

    plugin.MailAssistant._pendingSend = {
        orderId      = order.id,
        batchIndex   = 3,
        totalBatches = 3,
        recipient    = "Bob-TestRealm",
        items        = { [2447] = 1 },
        expiresAt    = (time and time() or 0) + 60,
    }
    plugin.Mailbox:OnMailSendSuccess()
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent",
        "third of 3 batches should advance the order to MaterialsSent")
end)

Test.it("OnMailSendSuccess never moves the order back to MaterialsPartial once it's past it", function()
    -- Defensive: if for some reason a follow-up send fires after the
    -- order has already moved to a downstream state, the auto-advance
    -- should NOT regress the state. Only Draft and MaterialsPartial
    -- are valid starting points.
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:Transition(order.id, "MaterialsSent", "requester")
    plugin.Store:Transition(order.id, "MaterialsReceived", "crafter")

    plugin.MailAssistant._pendingSend = {
        orderId      = order.id,
        batchIndex   = 1,
        totalBatches = 1,
        recipient    = "Bob-TestRealm",
        items        = {},
        expiresAt    = (time and time() or 0) + 60,
    }
    plugin.Mailbox:OnMailSendSuccess()
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsReceived",
        "downstream state must not be regressed by a late send")
end)
