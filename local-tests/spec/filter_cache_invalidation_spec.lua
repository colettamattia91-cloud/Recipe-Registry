local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data
local filters = addon.RecipeUiFilters

local function seedMember(memberKey, profession, recipeKeys, sourceType)
    local entry = data:GetOrCreateMember(memberKey)
    entry.guildStatus = "active"
    entry.sourceType = sourceType or "replica"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = entry.professions or {}
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys) do
        recipes[recipeKey] = true
    end
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipes,
        count = #recipeKeys,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = entry.sourceType,
    })
    data:InvalidateRecipeCaches()
end

Test.it("extends recipe list cache keys with filter state", function()
    seedMember("Filtercache-TestRealm", "Alchemy", { -2329, -28596 })

    local defaults = addon.db.profile.recipePrefilters.expansionDefaults
    defaults.vanilla = true
    defaults.tbc = true
    local allRows = data:GetRecipeList("Alchemy", "", "alpha", "recipe", nil, {})

    defaults.vanilla = false
    local filteredRows = data:GetRecipeList("Alchemy", "", "alpha", "recipe", nil, {})

    Test.eq(#allRows, 2)
    Test.eq(#filteredRows, 1)
    Test.eq(filteredRows[1].recipeKey, -28596)
    Test.gte(Test.countKeys(data._recipeListCache), 2)
end)

Test.it("invalidates only projection caches when filter settings change", function()
    data._recipeListCache = { sentinel = true }
    data._recipeListCacheOrder = { "sentinel" }
    local beforeGeneration = data._recipeListCacheGeneration or 0

    filters:InvalidateProfessionProjection("alchemy", "test-filter-change")

    Test.eq(data._recipeListCache, nil)
    Test.eq(data._recipeListCacheOrder, nil)
    Test.gte(data._recipeListCacheGeneration or 0, beforeGeneration + 1)
    Test.eq(addon.Performance.pendingUIRefreshScopes["test-filter-change"], true)
end)

Test.it("leaves sync fingerprints unchanged across filter-only changes", function()
    seedMember(data:GetPlayerKey(), "Alchemy", { -2329, -28596 }, "owner")
    local before = data:BuildLocalSummary({ reason = "filter-before" }).globalFingerprint

    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = false
    filters:InvalidateProfessionProjection("alchemy", "filter-fingerprint-smoke")

    local after = data:BuildLocalSummary({ reason = "filter-after" }).globalFingerprint
    Test.eq(after, before)
end)
