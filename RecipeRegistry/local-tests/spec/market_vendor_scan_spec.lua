-- Vendor prices learned from merchant windows. Reagents like vials, thread
-- and spices are sold at a fixed price and often have no auctions at all,
-- so the auction sources alone either priced them far above what anyone
-- pays or left them unpriced.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()

-- The real signature, all eight of it:
--   name, texture, price, quantity, numAvailable, isPurchasable, isUsable,
--   extendedCost
--
-- This fixture used to return seven, leaving isPurchasable out -- the same
-- slot the scanner was missing. Written to the shape of the bug, it asserted
-- a convention the game does not have, and five specs passed over code that
-- could not work in the client: extendedCost read isUsable, which is true for
-- anything the character can use, so every vial and thread was skipped as
-- though it cost honor points.
local function stockMerchant(rows)
    _G.GetMerchantNumItems = function() return #rows end
    _G.GetMerchantItemInfo = function(index)
        local row = rows[index]
        if not row then return nil end
        -- numAvailable: -1 is unlimited stock, anything else is a count.
        return row.name, "texture", row.price, row.quantity or 1,
            row.available or -1,
            true, row.isUsable ~= false, row.extendedCost == true
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

-- The bug this fixture used to hide. A vial the character can drink is
-- exactly the case: usable, bought with money, and skipped.
Test.it("records a reagent the character can use", function()
    resetStore()
    stockMerchant({
        { name = "Imbued Vial", itemID = 18256, price = 16000, quantity = 5, isUsable = true },
    })
    Test.eq(addon.Market:ScanMerchantPrices(), 1,
        "usable is not the same question as bought with something other than money")
    Test.eq(addon.db.global.vendorPrices[18256], 3200,
        "and the price is per item, not per stack of five")
end)

Test.it("still refuses anything bought with something other than money", function()
    resetStore()
    stockMerchant({
        { name = "Imbued Vial", itemID = 18256, price = 16000, quantity = 5, extendedCost = true },
    })
    Test.eq(addon.Market:ScanMerchantPrices(), 0)
    Test.eq(addon.db.global.vendorPrices[18256], nil)
end)

-- The scanner has to name every return it skips over, or the ones it reads
-- are somebody else's values.
Test.it("counts all eight returns of GetMerchantItemInfo", function()
    local handle = assert(io.open("Integrations/Market.lua", "r"))
    local source = handle:read("*a")
    handle:close()
    Test.truthy(source:find("_available, _purchasable, _usable, extendedCost", 1, true) ~= nil,
        "isPurchasable sits between numAvailable and isUsable and cannot be skipped")
end)

-- An Adamantite Frame sitting on a merchant for a few silver is two of them,
-- gone, and then a respawn timer. Costing a craft at that price promises
-- materials that are not for sale.
Test.it("prices only what the merchant always has in stock", function()
    resetStore()
    stockMerchant({
        { name = "Imbued Vial", itemID = 18256, price = 16000, quantity = 5, available = -1 },
        { name = "Adamantite Frame", itemID = 23782, price = 12000, available = 2 },
    })
    Test.eq(addon.Market:ScanMerchantPrices(), 1)
    Test.eq(addon.db.global.vendorPrices[18256], 3200, "unlimited stock is a price")
    Test.eq(addon.db.global.vendorPrices[23782], nil, "two in the world is not")
end)

Test.it("does not treat a stock of one as unlimited", function()
    resetStore()
    stockMerchant({
        { name = "Imbued Vial", itemID = 18256, price = 3200, available = 1 },
    })
    Test.eq(addon.Market:ScanMerchantPrices(), 0)
end)

-- A full scan sends a page event every few hundred milliseconds for minutes.
-- The addon window is often open at the auction house -- looking up what a
-- craft needs is exactly why you would have it open -- so dropping the caches
-- on a timer would churn the panel under the player for the whole scan.
-- Debounced instead: every event pushes the deadline out, and the refresh
-- lands once, after the numbers stop moving.
local function countingInvalidation()
    local calls = { n = 0 }
    local real = addon.Market.InvalidatePriceCache
    addon.Market.InvalidatePriceCache = function(self, reason)
        calls.n = calls.n + 1
        calls.last = reason
        return real(self, reason)
    end
    calls.restore = function() addon.Market.InvalidatePriceCache = real end
    return calls
end

Test.it("refreshes once when a scan settles, not once per page", function()
    resetStore()
    -- Something has to be cached, or there is nothing stale to schedule for.
    addon.Market.priceCache = { [22573] = { price = 100, source = "spec" } }
    local calls = countingInvalidation()

    for _ = 1, 12 do
        addon.Market:OnAuctionDataUpdated()
        _wow.AdvanceTime(0.4)
        _wow.RunDueTimers()
    end
    Test.eq(calls.n, 0, "nothing is dropped while the pages are still arriving")

    _wow.AdvanceTime(3)
    _wow.RunDueTimers()
    Test.eq(calls.n, 1, "and exactly once after they stop")
    Test.eq(calls.last, "auction-data-settled")
    calls.restore()
end)

Test.it("schedules nothing when there is nothing cached", function()
    resetStore()
    addon.Market.priceCache = {}
    addon.Market.vendorCache = {}
    local calls = countingInvalidation()

    Test.eq(addon.Market:OnAuctionDataUpdated(), false)
    _wow.AdvanceTime(5)
    _wow.RunDueTimers()
    Test.eq(calls.n, 0)
    calls.restore()
end)

Test.it("does not refresh twice when the window closes mid-scan", function()
    resetStore()
    addon.Market.priceCache = { [22573] = { price = 100, source = "spec" } }
    local calls = countingInvalidation()

    addon.Market:OnAuctionDataUpdated()
    addon.Market:OnAuctionHouseClosed()
    _wow.AdvanceTime(5)
    _wow.RunDueTimers()
    Test.eq(calls.n, 1, "closing settles the scan; the pending timer is dropped")
    Test.eq(calls.last, "auction-house-closed")
    calls.restore()
end)

io.write(string.format("Merchant vendor scan: %d test(s) passed\n", Test.count))
