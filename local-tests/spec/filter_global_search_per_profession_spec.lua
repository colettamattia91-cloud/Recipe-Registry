local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

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

Test.it("applies global search filters using each recipe's own profession", function()
    seedMember("Searchalchemy-TestRealm", "Alchemy", { -2329 })
    seedMember("Searchengineering-TestRealm", "Engineering", { -3918 })

    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true
    addon.db.profile.recipePrefilters.professionExpansionOverrides.engineering = {
        inherit = false,
        vanilla = false,
        tbc = true,
    }

    local original = data.GetRecipeDisplayInfo
    local calls = {}
    data.GetRecipeDisplayInfo = function(self, recipeKey)
        calls[tostring(recipeKey)] = (calls[tostring(recipeKey)] or 0) + 1
        return original(self, recipeKey)
    end

    local rows = data:GetRecipeList(nil, "Spell", "alpha", "recipe", nil, {
        globalSearch = true,
        selectedProfession = nil,
        effectiveProfession = "Engineering",
    })
    data.GetRecipeDisplayInfo = original

    Test.eq(#rows, 1)
    Test.eq(rows[1].recipeKey, -2329)
    Test.eq(calls["-2329"], 1, "visible Alchemy recipe should build detail")
    Test.eq(calls["-3918"], nil, "hidden Engineering recipe should not build detail")
end)

