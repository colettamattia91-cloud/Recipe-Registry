local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function seedDirtyMember(data, memberKey)
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = 100
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.professions.Alchemy = {
        recipes = {
            [91001] = true,
            [999999999999] = true,
        },
        count = 7,
        signature = "legacy",
        skillRank = 300,
        skillMaxRank = 375,
        sourceType = "replica",
        guildStatus = "active",
    }
    return entry
end

io.write("Data cleanup\n")

Test.it("dry-run corrupt cleanup reports repairs without mutating data or dirtying the index", function()
    local _addon, _wow, data = freshAddon()
    seedDirtyMember(data, "Cleanupdry-TestRealm")
    data:ClearSyncIndexDirty("baseline")

    local stats = data:CleanCorruptData({
        dryRun = true,
        checkProfessionMismatches = false,
    })
    local entry = data:GetMember("Cleanupdry-TestRealm")

    Test.eq(stats.removedRecipes, 1, "dry-run should count invalid recipes")
    Test.eq(stats.repairedCounts, 1, "dry-run should count bad counts")
    Test.eq(stats.repairedSignatures, 1, "dry-run should count legacy signatures")
    Test.hasKey(entry.professions.Alchemy.recipes, 999999999999, "dry-run should not remove recipes")
    Test.eq(entry.professions.Alchemy.count, 7, "dry-run should not repair count")
    Test.eq(entry.professions.Alchemy.signature, "legacy", "dry-run should not strip signature")
    Test.falsy(data:IsSyncIndexDirty(), "dry-run should not dirty the sync index")
end)

Test.it("corrupt cleanup repairs a specific profession block and marks only that block dirty", function()
    local _addon, _wow, data = freshAddon()
    local memberKey = "Cleanupone-TestRealm"
    seedDirtyMember(data, memberKey)
    data:ClearSyncIndexDirty("baseline")

    local stats = data:CleanCorruptData({
        checkProfessionMismatches = false,
    })
    local entry = data:GetMember(memberKey)
    local cache = data._syncIndexCache or {}
    local blockKey = data:BuildSyncBlockKey(memberKey, "Alchemy")

    Test.eq(stats.removedRecipes, 1, "invalid recipe should be removed")
    Test.eq(stats.repairedCounts, 1, "bad count should be repaired")
    Test.eq(stats.repairedSignatures, 1, "legacy signature should be stripped")
    Test.noKey(entry.professions.Alchemy.recipes, 999999999999, "invalid recipe should be gone")
    Test.eq(entry.professions.Alchemy.count, 1, "count should match remaining recipes")
    Test.eq(entry.professions.Alchemy.signature, nil, "signature should be stripped")
    Test.falsy(cache.dirtyAll, "specific repair should not force full dirty")
    Test.truthy(cache.dirtyBlocks and cache.dirtyBlocks[blockKey], "repaired block should be dirty")
end)

Test.it("database wipe clears members, runtime sync state, caches, and schedules resync", function()
    local addon, _wow, data = freshAddon()
    seedDirtyMember(data, "Wipeone-TestRealm")
    data._recipeListCache = { keep = true }
    data._recipeDetailCache = { keep = true }
    data._recipeIndex = { keep = true }
    addon.Sync.outboundSeedSession = { state = "waiting-block" }
    addon.Sync.inboundSeedSessions = {
        ["Peerone-TestRealm"] = {
            ["request-1"] = { requestId = "request-1" },
        },
    }

    data:WipeDatabase()

    Test.eq(Test.countKeys(data:GetMembersDB()), 0, "wipe should clear members")
    Test.eq(data._recipeListCache, nil, "wipe should clear list cache")
    Test.eq(data._recipeDetailCache, nil, "wipe should clear detail cache")
    Test.eq(data._recipeIndex, nil, "wipe should clear recipe index")
    Test.eq(addon.Sync.outboundSeedSession, nil, "wipe should clear outbound session")
    Test.eq(addon.Sync:GetInboundSeedSessionCount(), 0, "wipe should clear inbound sessions")
    Test.truthy(addon.Sync._helloTimer ~= nil or type(addon.Sync.lastHelloScheduleReason) == "string",
        "wipe should schedule a fresh sync cycle")
end)

io.write(string.format("Data cleanup: %d test(s) passed\n", Test.count))
