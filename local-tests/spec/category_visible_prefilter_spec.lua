local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

-- A handful of Alchemy recipes that resolve in the committed metadata dataset
-- and span more than one category/subcategory.
local ALCHEMY_RECIPES = { -2329, -2330, -28555, -28587 }
local SIDEBAR_CONTEXT = { selectedProfession = "Alchemy", effectiveProfession = "Alchemy" }

local function seedProfession(memberKey, profession, recipeKeys)
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end

    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = entry.updatedAt or 100
    entry.sourceType = entry.sourceType or "owner"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipes,
        count = #recipeKeys,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = entry.sourceType,
        guildStatus = entry.guildStatus,
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    })
end

local function keySet(rows)
    local set = {}
    for _, row in ipairs(rows or {}) do
        set[tostring(row.key)] = true
    end
    return set
end

Test.it("prunes sidebar categories to those with recipes visible under a restrictive filter", function()
    local selfKey = data:GetPlayerKey()
    seedProfession(selfKey, "Alchemy", ALCHEMY_RECIPES)

    -- Hide vanilla for alchemy: only the TBC seeded recipes (-28555, -28587)
    -- should survive the predicate, so the sidebar must drop every taxonomy
    -- category that those two recipes don't belong to.
    addon.db.profile.recipePrefilters.professionExpansionOverrides.alchemy = {
        inherit = false,
        vanilla = false,
        tbc = true,
    }
    data:InvalidateRecipeListCacheForFilter("alchemy", "visible-category-restrictive-test")

    local full = data:GetRecipeCategories("Alchemy", true)
    Test.truthy(#full > 0, "full taxonomy should expose categories")

    local visible = data:GetVisibleRecipeCategories("Alchemy", SIDEBAR_CONTEXT)
    Test.truthy(#visible > 0, "restrictive filter should still keep at least one category visible")
    Test.truthy(#visible < #full, "restrictive filter should prune at least one taxonomy category")

    -- Every visible category must exist in the taxonomy and actually contain at
    -- least one recipe that passes the same predicate the list uses.
    local fullSet = keySet(full)
    for _, row in ipairs(visible) do
        Test.truthy(fullSet[tostring(row.key)], "visible category must exist in the taxonomy")
        local rows = data:GetRecipeList("Alchemy", "", "alpha", "recipe", row.key, SIDEBAR_CONTEXT)
        Test.truthy(#rows > 0, "a visible category should contain at least one visible recipe")
    end
end)

Test.it("drops every sidebar category when all expansions are hidden for the profession", function()
    local selfKey = data:GetPlayerKey()
    seedProfession(selfKey, "Alchemy", ALCHEMY_RECIPES)

    addon.db.profile.recipePrefilters.professionExpansionOverrides.alchemy = {
        inherit = false,
        vanilla = false,
        tbc = false,
    }
    data:InvalidateRecipeListCacheForFilter("alchemy", "visible-category-all-hidden-test")

    -- The static taxonomy is filter-independent; only the visible projection prunes.
    Test.truthy(#data:GetRecipeCategories("Alchemy", true) > 0, "full taxonomy is unaffected by filters")
    Test.eq(#data:GetVisibleRecipeCategories("Alchemy", SIDEBAR_CONTEXT), 0,
        "hiding both expansions should prune every sidebar category")
end)
