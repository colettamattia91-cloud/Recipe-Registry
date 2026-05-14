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

local function withModernVersion(addon, payload)
    payload = payload or {}
    payload.addonVersion = payload.addonVersion or addon.ADDON_VERSION
    payload.wireVersion = payload.wireVersion or addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or addon.BUILD_CHANNEL
    payload.caps = payload.caps or (addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or nil)
    return payload
end

io.write("Manifest cache\n")

Test.it("builds and reuses cached manifest chunks", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 93001, { sourceType = "owner" })

    local manifest = data:BuildManifestCacheNow("test")
    Test.eq(manifest.totals.blocks, 1, "manifest block count")

    local chunks = addon.TrickleSync:BuildManifestChunks({ syncFallback = true })
    Test.truthy(chunks and chunks[1], "manifest chunks should build")
    local telemetry = addon.TrickleSync:GetManifestChunkTelemetry()
    Test.eq(telemetry.chunkBuilds, 1, "first chunk build")

    local chunksAgain = addon.TrickleSync:BuildManifestChunks({ syncFallback = true })
    Test.truthy(chunksAgain and chunksAgain[1], "cached manifest chunks should be returned")
    Test.eq(telemetry.chunkBuilds, 1, "chunk cache should avoid rebuild")
    Test.eq(telemetry.chunkCacheHits, 1, "chunk cache hit")
end)

Test.it("updates cached manifest by dirty block delta", function()
    local _addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local prof = seedProfession(data, localKey, "Alchemy", 93011, { sourceType = "owner" })

    data:BuildManifestCacheNow("initial")
    prof.recipes[93012] = true
    prof.count = 2
    prof.signature = "93011,93012"
    data:MarkManifestDirty(data:BuildSyncBlockKey(localKey, "Alchemy"), "delta")

    local manifest = data:BuildManifestCacheNow("delta")
    local block = manifest.blocks[data:BuildSyncBlockKey(localKey, "Alchemy")]
    local snapshot = data:GetManifestDebugSnapshot()

    Test.eq(block.count, 2, "dirty block count should update")
    Test.eq(manifest.totals.recipes, 2, "manifest totals should update")
    Test.eq(snapshot.telemetry.deltaBuilds, 1, "delta build telemetry")
end)

Test.it("removes stale blocks from cached manifest by delta", function()
    local _addon, _wow, data = freshAddon()
    local replicaKey = "Replicaone-Testrealm"
    seedProfession(data, replicaKey, "Tailoring", 93021, { sourceType = "replica" })

    data:BuildManifestCacheNow("initial")
    data:MarkMemberStale(replicaKey, 200)
    local manifest = data:BuildManifestCacheNow("stale")

    Test.eq(manifest.totals.blocks, 0, "stale member should leave active manifest")
    Test.falsy(manifest.blocks[data:BuildSyncBlockKey(replicaKey, "Tailoring")], "stale block should be removed")
end)

Test.it("defers manifest send until background cache build is ready", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 93031, { sourceType = "owner" })
    data:BuildManifestCacheNow("initial")

    local prof = data:GetMember(localKey).professions.Alchemy
    prof.recipes[93032] = true
    prof.count = 2
    prof.signature = "93031,93032"
    data:MarkManifestDirty(data:BuildSyncBlockKey(localKey, "Alchemy"), "dirty-send")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")
    Test.eq(#wow.GetSentComm(), 0, "dirty manifest should not send stale chunks")
    Test.truthy(addon.Sync.pendingManifestPeers["Peerone-Testrealm"], "peer should be queued for ready manifest")

    local manifest = data:BuildManifestCacheNow("ready")
    Test.eq(manifest.totals.recipes, 2, "fresh manifest should be ready")
    Test.eq(#wow.GetSentComm(), 0, "ready manifest should enqueue paced MANI chunks")
    Test.gte(#addon.Sync.manifestChunkQueue, 1, "ready manifest should queue MANI chunks")
    addon.Sync:SendNextLowPriorityChunk()
    Test.gte(#wow.GetSentComm(), 1, "paced MANI worker should send queued chunk")
    Test.eq(addon.Sync.telemetry.manifestDeferredSends, 1, "deferred send telemetry")
    Test.eq(addon.Sync.telemetry.manifestPendingFlushes, 1, "pending flush telemetry")
end)

Test.it("defers inline manifest compare fallback during warmup and replays it once the cache is ready", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local blockKey = data:BuildSyncBlockKey(peerKey, "Alchemy")

    addon.Sync:EnterWarmup("test", 12)
    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.7.0" }

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "MANI",
        manifestId = "peer-manifest-1",
        builtAt = time(),
        memberKey = peerKey,
        totals = { blocks = 1, recipes = 1 },
        seq = 1,
        total = 1,
        sender = peerKey,
        blocks = {
            {
                blockKey = blockKey,
                ownerCharacter = peerKey,
                professionKey = "Alchemy",
                revision = 3,
                lastUpdatedAt = 500,
                sourceType = "owner",
                guildStatus = "active",
                lastSeenInGuildAt = 500,
                count = 1,
                fingerprint = "peer-fingerprint",
            },
        },
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "warmup compare should not force inline fallback work")
    Test.truthy(addon.Sync._pendingManifestComparePeers[peerKey], "peer manifest compare should be queued for later")
    Test.eq(data:GetManifestDebugSnapshot().telemetry.syncFallbackDeferrals or 0, 1, "fallback deferral telemetry")

    addon.Sync.warmupUntil = 0
    addon.Sync.warmupReason = nil
    data:BuildManifestCacheNow("ready")

    Test.truthy(addon.Sync.pendingRequests[peerKey], "deferred peer compare should queue catch-up once the manifest cache is ready")
    Test.falsy(addon.Sync._pendingManifestComparePeers[peerKey], "pending compare queue should flush when the cache becomes ready")
end)

Test.it("paces queued manifest chunks for the same peer", function()
    local addon, wow, data = freshAddon()
    for index = 1, 30 do
        seedProfession(data, "Replica" .. tostring(index) .. "-Testrealm", "Alchemy", 94000 + index, { sourceType = "replica" })
    end
    data:BuildManifestCacheNow("many-blocks")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")

    Test.eq(#wow.GetSentComm(), 0, "manifest chunks should be queued, not sent inline")
    Test.eq(#addon.Sync.manifestChunkQueue, 2, "30 manifest blocks should produce two MANI chunks")
    Test.eq(addon.Sync.telemetry.manifestChunksQueued, 2, "queued chunk telemetry")

    addon.Sync:SendNextLowPriorityChunk()
    Test.eq(#wow.GetSentComm(), 1, "first MANI chunk should send")
    Test.eq(#addon.Sync.manifestChunkQueue, 1, "one MANI chunk should remain")

    addon.Sync:SendNextLowPriorityChunk()
    Test.eq(#wow.GetSentComm(), 1, "same-peer MANI pacing should delay immediate second send")

    wow.AdvanceTime(0.13)
    addon.Sync:SendNextLowPriorityChunk()
    Test.eq(#wow.GetSentComm(), 2, "second MANI chunk should send after pacing delay")
    Test.eq(#addon.Sync.manifestChunkQueue, 0, "manifest queue should drain")
end)

Test.it("caps trickle outbound diagnostics instead of appending forever across repeated compares", function()
    local addon, _wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local peerManifest = {
        memberKey = peerKey,
        blocks = {},
        totals = { blocks = 140, recipes = 140 },
    }

    data:BuildManifestCacheNow("trickle-cap")
    for index = 1, 140 do
        local ownerKey = "Replica" .. tostring(index) .. "-Testrealm"
        local blockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")
        peerManifest.blocks[blockKey] = {
            blockKey = blockKey,
            ownerCharacter = ownerKey,
            professionKey = "Alchemy",
            revision = index,
            lastUpdatedAt = 200 + index,
            sourceType = "replica",
            guildStatus = "active",
            lastSeenInGuildAt = 200 + index,
            count = 1,
            fingerprint = "fp-" .. tostring(index),
        }
    end

    local firstDepth = addon.TrickleSync:QueueMissingBlocksForPeer(peerKey, peerManifest)
    local firstQueueDepth = #(addon.TrickleSync.outboundQueue[peerKey] or {})

    addon.TrickleSync:QueueMissingBlocksForPeer(peerKey, peerManifest)
    local secondQueueDepth = #(addon.TrickleSync.outboundQueue[peerKey] or {})

    Test.eq(firstDepth, firstQueueDepth, "reported depth should match stored queue depth")
    Test.truthy(firstQueueDepth <= 96, "diagnostic queue should stay bounded per peer")
    Test.eq(secondQueueDepth, firstQueueDepth, "repeated compares should replace the diagnostic queue instead of appending")
    Test.gte(addon.TrickleSync.telemetry.queueCapHits or 0, 1, "queue cap should be hit for oversized compare sets")
    Test.gte(addon.TrickleSync.telemetry.queueCapDrops or 0, 1, "queue cap drops should be counted")
end)

Test.it("skips re-announcing an unchanged manifest to the same peer until a force refresh is requested", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 94041, { sourceType = "owner" })
    data:BuildManifestCacheNow("steady-state")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "auto-tick")
    Test.eq(#addon.Sync.manifestChunkQueue, 1, "first manifest should queue")
    wow.AdvanceTime(0.5)
    addon.Sync:SendNextLowPriorityChunk()
    Test.eq(#wow.GetSentComm(), 1, "first manifest should send")

    wow.AdvanceTime(25)
    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "auto-tick")
    Test.eq(#addon.Sync.manifestChunkQueue, 0, "unchanged manifest should not requeue")
    Test.eq(#wow.GetSentComm(), 1, "unchanged manifest should not resend")
    Test.eq(addon.Sync.telemetry.manifestUnchangedSkips, 1, "unchanged manifest skip telemetry")

    addon.Sync:SendManifestToPeer("Peerone-Testrealm", "force")
    Test.eq(#addon.Sync.manifestChunkQueue, 1, "force refresh should bypass unchanged skip")
end)

Test.it("forgets the last announced manifest after a peer times out", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local peerKey = "Peerone-Testrealm"
    seedProfession(data, localKey, "Alchemy", 94051, { sourceType = "owner" })
    data:BuildManifestCacheNow("timeout-reset")

    addon.Sync:TouchNode(peerKey, "1.0")
    addon.Sync:SendManifestToPeer(peerKey, "hello")
    wow.AdvanceTime(0.5)
    addon.Sync:SendNextLowPriorityChunk()
    Test.eq(#wow.GetSentComm(), 1, "initial manifest should send")

    wow.AdvanceTime(120)
    addon.Sync:PruneOnlineNodes()
    Test.falsy(addon.Sync.onlineNodes[peerKey], "peer should time out")

    addon.Sync:SendManifestToPeer(peerKey, "hello")
    Test.eq(#addon.Sync.manifestChunkQueue, 1, "timed-out peer should be allowed to receive the same manifest again")
end)

Test.it("keeps bootstrap completeness safe when manifest fallback is deferred during warmup", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 94061, { sourceType = "owner" })

    addon.Sync:EnterWarmup("test", 12)

    local blockCount, recipeCount = data:GetDatasetCompletenessEstimate()
    Test.eq(blockCount, 1, "dataset completeness should fall back to active local blocks when manifest cache is deferred")
    Test.eq(recipeCount, 1, "dataset completeness should fall back to active local recipe counts when manifest cache is deferred")

    local ok, uiState = pcall(function()
        return addon.BootstrapSync:GetUiState()
    end)
    Test.truthy(ok, "bootstrap UI state should not error when manifest completeness is requested during warmup")
    Test.truthy(type(uiState) == "table", "bootstrap UI state should still be returned")
    Test.falsy(uiState.canBootstrap, "non-empty local data should not look bootstrap-needed just because the manifest cache is deferred")
end)

Test.it("retries targeted manifest refreshes on later hello sessions until a manifest arrives", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-Testrealm"

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 500,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 0, "first hello should not trigger an immediate targeted manifest refresh")

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 501,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 1, "the next hello without any manifest should trigger the first targeted refresh")

    wow.AdvanceTime(31)
    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 502,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 2, "a later hello without any received manifest should retry the targeted refresh after cooldown")

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "MANI",
        manifestId = "peer-manifest-1",
        builtAt = 900,
        memberKey = peerKey,
        totals = { blocks = 0, recipes = 0 },
        seq = 1,
        total = 1,
        blocks = {},
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    wow.AdvanceTime(31)
    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 503,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 2, "once a manifest arrives, later hellos should not keep forcing refreshes")

    wow.AdvanceTime(120)
    addon.Sync:PruneOnlineNodes()
    Test.falsy(addon.Sync.onlineNodes[peerKey], "peer should time out between hello sessions")

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 504,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 2, "the first hello of a new session should stay quiet until a later refresh is actually needed")
end)

Test.it("suppresses hello-driven manifest refreshes while a partial receive is already active", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local blockKey = data:BuildSyncBlockKey(peerKey, "Alchemy")

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 500,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "MANI",
        manifestId = "peer-manifest-partial",
        builtAt = 510,
        memberKey = peerKey,
        sender = peerKey,
        totals = { blocks = 2, recipes = 2 },
        seq = 1,
        total = 2,
        blocks = {
            {
                blockKey = blockKey,
                ownerCharacter = peerKey,
                professionKey = "Alchemy",
                revision = 5,
                lastUpdatedAt = 500,
                sourceType = "owner",
                guildStatus = "active",
                lastSeenInGuildAt = 500,
                count = 1,
                fingerprint = "peer-fingerprint",
            },
        },
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    wow.AdvanceTime(31)
    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        rev = 5,
        updatedAt = 501,
        sender = peerKey,
        version = "1.6.0",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.eq(countCommKind(wow, "MREQ"), 0, "later hello should not request another manifest while a partial batch is still active")
end)

Test.it("wiping the database clears sync session state and requests a fresh guild resync", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local blockKey = data:BuildSyncBlockKey(peerKey, "Alchemy")

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.6.0" }
    addon.Sync.registry[peerKey] = { owner = peerKey, rev = 7, updatedAt = 700 }
    addon.Sync.pendingRequests[peerKey] = {
        source = peerKey,
        memberKey = peerKey,
        rev = 7,
        why = "test",
        queuedAt = time(),
    }
    addon.Sync.partialReceive[peerKey] = {
        memberKey = peerKey,
        source = peerKey,
        rev = 7,
        total = 1,
        seen = {},
    }
    addon.Sync.partialManifestReceive[peerKey] = {
        stale = {
            manifestId = "stale",
            memberKey = peerKey,
            total = 1,
            seen = {},
            blocks = {},
        },
    }
    addon.Sync.outgoingSessions["wipe-test"] = {
        memberKey = peerKey,
        targetKey = peerKey,
        rev = 7,
        total = 1,
        chunks = {},
    }
    addon.Sync.outboundChunkQueue = {
        { peer = peerKey, block = { key = peerKey } },
    }
    addon.Sync.manifestChunkQueue = {
        { peer = peerKey, payload = { memberKey = data:GetPlayerKey() } },
    }
    addon.Sync.inFlight = {
        source = peerKey,
        memberKey = peerKey,
        rev = 7,
    }
    addon.Sync._lastManifestSentAt[peerKey] = time()
    addon.Sync._lastManifestAnnouncedId[peerKey] = "known-manifest"
    addon.Sync._helloManifestRefreshRequested[peerKey] = time()
    addon.Sync.pendingManifestPeers[peerKey] = "hello"
    addon.Sync.manifestCatchupQueue = {
        {
            senderKey = peerKey,
            ownerCharacter = peerKey,
            revision = 7,
            blockKeys = { blockKey },
        },
    }
    addon.Sync._manifestCatchupJobActive = true

    data:WipeDatabase()

    Test.eq(countCommKind(wow, "MREQ"), 1, "wipe should immediately request fresh manifests from the guild")
    Test.eq(Test.countKeys(addon.Sync.onlineNodes), 0, "wipe should clear cached online nodes")
    Test.eq(Test.countKeys(addon.Sync.registry), 0, "wipe should clear revision hints")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "wipe should clear queued requests")
    Test.eq(Test.countKeys(addon.Sync.partialReceive), 0, "wipe should clear partial snapshot state")
    Test.eq(Test.countKeys(addon.Sync.partialManifestReceive), 0, "wipe should clear partial manifest state")
    Test.falsy(addon.Sync.inFlight, "wipe should clear in-flight requests")
    Test.falsy(addon.Sync._helloManifestRefreshRequested[peerKey], "wipe should forget per-peer manifest refresh state")
    Test.eq(#addon.Sync.manifestCatchupQueue, 0, "wipe should clear deferred manifest catch-up work")

    wow.RunTimers(2)
    Test.eq(countCommKind(wow, "HELLO"), 1, "wipe should schedule a fresh hello broadcast")
end)

Test.it("prunes stale partial manifest and trickle peer state on the periodic prune pass", function()
    local addon, _wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time() - 200, version = "1.6.0" }
    addon.Sync.partialManifestReceive[peerKey] = {
        stale = {
            manifestId = "stale",
            memberKey = peerKey,
            builtAt = time() - 200,
            total = 1,
            seen = {},
            blocks = {},
        },
    }
    addon.TrickleSync.peerState[peerKey] = {
        manifest = {
            memberKey = peerKey,
            blocks = {
                [data:BuildSyncBlockKey(peerKey, "Alchemy")] = {
                    ownerCharacter = peerKey,
                    professionKey = "Alchemy",
                },
            },
        },
        lastManifestAt = time() - 200,
        queuedBlocks = 1,
    }
    addon.TrickleSync.outboundQueue[peerKey] = {
        data:BuildSyncBlockKey(peerKey, "Alchemy"),
    }

    addon.Sync:PruneState()

    Test.eq(Test.countKeys(addon.Sync.onlineNodes), 0, "stale online node should be pruned")
    Test.eq(Test.countKeys(addon.Sync.partialManifestReceive), 0, "stale partial manifest receive should be pruned")
    Test.eq(Test.countKeys(addon.TrickleSync.peerState), 0, "stale trickle peer state should be pruned")
    Test.eq(Test.countKeys(addon.TrickleSync.outboundQueue), 0, "stale trickle outbound queue should be pruned")
    Test.eq(addon.Sync.telemetry.prunedPartialManifestReceives or 0, 1, "partial manifest prune telemetry")
    Test.eq(addon.Sync.telemetry.prunedTricklePeerState or 0, 1, "trickle peer prune telemetry")
    Test.eq(addon.Sync.telemetry.prunedTrickleOutboundQueues or 0, 1, "trickle outbound prune telemetry")
end)

io.write(string.format("Manifest cache: %d test(s) passed\n", Test.count))
