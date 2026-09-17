-- Where a recipe comes from, on the recipe detail.
--
-- The obtain-side data has been on disk since the source import, but until
-- now only the Collection tab read it, and only as one joined line. The
-- describer is shared so the two views cannot drift apart, and the detail
-- panel takes the per-place list form because it has the room for it.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data
local metadata = addon.RecipeMetadata

-- Walks the catalogued recipes of a profession until `predicate` accepts one.
-- The fixtures are the real generated payload, so picking recipes by shape
-- rather than by id keeps the specs from breaking every time the data is
-- regenerated.
local function findRecipe(professionKey, predicate)
    local candidates = metadata:BuildVisibleSpellIdHash(professionKey,
        { vanilla = true, tbc = true })
    -- Sorted so a failure is reproducible: the hash order is not stable.
    local spellIds = {}
    for spellId in pairs(candidates or {}) do
        spellIds[#spellIds + 1] = spellId
    end
    table.sort(spellIds)
    for _, spellId in ipairs(spellIds) do
        local recipeKey = -spellId
        local source = data:DescribeRecipeSource(recipeKey, professionKey)
        if predicate(source, recipeKey) then
            return recipeKey, source
        end
    end
    return nil
end

io.write("Recipe source on the detail\n")

Test.it("puts the source on the recipe detail", function()
    local recipeKey = findRecipe("alchemy", function(source)
        return source.known and source.kind == "vendor"
    end)
    Test.truthy(recipeKey ~= nil, "expected a vendor-taught alchemy recipe")

    local detail = data:GetRecipeDetail(recipeKey)
    Test.truthy(detail.source ~= nil, "the detail should carry its source")
    Test.eq(detail.source.kind, "vendor")
    Test.truthy(detail.source.label:find("Vendor") == 1,
        "got: " .. tostring(detail.source.label))
end)

-- The Collection tab's column is one line, so it joins the places with commas.
-- The panel lists them, because a recipe sold in four cities is four errands
-- and the reader has to be able to pick one.
Test.it("gives every place its own line", function()
    local recipeKey, source = findRecipe("alchemy", function(candidate)
        return candidate.places ~= nil and #candidate.places > 1
    end)
    Test.truthy(recipeKey ~= nil, "expected a recipe with more than one place")

    Test.eq(#source.lines, #source.places)
    for index, place in ipairs(source.places) do
        local line = source.lines[index]
        if place.name then
            Test.truthy(line:find(place.name, 1, true) ~= nil,
                "line should name " .. tostring(place.name) .. ", got: " .. line)
        elseif place.zone then
            Test.truthy(line:find(place.zone, 1, true) ~= nil,
                "line should place " .. tostring(place.zone) .. ", got: " .. line)
        end
    end
end)

-- Every line obeys the same rule as the joined label: a colon introduces who,
-- a preposition introduces where.
Test.it("applies the label rule to each line, not just to the joined one", function()
    local recipeKey, source = findRecipe("alchemy", function(candidate)
        return candidate.places ~= nil and #candidate.places > 1
    end)
    Test.truthy(recipeKey ~= nil)

    for index, place in ipairs(source.places) do
        local line = source.lines[index]
        if place.name then
            Test.truthy(line:find(": ") ~= nil, "a named place takes a colon: " .. line)
        else
            Test.eq(line:find(": "), nil)
        end
    end
end)

-- A world drop or a discovery names no place at all, so listing one line per
-- place would repeat the same sentence.
Test.it("never repeats the same line twice", function()
    for _, professionKey in ipairs({ "alchemy", "blacksmithing", "engineering", "tailoring" }) do
        local candidates = metadata:BuildVisibleSpellIdHash(professionKey,
            { vanilla = true, tbc = true })
        for spellId in pairs(candidates or {}) do
            local source = data:DescribeRecipeSource(-spellId, professionKey)
            local seen = {}
            for _, line in ipairs(source.lines or {}) do
                Test.eq(seen[line], nil, "repeated line: " .. line)
                seen[line] = true
            end
        end
    end
end)

-- A recipe the metadata cannot place still gets a line: the panel should never
-- render an empty "Where to learn" block.
Test.it("always produces at least one line", function()
    local candidates = metadata:BuildVisibleSpellIdHash("blacksmithing",
        { vanilla = true, tbc = true })
    local checked = 0
    for spellId in pairs(candidates or {}) do
        local source = data:DescribeRecipeSource(-spellId, "blacksmithing")
        Test.gte(#(source.lines or {}), 1)
        Test.truthy(source.label ~= nil and source.label ~= "")
        checked = checked + 1
    end
    Test.gte(checked, 1)
end)

-- The specialization is a hard gate -- unlike skill you cannot grind your way
-- to it later -- so the panel says so next to the skill requirement.
Test.it("carries the specialization requirement onto the detail", function()
    local recipeKey = findRecipe("blacksmithing", function(_, candidateKey)
        return metadata:GetSpecialization(candidateKey) ~= nil
    end)
    Test.truthy(recipeKey ~= nil, "expected a specialization-gated plan")

    local detail = data:GetRecipeDetail(recipeKey)
    Test.truthy(detail.specializationSpellId ~= nil)
    Test.eq(detail.specializationName,
        data:GetSpecializationName(detail.professionName, detail.specializationSpellId))
    Test.truthy(detail.specializationName ~= nil,
        "the spell id should resolve to a specialization name")
end)

Test.it("leaves the specialization empty for a plain recipe", function()
    local recipeKey = findRecipe("blacksmithing", function(_, candidateKey)
        return metadata:GetSpecialization(candidateKey) == nil
    end)
    Test.truthy(recipeKey ~= nil)

    local detail = data:GetRecipeDetail(recipeKey)
    Test.eq(detail.specializationSpellId, nil)
    Test.eq(detail.specializationName, nil)
end)

-- The Collection tab and the detail panel must never disagree about a recipe:
-- both read the one describer.
Test.it("describes a recipe the same way for both views", function()
    data:GetOrCreateMember(data:GetPlayerKey()).professions = {}
    local playerKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(playerKey)
    entry.guildStatus = "active"
    entry.sourceType = "owner"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = {
        Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
            recipes = {},
            skillRank = 375,
            skillMaxRank = 375,
            sourceType = "owner",
        }),
    }
    data:InvalidateRecipeCaches()

    -- Compared through the detail panel's own entry point rather than by
    -- re-describing the key: a collection row is keyed by its created item,
    -- and the two views agreeing is exactly what has to hold.
    local rows = data:BuildCollectionRows()
    Test.gte(#rows, 1)
    local checked = 0
    for _, row in ipairs(rows) do
        local detail = data:GetRecipeDetail(row.recipeKey, "Alchemy")
        Test.eq(row.collection.sourceLabel, detail.source.label)
        Test.eq(row.collection.sourceKind, detail.source.kind)
        checked = checked + 1
        if checked >= 40 then break end
    end
    Test.gte(checked, 1)
end)

io.write(string.format("Recipe source on the detail: %d test(s) passed\n", Test.count))
