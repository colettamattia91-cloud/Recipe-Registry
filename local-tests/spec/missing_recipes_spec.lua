-- The Missing recipes view: what the CURRENT character can still learn.
-- Answers a different question from the rest of the addon, so it gets its
-- own projection rather than reusing the guild recipe list.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

-- spell 36391 = a TBC blacksmithing plan requiring skill 375.
local PLAN = -36391

local function setLocalProfession(professionName, opts)
    opts = opts or {}
    local playerKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(playerKey)
    entry.guildStatus = "active"
    entry.sourceType = "owner"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = entry.professions or {}
    entry.professions[professionName] = data:NormalizeProfessionBlock(entry, professionName, {
        recipes = opts.recipes or {},
        skillRank = opts.skillRank or 375,
        skillMaxRank = 375,
        specialization = opts.specialization,
        sourceType = "owner",
    })
    data:InvalidateRecipeCaches()
end

local function clearLocalProfessions()
    local entry = data:GetOrCreateMember(data:GetPlayerKey())
    entry.professions = {}
    data:InvalidateRecipeCaches()
end

local function findRow(rows, recipeKey)
    for _, row in ipairs(rows) do
        if row.recipeKey == recipeKey then return row end
    end
    return nil
end

io.write("Missing recipes\n")

Test.it("reports nothing until the character has a scanned profession", function()
    clearLocalProfessions()
    Test.eq(#data:BuildMissingRecipeRows(), 0)
end)

Test.it("lists a catalogued recipe the character has not learned", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local rows = data:BuildMissingRecipeRows()
    Test.gte(#rows, 1)
    local row = findRow(rows, PLAN)
    Test.truthy(row ~= nil, "expected the unlearned plan to be listed")
    Test.eq(row.missing.professionName, "Blacksmithing")
    Test.eq(row.crafterCount, 0)
end)

Test.it("drops a recipe once the character knows it", function()
    setLocalProfession("Blacksmithing", { skillRank = 375, recipes = { [PLAN] = true } })

    Test.eq(data:IsRecipeKnownByCurrentPlayer(PLAN), true)
    Test.eq(findRow(data:BuildMissingRecipeRows(), PLAN), nil)
end)

Test.it("flags a recipe the skill rank cannot reach yet", function()
    setLocalProfession("Blacksmithing", { skillRank = 1 })

    local row = findRow(data:BuildMissingRecipeRows(), PLAN)
    Test.truthy(row ~= nil)
    Test.truthy(row.missing.requiredSkill ~= nil, "the plan should carry a required skill")
    Test.eq(row.missing.skillMet, false)
    Test.eq(row.missing.skillRank, 1)
end)

Test.it("reports how the recipe is taught", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local rows = data:BuildMissingRecipeRows()
    local trainer, item = 0, 0
    for _, row in ipairs(rows) do
        if row.missing.sourceKind == "trainer" then trainer = trainer + 1 end
        if row.missing.sourceKind == "item" then item = item + 1 end
    end
    -- Blacksmithing has both kinds; a proxy that collapsed to one value
    -- would be useless.
    Test.gte(trainer, 1)
    Test.gte(item, 1)
end)

Test.it("marks a specialization the character does not have", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local gated
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        if row.missing.specializationSpellId then
            gated = row
            break
        end
    end
    Test.truthy(gated ~= nil, "expected at least one specialization-gated blacksmithing recipe")
    Test.eq(gated.missing.specializationMet, false)
    Test.truthy(gated.missing.specializationName ~= nil, "the requirement should resolve to a display name")
end)

Test.it("clears the specialization flag once the character has it", function()
    setLocalProfession("Blacksmithing", { skillRank = 375, specialization = "Armorsmith" })

    local armorsmithId = data:GetSpecializationSpellId("Blacksmithing", "Armorsmith")
    Test.eq(armorsmithId, 9788)

    local met, unmet = 0, 0
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        if row.missing.specializationSpellId == armorsmithId then
            if row.missing.specializationMet then met = met + 1 else unmet = unmet + 1 end
        end
    end
    Test.gte(met, 1)
    Test.eq(unmet, 0)
end)

Test.it("honours the per-profession opt-out", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })
    Test.gte(#data:BuildMissingRecipeRows(), 1)

    data:SetMissingRecipesEnabledForProfession("Blacksmithing", false)
    Test.eq(data:IsMissingRecipesEnabledForProfession("Blacksmithing"), false)
    Test.eq(#data:BuildMissingRecipeRows(), 0)

    data:SetMissingRecipesEnabledForProfession("Blacksmithing", true)
    Test.gte(#data:BuildMissingRecipeRows(), 1)
end)

Test.it("puts what can be learned right now first", function()
    setLocalProfession("Blacksmithing", { skillRank = 300 })

    local rows = data:BuildMissingRecipeRows()
    Test.gte(#rows, 2)
    local seenBlocked = false
    for _, row in ipairs(rows) do
        local ready = row.missing.skillMet and row.missing.specializationMet
        if not ready then
            seenBlocked = true
        elseif seenBlocked then
            Test.truthy(false, "a learnable recipe appeared after a blocked one")
        end
    end
end)

Test.it("respects the expansion prefilter", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })
    local prefilters = addon.db.profile.recipePrefilters
    prefilters.expansionDefaults.vanilla = true
    prefilters.expansionDefaults.tbc = true
    addon.RecipeUiFilters:InvalidateProfessionProjection("blacksmithing", "spec")
    local both = #data:BuildMissingRecipeRows()

    prefilters.expansionDefaults.vanilla = false
    addon.RecipeUiFilters:InvalidateProfessionProjection("blacksmithing", "spec")
    local tbcOnly = #data:BuildMissingRecipeRows()

    Test.truthy(tbcOnly < both, "hiding Vanilla should shorten the missing list")
end)

-- Guards the fix for the freeze this view first shipped with: resolving a
-- name, icon and quality per candidate costs two GetItemInfo calls and a
-- slot in a 256-entry cache, and a two-profession character has more than
-- 600 candidates. Only the rows actually painted may be resolved.
Test.it("builds rows without resolving names or icons", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local rows = data:BuildMissingRecipeRows()
    Test.gte(#rows, 100)
    for _, row in ipairs(rows) do
        Test.eq(row.detail, nil)
        Test.eq(row.label, nil)
    end
end)

Test.it("resolves a row on demand, once", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local row = data:BuildMissingRecipeRows()[1]
    data:ResolveMissingRow(row)
    Test.truthy(row.label ~= nil, "resolving should give the row a label")
    Test.eq(row._missingResolved, true)

    -- A second call is a no-op: the renderer rebinds the same row on every
    -- scroll tick.
    local label = row.label
    row.detail = "sentinel"
    data:ResolveMissingRow(row)
    Test.eq(row.detail, "sentinel")
    Test.eq(row.label, label)
end)

Test.it("keeps a stable order between rebuilds", function()
    setLocalProfession("Blacksmithing", { skillRank = 300 })

    local first = data:BuildMissingRecipeRows()
    local second = data:BuildMissingRecipeRows()
    Test.eq(#first, #second)
    for index = 1, #first do
        Test.eq(first[index].recipeKey, second[index].recipeKey)
    end
end)

io.write(string.format("Missing recipes: %d test(s) passed\n", Test.count))
