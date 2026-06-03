-- Backend coverage for the outgoing Mail Assistant: planning,
-- composition, and the SendBatch driver against the harness's
-- mailbox mock.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

-- A single-reagent recipe keeps the maths trivial: one line for N
-- crafts produces a materials map of one bucket worth `count*N`.
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

-- Builds a draft order, runs the planner so order.materials is
-- populated (the Assistant reads from there), and returns the order.
local function draftWithLines(plugin, lines)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = lines,
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

io.write("Craft Orders mail assistant\n")

Test.it("GatherShippableItems sorts by itemID and skips non-mailable / excluded buckets", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
    })
    -- Mark Silverleaf as non-mailable to verify it's filtered out.
    order.materials[765].mailable = false

    local items = plugin.MailAssistant:GatherShippableItems(order)
    Test.eq(#items, 1)
    Test.eq(items[1].itemID, 2447, "Peacebloom (the mailable one) should remain")
end)

Test.it("PlanBatches produces one batch when items fit under the limit", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
    })
    local batches = plugin.MailAssistant:PlanBatches(order)
    Test.eq(#batches, 1)
    Test.eq(batches[1].batchNumber, 1)
    Test.eq(batches[1].totalBatches, 1)
    Test.eq(#batches[1].items, 2)
end)

Test.it("PlanBatches splits into multiple batches when distinct items exceed the limit", function()
    local plugin = freshPlugin()
    -- Force the test order to have 15 distinct materials by mutating
    -- materials directly. This isolates the splitting logic from the
    -- planner's per-recipe math.
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })
    order.materials = {}
    for itemID = 1, 15 do
        order.materials[itemID] = {
            itemID            = itemID,
            name              = "item-" .. itemID,
            required          = 1,
            requesterProvided = 1,
            mailable          = true,
            excluded          = false,
        }
    end

    local batches = plugin.MailAssistant:PlanBatches(order)
    Test.eq(#batches, 2, "15 items / 12 per mail = 2 batches")
    Test.eq(#batches[1].items, 12)
    Test.eq(#batches[2].items, 3)
    Test.eq(batches[1].totalBatches, 2)
    Test.eq(batches[2].totalBatches, 2)
end)

Test.it("FormatSubject stays under the 50-char soft cap for typical orders", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
    })
    local subject = plugin.MailAssistant:FormatSubject(order, { batchNumber = 1, totalBatches = 1 })
    Test.lte(#subject, plugin.MailAssistant.SUBJECT_MAX,
        "subject must fit the in-game subject line: " .. subject)
    Test.truthy(subject:find("[RR]", 1, true))
    Test.truthy(subject:find("Order", 1, true))
end)

Test.it("ComposeMail produces a body whose marker round-trips via the codec", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" },
    })
    local batches = plugin.MailAssistant:PlanBatches(order)
    local mail, err = plugin.MailAssistant:ComposeMail(order, batches[1])
    Test.truthy(mail, err)
    Test.eq(mail.recipient, "Bob-TestRealm")
    Test.truthy(mail.subject)
    Test.truthy(mail.body)

    local decoded, decodeErr = plugin.MailMarker:Decode(mail.body)
    Test.truthy(decoded, decodeErr)
    Test.eq(decoded.orderId, order.id)
    Test.eq(decoded.requester, "Mattia-TestRealm")
    Test.eq(decoded.crafter, "Bob-TestRealm")
    Test.eq(decoded.items[2447], 2, "Peacebloom required = count*quantity = 1*2")
    Test.eq(decoded.items[765],  2, "Silverleaf required = count*quantity = 1*2")
end)

Test.it("ComposeMail rejects orders missing crafter or requester", function()
    local plugin = freshPlugin()
    local _, err1 = plugin.MailAssistant:ComposeMail({}, { batchNumber = 1, totalBatches = 1, items = {} })
    Test.eq(err1, "missing-crafter")
    local _, err2 = plugin.MailAssistant:ComposeMail(
        { crafter = "B-R" },
        { batchNumber = 1, totalBatches = 1, items = {} })
    Test.eq(err2, "missing-requester")
end)

Test.it("SendBatch attaches items via supplier and dispatches SendMail", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
    })
    plugin.MailAssistant:SetMailboxOpen(true)

    local batches = plugin.MailAssistant:PlanBatches(order)
    local supplied = {}
    local supplier = function(itemID, count)
        supplied[#supplied + 1] = { itemID = itemID, count = count }
        Loader.Wow.PutItemOnCursor({ itemID = itemID, count = count, name = "fake" })
        return true
    end

    local ok, err = plugin.MailAssistant:SendBatch(order, batches[1], supplier)
    Test.truthy(ok, err)
    Test.eq(#supplied, 2, "supplier called once per shippable item")

    local sent = Loader.Wow.GetSentMail()
    Test.eq(#sent, 1)
    Test.eq(sent[1].recipient, "Bob-TestRealm")
    Test.eq(#sent[1].attachments, 2)
end)

Test.it("SendBatch refuses when the mailbox is closed", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
    })
    plugin.MailAssistant:SetMailboxOpen(false)
    local batches = plugin.MailAssistant:PlanBatches(order)
    local ok, err = plugin.MailAssistant:SendBatch(order, batches[1],
        function() return true end)
    Test.eq(ok, false)
    Test.eq(err, "mailbox-closed")
    Test.eq(#Loader.Wow.GetSentMail(), 0,
        "no mail should leak out when the mailbox isn't open")
end)

Test.it("SendBatch surfaces supplier failures and aborts the send", function()
    local plugin = freshPlugin()
    local order = draftWithLines(plugin, {
        { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
    })
    plugin.MailAssistant:SetMailboxOpen(true)
    local batches = plugin.MailAssistant:PlanBatches(order)
    local ok, err = plugin.MailAssistant:SendBatch(order, batches[1],
        function() return false end)
    Test.eq(ok, false)
    Test.truthy(err:find("supplier-failed", 1, true))
    Test.eq(#Loader.Wow.GetSentMail(), 0,
        "no mail should be sent if supplier can't stage the first item")
end)
