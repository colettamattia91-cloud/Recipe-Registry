local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local filters = addon.RecipeUiFilters

local UNKNOWN_RECIPE_KEY = -999999

Test.it("hides recipes that the metadata library does not catalogue by default", function()
    local passes, reason = filters:RecipePasses(UNKNOWN_RECIPE_KEY)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-uncatalogued")
end)

Test.it("falls back to conservative show when hideUncataloguedRecipes is disabled", function()
    addon.db.profile.recipePrefilters.hideUncataloguedRecipes = false
    local passes, reason = filters:RecipePasses(UNKNOWN_RECIPE_KEY)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unresolved-conservative")
end)
