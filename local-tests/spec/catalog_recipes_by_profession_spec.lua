local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon = Loader.Load()
    return addon, addon.Data
end

local function seedMember(data, memberKey, profession, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = opts.updatedAt or 100
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions = entry.professions or {}
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipeKeys,
        count = opts.count or 0,
        skillRank = opts.skillRank or 300,
        skillMaxRank = opts.skillMaxRank or 375,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })
    return entry
end

local function recipeSet(firstKey, lastKey)
    local recipes = {}
    for recipeKey = firstKey, lastKey do
        recipes[recipeKey] = true
    end
    return recipes
end

local function asSet(list)
    local set = {}
    for _, value in ipairs(list or {}) do
        set[value] = (set[value] or 0) + 1
    end
    return set
end

io.write("Catalog recipes-by-profession\n")

Test.it("GetRecipeKeysForProfession returns only that profession's recipes", function()
    local _addon, data = freshAddon()
    seedMember(data, "Alche-TestRealm",   "Alchemy",     recipeSet(70001, 70010), { count = 10 })
    seedMember(data, "Enchant-TestRealm", "Enchanting",  recipeSet(70100, 70105), { count = 6 })
    seedMember(data, "Smith-TestRealm",   "Blacksmithing", recipeSet(70200, 70203), { count = 4 })

    data:BuildRecipeIndex()

    local alchemyKeys = data:GetRecipeKeysForProfession("Alchemy") or {}
    local enchantingKeys = data:GetRecipeKeysForProfession("Enchanting") or {}
    local smithKeys = data:GetRecipeKeysForProfession("Blacksmithing") or {}

    Test.eq(#alchemyKeys, 10, "alchemy slice should contain only its 10 recipes")
    Test.eq(#enchantingKeys, 6, "enchanting slice should contain only its 6 recipes")
    Test.eq(#smithKeys, 4, "blacksmithing slice should contain only its 4 recipes")

    for _, key in ipairs(alchemyKeys) do
        Test.truthy(key >= 70001 and key <= 70010, "alchemy slice leaked a non-alchemy recipe: " .. tostring(key))
    end
    for _, key in ipairs(enchantingKeys) do
        Test.truthy(key >= 70100 and key <= 70105, "enchanting slice leaked a non-enchanting recipe: " .. tostring(key))
    end

    Test.falsy(data:GetRecipeKeysForProfession("Cooking"), "profession with no members returns nil")
end)

Test.it("shared recipes across members appear once per profession slice", function()
    local _addon, data = freshAddon()
    -- Two alchemists who happen to know the same 5 recipes plus 3 unique each.
    seedMember(data, "Alche1-TestRealm", "Alchemy", recipeSet(80001, 80008), { count = 8 })
    seedMember(data, "Alche2-TestRealm", "Alchemy", recipeSet(80001, 80005), { count = 5 })
    seedMember(data, "Alche2-TestRealm-extra", "Alchemy", { [80020] = true, [80021] = true, [80022] = true }, { count = 3 })

    data:BuildRecipeIndex()

    local alchemyKeys = data:GetRecipeKeysForProfession("Alchemy") or {}
    local counts = asSet(alchemyKeys)
    for key, count in pairs(counts) do
        Test.eq(count, 1, "recipe " .. tostring(key) .. " should appear exactly once in the slice")
    end
    -- 8 unique from first member + 3 extra-unique = 11 (alche2's 5 are shared)
    Test.eq(#alchemyKeys, 11, "shared recipes should not inflate the slice")
end)

Test.it("scoped GetRecipeList matches full-scan result for the same profession", function()
    local _addon, data = freshAddon()
    seedMember(data, "Alche-TestRealm", "Alchemy", recipeSet(90001, 90030), { count = 30 })
    seedMember(data, "Enchant-TestRealm", "Enchanting", recipeSet(90100, 90120), { count = 21 })
    seedMember(data, "Cook-TestRealm", "Cooking", recipeSet(90200, 90210), { count = 11 })

    local alchemyRows = data:GetRecipeList("Alchemy", "", "alpha")
    Test.eq(#alchemyRows, 30, "scoped list should return only alchemy recipes")
    for _, row in ipairs(alchemyRows) do
        Test.truthy(row.recipeKey >= 90001 and row.recipeKey <= 90030,
            "scoped alchemy list leaked a non-alchemy recipe: " .. tostring(row.recipeKey))
    end

    local allRows = data:GetRecipeList("All", "", "alpha")
    Test.eq(#allRows, 30 + 21 + 11, "All view should still see every recipe")
end)

Test.it("metadata invalidation drops the per-profession slice; presence does not", function()
    local _addon, data = freshAddon()
    seedMember(data, "Alche-TestRealm", "Alchemy", recipeSet(60001, 60005), { count = 5 })
    data:BuildRecipeIndex()
    Test.truthy(data._recipesByProfession ~= nil, "by-profession map should be populated after build")

    data:InvalidateRecipeCaches("presence")
    Test.truthy(data._recipesByProfession ~= nil, "presence-scope invalidation must leave content slice intact")

    data:InvalidateRecipeCaches("metadata")
    Test.falsy(data._recipesByProfession, "metadata-scope invalidation must drop the slice")

    -- And it must be rebuilt on next access.
    local alchemyKeys = data:GetRecipeKeysForProfession("Alchemy") or {}
    Test.eq(#alchemyKeys, 5, "slice should rebuild lazily on next access")
end)

io.write(string.format("Catalog recipes-by-profession: %d test(s) passed\n", Test.count))
