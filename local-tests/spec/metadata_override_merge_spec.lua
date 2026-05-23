local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local addon = Loader.LoadMetadata()
local metadata = addon.RecipeMetadata
local overrides = metadata._overrides

Test.it("lets runtime overrides beat generated recipe fields", function()
    overrides.expansionBySpellId[28596] = "vanilla"
    overrides.createdItemBySpellId[28596] = 99901
    overrides.recipeItemBySpellId[28596] = 99902
    overrides.categoryBySpellId[28596] = {
        category = "override_category",
        subcategory = "override_subcategory",
        sortOrder = 42,
    }
    overrides.selfOnlyOutputlessBySpellId[28596] = true
    overrides.bopOutputBySpellId[28596] = true

    metadata:_Rebuild()

    local info = metadata:GetRecipeInfo(-28596)
    Test.eq(info.spellId, 28596)
    Test.eq(metadata:GetRecipeExpansion(-28596, info), "vanilla")
    Test.eq(metadata:GetCreatedItemId(-28596, info), 99901)
    Test.eq(metadata:GetRecipeItemId(-28596, info), 99902)
    Test.eq(metadata:IsOutputlessSelfOnly(-28596, info), true)
    Test.eq(metadata:IsBopOutput(-28596, info), true)

    local category = metadata:GetCategory(-28596, info)
    Test.eq(category.category, "override_category")
    Test.eq(category.subcategory, "override_subcategory")
    Test.eq(category.sortOrder, 42)
end)

Test.it("rebuilds recipe-item and created-item indexes from overrides", function()
    local byRecipeItem = metadata:NormalizeRecipeKey(99902)
    Test.eq(byRecipeItem.source, "recipeItem")
    Test.eq(byRecipeItem.spellId, 28596)
    Test.eq(byRecipeItem.createdItemId, 99901)

    local byCreatedItem = metadata:NormalizeRecipeKey(99901)
    Test.eq(byCreatedItem.source, "createdItem")
    Test.eq(byCreatedItem.spellId, 28596)
    Test.eq(byCreatedItem.recipeItemId, 99902)
end)

Test.it("uses created-item bind-type overrides when no spell override exists", function()
    overrides.bindTypeByCreatedItemId[22823] = 1
    metadata:_Rebuild()
    Test.eq(metadata:IsBopOutput(-28543), true)

    overrides.bindTypeByCreatedItemId[22823] = 2
    metadata:_Rebuild()
    Test.eq(metadata:IsBopOutput(-28543), false)
    Test.eq(metadata:GetMetadataResolutionStatus(-28543), "resolved")
end)

Test.it("reports runtime override volume for diagnostics", function()
    local counts = metadata:GetRecordCounts()
    Test.gte(counts.overrides, 7)
    Test.eq(counts.recipes, 14)
end)
