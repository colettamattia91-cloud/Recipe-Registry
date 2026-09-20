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
            local prices = {
                ["i:18256"] = 10,    -- Imbued Vial
                ["i:22790"] = 100,   -- Netherbloom
                ["i:22793"] = 50,    -- Mana Thistle
                ["i:22794"] = 200,   -- Fel Lotus
            }
            return prices[itemString]
        end,
    }
    addon.Market.priceCache = {}

    -- spellId 28587 = Flask of Fortification (4 real reagents from the snapshot).
    local detail = data:GetRecipeDetail(-28587)
    Test.eq(#detail.reagents, 4)
    Test.eq(detail.reagents[1].itemID, 18256)
    Test.eq(detail.reagents[1].count, 1)
    Test.eq(detail.reagents[2].itemID, 22790)
    Test.eq(detail.reagents[2].count, 7)
    Test.eq(detail.reagents[3].itemID, 22793)
    Test.eq(detail.reagents[3].count, 3)
    Test.eq(detail.reagents[4].itemID, 22794)
    Test.eq(detail.reagents[4].count, 1)
    -- 1*10 + 7*100 + 3*50 + 1*200 = 1060
    Test.eq(detail.cost.total, 1060)
    Test.eq(detail.cost.pricedCount, 4)
    Test.eq(detail.cost.missingCount, 0)
    Test.eq(detail.cost.source, "TSM")
end)
