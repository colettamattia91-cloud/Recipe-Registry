local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, profession, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = entry.owner or memberKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys) do
        recipes[recipeKey] = true
    end
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipes,
        count = #recipeKeys,
        signature = table.concat(recipeKeys, ","),
        skillRank = opts.skillRank or 300,
        skillMaxRank = opts.skillMaxRank or 300,
        specialization = opts.specialization,
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
    })
    return entry
end

io.write("Snapshot identical metadata\n")

Test.it("identical recipes with new metadata avoid heavy cache invalidation", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "Peerone-TestRealm"
    seedProfession(data, memberKey, "Alchemy", { 99301, 99302 }, {
        sourceType = "owner",
        rev = 3,
        updatedAt = 100,
        skillRank = 300,
    })

    data._recipeListCache = { keep = true }
    data._recipeListCacheOrder = { "keep" }
    data._recipeDetailCache = { drop = true }
    data._recipeDetailCacheOrder = { "drop" }
    data._recipeIndex = { drop = true }

    data:BeginIncomingSnapshot(memberKey, 4, 200)
    data:AppendIncomingChunk({
        memberKey = memberKey,
        rev = 4,
        updatedAt = 200,
        sourceType = "owner",
        profession = "Alchemy",
        skillRank = 325,
        skillMaxRank = 375,
        specialization = "Transmute",
        recipeKeys = { 99301, 99302 },
    })

    local applied = data:FinalizeIncomingSnapshot(memberKey, 4, {
        sourceType = "owner",
    })

    Test.truthy(applied, "metadata-only snapshot should still apply")
    Test.eq(addon.Sync.telemetry.snapshotMetadataOnlyApplies or 0, 1, "metadata-only telemetry should increment")
    Test.truthy(data._recipeListCache and data._recipeListCache.keep, "list cache should survive metadata-only apply")
    Test.eq(data._recipeDetailCache, nil, "detail cache should invalidate on metadata-only apply")
    Test.eq(data._recipeIndex, nil, "recipe index should invalidate on metadata-only apply")
    Test.eq(data:GetMember(memberKey).professions.Alchemy.skillRank, 325, "skill metadata should update")
end)

Test.it("equivalent snapshot skips apply and counts as identical", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "Peertwo-TestRealm"
    seedProfession(data, memberKey, "Alchemy", { 99311 }, {
        sourceType = "owner",
        rev = 5,
        updatedAt = 500,
    })

    data:BeginIncomingSnapshot(memberKey, 5, 500)
    data:AppendIncomingChunk({
        memberKey = memberKey,
        rev = 5,
        updatedAt = 500,
        sourceType = "owner",
        profession = "Alchemy",
        skillRank = 300,
        skillMaxRank = 300,
        recipeKeys = { 99311 },
    })

    local applied = data:FinalizeIncomingSnapshot(memberKey, 5, {
        sourceType = "owner",
    })

    Test.falsy(applied, "exactly equivalent snapshot should be skipped")
    Test.eq(addon.Sync.telemetry.snapshotIdenticalSkips or 0, 1, "identical snapshot telemetry should increment")
end)

io.write(string.format("Snapshot identical metadata: %d test(s) passed\n", Test.count))
