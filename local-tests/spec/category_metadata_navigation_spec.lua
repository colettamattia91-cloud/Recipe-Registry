local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

local PROFESSION_RECIPES = {
    Alchemy = { -2329, -28596 },
    Blacksmithing = { -2660 },
    Cooking = { -2538 },
    Enchanting = { -27924 },
    Engineering = { -3918, -30303 },
    Jewelcrafting = { -25255 },
    Leatherworking = { -35530 },
    Tailoring = { -26745, -26746 },
}

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

local function containsRecipe(rows, wantedKey)
    local wanted = tostring(wantedKey)
    for _, row in ipairs(rows or {}) do
        if tostring(row.recipeKey) == wanted then
            return true
        end
    end
    return false
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function assertCategoryCoverage(profession)
    local allRows = data:GetRecipeList(profession, "", "alpha", "recipe", "All", {})
    local allSet = {}
    for _, row in ipairs(allRows) do
        allSet[tostring(row.recipeKey)] = true
    end

    local union = {}
    local summedRows = 0
    for _, categoryName in ipairs(data:GetRecipeCategories(profession, true)) do
        local rows = data:GetRecipeList(profession, "", "alpha", "recipe", categoryName, {})
        summedRows = summedRows + #rows
        for _, row in ipairs(rows) do
            local key = tostring(row.recipeKey)
            Test.falsy(union[key], "recipe should not appear in more than one metadata category")
            union[key] = true
        end
    end

    Test.eq(summedRows, #allRows, profession .. " category row sum should match All")
    Test.eq(countKeys(union), #allRows, profession .. " category union should match All")
    for key in pairs(allSet) do
        Test.truthy(union[key], profession .. " recipe should be covered by metadata categories")
    end
end

Test.it("navigates categories from RecipeRegistry_Metadata with AtlasLoot absent", function()
    _G.AtlasLoot = nil
    local selfKey = data:GetPlayerKey()
    for profession, recipeKeys in pairs(PROFESSION_RECIPES) do
        seedProfession(selfKey, profession, recipeKeys)
    end
    data:InvalidateRecipeCaches("category-metadata-test")

    for profession, recipeKeys in pairs(PROFESSION_RECIPES) do
        local categories = data:GetRecipeCategories(profession, true)
        Test.truthy(#categories > 0, profession .. " should expose metadata categories")
        for _, recipeKey in ipairs(recipeKeys) do
            local categoryName = data:GetRecipeCategory(recipeKey, profession)
            Test.truthy(categoryName, profession .. " recipe should resolve a metadata category")
            local rows = data:GetRecipeList(profession, "", "alpha", "recipe", categoryName, {})
            Test.truthy(containsRecipe(rows, recipeKey), profession .. " category should contain the recipe")
        end
        assertCategoryCoverage(profession)
    end
end)

Test.it("does not call the AtlasLoot category index while metadata is installed", function()
    local selfKey = data:GetPlayerKey()
    seedProfession(selfKey, "Alchemy", { -2329, -28596 })
    data:InvalidateRecipeCaches("category-atlas-block-test")

    data.GetAtlasLootCategoryIndex = function()
        error("AtlasLoot category index must not be used by metadata-backed category navigation")
    end
    data.BuildAtlasLootCategoryIndex = function()
        error("AtlasLoot category builder must not be used by metadata-backed category navigation")
    end
    _G.AtlasLoot = {
        ItemDB = {
            Get = function()
                error("AtlasLoot ItemDB must not be consulted by metadata-backed category navigation")
            end,
        },
    }

    Test.eq(data:GetRecipeCategory(-28596, "Alchemy"), "flasks")
    Test.truthy(#data:GetRecipeCategories("Alchemy", true) > 0)
    Test.eq(#data:GetRecipeList("Alchemy", "", "alpha", "recipe", "flasks", {}), 1)
end)
