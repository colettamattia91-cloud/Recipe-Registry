local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local addon = Loader.Load()
local data = addon.Data
local filters = addon.RecipeUiFilters

local function seedMember(memberKey, profession, recipeKey)
    local entry = data:GetOrCreateMember(memberKey)
    entry.guildStatus = "active"
    entry.sourceType = "replica"
    entry.updatedAt = 100
    entry.lastSeenInGuildAt = 100
    entry.professions = entry.professions or {}
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = "replica",
    })
    data:InvalidateRecipeCaches()
end

Test.it("returns visible-no-plugin when metadata addon is absent", function()
    Test.eq(_G.RecipeRegistry_Metadata, nil)
    local passes, reason = filters:RecipePasses(-35530)
    Test.eq(passes, true)
    Test.eq(reason, "visible-no-plugin")
end)

Test.it("includes a plugin-absence discriminator in cache keys", function()
    local key = filters:BuildFilterCacheKey({})
    Test.truthy(key:find("plugin=absent", 1, true), "cache key should record plugin absence")
end)

Test.it("keeps list projection visible when the plugin is absent", function()
    seedMember("Absentplugin-TestRealm", "Leatherworking", -35530)
    addon.db.profile.recipePrefilters.showRemoteBopOutputRecipes = false

    local rows = data:GetRecipeList("Leatherworking", "", "alpha", "recipe", nil, {})

    Test.eq(#rows, 1)
    Test.eq(rows[1].recipeKey, -35530)
    Test.eq(rows[1].visibilityReason, "visible-no-plugin")
end)
