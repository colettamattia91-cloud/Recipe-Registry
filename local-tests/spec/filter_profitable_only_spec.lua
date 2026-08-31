-- The single "only profitable recipes" toggle. One switch, not a filter
-- axis: a craft is in when its created item sells for more than its
-- reagents, out otherwise, and out as well when it cannot be priced.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local filters = addon.RecipeUiFilters

-- spell 30303 = an engineering craft: 4 of item 23781 from 2x 22573 + 1x 22574.
local STONE = -30303

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

local function setProfitableOnly(enabled)
    addon.db.profile.recipePrefilters.showOnlyProfitableRecipes = enabled
end

io.write("Profitable-only filter\n")

Test.it("leaves the list untouched while the toggle is off", function()
    setProfitableOnly(false)
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 50, ["i:23781"] = 1 })

    local passes, reason = filters:RecipePasses(STONE)
    Test.eq(passes, true)
    Test.eq(reason, "visible-normal")
end)

Test.it("keeps a craft that sells for more than its reagents", function()
    setProfitableOnly(true)
    -- 4 x 100 = 400 out, 2x100 + 1x50 = 250 in.
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 50, ["i:23781"] = 100 })

    local passes, reason = filters:RecipePasses(STONE)
    Test.eq(passes, true)
    Test.eq(reason, "visible-normal")
end)

Test.it("drops a craft that sells for less than its reagents", function()
    setProfitableOnly(true)
    -- 4 x 50 = 200 out against the same 250 in.
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 50, ["i:23781"] = 50 })

    local passes, reason = filters:RecipePasses(STONE)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-not-profitable")
end)

Test.it("counts the crafted quantity, not one unit", function()
    setProfitableOnly(true)
    -- A single stone at 100 would lose 150; four of them earn 150.
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 50, ["i:23781"] = 100 })
    Test.eq(addon.Market:EstimateRecipeProfit(STONE), 150)
end)

-- Vendor reagents (vials, thread, spices) often have no auctions at all.
-- Hiding what cannot be priced would quietly empty whole professions, so
-- the filter only drops a craft it has actually judged unprofitable.
Test.it("keeps a craft it cannot price and marks it instead", function()
    setProfitableOnly(true)
    usePrices({ ["i:22573"] = 100, ["i:23781"] = 10000 })

    local profit, why = addon.Market:EstimateRecipeProfit(STONE)
    Test.eq(profit, nil)
    Test.eq(why, "unpriceable")

    local passes, reason = filters:RecipePasses(STONE)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unpriced")
end)

Test.it("keeps a craft whose output has no price", function()
    setProfitableOnly(true)
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 50 })

    local passes, reason = filters:RecipePasses(STONE)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unpriced")
end)

Test.it("keeps the toggle out of the cheap predicate path when off", function()
    -- With the toggle off the market module is never consulted, so a broken
    -- price provider cannot affect the default list.
    setProfitableOnly(false)
    local calls = 0
    local realEstimate = addon.Market.EstimateRecipeProfit
    addon.Market.EstimateRecipeProfit = function(...)
        calls = calls + 1
        return realEstimate(...)
    end
    filters:RecipePasses(STONE)
    addon.Market.EstimateRecipeProfit = realEstimate
    Test.eq(calls, 0)
end)

Test.it("separates cached recipe lists by toggle state", function()
    setProfitableOnly(false)
    local off = filters:BuildFilterCacheKey({})
    setProfitableOnly(true)
    local on = filters:BuildFilterCacheKey({})
    Test.ne(off, on)
    setProfitableOnly(false)
end)

Test.it("prices a vendor reagent at the vendor, not the auction house", function()
    setProfitableOnly(true)
    -- 22574 is listed at a gouging 5000 on the auction house but a merchant
    -- sells it for 50. Without the vendor price the craft reads as a loss.
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 5000, ["i:23781"] = 100 })
    addon.db.global.vendorPrices[22574] = 50

    Test.eq(addon.Market:GetMaterialCost(22574), 50)
    Test.eq(addon.Market:EstimateRecipeProfit(STONE), 150)
    Test.eq(filters:RecipePasses(STONE), true)

    addon.db.global.vendorPrices[22574] = nil
end)

Test.it("keeps the auction price when it undercuts the vendor", function()
    usePrices({ ["i:22574"] = 20 })
    addon.db.global.vendorPrices[22574] = 50
    Test.eq(addon.Market:GetMaterialCost(22574), 20)
    addon.db.global.vendorPrices[22574] = nil
end)

Test.it("values the output at market price even when a vendor sells it too", function()
    -- A vendor's asking price is what you pay to buy, never what you get
    -- for selling: it must not become the craft's sale value.
    usePrices({ ["i:23781"] = 100 })
    addon.db.global.vendorPrices[23781] = 1
    Test.eq(addon.Market:GetMarketPrice(23781), 100)
    Test.eq(addon.Market:GetMaterialCost(23781), 1)
    addon.db.global.vendorPrices[23781] = nil
end)

Test.it("nets the auction house cut out of the verdict when asked", function()
    setProfitableOnly(true)
    -- 4 stones at 65 = 260 gross against 250 of reagents: profitable gross,
    -- a loss once the house takes its 5%.
    usePrices({ ["i:22573"] = 100, ["i:22574"] = 50, ["i:23781"] = 65 })
    Test.eq(addon.Market:EstimateRecipeProfit(STONE), 10)
    Test.eq(filters:RecipePasses(STONE), true)

    addon.db.profile.subtractAuctionHouseCut = true
    addon.Market:InvalidatePriceCache("spec")
    Test.eq(addon.Market:EstimateRecipeProfit(STONE), -3)
    local passes, reason = filters:RecipePasses(STONE)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-not-profitable")

    addon.db.profile.subtractAuctionHouseCut = false
    setProfitableOnly(false)
end)

io.write(string.format("Profitable-only filter: %d test(s) passed\n", Test.count))
