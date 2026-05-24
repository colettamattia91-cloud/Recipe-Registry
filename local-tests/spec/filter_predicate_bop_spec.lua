local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local metadataAddon, wow, addon = Loader.LoadMetadata()
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

Test.it("keeps unknown BoP visible until item info confirms the bind type", function()
    local metadata = metadataAddon.RecipeMetadata
    local record = metadata:GetRecipeInfo(-28543)
    record.bopOutput = nil
    addon.db.profile.recipePrefilters.showRemoteBopOutputRecipes = false
    seedMember("RemoteBop-TestRealm", "Alchemy", -28543, "replica")

    local passes, reason = filters:RecipePasses(-28543)
    Test.eq(passes, true)
    Test.eq(reason, "visible-normal")
    Test.truthy(data._pendingBopItemInfoByItemID and data._pendingBopItemInfoByItemID[22823], "unknown bind should be tracked")

    wow.GetState().items[22823] = { bindType = 1 }
    wow.DeliverEvent(addon, "GET_ITEM_INFO_RECEIVED", 22823)
    wow.AdvanceTime(0.8)
    wow.RunDueTimers()

    passes, reason = filters:RecipePasses(-28543)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-remote-bop")
end)
