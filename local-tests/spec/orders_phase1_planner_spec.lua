local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

-- Per-recipe reagent table. Recipe keys mirror what RR returns from
-- Data:GetRecipeDisplayInfo — itemID-keyed or negative spellID-keyed.
local RECIPES = {
    -- Healing Potion: 1x Peacebloom + 1x Silverleaf, makes 1
    [929]  = {
        label = "Major Healing Potion",
        createdItemID = 22829,
        numCreated = 1,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom",  icon = "p", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf",  icon = "s", quality = 1 },
        },
    },
    -- Mana Potion: 2x Mageroyal + 1x Silverleaf, makes 1
    [858]  = {
        label = "Lesser Mana Potion",
        createdItemID = 3385,
        numCreated = 1,
        reagents = {
            { itemID = 785,  count = 2, name = "Mageroyal",  icon = "m", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", icon = "s", quality = 1 },
        },
    },
    -- A recipe whose info is missing entirely (RR not loaded for that key)
    [13262] = nil,
    -- A recipe whose info exists but with an empty reagents list (data
    -- corruption or AtlasLoot miss).
    [22444] = {
        label = "Phantom Recipe",
        reagents = {},
    },
}

local function makeStub()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, recipeKey)
                return RECIPES[recipeKey]
            end,
        },
    }
end

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

io.write("Craft Orders planner\n")

Test.it("aggregates a single line into per-item buckets", function()
    local plugin = freshPlugin()
    local mats, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 929, quantity = 3 },
    })
    Test.eq(#missing, 0)

    local peacebloom = mats[2447]
    local silverleaf = mats[765]
    Test.truthy(peacebloom, "peacebloom bucket present")
    Test.truthy(silverleaf, "silverleaf bucket present")
    Test.eq(peacebloom.required, 3)
    Test.eq(silverleaf.required, 3)
    -- Default split per planner: 100% requester-provided.
    Test.eq(peacebloom.requesterProvided, 3)
    Test.eq(peacebloom.crafterProvided, 0)
end)

Test.it("multiplies per-craft reagent count by quantity", function()
    local plugin = freshPlugin()
    local mats = plugin.Planner:ComputeFromLines({
        { recipeKey = 858, quantity = 4 },
    })
    -- Mana Potion takes 2 Mageroyal per craft -> 8 across 4 crafts.
    Test.eq(mats[785].required, 8)
    Test.eq(mats[765].required, 4)
end)

Test.it("sums repeated lines of the same recipe", function()
    local plugin = freshPlugin()
    local mats = plugin.Planner:ComputeFromLines({
        { recipeKey = 929, quantity = 2 },
        { recipeKey = 929, quantity = 3 },
    })
    Test.eq(mats[2447].required, 5, "peacebloom summed across both lines")
    Test.eq(mats[765].required, 5, "silverleaf summed across both lines")
end)

Test.it("merges shared reagents across different recipes", function()
    local plugin = freshPlugin()
    local mats = plugin.Planner:ComputeFromLines({
        { recipeKey = 929, quantity = 2 },  -- 2 Peacebloom + 2 Silverleaf
        { recipeKey = 858, quantity = 3 },  -- 6 Mageroyal + 3 Silverleaf
    })
    Test.eq(mats[2447].required, 2, "peacebloom only from recipe 929")
    Test.eq(mats[785].required, 6, "mageroyal only from recipe 858")
    Test.eq(mats[765].required, 5, "silverleaf merged: 2 + 3")
end)

Test.it("records lines with missing recipe info under missing", function()
    local plugin = freshPlugin()
    local mats, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 13262, quantity = 1 },  -- info missing
    })
    Test.eq(next(mats), nil, "no materials produced")
    Test.eq(#missing, 1)
    Test.eq(missing[1].recipeKey, 13262)
    Test.eq(missing[1].quantity, 1)
    Test.eq(missing[1].reason, "no-info")
end)

Test.it("flags recipes whose info has zero reagents", function()
    local plugin = freshPlugin()
    local mats, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 22444, quantity = 2 },  -- empty reagents
    })
    Test.eq(next(mats), nil)
    Test.eq(#missing, 1)
    Test.eq(missing[1].reason, "no-reagents")
end)

Test.it("ignores lines with non-positive quantity", function()
    local plugin = freshPlugin()
    local mats, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 929, quantity = 0 },
        { recipeKey = 929, quantity = -1 },
    })
    Test.eq(next(mats), nil)
    Test.eq(#missing, 0, "zero/negative quantities are silently skipped, not 'missing'")
end)

Test.it("handles nil and non-table inputs without crashing", function()
    local plugin = freshPlugin()
    local mats, missing = plugin.Planner:ComputeFromLines(nil)
    Test.eq(next(mats), nil)
    Test.eq(#missing, 0)

    local mats2, missing2 = plugin.Planner:ComputeFromLines("not-a-table")
    Test.eq(next(mats2), nil)
    Test.eq(#missing2, 0)
end)

Test.it("RecomputeOrder writes materials and missing onto the order", function()
    local plugin = freshPlugin()
    local order = {
        lines = {
            { recipeKey = 929,   quantity = 1 },
            { recipeKey = 13262, quantity = 1 },
        },
    }
    local ok = plugin.Planner:RecomputeOrder(order)
    Test.truthy(ok)
    Test.eq(order.materials[2447].required, 1)
    Test.truthy(order._plannerMissing, "missing list attached")
    Test.eq(#order._plannerMissing, 1)
end)

Test.it("RecomputeOrder clears prior _plannerMissing when all lines resolve", function()
    local plugin = freshPlugin()
    local order = {
        lines = { { recipeKey = 13262, quantity = 1 } },
    }
    plugin.Planner:RecomputeOrder(order)
    Test.truthy(order._plannerMissing)

    order.lines = { { recipeKey = 929, quantity = 1 } }
    plugin.Planner:RecomputeOrder(order)
    Test.eq(order._plannerMissing, nil, "should be cleared, not left stale")
end)

Test.it("CountMaterials returns distinct count and total units", function()
    local plugin = freshPlugin()
    local order = {
        lines = {
            { recipeKey = 929, quantity = 2 },
            { recipeKey = 858, quantity = 3 },
        },
    }
    plugin.Planner:RecomputeOrder(order)
    local distinct, total = plugin.Planner:CountMaterials(order)
    -- 3 distinct items: Peacebloom (2), Mageroyal (6), Silverleaf (5) = 13.
    Test.eq(distinct, 3)
    Test.eq(total, 13)
end)

Test.it("GetSortedMaterials sorts by name then itemID", function()
    local plugin = freshPlugin()
    local order = {
        lines = {
            { recipeKey = 929, quantity = 1 },
            { recipeKey = 858, quantity = 1 },
        },
    }
    plugin.Planner:RecomputeOrder(order)
    local list = plugin.Planner:GetSortedMaterials(order)
    -- Expect alphabetic by name: Mageroyal, Peacebloom, Silverleaf.
    Test.eq(list[1].name, "Mageroyal")
    Test.eq(list[2].name, "Peacebloom")
    Test.eq(list[3].name, "Silverleaf")
end)

Test.it("returns nil from getRecipeDisplayInfo when RR is absent", function()
    Loader.Wow.Reset()
    -- No recipeRegistryStub: _G.RecipeRegistry remains nil.
    local plugin = Loader.LoadOrders()
    local mats, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 929, quantity = 1 },
    })
    Test.eq(next(mats), nil)
    Test.eq(#missing, 1)
    Test.eq(missing[1].reason, "no-info")
end)

io.write(string.format("Craft Orders planner: %d test(s) passed\n", Test.count))
