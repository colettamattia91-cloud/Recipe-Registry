local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function getUiFiles()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "UI/MainFrame.lua"
    return files
end

local addon = Loader.Load({ files = getUiFiles() })
Loader.LoadMetadata({ reset = false, loadCore = false })
local data = addon.Data
local ui = addon.UI

local function seedMember(memberKey, profession, recipeKeys)
    local entry = data:GetOrCreateMember(memberKey)
    entry.guildStatus = "active"
    entry.sourceType = "replica"
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
        guildStatus = entry.guildStatus,
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
    })
    data:InvalidateRecipeCaches()
end

local function favoriteRows()
    ui.searchText = ""
    ui.searchMode = "recipe"
    ui.sortMode = "alpha"
    return ui:BuildFavoriteRecipeRows({
        selectedProfession = "Favorites",
        effectiveProfession = nil,
    })
end

Test.it("shows preserved favorites again when their profession filter is unhidden", function()
    seedMember("Reappearfavorite-TestRealm", "Engineering", { -3918 })
    addon.charDB.favorites = {
        ["-3918"] = true,
    }

    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true
    addon.db.profile.recipePrefilters.professionExpansionOverrides.engineering = {
        inherit = false,
        vanilla = false,
        tbc = true,
    }

    local hiddenRows = favoriteRows()
    Test.eq(#hiddenRows, 0)
    Test.eq(addon.charDB.favorites["-3918"], true, "hidden favorite should remain saved")

    addon.db.profile.recipePrefilters.professionExpansionOverrides.engineering = {
        inherit = true,
    }
    addon.RecipeUiFilters:InvalidateProfessionProjection("engineering", "test-favorite-unhide")

    local visibleRows = favoriteRows()
    Test.eq(#visibleRows, 1)
    Test.eq(visibleRows[1].recipeKey, -3918)
    Test.eq(addon.charDB.favorites["-3918"], true)
end)

