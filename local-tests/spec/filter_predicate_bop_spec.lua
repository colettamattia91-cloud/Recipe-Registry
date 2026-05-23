local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data
local filters = addon.RecipeUiFilters

local function seedMember(memberKey, profession, recipeKey, sourceType)
    local entry = data:GetOrCreateMember(memberKey)
    entry.guildStatus = "active"
    entry.sourceType = sourceType or "replica"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = entry.professions or {}
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = entry.sourceType,
    })
    data:InvalidateRecipeCaches()
end

Test.it("hides remote-only BoP output recipes by default", function()
    local passes, reason = filters:RecipePasses(-35530)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-remote-bop")
end)

Test.it("shows remote BoP output recipes when the profile option allows it", function()
    addon.db.profile.recipePrefilters.showRemoteBopOutputRecipes = true
    local passes, reason = filters:RecipePasses(-35530)
    Test.eq(passes, true)
    Test.eq(reason, "visible-normal")
end)

Test.it("always shows BoP output recipes known by the current player", function()
    addon.db.profile.recipePrefilters.showRemoteBopOutputRecipes = false
    seedMember(data:GetPlayerKey(), "Leatherworking", -35530, "owner")

    Test.eq(data:IsRecipeKnownByCurrentPlayer(-35530), true)
    local passes, reason = filters:RecipePasses(-35530)
    Test.eq(passes, true)
    Test.eq(reason, "visible-current-player")
end)
