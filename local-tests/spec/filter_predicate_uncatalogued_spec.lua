local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local filters = addon.RecipeUiFilters

local UNKNOWN_ITEM_KEY = 999999     -- positive: looks like a stray item-id
local UNKNOWN_SPELL_KEY = -999999   -- negative: scanned from a TradeSkill spell

Test.it("hides uncatalogued item-keyed entries by default (likely garbage)", function()
    local passes, reason = filters:RecipePasses(UNKNOWN_ITEM_KEY)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-uncatalogued")
end)

Test.it("keeps uncatalogued spell-keyed entries visible (legit out-of-scope scan)", function()
    -- A real TradeSkill spell (Mining smelting, First Aid, Fishing) that the
    -- v1 metadata library does not catalogue must stay visible per the
    -- conservative show policy — it's a real recipe, not garbage.
    local passes, reason = filters:RecipePasses(UNKNOWN_SPELL_KEY)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unresolved-conservative")
end)

Test.it("falls back to conservative show for item keys when hideUncataloguedRecipes is disabled", function()
    addon.db.profile.recipePrefilters.hideUncataloguedRecipes = false
    local passes, reason = filters:RecipePasses(UNKNOWN_ITEM_KEY)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unresolved-conservative")
end)
