-- Backend coverage for §9.1 — the shopping-list aggregator that sums
-- material requirements across the local player's outgoing orders
-- (Draft + MaterialsPartial), subtracts already-shipped batches,
-- on-hand bag stock, and a cached bank snapshot.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label = "Major Healing Potion", createdItemID = 22829, numCreated = 1,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", quality = 1 },
        },
    },
    [858] = {
        label = "Lesser Mana Potion", createdItemID = 3385, numCreated = 1,
        reagents = {
            { itemID = 785,  count = 2, name = "Mageroyal",  quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", quality = 1 },
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

local function freshPlugin(playerName)
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer(playerName or "Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function order(plugin, requester, crafter, recipeKey, quantity)
    local o = plugin.Store:CreateDraft({
        requester = requester,
        crafter   = crafter,
        lines     = { { recipeKey = recipeKey, quantity = quantity, recipeLabel = "x" } },
    })
    plugin.Planner:RecomputeOrder(o)
    return o
end

local function bucketByItemID(materials, itemID)
    for index = 1, #materials do
        if materials[index].itemID == itemID then return materials[index] end
    end
    return nil
end

io.write("Craft Orders shopping aggregation\n")

Test.it("ComputeAggregated returns empty when no outgoing orders exist", function()
    local plugin = freshPlugin()
    local result = plugin.Shopping:ComputeAggregated()
    Test.eq(result.orderCount, 0)
    Test.eq(#result.materials, 0)
end)

Test.it("sums required across multiple orders for the same itemID", function()
    local plugin = freshPlugin("Mattia")
    order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 3)  -- 3x potion = 3 Peacebloom + 3 Silverleaf
    order(plugin, "Mattia-TestRealm", "Carl-TestRealm", 858, 2) -- 2x mana = 4 Mageroyal + 2 Silverleaf
    local result = plugin.Shopping:ComputeAggregated()

    Test.eq(result.orderCount, 2)
    local silverleaf = bucketByItemID(result.materials, 765)
    Test.truthy(silverleaf, "Silverleaf is needed by both orders")
    Test.eq(silverleaf.required, 5, "3 from healing + 2 from mana = 5 silverleaf")
    Test.eq(silverleaf.stillToGather, 5,
        "no on-hand stock, no shipments yet — still 5 to gather")
    Test.eq(#silverleaf.contributingOrders, 2,
        "row tooltip should attribute back to both orders")
end)

Test.it("skips orders where local player isn't the requester", function()
    local plugin = freshPlugin("Mattia")
    order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 1)
    order(plugin, "Carl-TestRealm",   "Mattia-TestRealm", 929, 1)
    local result = plugin.Shopping:ComputeAggregated()
    Test.eq(result.orderCount, 1,
        "only the order I requested should drive the shopping list")
end)

Test.it("skips orders past the MaterialsPartial gathering phase", function()
    local plugin = freshPlugin("Mattia")
    local o1 = order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 1)
    local o2 = order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 858, 1)
    Test.truthy(plugin.Store:Transition(o1.id, "MaterialsSent", "requester"))
    local result = plugin.Shopping:ComputeAggregated()
    Test.eq(result.orderCount, 1,
        "after MaterialsSent the materials have left the requester; only o2 remains")
    Test.eq(bucketByItemID(result.materials, 2447), nil,
        "Peacebloom (only in o1) should NOT appear once o1 left the gathering phase")
    Test.truthy(bucketByItemID(result.materials, 785),
        "Mageroyal (only in o2) is still pending")
end)

Test.it("subtracts crafterProvided from the requester's gathering workload (BoP case)", function()
    local plugin = freshPlugin("Mattia")
    local o = order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 4)
    -- Simulate: crafter says "I'll provide 2 Peacebloom myself" (e.g.
    -- because it's BoP from a JC daily, or because of trust).
    o.materials[2447].crafterProvided = 2

    local result = plugin.Shopping:ComputeAggregated()
    local peacebloom = bucketByItemID(result.materials, 2447)
    Test.truthy(peacebloom)
    Test.eq(peacebloom.required, 2,
        "requester only owes the 4-2 share they didn't offload")
    Test.eq(peacebloom.stillToGather, 2)
end)

Test.it("subtracts already-shipped batches from stillToGather", function()
    local plugin = freshPlugin("Mattia")
    local o = order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 5) -- need 5 Peacebloom
    -- Pretend the user already sent batch 1 carrying 3 Peacebloom.
    plugin.Store:RecordBatchSent(o.id, 1, {
        recipient = "Bob-TestRealm",
        items     = { [2447] = 3 },
    })

    local result = plugin.Shopping:ComputeAggregated()
    local peacebloom = bucketByItemID(result.materials, 2447)
    Test.eq(peacebloom.required, 5)
    Test.eq(peacebloom.sent, 3, "the sent column should reflect batch 1's items")
    Test.eq(peacebloom.stillToGather, 2,
        "5 required - 3 sent = 2 left to send")
end)

Test.it("subtracts bag inventory from stillToGather", function()
    local plugin = freshPlugin("Mattia")
    order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 4) -- 4 of each
    Loader.Wow.SetBagContents({
        [0] = {
            [1] = { itemID = 2447, count = 3, name = "Peacebloom" },
        },
    })
    local result = plugin.Shopping:ComputeAggregated()
    local peacebloom = bucketByItemID(result.materials, 2447)
    Test.eq(peacebloom.inBags, 3)
    Test.eq(peacebloom.stillToGather, 1, "4 required - 3 in bags = 1")
end)

Test.it("UpdateBankSnapshot caches bank contents per local char", function()
    local plugin = freshPlugin("Mattia")
    Loader.Wow.SetBankContents({
        [-1] = { [1] = { itemID = 2447, count = 8, name = "Peacebloom" } },
        [5]  = { [1] = { itemID = 765,  count = 4, name = "Silverleaf" } },
    })
    Loader.Wow.OpenBank()
    plugin.Shopping:UpdateBankSnapshot()
    local snap = plugin.Shopping:GetBankSnapshot()
    Test.truthy(snap)
    Test.eq(snap.items[2447], 8, "main bank Peacebloom should land in the snapshot")
    Test.eq(snap.items[765],  4, "bank bag Silverleaf should land too")
end)

Test.it("ComputeAggregated uses the bank snapshot to reduce stillToGather", function()
    local plugin = freshPlugin("Mattia")
    order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 10) -- need 10 of each
    Loader.Wow.SetBankContents({
        [-1] = { [1] = { itemID = 2447, count = 6, name = "Peacebloom" } },
    })
    plugin.Shopping:UpdateBankSnapshot()

    local result = plugin.Shopping:ComputeAggregated()
    local peacebloom = bucketByItemID(result.materials, 2447)
    Test.eq(peacebloom.inBank, 6)
    Test.eq(peacebloom.stillToGather, 4, "10 - 6 in bank = 4")
end)

Test.it("contributingOrders carries each order's per-item quantity for the breakdown tooltip", function()
    local plugin = freshPlugin("Mattia")
    local o1 = order(plugin, "Mattia-TestRealm", "Bob-TestRealm",  929, 3)
    local o2 = order(plugin, "Mattia-TestRealm", "Carl-TestRealm", 858, 2)
    local result = plugin.Shopping:ComputeAggregated()
    local silverleaf = bucketByItemID(result.materials, 765)
    Test.eq(#silverleaf.contributingOrders, 2)

    -- The two attribution entries should sum to the row's required.
    local total = 0
    for index = 1, #silverleaf.contributingOrders do
        total = total + silverleaf.contributingOrders[index].quantity
    end
    Test.eq(total, silverleaf.required,
        "per-order quantities should sum to the aggregate required")
end)

Test.it("rows are sorted by stillToGather DESC then name ASC for stable top-of-list visibility", function()
    local plugin = freshPlugin("Mattia")
    -- Force two items with different stillToGather: 4 Peacebloom needed,
    -- 1 Silverleaf needed (covered in bags so 0 left).
    order(plugin, "Mattia-TestRealm", "Bob-TestRealm", 929, 1) -- 1 + 1
    order(plugin, "Mattia-TestRealm", "Carl-TestRealm", 929, 3) -- 3 + 3 = 4 + 4 total
    Loader.Wow.SetBagContents({
        [0] = { [1] = { itemID = 765, count = 5, name = "Silverleaf" } }, -- covers all silverleaf
    })
    local result = plugin.Shopping:ComputeAggregated()
    Test.eq(result.materials[1].itemID, 2447,
        "Peacebloom (4 still needed) should be at the top")
    Test.eq(result.materials[2].itemID, 765,
        "Silverleaf (0 still needed) should fall to the bottom")
end)
