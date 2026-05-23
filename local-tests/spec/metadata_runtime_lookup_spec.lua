local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local addon = Loader.LoadMetadata()
local metadata = addon.RecipeMetadata

Test.it("exposes the Phase 1 public identity fields", function()
    Test.eq(addon.ADDON_VERSION, "0.1.0")
    Test.eq(metadata.metadataVersion, "2026.05.23.2")
    Test.eq(metadata.schemaVersion, 1)
    Test.eq(metadata.flavor, "tbc")
end)

Test.it("resolves one recipe through spell, recipe item, and created item keys", function()
    local bySpell = metadata:GetRecipeInfo(-28596)
    local byRecipeItem = metadata:GetRecipeInfo(22900)
    local byCreatedItem = metadata:GetRecipeInfo(22845)

    Test.eq(bySpell.spellId, 28596)
    Test.eq(byRecipeItem.spellId, 28596)
    Test.eq(byCreatedItem.spellId, 28596)
    Test.eq(metadata:GetRecipeExpansion(-28596, bySpell), "tbc")
    Test.eq(metadata:GetProfession(-28596, bySpell), "alchemy")

    local category = metadata:GetCategory(-28596, bySpell)
    Test.eq(category.category, "flasks")
    Test.eq(category.subcategory, "guardian_elixirs")
    Test.eq(category.sortOrder, 120)
    Test.eq(metadata:GetCreatedItemId(-28596, bySpell), 22845)
    Test.eq(metadata:GetRecipeItemId(-28596, bySpell), 22900)
    Test.eq(metadata:GetMetadataResolutionStatus(-28596, bySpell), "resolved")
end)

Test.it("returns cloned reagent data for normal crafts", function()
    local reagents = metadata:GetReagents(-28596)
    Test.eq(#reagents, 2)
    Test.eq(reagents[1].itemId, 22790)
    Test.eq(reagents[1].count, 7)

    reagents[1].count = 99
    local fresh = metadata:GetReagents(-28596)
    Test.eq(fresh[1].count, 7)
end)

Test.it("reports outputless and BoP metadata without requiring Recipe Registry integration", function()
    local outputless = metadata:GetRecipeInfo(-27924)
    Test.eq(outputless.spellId, 27924)
    Test.eq(metadata:GetCreatedItemId(-27924, outputless), nil)
    Test.eq(metadata:IsOutputlessSelfOnly(-27924, outputless), true)
    Test.eq(metadata:GetMetadataResolutionStatus(-27924, outputless), "resolved")

    Test.eq(metadata:IsBopOutput(-35530), true)
    Test.eq(metadata:IsBopOutput(-28596), false)
end)
