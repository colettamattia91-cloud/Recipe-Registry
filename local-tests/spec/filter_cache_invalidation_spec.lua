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
    data._recipeListCache = {
        ["Alchemy\t\talpha\trecipe\t\told"] = true,
        ["Blacksmithing\t\talpha\trecipe\t\told"] = true,
    }
    data._recipeListCacheOrder = {
        "Alchemy\t\talpha\trecipe\t\told",
        "Blacksmithing\t\talpha\trecipe\t\told",
    }
    data._recipeIndex = { sentinel = true }

    filters:InvalidateProfessionProjection("alchemy", "test-filter-change")

    Test.eq(data._recipeListCache["Alchemy\t\talpha\trecipe\t\told"], nil)
    Test.eq(data._recipeListCache["Blacksmithing\t\talpha\trecipe\t\told"], true)
    Test.truthy(data._recipeIndex.sentinel, "filter invalidation must not drop the content index")
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

Test.it("keeps profession cache keys scoped to the active profession", function()
    local ctx = { selectedProfession = "Alchemy", effectiveProfession = "Alchemy" }
    local before = filters:BuildFilterCacheKey(ctx)

    addon.db.profile.recipePrefilters.professionExpansionOverrides.engineering = {
        inherit = false,
        vanilla = false,
        tbc = true,
    }

    local after = filters:BuildFilterCacheKey(ctx)
    Test.eq(after, before)
end)

Test.it("preserves unrelated profession list caches on scoped override changes", function()
    seedMember("ScopedCache-Alchemy", "Alchemy", { -2329, -28596 })
    seedMember("ScopedCache-Engineering", "Engineering", { -3918, -30303 })

    local alchemyCtx = { selectedProfession = "Alchemy", effectiveProfession = "Alchemy" }
    local engineeringCtx = { selectedProfession = "Engineering", effectiveProfession = "Engineering" }
    data:GetRecipeList("Alchemy", "", "alpha", "recipe", nil, alchemyCtx)
    data:GetRecipeList("Engineering", "", "alpha", "recipe", nil, engineeringCtx)

    local alchemyCacheKey
    local engineeringCacheKey
    for key in pairs(data._recipeListCache or {}) do
        local text = tostring(key)
        if text:sub(1, 8) == "Alchemy\t" then
            alchemyCacheKey = key
        elseif text:sub(1, 12) == "Engineering\t" then
            engineeringCacheKey = key
        end
    end

    Test.truthy(alchemyCacheKey, "alchemy cache should exist before scoped invalidation")
    Test.truthy(engineeringCacheKey, "engineering cache should exist before scoped invalidation")

    filters:InvalidateProfessionProjection("engineering", "filters:engineering")

    Test.truthy(data._recipeListCache[alchemyCacheKey], "alchemy cache should be preserved")
    Test.eq(data._recipeListCache[engineeringCacheKey], nil)
end)
