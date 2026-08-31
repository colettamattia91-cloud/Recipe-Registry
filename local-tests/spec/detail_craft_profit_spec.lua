-- Craft value / profit on the recipe detail: the created item priced at
-- market, multiplied by the crafted quantity, minus the reagent cost.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

local function usePrices(prices)
    _G.AtlasLoot = nil
    _G.Auctionator = nil
    _G.TSM_API_FOUR = nil
    _G.TSM_API = {
        GetCustomPriceValue = function(_source, itemString)
            return prices[itemString]
        end,
    }
    addon.Market:InvalidatePriceCache("spec")
end

io.write("Detail craft profit\n")

-- spell 28587 = Flask of Fortification: 4 reagents, one flask (item 22851).
Test.it("prices a single-output craft against its reagent cost", function()
    usePrices({
        ["i:18256"] = 10,
        ["i:22790"] = 100,
        ["i:22793"] = 50,
        ["i:22794"] = 200,
        ["i:22851"] = 2000,
    })

    local detail = data:GetRecipeDetail(-28587)
    Test.eq(detail.cost.total, 1060)
    Test.eq(detail.value.count, 1)
    Test.eq(detail.value.unitPrice, 2000)
    Test.eq(detail.value.total, 2000)
    Test.eq(detail.profit.total, 940)
    Test.eq(detail.profit.complete, true)
end)

-- spell 30303 = Adamantite Sharpening Stone: 2 reagents, 4 stones (item 23781).
Test.it("multiplies the output price by the crafted quantity", function()
    usePrices({
        ["i:22573"] = 100,
        ["i:22574"] = 50,
        ["i:23781"] = 500,
    })

    local detail = data:GetRecipeDetail(-30303)
    Test.eq(detail.numCreated, 4)
    Test.eq(detail.cost.total, 250)
    Test.eq(detail.value.count, 4)
    Test.eq(detail.value.total, 2000)
    Test.eq(detail.profit.total, 1750)
end)

Test.it("flags profit as incomplete when a reagent has no price", function()
    usePrices({
        ["i:22573"] = 100,
        ["i:23781"] = 500,
    })

    local detail = data:GetRecipeDetail(-30303)
    Test.eq(detail.cost.missingCount, 1)
    -- Cost is understated, so the profit shown can only be an upper bound.
    Test.eq(detail.profit.total, 1800)
    Test.eq(detail.profit.complete, false)
end)

Test.it("reports a loss without mangling the sign", function()
    usePrices({
        ["i:22573"] = 100,
        ["i:22574"] = 50,
        ["i:23781"] = 10,
    })

    local detail = data:GetRecipeDetail(-30303)
    Test.eq(detail.value.total, 40)
    Test.eq(detail.profit.total, -210)
end)

Test.it("offers no craft value when the created item is unpriced", function()
    usePrices({
        ["i:22573"] = 100,
        ["i:22574"] = 50,
    })

    local detail = data:GetRecipeDetail(-30303)
    Test.eq(detail.cost.total, 250)
    Test.eq(detail.value, nil)
    Test.eq(detail.profit, nil)
end)

Test.it("offers no craft value for recipes with no created item", function()
    usePrices({ ["i:22573"] = 100 })

    local detail = {
        createdItemID = nil,
        reagents = { { itemID = 22573, count = 1 } },
    }
    addon.Market:ApplyRecipeCosts(detail)
    Test.eq(detail.cost.total, 100)
    Test.eq(detail.value, nil)
    Test.eq(detail.profit, nil)
end)

Test.it("spans the yield range for random-output crafts", function()
    usePrices({ ["i:22573"] = 100, ["i:23781"] = 500 })

    local detail = {
        createdItemID = 23781,
        numCreated = 2,
        numCreatedMax = 5,
        reagents = { { itemID = 22573, count = 3 } },
    }
    addon.Market:ApplyRecipeCosts(detail)
    Test.eq(detail.cost.total, 300)
    Test.eq(detail.value.total, 1000)
    Test.eq(detail.value.totalMax, 2500)
    Test.eq(detail.profit.total, 700)
    Test.eq(detail.profit.totalMax, 2200)
end)

io.write(string.format("Detail craft profit: %d test(s) passed\n", Test.count))
