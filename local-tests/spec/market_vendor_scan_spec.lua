-- Vendor prices learned from merchant windows. Reagents like vials, thread
-- and spices are sold at a fixed price and often have no auctions at all,
-- so the auction sources alone either priced them far above what anyone
-- pays or left them unpriced.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()

-- name, texture, price, quantity, numAvailable, isUsable, extendedCost
local function stockMerchant(rows)
    _G.GetMerchantNumItems = function() return #rows end
    _G.GetMerchantItemInfo = function(index)
        local row = rows[index]
        if not row then return nil end
        return row.name, "texture", row.price, row.quantity or 1, -1, true, row.extendedCost == true
    end
    _G.GetMerchantItemLink = function(index)
        local row = rows[index]
        return row and ("item:" .. tostring(row.itemID)) or nil
    end
end

local function resetStore()
    addon.db.global.vendorPrices = {}
    addon.Market:InvalidatePriceCache("spec")
end

io.write("Merchant vendor scan\n")

Test.it("records the per-unit price of what a merchant sells", function()
    resetStore()
    stockMerchant({
        { itemID = 3371, name = "Empty Vial", price = 25, quantity = 1 },
        { itemID = 2320, name = "Coarse Thread", price = 500, quantity = 5 },
    })

    Test.eq(addon.Market:ScanMerchantPrices(), 2)
    Test.eq(addon.db.global.vendorPrices[3371], 25)
    -- 500 for a stack of 5 is 100 each, not 500.
    Test.eq(addon.db.global.vendorPrices[2320], 100)
end)

Test.it("skips items bought with an alternate currency", function()
    resetStore()
    stockMerchant({
        { itemID = 3371, name = "Empty Vial", price = 25, quantity = 1 },
        { itemID = 29434, name = "Badge reward", price = 0, quantity = 1, extendedCost = true },
    })

    Test.eq(addon.Market:ScanMerchantPrices(), 1)
    Test.eq(addon.db.global.vendorPrices[29434], nil)
end)

Test.it("learns nothing from a merchant it has already scanned", function()
    resetStore()
    stockMerchant({ { itemID = 3371, name = "Empty Vial", price = 25, quantity = 1 } })

    Test.eq(addon.Market:ScanMerchantPrices(), 1)
    -- A second visit must not churn the derived caches for no new facts.
    Test.eq(addon.Market:ScanMerchantPrices(), 0)
end)

Test.it("feeds the learned price into the reagent cost", function()
    resetStore()
    _G.TSM_API = nil
    _G.TSM_API_FOUR = nil
    _G.Auctionator = nil
    stockMerchant({ { itemID = 3371, name = "Empty Vial", price = 25, quantity = 1 } })
    addon.Market:ScanMerchantPrices()

    -- No auction data at all, yet the reagent is priced.
    Test.eq(addon.Market:GetMarketPrice(3371), nil)
    Test.eq(addon.Market:GetMaterialCost(3371), 25)
end)

Test.it("survives a client with no merchant API", function()
    resetStore()
    _G.GetMerchantNumItems = nil
    _G.GetMerchantItemInfo = nil
    Test.eq(addon.Market:ScanMerchantPrices(), 0)
end)

-- The store is saved for good, so it has to be bounded by something other
-- than how many merchants the player happens to open.
Test.it("records only items the addon will ever price as a reagent", function()
    resetStore()
    -- 6948 is a Hearthstone: sold by nobody as a reagent, and never priced.
    stockMerchant({
        { itemID = 3371, name = "Empty Vial", price = 25, quantity = 1 },
        { itemID = 6948, name = "Hearthstone", price = 100, quantity = 1 },
    })

    Test.eq(addon.Market:ScanMerchantPrices(), 1)
    Test.eq(addon.db.global.vendorPrices[3371], 25)
    Test.eq(addon.db.global.vendorPrices[6948], nil)
end)

Test.it("bounds the reagent set to the metadata", function()
    local ids = addon.Market:GetPriceableReagentIds()
    local count = 0
    for _ in pairs(ids) do count = count + 1 end
    -- A few hundred distinct reagents across the whole dataset: a fixed
    -- ceiling, not one that grows with play time.
    Test.gte(count, 50)
    Test.lte(count, 2000)
    Test.eq(ids[3371], true)
end)

io.write(string.format("Merchant vendor scan: %d test(s) passed\n", Test.count))
