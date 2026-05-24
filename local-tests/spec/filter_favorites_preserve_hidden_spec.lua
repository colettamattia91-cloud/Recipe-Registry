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

Test.it("filters hidden favorites without deleting saved favorite state", function()
    seedMember("Favoritealchemy-TestRealm", "Alchemy", { -2329 })
    seedMember("Favoriteengineering-TestRealm", "Engineering", { -3918 })
    addon.charDB.favorites = {
        ["-2329"] = true,
        ["-3918"] = true,
    }

    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true
    addon.db.profile.recipePrefilters.professionExpansionOverrides.engineering = {
        inherit = false,
        vanilla = false,
        tbc = true,
    }

    ui.searchText = ""
    ui.searchMode = "recipe"
    ui.sortMode = "alpha"

    local original = data.GetRecipeDisplayInfo
    local calls = {}
    data.GetRecipeDisplayInfo = function(self, recipeKey)
        calls[tostring(recipeKey)] = (calls[tostring(recipeKey)] or 0) + 1
        return original(self, recipeKey)
    end

    local rows = ui:BuildFavoriteRecipeRows({
        selectedProfession = "Favorites",
        effectiveProfession = nil,
    })
    data.GetRecipeDisplayInfo = original

    Test.eq(#rows, 1)
    Test.eq(rows[1].recipeKey, -2329)
    Test.eq(addon.charDB.favorites["-2329"], true)
    Test.eq(addon.charDB.favorites["-3918"], true, "hidden favorite should remain saved")
    Test.eq(calls["-2329"], 1, "visible favorite should build detail")
    Test.eq(calls["-3918"], nil, "hidden favorite should not build detail")
end)

