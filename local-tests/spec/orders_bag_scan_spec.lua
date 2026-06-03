-- Backend coverage for BagScan + the Assistant's auto-attach path.
-- The harness's bag mock backs both surfaces so the spec drives the
-- whole flow (compose -> auto-attach -> SendMail) deterministically.

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
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin, quantity)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = quantity or 2, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

io.write("Craft Orders bag scan + auto-attach\n")

Test.it("CountItem aggregates across stacks in different bags", function()
    local plugin = freshPlugin()
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 2447, count = 10, name = "Peacebloom" } },
        [1] = { [2] = { itemID = 2447, count = 5,  name = "Peacebloom" } },
        [2] = { [3] = { itemID = 765,  count = 7,  name = "Silverleaf" } },
    })
    Test.eq(plugin.BagScan:CountItem(2447), 15)
    Test.eq(plugin.BagScan:CountItem(765), 7)
    Test.eq(plugin.BagScan:CountItem(99999), 0, "unknown items count as zero")
end)

Test.it("IndexItem returns stacks sorted by descending count", function()
    local plugin = freshPlugin()
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 2447, count = 4, name = "Peacebloom" } },
        [1] = { [1] = { itemID = 2447, count = 9, name = "Peacebloom" } },
        [2] = { [1] = { itemID = 2447, count = 1, name = "Peacebloom" } },
    })
    local stacks = plugin.BagScan:IndexItem(2447)
    Test.eq(#stacks, 3)
    Test.eq(stacks[1].count, 9, "largest stack first")
    Test.eq(stacks[2].count, 4)
    Test.eq(stacks[3].count, 1)
end)

Test.it("Pick lifts the whole stack when the count exactly matches", function()
    local plugin = freshPlugin()
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 2447, count = 5, name = "Peacebloom" } },
    })
    Test.truthy(plugin.BagScan:Pick(2447, 5))
    local cursor = Loader.Wow.GetCursorItem()
    Test.truthy(cursor)
    Test.eq(cursor.itemID, 2447)
    Test.eq(cursor.count, 5)
    -- The stack slot should now be empty in the bag.
    Test.eq(Loader.Wow.GetBagContents()[0][1], nil)
end)

Test.it("Pick splits the stack when count is less than the source size", function()
    local plugin = freshPlugin()
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 2447, count = 10, name = "Peacebloom" } },
    })
    Test.truthy(plugin.BagScan:Pick(2447, 4))
    local cursor = Loader.Wow.GetCursorItem()
    Test.eq(cursor.count, 4)
    Test.eq(Loader.Wow.GetBagContents()[0][1].count, 6,
        "the source stack should drop by exactly the pick count")
end)

Test.it("Pick fails with split-across-stacks when no single stack covers the need", function()
    local plugin = freshPlugin()
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 2447, count = 3, name = "Peacebloom" } },
        [1] = { [1] = { itemID = 2447, count = 2, name = "Peacebloom" } },
    })
    local ok, err = plugin.BagScan:Pick(2447, 5)
    Test.eq(ok, false)
    Test.eq(err, "split-across-stacks")
end)

Test.it("Pick fails with no-stack when the item isn't in bags", function()
    local plugin = freshPlugin()
    local ok, err = plugin.BagScan:Pick(99999, 1)
    Test.eq(ok, false)
    Test.eq(err, "no-stack")
end)

Test.it("Pick prefers the smallest sufficient stack to avoid breaking big stacks", function()
    local plugin = freshPlugin()
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 2447, count = 100, name = "Peacebloom" } },
        [1] = { [1] = { itemID = 2447, count = 5,   name = "Peacebloom" } },
    })
    Test.truthy(plugin.BagScan:Pick(2447, 4))
    -- The smaller stack (5) should be split down to 1, the big stack untouched.
    Test.eq(Loader.Wow.GetBagContents()[1][1].count, 1)
    Test.eq(Loader.Wow.GetBagContents()[0][1].count, 100)
end)

Test.it("OpenComposer auto-attaches every batch item when bags have enough", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin, 2)  -- needs 2 Peacebloom + 2 Silverleaf
    Loader.Wow.SetBagContents({
        [0] = {
            [1] = { itemID = 2447, count = 10, name = "Peacebloom" },
            [2] = { itemID = 765,  count = 10, name = "Silverleaf" },
        },
    })
    plugin.MailAssistant:SetMailboxOpen(true)
    local ok, info = plugin.MailAssistant:OpenComposer(order)
    Test.truthy(ok)
    Test.truthy(info.autoAttach)
    Test.eq(info.autoAttach.attached, 2,
        "both items should land in attachment slots")
    Test.eq(#info.autoAttach.missing, 0)

    local outgoing = Loader.Wow.GetSendMailOutgoing()
    Test.eq(#outgoing.attachments, 2,
        "the SendMail outgoing struct should hold both staged attachments")
end)

Test.it("OpenComposer surfaces missing items when bags don't have enough", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin, 2)  -- needs 2 Peacebloom + 2 Silverleaf
    Loader.Wow.SetBagContents({
        [0] = {
            [1] = { itemID = 2447, count = 2, name = "Peacebloom" },
            -- Silverleaf missing entirely.
        },
    })
    plugin.MailAssistant:SetMailboxOpen(true)
    local ok, info = plugin.MailAssistant:OpenComposer(order)
    Test.truthy(ok)
    Test.eq(info.autoAttach.attached, 1)
    Test.eq(#info.autoAttach.missing, 1)
    Test.eq(info.autoAttach.missing[1].itemID, 765)
    Test.eq(info.autoAttach.missing[1].needed, 2)
    Test.eq(info.autoAttach.missing[1].available, 0)
end)

Test.it("OpenComposer with autoAttach=false leaves the slots empty for manual attach", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin, 2)
    Loader.Wow.SetBagContents({
        [0] = {
            [1] = { itemID = 2447, count = 10, name = "Peacebloom" },
            [2] = { itemID = 765,  count = 10, name = "Silverleaf" },
        },
    })
    plugin.MailAssistant:SetMailboxOpen(true)
    local ok, info = plugin.MailAssistant:OpenComposer(order, { autoAttach = false })
    Test.truthy(ok)
    Test.eq(info.autoAttach, nil, "no auto-attach summary when opted out")
    local outgoing = Loader.Wow.GetSendMailOutgoing()
    Test.eq(#outgoing.attachments, 0,
        "manual mode should leave attachment slots empty for the user to drag items into")
end)
