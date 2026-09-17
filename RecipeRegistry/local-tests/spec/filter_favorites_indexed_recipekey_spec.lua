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

Test.it("keeps the numeric recipe key when favorites build from the cached index, so the selected favorite still resolves crafters", function()
    seedMember("Indexedfavorite-TestRealm", "Alchemy", { -2329 })
    addon.charDB.favorites = {
        ["-2329"] = true,
    }

    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true

    -- Force the recipe index to build *before* the favorites row build so
    -- BuildFavoriteRecipeRows takes the `data._recipeIndex` branch instead
    -- of the GetMembersDB() fallback. That indexed branch is the one that
    -- regressed: it carried the stringified favorites key straight through
    -- as row.recipeKey instead of the numeric key the index itself uses.
    data:GetRecipeIndex()

    ui.searchText = ""
    ui.searchMode = "recipe"
    ui.sortMode = "alpha"

    local rows = ui:BuildFavoriteRecipeRows({
        selectedProfession = "Favorites",
        effectiveProfession = nil,
    })

    Test.eq(#rows, 1)
    Test.eq(rows[1].recipeKey, -2329)
    Test.eq(type(rows[1].recipeKey), "number", "row.recipeKey must match the numeric type the recipe index is keyed by")

    -- Simulate selecting the row: the detail panel looks crafters up by
    -- whatever type row.recipeKey carries. A stringified key silently
    -- misses the numerically-keyed index and reports zero crafters even
    -- though the roster has one.
    local crafters = data:GetRecipeCrafters(rows[1].recipeKey)
    Test.eq(#crafters, 1, "selecting the favorite row must resolve its known crafter")
    Test.eq(crafters[1].memberKey, "Indexedfavorite-TestRealm")
end)
