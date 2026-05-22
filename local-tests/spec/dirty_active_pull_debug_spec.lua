local Loader = dofile("local-tests/harness/load-addon.lua")
local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function countSentKind(rows, kind)
    local total = 0
    for _, row in ipairs(rows or {}) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
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
        sourceType = opts.professionSourceType or entry.sourceType,
        guildStatus = "active",
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkSyncIndexDirty(opts.reason or "dirty-debug-seed")
end

local function refreshSyncNode(node, reason)
    local addon = node and node.addon or nil
    if addon and addon.Data and addon.Data.PrepareSyncIndexNow then
        addon.Data:PrepareSyncIndexNow(reason or "dirty-debug-refresh")
    end
    if addon and addon.Sync and addon.Sync.RefreshSyncReadyState then
        addon.Sync:RefreshSyncReadyState(reason or "dirty-debug-refresh")
    end
end

io.write("Dirty active pull debug\n")

Test.it("dirty active pull debug keeps the session moving while HELLO stays blocked", function()
    local bus = CommBus.New({
        names = { "DebugRequester", "DebugSeed" },
    })
    local requester = bus:AddNode("DebugRequester")
    local seed = bus:AddNode("DebugSeed")

    bus:SeedSelfProfession(requester, {
        profession = "Alchemy",
        recipeCount = 1,
        baseRecipe = 9300,
    })
    bus:SeedSelfProfession(seed, {
        profession = "Alchemy",
        recipeCount = 3,
        baseRecipe = 9400,
    })
    bus:Activate(seed)
    seedProfession(seed.addon.Data, seed.key, "Tailoring", { 9501, 9502 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "dirty-debug-tailoring",
    })
    refreshSyncNode(seed, "dirty-debug-tailoring")
    requester.addon.Data:MarkSyncIndexDirty("dirty-debug-requester")
    seed.addon.Data:MarkSyncIndexDirty("dirty-debug-seed")
    refreshSyncNode(requester, "dirty-debug-requester")
    refreshSyncNode(seed, "dirty-debug-seed")

    bus:Activate(requester)
    requester.addon.Sync:BroadcastHello()

    local waiting = bus:RunUntil(function()
        local session = requester.addon.Sync.outboundSeedSession
        return session and session.state == "waiting-next-block-delay"
    end, {
        maxTicks = 300,
    })

    Test.truthy(waiting, "session should reach the next-block delay after the first merge")
    local snapshot = requester.addon.Sync:GetRuntimeObservabilitySnapshot()
    Test.truthy(snapshot.index.globalFingerprintDirty, "snapshot should show dirty global fingerprint during the active pull")
    Test.truthy(snapshot.outboundSession.indexDirtyAllowedForActivePull, "snapshot should explain the dirty active-pull exception")

    local helloBefore = countSentKind(requester.state.sentComm, "HELLO")
    Test.falsy(requester.addon.Sync:BroadcastHello(), "HELLO should stay blocked while the active pull is dirty")
    Test.eq(countSentKind(requester.state.sentComm, "HELLO"), helloBefore, "dirty active pull should not publish a new HELLO")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 1, "only one block pull should be in flight before the paced follow-up")

    local completed = bus:RunUntil(function()
        local session = requester.addon.Sync.outboundSeedSession
        return session and session.state == "completed"
    end, {
        maxTicks = 240,
    })

    Test.truthy(completed, "the active session should still continue and complete")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 2, "the next block pull should still be sent for the same session")
end)

io.write(string.format("Dirty active pull debug: %d test(s) passed\n", Test.count))
