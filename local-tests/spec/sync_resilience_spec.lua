local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function countCommKind(wow, kind)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function seedProfession(data, memberKey, profession, recipeKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = entry.owner or memberKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
    })
    data:MarkManifestDirty(data:BuildSyncBlockKey(memberKey, profession), "test-seed")
    return entry
end

io.write("Sync resilience\n")

Test.it("backs off a failed source and lets another queued request proceed", function()
    local addon, wow, _data = freshAddon()
    local badSource = "Avero-TestRealm"
    local goodSource = "Morbolt-TestRealm"
    local requestTimeout = addon.Sync._private.constants.REQUEST_TIMEOUT + 1
    addon.Sync.onlineNodes[badSource] = { lastSeen = time(), version = "1.7.0" }
    addon.Sync.onlineNodes[goodSource] = { lastSeen = time(), version = "1.7.0" }

    addon.Sync:QueueRequest(badSource, badSource, 5, "index")
    addon.Sync:ProcessRequestQueue()
    Test.truthy(addon.Sync.inFlight, "first request should dispatch")
    Test.eq(addon.Sync.inFlight.source, badSource, "bad source should be in-flight first")

    wow.AdvanceTime(requestTimeout)
    addon.Sync:ProcessRequestQueue()
    Test.falsy(addon.Sync.inFlight, "timed out request should clear in-flight state")
    Test.truthy(addon.Sync.pendingRequests[badSource], "failed request should requeue below retry cap")
    Test.eq(addon.Sync.pendingRequests[badSource].why, "index:retry", "retry reason should be normalized once")
    Test.falsy(addon.Sync:IsPeerBackoffActive(badSource), "a single index failure should not exile the peer immediately")

    addon.Sync:QueueRequest(goodSource, goodSource, 7, "index")
    addon.Sync:ProcessRequestQueue()
    Test.eq(addon.Sync:GetActiveRequestCount(), 2, "bounded concurrency should allow another source to proceed without waiting")
    Test.truthy(addon.Sync:GetInFlightRequest(goodSource), "responsive source should take one active slot")
    Test.truthy(addon.Sync:GetInFlightRequest(badSource), "the retried source can use the remaining bounded slot")
    Test.eq(countCommKind(wow, "REQ"), 3, "the pump should send the responsive REQ and the retry without extra ticks")

    addon.Sync:FailInFlight(false, "done")
    addon.Sync:QueueRequest(badSource, badSource, 5, "index")
    addon.Sync:ProcessRequestQueue()
    Test.truthy(addon.Sync:GetInFlightRequest(badSource), "bad source should still be retryable after a single failure")

    wow.AdvanceTime(requestTimeout)
    addon.Sync:ProcessRequestQueue()
    Test.truthy(addon.Sync:IsPeerBackoffActive(badSource), "repeated failures should eventually back off the peer")
end)

Test.it("backfills the next queued request immediately when a bounded request slot frees up", function()
    local addon, wow, _data = freshAddon()
    local firstPeer = "Avero-TestRealm"
    local secondPeer = "Morbolt-TestRealm"
    local thirdPeer = "Cindar-TestRealm"

    addon.Sync.onlineNodes[firstPeer] = { lastSeen = time(), version = "1.7.0" }
    addon.Sync.onlineNodes[secondPeer] = { lastSeen = time(), version = "1.7.0" }
    addon.Sync.onlineNodes[thirdPeer] = { lastSeen = time(), version = "1.7.0" }

    addon.Sync:QueueRequest(firstPeer, firstPeer, 6, "index")
    addon.Sync:QueueRequest(secondPeer, secondPeer, 5, "index")
    addon.Sync:QueueRequest(thirdPeer, thirdPeer, 4, "index")
    addon.Sync:ProcessRequestQueue()
    Test.eq(addon.Sync:GetActiveRequestCount(), 2, "two requests should dispatch inside the bounded concurrency window")
    Test.truthy(addon.Sync:GetInFlightRequest(firstPeer), "first peer should occupy one active slot")
    Test.truthy(addon.Sync:GetInFlightRequest(secondPeer), "second peer should occupy the other active slot")
    Test.truthy(addon.Sync.pendingRequests[thirdPeer], "third peer should stay queued until a slot frees up")
    Test.eq(countCommKind(wow, "REQ"), 2, "two REQ messages should be sent immediately")

    wow.DeliverComm(addon.Sync, {
        kind = "SNAP",
        sessionId = "session-1",
        key = firstPeer,
        rev = 6,
        updatedAt = 500,
        sender = firstPeer,
        sourceType = "owner",
        profession = "Alchemy",
        skillRank = 300,
        skillMaxRank = 300,
        specialization = nil,
        recipeKeys = { 91001 },
        seq = 1,
        total = 1,
    }, {
        sender = firstPeer,
        distribution = "WHISPER",
    })

    wow.AdvanceTime(0.1)
    wow.RunDueTimers(5)
    Test.eq(addon.Sync:GetActiveRequestCount(), 2, "queue pump should refill the freed slot immediately")
    Test.truthy(addon.Sync:GetInFlightRequest(secondPeer), "already active peer should remain active")
    Test.truthy(addon.Sync:GetInFlightRequest(thirdPeer), "queued peer should dispatch without waiting for the 1s ticker")
    Test.eq(countCommKind(wow, "REQ"), 3, "the queued third REQ should be sent by the queue pump")
end)

Test.it("keeps direct request burst parallelism bounded under load", function()
    local addon, wow, _data = freshAddon()
    local peers = {
        "Burstone-TestRealm",
        "Bursttwo-TestRealm",
        "Burstthree-TestRealm",
        "Burstfour-TestRealm",
        "Burstfive-TestRealm",
    }

    for index = 1, #peers do
        local peerKey = peers[index]
        addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.7.0" }
        addon.Sync:QueueRequest(peerKey, peerKey, 10 + index, "index")
    end

    addon.Sync:ProcessRequestQueue()

    Test.eq(addon.Sync:GetActiveRequestCount(), addon.Sync:GetMaxConcurrentRequests(), "burst dispatch should fill but not exceed the bounded request window")
    Test.eq(countCommKind(wow, "REQ"), addon.Sync:GetMaxConcurrentRequests(), "only the bounded number of REQ messages should send immediately")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), #peers - addon.Sync:GetMaxConcurrentRequests(), "remaining burst requests should stay queued")
    Test.eq(addon.Sync.telemetry.requestConcurrencyMax or 0, addon.Sync:GetMaxConcurrentRequests(), "telemetry should record the bounded concurrency ceiling")
end)

Test.it("hello-auto fails fast and stays blocked until peer backoff expires", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Aldergar-TestRealm"
    local requestTimeout = addon.Sync._private.constants.REQUEST_TIMEOUT + 1

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.6.0" }
    addon.Sync:QueueRequest(peerKey, peerKey, 9, "hello-auto")
    addon.Sync:ProcessRequestQueue()
    Test.truthy(addon.Sync.inFlight, "hello-auto should dispatch once")

    wow.AdvanceTime(requestTimeout)
    addon.Sync:ProcessRequestQueue()
    Test.falsy(addon.Sync.inFlight, "hello-auto timeout should clear in-flight state")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "hello-auto should not retry forever")
    Test.truthy(addon.Sync:IsPeerBackoffActive(peerKey), "timed out hello-auto peer should enter backoff")

    addon.Sync:QueueRequest(peerKey, peerKey, 10, "hello-auto")
    addon.Sync:ProcessRequestQueue()
    Test.falsy(addon.Sync.inFlight, "active backoff should defer a fresh hello-auto dispatch")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "automatic hello-auto should not stay queued during backoff")
    Test.eq(countCommKind(wow, "REQ"), 1, "no extra REQ should be sent during backoff")

    wow.AdvanceTime(21)
    addon.Sync:QueueRequest(peerKey, peerKey, 10, "hello-auto")
    addon.Sync:ProcessRequestQueue()
    Test.truthy(addon.Sync.inFlight, "request should dispatch again after backoff expires")
    Test.eq(addon.Sync.inFlight.source, peerKey, "same peer can be retried after backoff")
end)

Test.it("stale roster metadata does not veto a live sync source and triggers a refresh", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Rosterpeer-TestRealm"
    local beforeRefreshes = wow.GetState().guildRosterRequested

    wow.SetGuildRoster({
        {
            name = peerKey,
            rankName = "Member",
            rankIndex = 1,
            level = 70,
            classDisplayName = "Mage",
            zone = "Shattrath",
            publicNote = "",
            officerNote = "",
            online = false,
            status = "",
            classFileName = "MAGE",
        },
    })
    addon.Data:RebuildOnlineCache()
    addon.Data._guildRosterBuiltAt = time() - 60
    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.7.0" }

    local viable = addon.Sync:IsRequestStillViable({
        source = peerKey,
        memberKey = peerKey,
        rev = 5,
    })

    Test.truthy(viable, "stale roster metadata should not override a live online-node source")
    Test.eq(wow.GetState().guildRosterRequested, beforeRefreshes + 1, "stale roster should request a refresh")
end)

Test.it("warmup defers manifest fan-out and targeted manifest refreshes until expiry", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local peerKey = "Peerone-TestRealm"

    seedProfession(data, localKey, "Alchemy", 98101, { sourceType = "owner" })
    data:BuildManifestCacheNow("steady")
    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.6.0" }
    addon.Sync:EnterWarmup("test", 12)

    addon.Sync:BroadcastManifestToOnlinePeers("auto-tick")
    Test.eq(#addon.Sync.manifestChunkQueue, 0, "warmup should defer manifest fan-out")

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 500,
        sender = peerKey,
        version = "1.6.0",
    }, {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 0, "warmup should avoid extra targeted manifest refreshes during login grace")
    Test.eq(#addon.Sync.manifestChunkQueue, 0, "warmup should defer manifest replies triggered by HELLO")

    wow.AdvanceTime(13)
    wow.RunTimers(10)
    for _ = 1, 20 do
        wow.AdvanceTime(1)
        addon.Performance:RunNextStep()
    end
    Test.eq(countCommKind(wow, "MREQ"), 0, "warmup should not turn a first hello into a targeted refresh storm once the grace window ends")
    Test.eq(countCommKind(wow, "MANI"), 1, "deferred manifest reply should send after warmup")
end)

Test.it("manual manifest refresh bypasses peer backoff and refresh cooldown", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-TestRealm"

    addon.Sync.peerBackoffUntil[peerKey] = time() + 60
    addon.Sync._helloManifestRefreshRequested[peerKey] = time()

    addon.Sync:RequestManifestRefresh(peerKey, {
        force = true,
        clearBackoff = true,
        reason = "manual",
    })

    Test.eq(countCommKind(wow, "MREQ"), 1, "manual refresh should still send an immediate targeted MREQ")
    Test.falsy(addon.Sync:IsPeerBackoffActive(peerKey), "manual refresh should clear peer backoff for troubleshooting")
end)

Test.it("warmup defers manifest catch-up drain until the grace window ends", function()
    local addon, wow, data = freshAddon()
    local senderKey = "Morbolt-TestRealm"
    local ownerKey = "Offlineone-TestRealm"
    local blockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")

    addon.Sync.onlineNodes[senderKey] = { lastSeen = time(), version = "1.7.0" }
    addon.Sync:EnterWarmup("test", 12)
    addon.Sync.manifestCatchupQueue = {
        {
            senderKey = senderKey,
            ownerCharacter = ownerKey,
            revision = 3,
            blockKeys = { blockKey },
            expectedFingerprints = {},
            offlineReplica = true,
        },
    }

    addon.Sync:ScheduleManifestCatchupDrain()
    for _ = 1, 20 do
        addon.Performance:RunNextStep()
    end
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "warmup should keep catch-up requests deferred")

    wow.AdvanceTime(13)
    wow.RunTimers(10)
    for _ = 1, 30 do
        addon.Performance:RunNextStep()
    end
    Test.truthy(addon.Sync.pendingRequests[ownerKey], "catch-up should resume after warmup expires")
end)

Test.it("catch-up drain still progresses while an unrelated request is already in flight", function()
    local addon, wow, data = freshAddon()
    local senderKey = "Morbolt-TestRealm"
    local ownerKey = "Offlineone-TestRealm"
    local otherPeer = "Avero-TestRealm"
    local blockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")

    addon.Sync.onlineNodes[senderKey] = { lastSeen = time(), version = "1.7.0" }
    addon.Sync.onlineNodes[otherPeer] = { lastSeen = time(), version = "1.7.0" }
    addon.Sync.inFlight = {
        source = otherPeer,
        memberKey = otherPeer,
        rev = 9,
        why = "index",
        startedAt = time(),
        lastProgressAt = time(),
        attempts = 1,
    }
    addon.Sync.manifestCatchupQueue = {
        {
            senderKey = senderKey,
            ownerCharacter = ownerKey,
            revision = 3,
            blockKeys = { blockKey },
            expectedFingerprints = {},
            offlineReplica = true,
        },
    }

    addon.Sync:DrainManifestCatchupQueue()

    Test.truthy(addon.Sync.pendingRequests[ownerKey], "deferred catch-up should queue even while another owner is already in flight")
end)

Test.it("syncreset clears runtime sync state without deleting saved professions", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local remoteKey = "Replicaone-TestRealm"
    addon.debugMode = true

    seedProfession(data, localKey, "Alchemy", 98201, { sourceType = "owner" })
    seedProfession(data, remoteKey, "Tailoring", 98202, { sourceType = "replica" })

    addon.Sync.pendingRequests[remoteKey] = {
        source = remoteKey,
        memberKey = remoteKey,
        rev = 8,
        why = "test",
        queuedAt = time(),
    }
    addon.Sync.inFlight = {
        source = remoteKey,
        memberKey = remoteKey,
        rev = 8,
        why = "test",
        startedAt = time(),
    }
    addon.Sync.partialReceive[remoteKey] = {
        source = remoteKey,
        memberKey = remoteKey,
        rev = 8,
        sessionId = "test",
        total = 1,
        seen = {},
    }
    addon.Sync.manifestCatchupQueue = {
        {
            senderKey = remoteKey,
            ownerCharacter = remoteKey,
            revision = 8,
            blockKeys = { data:BuildSyncBlockKey(remoteKey, "Tailoring") },
        },
    }
    addon.Sync.peerBackoffUntil[remoteKey] = time() + 90

    addon:SlashHandler("syncreset")

    Test.truthy(data:GetMember(localKey), "local recipes should remain after syncreset")
    Test.truthy(data:GetMember(remoteKey), "saved remote recipes should remain after syncreset")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "syncreset should clear pending requests")
    Test.falsy(addon.Sync.inFlight, "syncreset should clear in-flight request")
    Test.eq(Test.countKeys(addon.Sync.partialReceive), 0, "syncreset should clear partial receives")
    Test.eq(#addon.Sync.manifestCatchupQueue, 0, "syncreset should clear deferred catch-up queue")
    Test.eq(Test.countKeys(addon.Sync.peerBackoffUntil), 0, "syncreset should clear peer backoff state")
    Test.eq(countCommKind(wow, "MREQ"), 1, "syncreset should request a fresh manifest pass")

    wow.RunTimers(2)
    Test.eq(countCommKind(wow, "HELLO"), 1, "syncreset should schedule a fresh hello")
end)

Test.it("coalesces explicit manifest announce requests into one delayed broadcast", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local peerKey = "Peerone-TestRealm"

    seedProfession(data, localKey, "Alchemy", 98301, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")
    addon.Sync:TouchNode(peerKey, "1.7.0")

    addon.Sync:ScheduleCoalescedManifestAnnounce("snapshot-merge")
    addon.Sync:ScheduleCoalescedManifestAnnounce("snapshot-merge")
    addon.Sync:ScheduleCoalescedManifestAnnounce("snapshot-merge")

    Test.eq(#addon.Sync.manifestChunkQueue, 0, "coalesced manifest announce should not send immediately")
    wow.AdvanceTime(7)
    wow.RunDueTimers(10)
    Test.eq(#addon.Sync.manifestChunkQueue, 0, "announce should still be waiting inside debounce window")

    wow.AdvanceTime(2)
    wow.RunDueTimers(10)
    Test.eq(#addon.Sync.manifestChunkQueue, 1, "one coalesced manifest announce should be queued")
    Test.eq(addon.Sync.telemetry.coalescedManifestSchedules or 0, 1, "only one coalesced schedule should be recorded")
    Test.eq(addon.Sync.telemetry.coalescedManifestFlushes or 0, 1, "coalesced announce should flush once")
end)

io.write(string.format("Sync resilience: %d test(s) passed\n", Test.count))
