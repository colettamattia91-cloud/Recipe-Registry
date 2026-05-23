local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data
local filters = addon.RecipeUiFilters

local function seedCurrentPlayer(recipeKey)
    local entry = data:GetOrCreateMember(data:GetPlayerKey())
    entry.guildStatus = "active"
    entry.sourceType = "owner"
    entry.updatedAt = 100
    entry.lastSeenInGuildAt = 100
    entry.professions = entry.professions or {}
    entry.professions.Enchanting = data:NormalizeProfessionBlock(entry, "Enchanting", {
        recipes = { [recipeKey] = true },
        count = 1,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = "owner",
    })
    data:InvalidateRecipeCaches()
end

Test.it("hides outputless self-only recipes for remote-only visibility by default", function()
    local passes, reason = filters:RecipePasses(-27924)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-outputless-self-only")
end)

Test.it("shows outputless self-only recipes known by the current player", function()
    seedCurrentPlayer(-27924)
    local passes, reason = filters:RecipePasses(-27924)
    Test.eq(data:IsRecipeKnownByCurrentPlayer(-27924), true)
    Test.eq(passes, true)
    Test.eq(reason, "visible-current-player")
end)

Test.it("can show remote outputless self-only recipes when remote restricted recipes are enabled", function()
    data:InvalidateRecipeOwnershipIndex("reset-test")
    data._recipeOwnershipIndex = { byRecipeKey = {}, generation = data._recipeOwnershipIndexGeneration or 0 }
    addon.db.profile.recipePrefilters.showRemoteBopOutputRecipes = true

    local passes, reason = filters:RecipePasses(-27924)
    Test.eq(passes, true)
    Test.eq(reason, "visible-normal")
end)
