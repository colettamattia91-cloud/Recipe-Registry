local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, professionKey, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end
    entry.guildStatus = "active"
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[professionKey] = {
        recipes = recipes,
        skillRank = opts.skillRank or 75,
        skillMaxRank = opts.skillMaxRank or 150,
        specialization = opts.specialization,
        sourceType = opts.professionSourceType or entry.sourceType,
        guildStatus = "active",
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    return entry
end

local function primeListCache(data)
    data._recipeListCache = { sentinel = "keep" }
    data._recipeListCacheOrder = { "sentinel" }
end

local function buildPayload(blockKey, ownerCharacter, professionKey, recipeKeys, opts)
    opts = opts or {}
    return {
        blockKey = blockKey,
        ownerCharacter = ownerCharacter,
        professionKey = professionKey,
        recipeKeys = recipeKeys,
        skillRank = opts.skillRank or 75,
        skillMaxRank = opts.skillMaxRank or 150,
        specialization = opts.specialization,
    }
end

io.write("Block merge list cache invalidation\n")

-- Use real TBC spell IDs (as negative keys) so the sync inbound gate
-- in MergeEngine — which drops keys not catalogued in metadata — lets
-- them through. Synthetic placeholders like 11001 are not in the
-- generated metadata and would be filtered before reaching the merge.
local ALCHEMY_RECIPE_A = -28543  -- Elixir of Major Strength
local ALCHEMY_RECIPE_B = -28544  -- Elixir of Major Defense
local ALCHEMY_RECIPE_C = -28545  -- Elixir of Major Frost Power
local TAILORING_RECIPE = -26745  -- Bolt of Imbued Netherweave

Test.it("block merge that adds recipes drops the recipe list cache", function()
    local _addon, _wow, data = freshAddon()
    local owner = "Crafter-TestRealm"
    local profession = "Alchemy"
    seedProfession(data, owner, profession, { ALCHEMY_RECIPE_A, ALCHEMY_RECIPE_B })
    local blockKey = data:BuildSyncBlockKey(owner, profession)

    primeListCache(data)

    local applied, result = data:ApplyIncomingBlockAdditive(
        blockKey,
        buildPayload(blockKey, owner, profession, { ALCHEMY_RECIPE_A, ALCHEMY_RECIPE_B, ALCHEMY_RECIPE_C }),
        { sourceType = "replica" }
    )

    Test.truthy(applied, "merge with new recipe should apply")
    Test.eq(result.addedRecipes, 1, "expected one new recipe added")
    Test.eq(data._recipeListCache, nil, "list cache must be invalidated when content changes")
    Test.eq(data._recipeListCacheOrder, nil, "list cache order must be cleared alongside the cache")
end)

Test.it("metadata-only block merge preserves the recipe list cache", function()
    local _addon, _wow, data = freshAddon()
    local owner = "Crafter-TestRealm"
    local profession = "Alchemy"
    seedProfession(data, owner, profession, { ALCHEMY_RECIPE_A, ALCHEMY_RECIPE_B }, { skillRank = 100 })
    local blockKey = data:BuildSyncBlockKey(owner, profession)

    primeListCache(data)

    local applied, result = data:ApplyIncomingBlockAdditive(
        blockKey,
        buildPayload(blockKey, owner, profession, { ALCHEMY_RECIPE_A, ALCHEMY_RECIPE_B }, {
            skillRank = 175,
            skillMaxRank = 225,
            specialization = "Transmute",
        }),
        { sourceType = "owner" }
    )

    Test.truthy(applied, "metadata-only merge should still apply")
    Test.eq(result.addedRecipes, 0, "metadata-only merge must not add recipes")
    Test.truthy(
        data._recipeListCache and data._recipeListCache.sentinel == "keep",
        "list cache must survive a metadata-only block merge"
    )
end)

Test.it("first-ever block merge for a new owner drops the recipe list cache", function()
    local _addon, _wow, data = freshAddon()
    local newOwner = "Stranger-TestRealm"
    local profession = "Tailoring"
    local blockKey = data:BuildSyncBlockKey(newOwner, profession)

    primeListCache(data)

    local applied = data:ApplyIncomingBlockAdditive(
        blockKey,
        buildPayload(blockKey, newOwner, profession, { TAILORING_RECIPE }),
        { sourceType = "replica" }
    )

    Test.truthy(applied, "merge for a brand-new owner should apply")
    Test.eq(data._recipeListCache, nil, "list cache must drop when a new owner is introduced")
end)

io.write(string.format("Block merge list cache invalidation: %d test(s) passed\n", Test.count))
