local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

Test.it("uses internal metadata reagents for detail cost estimates without AtlasLoot", function()
    _G.AtlasLoot = nil
    _G.Auctionator = nil
    _G.TSM_API_FOUR = nil
    _G.TSM_API = {
        GetCustomPriceValue = function(_source, itemString)
            if itemString == "i:22790" then
                return 100
            end
            if itemString == "i:22791" then
                return 200
            end
            return nil
        end,
    }
    addon.Market.priceCache = {}

    local detail = data:GetRecipeDetail(-28596)
    Test.eq(#detail.reagents, 2)
    Test.eq(detail.reagents[1].itemID, 22790)
    Test.eq(detail.reagents[1].count, 7)
    Test.eq(detail.reagents[2].itemID, 22791)
    Test.eq(detail.reagents[2].count, 3)
    Test.eq(detail.cost.total, 1300)
    Test.eq(detail.cost.pricedCount, 2)
    Test.eq(detail.cost.missingCount, 0)
    Test.eq(detail.cost.source, "TSM")
end)
