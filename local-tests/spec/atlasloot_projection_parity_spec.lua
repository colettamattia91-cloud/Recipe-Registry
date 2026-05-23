local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function seedMember(data)
    local entry = data:GetOrCreateMember("Parity-TestRealm")
    entry.owner = "Parity-TestRealm"
    entry.guildStatus = "active"
    entry.sourceType = "replica"
    entry.updatedAt = 100
    entry.lastSeenInGuildAt = 100
    entry.professions = entry.professions or {}
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = {
            [-28596] = true,
            [22900] = true,
        },
        count = 2,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = 100,
    })
    data:InvalidateRecipeCaches()
end

local function installContradictingAtlasStub()
    _G.AtlasLoot = {
        Data = {
            Recipe = {},
            Profession = {
                GetCraftSpellForRecipe = function()
                    return 999001
                end,
                GetCraftSpellForCreatedItem = function()
                    return 999002
                end,
                GetProfessionData = function()
                    return {
                        999999,
                        99,
                        1,
                        1,
                        1,
                        { 123456 },
                        { 77 },
                        1,
                    }
                end,
                GetProfessionName = function()
                    return "Wrong Profession"
                end,
            },
        },
    }
end

local function captureProjection(withAtlas)
    local _metadataAddon, _wow, addon = Loader.LoadMetadata()
    if withAtlas then
        installContradictingAtlasStub()
    end

    local data = addon.Data
    seedMember(data)

    local categories = data:GetRecipeCategories("Alchemy", true)
    local rows = data:GetRecipeList("Alchemy", "", "alpha", "materials", nil, {})
    local detail = data:GetRecipeDisplayInfo(-28596)

    local reagentParts = {}
    for _, reagent in ipairs(detail.reagents or {}) do
        reagentParts[#reagentParts + 1] = tostring(reagent.itemID) .. ":" .. tostring(reagent.count)
    end
    table.sort(reagentParts)

    local rowKeys = {}
    for _, row in ipairs(rows or {}) do
        rowKeys[#rowKeys + 1] = tostring(row.recipeKey) .. ":" .. tostring(row.label)
    end
    table.sort(rowKeys)

    return table.concat({
        table.concat(categories or {}, ","),
        table.concat(rowKeys, ","),
        tostring(detail.spellID),
        tostring(detail.createdItemID),
        tostring(detail.recipeItemID),
        tostring(detail.professionName),
        tostring(detail.minRank),
        table.concat(reagentParts, ","),
    }, "|")
end

Test.it("keeps projection output identical with AtlasLoot installed or absent", function()
    local withoutAtlas = captureProjection(false)
    local withAtlas = captureProjection(true)
    Test.eq(withAtlas, withoutAtlas)
end)

