-- Backend coverage for the Mailbox orchestrator (the glue between
-- MAIL_SHOW / MAIL_INBOX_UPDATE and the scanner+ledger pipeline).
-- Drives ProcessInbox directly so the test is independent of WoW's
-- event loop.

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
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

-- Adds a happy-path mail matching the given order to the inbox.
local function dropMail(plugin, order)
    local batches = plugin.MailAssistant:PlanBatches(order)
    local mail = plugin.MailAssistant:ComposeMail(order, batches[1])
    Loader.Wow.AddInboxMail({
        sender  = "Mattia-TestRealm",
        subject = mail.subject,
        body    = mail.body,
        items   = {
            { itemID = 2447, count = 2, name = "Peacebloom" },
            { itemID = 765,  count = 2, name = "Silverleaf" },
        },
    })
end

io.write("Craft Orders mailbox orchestrator\n")

Test.it("ProcessInbox is a no-op with an empty inbox", function()
    local plugin = freshPlugin()
    local summary = plugin.Mailbox:ProcessInbox()
    Test.eq(summary.scanned,    0)
    Test.eq(summary.recognized, 0)
    Test.eq(summary.recorded,   0)
    Test.eq(summary.tampered,   0)
end)

Test.it("ProcessInbox records a receipt for a recognized order", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    dropMail(plugin, order)
    local summary = plugin.Mailbox:ProcessInbox()
    Test.eq(summary.scanned, 1)
    Test.eq(summary.recognized, 1)
    Test.eq(summary.recorded, 1)
    Test.eq(summary.tampered, 0)

    local updated = plugin.Store:GetOrder(order.id)
    Test.truthy(updated.batches and updated.batches[1],
        "the ledger slot for batch 1 should now exist")
    Test.eq(updated.batches[1].confirmed[2447], 2)
    Test.eq(updated.batches[1].confirmed[765],  2)
end)

Test.it("ProcessInbox skips RR mails whose orderId is unknown locally", function()
    local plugin = freshPlugin()
    -- Mail referencing a foreign order id that's never been imported.
    local marker = plugin.MailMarker:Encode({
        orderId      = "rr-ord-unknown",
        requester    = "Mattia-TestRealm",
        crafter      = "Bob-TestRealm",
        batchNumber  = 1,
        totalBatches = 1,
        items        = { [2447] = 1 },
    })
    Loader.Wow.AddInboxMail({
        sender  = "Mattia-TestRealm",
        subject = "[RR] Order unknown",
        body    = "body\n" .. marker,
        items   = { { itemID = 2447, count = 1, name = "Peacebloom" } },
    })
    local summary = plugin.Mailbox:ProcessInbox()
    Test.eq(summary.scanned, 1)
    Test.eq(summary.recognized, 0)
    Test.eq(summary.recorded, 0)
end)

Test.it("ProcessInbox flags tampered mail in the summary counter", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Compose the body normally then drop one item — the marker
    -- promises 2 but the inbox only has 1, so item-count-mismatch.
    local batches = plugin.MailAssistant:PlanBatches(order)
    local mail = plugin.MailAssistant:ComposeMail(order, batches[1])
    Loader.Wow.AddInboxMail({
        sender  = "Mattia-TestRealm",
        subject = mail.subject,
        body    = mail.body,
        items   = {
            { itemID = 2447, count = 2, name = "Peacebloom" },
            { itemID = 765,  count = 1, name = "Silverleaf" },  -- short by 1
        },
    })
    local summary = plugin.Mailbox:ProcessInbox()
    Test.eq(summary.recorded, 1)
    Test.eq(summary.tampered, 1)

    local updated = plugin.Store:GetOrder(order.id)
    Test.eq(updated.batches[1].missing[765], 1,
        "missing should reflect the shortfall")
end)

Test.it("ProcessInbox does not advance order status (crafter still drives transition)", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    dropMail(plugin, order)
    plugin.Mailbox:ProcessInbox()
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent",
        "crafter must still mark MaterialsReceived manually")
end)
