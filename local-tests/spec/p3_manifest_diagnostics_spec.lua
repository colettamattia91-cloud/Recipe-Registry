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
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.professions[profession] = {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
    }
    data:MarkManifestDirty(data:BuildSyncBlockKey(memberKey, profession), "test-seed")
    return entry.professions[profession]
end

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function runUntil(addon, wow, predicate, maxTicks)
    maxTicks = maxTicks or 5000
    for _ = 1, maxTicks do
        addon.Sync:ProcessRequestQueue()
        addon.Sync:ProcessInboundQueue()
        addon.Performance:RunNextStep()
        addon.MockSync:GetDebugSnapshot()
        if predicate() then
            return true
        end
        wow.AdvanceTime(0.25)
    end
    return false
end

local function queuesIdle(addon)
    return #addon.Sync.inboundChunkQueue == 0
        and #addon.Sync.inboundFinalizeQueue == 0
        and addon.Sync.inFlight == nil
        and next(addon.Sync.pendingRequests) == nil
end

local function drainTrafficScenario(addon, wow)
    return runUntil(addon, wow, function()
        local snapshot = addon.MockSync:GetDebugSnapshot()
        return snapshot.pendingPayloads == 0
            and queuesIdle(addon)
            and (addon.Sync.telemetry.replicaRequestsQueued or 0) == (addon.Sync.telemetry.replicaOwnersApplied or 0)
            and (addon.Sync.telemetry.replicaRequestsQueued or 0) > 0
    end, 20000)
end

io.write("P3 manifest diagnostics\n")

Test.it("tracks manifest build cost timing", function()
    local _addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95001, { sourceType = "owner" })

    data:BuildManifestCacheNow("test-timing")

    local snapshot = data:GetManifestDebugSnapshot()
    Test.truthy(snapshot.lastBuildCostMs >= 0, "lastBuildCostMs should be non-negative")
    Test.truthy(snapshot.maxBuildCostMs >= 0, "maxBuildCostMs should be non-negative")
    Test.truthy(snapshot.avgBuildCostMs >= 0, "avgBuildCostMs should be non-negative")
    Test.eq(snapshot.telemetry.buildsCompleted, 1, "one build completed")
    Test.truthy(snapshot.telemetry.totalBuildCostMs >= 0, "totalBuildCostMs should be non-negative")
end)

Test.it("tracks max build cost across multiple builds", function()
    local _addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95010, { sourceType = "owner" })

    data:BuildManifestCacheNow("first")
    local snap1 = data:GetManifestDebugSnapshot()
    local firstMax = snap1.maxBuildCostMs

    local prof = data:GetMember(localKey).professions.Alchemy
    prof.recipes[95011] = true
    prof.count = 2
    prof.signature = "95010,95011"
    data:MarkManifestDirty(data:BuildSyncBlockKey(localKey, "Alchemy"), "delta-timing")
    data:BuildManifestCacheNow("second")

    local snap2 = data:GetManifestDebugSnapshot()
    Test.eq(snap2.telemetry.buildsCompleted, 2, "two builds completed")
    Test.truthy(snap2.maxBuildCostMs >= firstMax, "maxBuildCostMs should not decrease")
    Test.truthy(snap2.avgBuildCostMs >= 0, "avgBuildCostMs should be valid")
end)

Test.it("counts manifest build requests in Sync telemetry", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95020, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    Test.eq(addon.Sync.telemetry.manifestBuildRequests, 0, "no build requests before send")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")
    Test.eq(addon.Sync.telemetry.manifestBuildRequests, 1, "one build request after send")

    addon.Sync:SendManifestToPeer("Peertwo-Testrealm", "force")
    Test.eq(addon.Sync.telemetry.manifestBuildRequests, 2, "two build requests after second send")
end)

Test.it("prints structured manifest batch, receive, and compare diagnostics in debug mode", function()
    local addon, wow, data = freshAddon()
    addon.debugMode = true
    local localKey = data:GetPlayerKey()
    local peerKey = "Peerone-Testrealm"
    seedProfession(data, localKey, "Alchemy", 95021, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    addon.Sync:SendManifestToPeer(peerKey, "force")
    Test.truthy(printLogContains(wow, "Manifest batch peer=" .. peerKey), "batch diagnostics should include peer")
    Test.truthy(printLogContains(wow, "queuedChunks="), "batch diagnostics should include queued chunks")
    Test.truthy(printLogContains(wow, "sentChunks=0"), "batch diagnostics should include sent chunk count")
    Test.truthy(printLogContains(wow, "reason=force"), "batch diagnostics should include reason")

    addon.Sync:HandleManifestChunk({
        sender = peerKey,
        manifestId = "Peerone-Testrealm:100:1:1",
        seq = 1,
        total = 1,
        builtAt = 100,
        memberKey = peerKey,
        totals = { blocks = 1, recipes = 1 },
        blocks = {
            {
                blockKey = "Peerone-Testrealm::Alchemy",
                ownerCharacter = peerKey,
                professionKey = "Alchemy",
                revision = 2,
                lastUpdatedAt = 100,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "peer-95021",
            },
        },
    })

    Test.truthy(printLogContains(wow, "Manifest receive peer=" .. peerKey), "receive diagnostics should include peer")
    Test.truthy(printLogContains(wow, "receivedSeqs=1/1"), "receive diagnostics should include receive progress")
    Test.truthy(printLogContains(wow, "missingSeqs=none"), "receive diagnostics should include missing seqs")
    Test.truthy(printLogContains(wow, "Manifest compare peer=" .. peerKey), "compare diagnostics should include peer")
    Test.truthy(printLogContains(wow, "blockCount=1"), "compare diagnostics should include block count")
    Test.truthy(printLogContains(wow, "queuedRequests="), "compare diagnostics should include queued request count")
end)

Test.it("counts manifest force replies", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95030, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    Test.eq(addon.Sync.telemetry.manifestForceReplies, 0, "no force replies initially")

    addon.Sync:HandleManifestRequest({ sender = "Peerone-Testrealm" })
    Test.eq(addon.Sync.telemetry.manifestForceReplies, 1, "one force reply")
    Test.eq(addon.Sync.telemetry.manifestBuildRequests, 1, "force reply triggers build request")
end)

Test.it("counts manifest chunks received", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95040, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    Test.eq(addon.Sync.telemetry.manifestChunksReceived, 0, "no chunks received initially")

    addon.Sync:HandleManifestChunk({
        sender = "Peerone-Testrealm",
        manifestId = "Peerone-Testrealm:100:1:1",
        seq = 1,
        total = 1,
        builtAt = 100,
        memberKey = "Peerone-Testrealm",
        totals = { blocks = 1, recipes = 1 },
        blocks = {
            {
                blockKey = "Peerone-Testrealm::Alchemy",
                ownerCharacter = "Peerone-Testrealm",
                professionKey = "Alchemy",
                revision = 1,
                lastUpdatedAt = 100,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "abc",
            },
        },
    })
    Test.eq(addon.Sync.telemetry.manifestChunksReceived, 1, "one chunk received")
end)

Test.it("does not double-count manifestChunksSent", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95050, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")
    Test.gte(#addon.Sync.manifestChunkQueue, 1, "manifest chunks queued")

    addon.Sync:SendNextLowPriorityChunk()
    Test.eq(addon.Sync.telemetry.manifestChunksSent, 1, "one chunk sent")
    Test.eq(addon.Sync.telemetry.manifestChunksDelivered, 0, "delivered counter should not double-count")
end)

Test.it("tracks chunk cache invalidation reason", function()
    local _addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95060, { sourceType = "owner" })

    data:BuildManifestCacheNow("initial")
    local chunkTel = _addon.TrickleSync:GetManifestChunkTelemetry()
    Test.eq(chunkTel.chunkInvalidations, 1, "commit invalidates chunk cache")
    Test.eq(chunkTel.lastInvalidationReason, "initial", "invalidation reason from commit")

    local prof = data:GetMember(localKey).professions.Alchemy
    prof.recipes[95061] = true
    prof.count = 2
    prof.signature = "95060,95061"
    data:MarkManifestDirty(data:BuildSyncBlockKey(localKey, "Alchemy"), "delta-reason")
    data:BuildManifestCacheNow("delta-reason")
    Test.eq(chunkTel.chunkInvalidations, 2, "second invalidation")
    Test.eq(chunkTel.lastInvalidationReason, "delta-reason", "updated invalidation reason")
end)

Test.it("includes manifest telemetry in sync dump output", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95070, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")
    addon.Sync:DumpStatus()

    Test.truthy(printLogContains(wow, "Role="), "sync status line present")
    Test.truthy(printLogContains(wow, "Manifest requests="), "manifest telemetry line present")
    Test.truthy(printLogContains(wow, "forceReplies="), "force replies in manifest telemetry")
    Test.truthy(printLogContains(wow, "cooldownSkips="), "cooldown skips in manifest telemetry")
    Test.truthy(printLogContains(wow, "Manifest recovery="), "recovery telemetry line present")
    Test.truthy(printLogContains(wow, "sendRetries="), "manifest retry telemetry in sync dump")
    Test.truthy(printLogContains(wow, "lastRecovery="), "manifest last recovery diagnostics in sync dump")
end)

Test.it("includes build counters in manifest summary output", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95080, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")
    addon.debugMode = true

    addon:SlashHandler("manifest")

    Test.truthy(printLogContains(wow, "Manifest local="), "manifest summary present")
    Test.truthy(printLogContains(wow, "Manifest builds="), "manifest build counters present")
    Test.truthy(printLogContains(wow, "Manifest sync recovery="), "manifest sync recovery counters present")
    Test.truthy(printLogContains(wow, "avgCostMs="), "build cost in manifest summary")
    Test.truthy(printLogContains(wow, "cooldownSkips="), "cooldown skips in manifest summary")
end)

Test.it("includes build cost and chunk invalidation in perf dump output", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95090, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")
    addon.debugMode = true

    addon:SlashHandler("perf dump")

    Test.truthy(printLogContains(wow, "Manifest cache ready="), "manifest cache line present")
    Test.truthy(printLogContains(wow, "Manifest recovery="), "manifest recovery counters in perf dump")
    Test.truthy(printLogContains(wow, "avgCostMs="), "build cost in perf dump")
    Test.truthy(printLogContains(wow, "maxCostMs="), "max build cost in perf dump")
    Test.truthy(printLogContains(wow, "chunkInvalidations="), "chunk invalidations in perf dump")
end)

Test.it("resets manifest telemetry counters on perf reset", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 95100, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")
    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")

    Test.truthy(addon.Sync.telemetry.manifestBuildRequests > 0, "build requests before reset")
    local snapshotBefore = data:GetManifestDebugSnapshot()
    Test.truthy(snapshotBefore.telemetry.buildsCompleted > 0, "builds before reset")

    addon:SlashHandler("perf reset")

    Test.eq(addon.Sync.telemetry.manifestBuildRequests, 0, "build requests reset")
    Test.eq(addon.Sync.telemetry.manifestForceReplies, 0, "force replies reset")
    Test.eq(addon.Sync.telemetry.manifestChunksReceived, 0, "chunks received reset")
    local snapshotAfter = data:GetManifestDebugSnapshot()
    Test.eq(snapshotAfter.telemetry.totalBuildCostMs, 0, "build cost reset")
    Test.eq(snapshotAfter.telemetry.maxBuildCostMs, 0, "max build cost reset")
    local chunkTel = addon.TrickleSync:GetManifestChunkTelemetry()
    Test.eq(chunkTel.chunkInvalidations, 0, "chunk invalidations reset")
    Test.eq(chunkTel.lastInvalidationReason, "none", "invalidation reason reset")
end)

Test.it("grows manifest counters during mock traffic scenario", function()
    local addon, wow = freshAddon()
    local ok = addon.MockSync:StartScenario("traffic")
    Test.truthy(ok, "traffic scenario should start")
    Test.truthy(drainTrafficScenario(addon, wow), "traffic scenario should drain")

    local tel = addon.Sync.telemetry
    Test.truthy(tel.manifestChunksReceived > 0, "traffic scenario should receive manifest chunks")
    Test.truthy(tel.replicaManifestBlocksSeen > 0, "traffic scenario should see replica manifest blocks")
    Test.truthy(tel.replicaRequestsQueued > 0, "traffic scenario should queue replica requests")
end)

Test.it("grows manifest counters during mock offline scenario", function()
    local addon, wow = freshAddon()
    local ok = addon.MockSync:StartScenario("offline")
    Test.truthy(ok, "offline scenario should start")
    Test.truthy(drainTrafficScenario(addon, wow), "offline scenario should drain")

    local tel = addon.Sync.telemetry
    Test.truthy(tel.manifestChunksReceived > 0, "offline scenario should receive manifest chunks")
    Test.truthy(tel.replicaManifestBlocksSeen > 0, "offline scenario should see replica blocks")
    Test.truthy(tel.replicaOwnersApplied > 0, "offline scenario should apply replica owners")
end)

io.write(string.format("P3 manifest diagnostics: %d test(s) passed\n", Test.count))
