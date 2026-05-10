local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, profession, recipeKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or "owner"
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })
    data:MarkManifestDirty(data:BuildSyncBlockKey(memberKey, profession), "test-seed")
    return entry
end

io.write("Pause policy\n")

Test.it("does not pause sync just for a raid group outside instances", function()
    local addon, wow, _data = freshAddon()

    wow.SetRaid(true)
    addon.SyncPausePolicy:RefreshPauseState()
    Test.falsy(addon.SyncPausePolicy:IsSensitiveSyncContext(), "raid group alone should not pause sync")
    Test.falsy(addon.Performance:IsCategoryPaused("sync-outbound"), "sync-outbound should stay active in raid group")
    Test.falsy(addon.Performance:IsCategoryPaused("sync-inbound"), "sync-inbound should stay active in raid group")
    Test.falsy(addon.Performance:IsCategoryPaused("sync-manifest"), "sync-manifest should stay active in raid group")
    Test.falsy(addon.Performance:IsCategoryPaused("bootstrap"), "bootstrap should stay active in raid group")
    Test.falsy(addon.Performance:IsCategoryPaused("maintenance"), "maintenance should stay active in raid group")
    Test.falsy(addon.Performance:IsCategoryPaused("ui"), "ui category should stay active in raid group")
end)

Test.it("treats instance contexts as sensitive and pauses non-essential categories", function()
    local addon, wow, _data = freshAddon()

    wow.SetInstance(true, "raid")
    addon.SyncPausePolicy:RefreshPauseState()
    Test.truthy(addon.SyncPausePolicy:IsSensitiveSyncContext(), "instance should pause sync")
    Test.truthy(addon.Performance:IsCategoryPaused("sync-outbound"), "sync-outbound should pause in instances")
    Test.truthy(addon.Performance:IsCategoryPaused("sync-inbound"), "sync-inbound should pause in instances")
    Test.truthy(addon.Performance:IsCategoryPaused("sync-manifest"), "sync-manifest should pause in instances")
    Test.truthy(addon.Performance:IsCategoryPaused("bootstrap"), "bootstrap should pause in instances")
    Test.truthy(addon.Performance:IsCategoryPaused("maintenance"), "maintenance should pause in instances")
    Test.truthy(addon.Performance:IsCategoryPaused("ui"), "ui category should pause in instances")

    wow.SetInstance(false, "none")
    addon.SyncPausePolicy:RefreshPauseState()
    Test.falsy(addon.SyncPausePolicy:IsSensitiveSyncContext(), "normal world should resume sync")
    Test.falsy(addon.Performance:IsCategoryPaused("sync-manifest"), "sync-manifest should resume")
    Test.falsy(addon.Performance:IsCategoryPaused("ui"), "ui should resume")
    Test.truthy(addon.Sync:IsInWarmup(), "leaving an instance should enter a short warmup window")
end)

Test.it("keeps protocol traffic active in raid groups outside instances", function()
    local addon, wow, _data = freshAddon()
    wow.SetRaid(true)
    addon.SyncPausePolicy:RefreshPauseState()

    addon.Sync:BroadcastHello()
    Test.eq(#wow.GetSentComm(), 1, "hello should still be sent in a raid group outside instances")

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = "Peerone-TestRealm",
        rev = 5,
        updatedAt = 500,
        sender = "Peerone-TestRealm",
        version = "1.6.0",
    }, {
        sender = "Peerone-TestRealm",
        distribution = "GUILD",
    })

    Test.truthy(addon.Sync.onlineNodes["Peerone-TestRealm"], "incoming hello should register the remote peer in a raid group outside instances")
end)

Test.it("halts protocol traffic and inbound sync handling while in instances", function()
    local addon, wow, _data = freshAddon()
    wow.SetInstance(true, "raid")
    addon.SyncPausePolicy:RefreshPauseState()

    addon.Sync:BroadcastHello()
    Test.eq(#wow.GetSentComm(), 0, "hello should not be sent while paused")

    addon.Sync.pendingRequests["Remoteone-TestRealm"] = {
        source = "Peerone-TestRealm",
        memberKey = "Remoteone-TestRealm",
        rev = 3,
        queuedAt = time(),
    }
    addon.Sync.pendingRequests["Remotetwo-TestRealm"] = {
        source = "Peertwo-TestRealm",
        memberKey = "Remotetwo-TestRealm",
        rev = 4,
        queuedAt = time(),
    }
    addon.Sync:ProcessRequestQueue()
    Test.eq(#wow.GetSentComm(), 0, "direct requests should not send while paused")
    Test.falsy(addon.Sync.inFlight, "request queue should not advance while paused")
    Test.eq(addon.Sync:GetActiveRequestCount(), 0, "bounded request concurrency should also stay blocked while paused")

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = "Peerone-TestRealm",
        rev = 5,
        updatedAt = 500,
        sender = "Peerone-TestRealm",
        version = "1.6.0",
    }, {
        sender = "Peerone-TestRealm",
        distribution = "GUILD",
    })

    Test.eq(Test.countKeys(addon.Sync.onlineNodes), 0, "incoming hello should be ignored while paused")
    Test.eq(#(addon.Sync.manifestChunkQueue or {}), 0, "incoming hello should not queue manifests while paused")
    Test.eq(#wow.GetSentComm(), 0, "incoming hello should not trigger replies while paused")
end)

Test.it("keeps manifest cache work paused while in instances and resumes it afterwards", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 98001, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    local prof = data:GetMember(localKey).professions.Alchemy
    prof.recipes[98002] = true
    prof.count = 2
    prof.signature = "98001,98002"
    data:MarkManifestDirty(data:BuildSyncBlockKey(localKey, "Alchemy"), "pause-test")

    local before = data:GetManifestDebugSnapshot()
    wow.SetInstance(true, "raid")
    addon.SyncPausePolicy:RefreshPauseState()
    addon.Performance:RunNextStep()
    local pausedSnapshot = data:GetManifestDebugSnapshot()
    local queueLengths = addon.Performance:GetQueueLengths()

    Test.eq((pausedSnapshot.telemetry or {}).buildsStarted or 0, (before.telemetry or {}).buildsStarted or 0, "manifest build should stay paused in instances")
    Test.gte(queueLengths["sync-manifest"] or 0, 1, "manifest build job should remain queued while paused")

    wow.SetInstance(false, "none")
    addon.SyncPausePolicy:RefreshPauseState()
    for _ = 1, 20 do
        addon.Performance:RunNextStep()
    end
    local resumed = data:GetManifestDebugSnapshot()
    Test.truthy(resumed.ready, "manifest cache should become ready again after leaving raid")
    Test.eq(resumed.recipes or 0, 2, "manifest cache should include the deferred recipe delta after leaving raid")
end)

io.write(string.format("Pause policy: %d test(s) passed\n", Test.count))
