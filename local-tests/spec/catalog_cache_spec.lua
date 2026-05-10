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
    entry.rev = opts.rev or 1
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
        blockRevision = opts.blockRevision or entry.rev,
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

io.write("Catalog cache\n")

Test.it("bounds recipe list cache across many distinct queries", function()
    local _addon, data = freshAddon()
    seedMember(data, "Cacheone-TestRealm", "Alchemy", recipeSet(98001, 98150), {
        sourceType = "replica",
        count = 150,
    })

    for i = 1, 20 do
        data:GetRecipeList(nil, "query-" .. tostring(i), "alpha")
    end

    Test.gte(12, Test.countKeys(data._recipeListCache), "recipe list cache should stay bounded")
    Test.gte(12, #(data._recipeListCacheOrder or {}), "recipe list cache order should stay bounded")
end)

Test.it("bounds recipe detail cache across many lookups", function()
    local _addon, data = freshAddon()
    seedMember(data, "Cachetwo-TestRealm", "Enchanting", recipeSet(99001, 99150), {
        sourceType = "replica",
        count = 150,
    })

    for recipeKey = 99001, 99150 do
        data:GetRecipeDisplayInfo(recipeKey)
    end

    Test.gte(128, Test.countKeys(data._recipeDetailCache), "recipe detail cache should stay bounded")
    Test.gte(128, #(data._recipeDetailCacheOrder or {}), "recipe detail cache order should stay bounded")
end)

io.write(string.format("Catalog cache: %d test(s) passed\n", Test.count))