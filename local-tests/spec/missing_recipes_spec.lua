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
    local counts, distinct = {}, 0
    for _, row in ipairs(rows) do
        local kind = row.missing.sourceKind
        Test.truthy(kind ~= nil, "every row should say where the recipe comes from")
        if not counts[kind] then distinct = distinct + 1 end
        counts[kind] = (counts[kind] or 0) + 1
    end

    -- Blacksmithing spans several kinds; a projection that collapsed to one
    -- value would be useless.
    Test.gte(distinct, 3)
    Test.gte(counts.trainer or 0, 1)
    Test.gte(counts.vendor or 0, 1)

    -- "Recipe item" is the fallback for a recipe whose source is unknown.
    -- Nothing in the dataset should reach it any more: a row landing there
    -- means the metadata lost its source, not that the recipe has none.
    Test.eq(counts.item, nil)
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


-- Recipes that are in the client data but not in the game. There is nowhere
-- to go and learn one, so offering it is not an opportunity: it is a player
-- looking for a trainer who does not exist.
-- 9942 = Mithril Scale Gloves, a vanilla blacksmithing plan requiring skill
-- 220, flagged removed by the generator.
local REMOVED = -9942

Test.it("never offers a recipe that is not in the game", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local meta = addon.RecipeMetadata
    Test.eq(meta:IsRemoved(REMOVED), true)

    local rows = data:BuildMissingRecipeRows()
    Test.eq(findRow(rows, REMOVED), nil)
end)

Test.it("still offers a recipe of the same skill that is in the game", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    -- Guards the exclusion against being a blanket one: the removed flag has
    -- to be what removed the row, not the skill or the expansion.
    local rows = data:BuildMissingRecipeRows()
    Test.truthy(#rows > 0, "some vanilla plans should still be offered")

    local anyRemoved = false
    for _, row in ipairs(rows) do
        if addon.RecipeMetadata:IsRemoved(row.recipeKey) then anyRemoved = true end
    end
    Test.eq(anyRemoved, false)
end)

Test.it("reads an absent flag as present in the game, not as unknown", function()
    Test.eq(addon.RecipeMetadata:IsRemoved(PLAN), false)
    -- A recipe the metadata knows nothing about is not claimed to be removed.
    Test.eq(addon.RecipeMetadata:IsRemoved(-999999999), false)
end)

-- The metadata says where a recipe comes from; the recipe-item proxy is only
-- a guess for when it does not. Checking the proxy first, as this view used
-- to, meant the guess beat the data for every recipe with no pattern -- and
-- an alchemy discovery has none, so all seventeen were reported as taught by
-- a trainer who does not teach them.
-- 28580 = an alchemy discovery: no pattern to buy, learned at the cauldron.
local DISCOVERY = -28580

Test.it("lets the recorded source beat the recipe-item guess", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    local info = addon.RecipeMetadata:GetRecipeInfo(DISCOVERY, "alchemy")
    Test.eq(info.recipeItemId, nil)
    Test.eq(addon.RecipeMetadata:GetSource(DISCOVERY, info).kind, "discovery")

    local row = findRow(data:BuildMissingRecipeRows(), DISCOVERY)
    Test.truthy(row ~= nil, "expected the discovery to be listed")
    Test.eq(row.missing.sourceKind, "discovery")
    Test.eq(row.missing.sourceLabel, "Discovery")
end)

Test.it("still guesses from the pattern when nothing is recorded", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    -- A recipe the metadata cannot place falls back to the old proxy rather
    -- than showing nothing: no pattern reads as trainer-taught.
    local kinds = {}
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        kinds[row.missing.sourceKind] = true
    end
    Test.truthy(kinds.trainer, "trainer-taught recipes should still be reported")
    Test.eq(kinds.item, nil)
end)

-- Most trainer-taught recipes name nobody on purpose, but the specialization
-- trainers are named, and there the name is the whole answer: your own city
-- trainer will not teach you a Gnomish schematic.
Test.it("names the trainer when the source knows one", function()
    setLocalProfession("Engineering", { skillRank = 375 })

    local named
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        if row.missing.sourceKind == "trainer" and row.missing.sourceLabel ~= "Trainer" then
            named = row.missing.sourceLabel
            break
        end
    end
    Test.truthy(named ~= nil, "a specialization trainer should be named, not just placed")
    -- Name first, place in brackets: the name is what you act on.
    Test.truthy(named:find("Trainer: ") == 1, "the label should lead with the kind")
    Test.truthy(named:find("%(") ~= nil, "the zone should follow the name in brackets")
end)

Test.it("keeps the bare label for a recipe every trainer teaches", function()
    setLocalProfession("Engineering", { skillRank = 375 })

    local bare = 0
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        if row.missing.sourceLabel == "Trainer" then bare = bare + 1 end
    end
    -- Naming three of the thirty-two trainers who teach a recipe is worse
    -- than naming none, so those rows stay unadorned.
    Test.gte(bare, 1)
end)

-- Two independent lists could not say which vendor stands in which city:
-- "Xandar Goodbeard, Hagrus, Defias Profiteer (Loch Modan, Orgrimmar,
-- Westfall)" leaves the reader to guess the pairing. Vendor stock is often
-- limited, so the alternatives have to be listed rather than collapsed.
Test.it("keeps every vendor next to its own zone", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    local multi
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        local source = addon.RecipeMetadata:GetSource(row.recipeKey)
        if row.missing.sourceKind == "vendor" and source and source.places
            and #source.places > 1 then
            multi = row
            break
        end
    end
    Test.truthy(multi ~= nil, "expected a recipe sold by more than one vendor")

    local source = addon.RecipeMetadata:GetSource(multi.recipeKey)
    local label = multi.missing.sourceLabel
    for _, place in ipairs(source.places) do
        -- Every vendor is named, and its own zone follows it in brackets.
        Test.truthy(label:find(place.name, 1, true) ~= nil,
            "the label should name " .. tostring(place.name))
        if place.zone then
            Test.truthy(label:find(place.name .. " (" .. place.zone .. ")", 1, true) ~= nil,
                tostring(place.name) .. " should carry its own zone")
        end
    end
end)

-- A colon introduces who, a preposition introduces where. "Quest: Hillsbrad
-- Foothills" reads as a quest by that name, which is not what the row means:
-- the source knows the zone and no quest name at all.
Test.it("does not write a place where a name would go", function()
    setLocalProfession("Alchemy", { skillRank = 375 })
    local prefilters = addon.db.profile.recipePrefilters
    prefilters.expansionDefaults.vanilla = true
    addon.RecipeUiFilters:InvalidateProfessionProjection("alchemy", "spec")

    local seen = {}
    for _, row in ipairs(data:BuildMissingRecipeRows()) do
        local source = addon.RecipeMetadata:GetSource(row.recipeKey)
        local hasName = false
        for _, place in ipairs(source and source.places or {}) do
            hasName = hasName or place.name ~= nil
        end
        if not hasName then
            -- Nothing is named, so nothing may follow a colon.
            Test.eq(row.missing.sourceLabel:find(": "), nil)
            seen[row.missing.sourceKind] = row.missing.sourceLabel
        end
    end
    Test.truthy(seen.quest ~= nil, "expected a quest known only by its zone")
    Test.truthy(seen.quest:find("^Quest at ") == 1, "got: " .. tostring(seen.quest))
end)

io.write(string.format("Missing recipes: %d test(s) passed\n", Test.count))
