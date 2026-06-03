-- Backend coverage for the delivery half of the order lifecycle:
-- crafter ships finished outputs back to the requester via a
-- delivery-kind mail. Verifies the marker variant, the assistant's
-- delivery planner/composer, the store's RecordDelivery accumulator,
-- the scanner's sender-check switch, and the Board's compose-delivery
-- action gating.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        createdItemName = "Major Healing Potion",
        numCreated    = 1,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom" },
        },
    },
    -- Trinkets: 1 craft -> 1 output, useful for the simple case.
    [858] = {
        label         = "Lesser Mana Potion",
        createdItemID = 3385,
        createdItemName = "Lesser Mana Potion",
        numCreated    = 1,
        reagents = {
            { itemID = 785, count = 2, name = "Mageroyal" },
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

local function freshPluginAs(playerName)
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer(playerName or "Bob", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftAndAccept(plugin)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 3, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    -- Walk through to Accepted so the crafter has something to deliver.
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsReceived", "crafter"))
    Test.truthy(plugin.Store:Transition(order.id, "Accepted", "crafter"))
    return order
end

io.write("Craft Orders delivery flow\n")

Test.it("Marker encodes/decodes a kind field; default is materials", function()
    local plugin = freshPluginAs()
    local materialsBody = plugin.MailMarker:Encode({
        orderId = "x", requester = "A-R", crafter = "B-R",
        batchNumber = 1, totalBatches = 1, items = { [1] = 1 },
    })
    local decodedMat = plugin.MailMarker:Decode(materialsBody)
    Test.eq(decodedMat.kind, plugin.MailMarker.KIND_MATERIALS)

    local deliveryBody = plugin.MailMarker:Encode({
        orderId = "x", requester = "A-R", crafter = "B-R",
        batchNumber = 1, totalBatches = 1, items = { [1] = 1 },
        kind = plugin.MailMarker.KIND_DELIVERY,
    })
    local decodedDel = plugin.MailMarker:Decode(deliveryBody)
    Test.eq(decodedDel.kind, "delivery")
end)

Test.it("PlanDeliveryItems aggregates outputItemID totals per recipe quantity", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    local items = plugin.MailAssistant:PlanDeliveryItems(order)
    Test.eq(#items, 1, "single-recipe order produces a single output bucket")
    Test.eq(items[1].itemID, 22829)
    Test.eq(items[1].count, 3, "3 crafts * 1 numCreated = 3")
end)

Test.it("PlanDeliveryItems multiplies quantity * numCreated when the recipe yields more than 1", function()
    local plugin = freshPluginAs("Bob")
    RECIPES[929].numCreated = 5
    local order = draftAndAccept(plugin)
    local items = plugin.MailAssistant:PlanDeliveryItems(order)
    Test.eq(items[1].count, 15, "3 crafts * 5 numCreated = 15")
    RECIPES[929].numCreated = 1  -- reset for other tests
end)

Test.it("ComposeDeliveryMail builds a body whose marker decodes as delivery", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    local batches = plugin.MailAssistant:PlanDeliveryBatches(order)
    Test.eq(#batches, 1)
    Test.eq(batches[1].kind, "delivery")

    local mail = plugin.MailAssistant:ComposeDeliveryMail(order, batches[1])
    Test.eq(mail.recipient, "Mattia-TestRealm",
        "delivery recipient is the order's requester")
    Test.truthy(mail.subject:find("Delivery", 1, true))

    local decoded = plugin.MailMarker:Decode(mail.body)
    Test.eq(decoded.kind, "delivery")
    Test.eq(decoded.items[22829], 3)
end)

Test.it("OpenDeliveryComposer auto-attaches outputs from the crafter's bags", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 22829, count = 5, name = "Major Healing Potion" } },
    })
    plugin.MailAssistant:SetMailboxOpen(true)
    local ok, info = plugin.MailAssistant:OpenDeliveryComposer(order)
    Test.truthy(ok)
    Test.eq(info.kind, "delivery")
    Test.eq(info.autoAttach.attached, 1)
    local outgoing = Loader.Wow.GetSendMailOutgoing()
    Test.eq(outgoing.recipient, "Mattia-TestRealm")
    Test.eq(#outgoing.attachments, 1)
    Test.eq(outgoing.attachments[1].count, 3)
end)

Test.it("Store:RecordDelivery accumulates observed items into order.delivered", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    plugin.Store:RecordDelivery(order.id, {
        observed = { [22829] = 2 }, source = "scanner", valid = true,
    })
    plugin.Store:RecordDelivery(order.id, {
        observed = { [22829] = 1 }, source = "scanner", valid = true,
    })
    Test.eq(plugin.Store:GetOrder(order.id).delivered[22829], 3,
        "two delivery mails should sum to the total")
end)

Test.it("Store:RecordDelivery does not advance the order's status", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    Test.truthy(plugin.Store:Transition(order.id, "DeliverySent", "crafter"))
    plugin.Store:RecordDelivery(order.id, {
        observed = { [22829] = 3 }, source = "scanner", valid = true,
    })
    Test.eq(plugin.Store:GetOrder(order.id).status, "DeliverySent",
        "the requester still manually marks Completed")
end)

Test.it("Scanner sender-check uses order.crafter for delivery mails", function()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")  -- requester scans inbox
    local plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub() })
    -- We re-create the order from the requester's vantage so its
    -- recognized locally.
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })

    -- Craft a delivery mail from the right sender.
    local body = plugin.MailMarker:Encode({
        orderId = order.id, requester = "Mattia-TestRealm", crafter = "Bob-TestRealm",
        kind = "delivery", batchNumber = 1, totalBatches = 1,
        items = { [22829] = 1 },
    })
    Loader.Wow.AddInboxMail({
        sender = "Bob-TestRealm", subject = "[RR] Delivery",
        body = body, items = { { itemID = 22829, count = 1, name = "Major Healing Potion" } },
    })
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.valid, true,
        "a delivery from the crafter to the requester should pass integrity")

    -- Inverse case: a delivery body that arrives from the requester
    -- (mis-sent) must fail sender-match.
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub() })
    plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })
    -- Use a body for SOME order id; we don't need it to match locally
    -- because we're checking the sender path with a known order.
    Loader.Wow.AddInboxMail({
        sender = "Mattia-TestRealm", subject = "[RR] Delivery",
        body = body, items = { { itemID = 22829, count = 1, name = "Major Healing Potion" } },
    })
    local r2 = plugin.MailScanner:ScanInbox()
    local localOrders = plugin.Store:ListOrders()
    local newOrder = localOrders[1]
    local outcome2 = plugin.MailScanner:VerifyIntegrity(r2[1], newOrder)
    Test.eq(outcome2.senderMatch, false,
        "a delivery body from the requester (not the crafter) must fail sender-match")
end)

Test.it("Mailbox.ProcessInbox routes delivery mails through RecordDelivery", function()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    local plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub() })
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })

    local body = plugin.MailMarker:Encode({
        orderId = order.id, requester = "Mattia-TestRealm", crafter = "Bob-TestRealm",
        kind = "delivery", batchNumber = 1, totalBatches = 1,
        items = { [22829] = 1 },
    })
    Loader.Wow.AddInboxMail({
        sender = "Bob-TestRealm", subject = "[RR] Delivery",
        body = body, items = { { itemID = 22829, count = 1, name = "Major Healing Potion" } },
    })
    local summary = plugin.Mailbox:ProcessInbox()
    Test.eq(summary.recognized, 1)
    Test.eq(summary.delivered, 1,
        "delivery routing should increment the summary's delivered counter")
    Test.eq(plugin.Store:GetOrder(order.id).delivered[22829], 1)
    -- The materials ledger should remain untouched by a delivery mail.
    Test.eq(plugin.Store:GetOrder(order.id).batches[1], nil)
end)

Test.it("Board action strip surfaces compose-delivery for the crafter on Accepted", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    local actions = plugin.Board:ComputeActionsForOrder(order)
    local found
    for index = 1, #actions do
        if actions[index].kind == "compose-delivery" then found = actions[index] end
    end
    Test.truthy(found, "compose-delivery should appear on Accepted for the crafter")
    Test.eq(found.actor, "crafter")
end)

Test.it("Board action strip hides compose-delivery for the requester", function()
    local plugin = freshPluginAs("Mattia")
    local order = draftAndAccept(plugin)
    local actions = plugin.Board:ComputeActionsForOrder(order)
    for index = 1, #actions do
        Test.ne(actions[index].kind, "compose-delivery",
            "the requester must never see compose-delivery on the strip")
    end
end)

Test.it("DispatchAction(compose-delivery) routes to OpenDeliveryComposer", function()
    local plugin = freshPluginAs("Bob")
    local order = draftAndAccept(plugin)
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 22829, count = 3, name = "Major Healing Potion" } },
    })
    plugin.MailAssistant:SetMailboxOpen(true)
    local ok = plugin.Board:DispatchAction(order.id, { kind = "compose-delivery" })
    Test.truthy(ok)
    local outgoing = Loader.Wow.GetSendMailOutgoing()
    Test.eq(outgoing.recipient, "Mattia-TestRealm")
end)
