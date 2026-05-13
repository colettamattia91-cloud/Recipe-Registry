local Loader = dofile("local-tests/harness/load-addon.lua")
local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local PROFESSIONS = {
    "Alchemy",
    "Blacksmithing",
    "Cooking",
    "Enchanting",
    "Engineering",
    "Jewelcrafting",
    "Leatherworking",
    "Tailoring",
}

local function freshAddon(opts)
    local addon, wow = Loader.Load(opts)
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function countCommKind(wow, kind)
    local count = 0
    for _, row in ipairs(wow.GetSentComm()) do
        local payload = row.message
        if type(payload) == "table" and payload.kind == kind then
            count = count + 1
        elseif type(payload) == "string" then
            local ok, decoded = LibStub("AceSerializer-3.0"):Deserialize(payload)
            if ok and type(decoded) == "table" and decoded.kind == kind then
                count = count + 1
            end
        end
    end
    return count
end

local function runOpts(overrides)
    local opts = {
        maxTicks = 1600,
        tickSeconds = 0.5,
        perfRuns = 4,
        inboundRuns = 4,
        timerRuns = 40,
        transportFlushThreshold = 16,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

local function seedReplicaManifestBlocks(data, count, opts)
    opts = opts or {}
    local prefix = opts.prefix or "Replica"
    local realm = opts.realm or "TestRealm"
    local recipeBase = opts.recipeBase or 300000
    local updatedAtBase = opts.updatedAtBase or 5000
    local revBase = opts.revBase or 800
    local reason = opts.reason or "manifest-bulk-seed"
    local sourceType = opts.sourceType or "replica"

    for index = 1, count do
        local ownerKey = string.format("%s%03d-%s", prefix, index, realm)
        local profession = PROFESSIONS[((index - 1) % #PROFESSIONS) + 1]
        local recipeKey = recipeBase + index
        local updatedAt = updatedAtBase + index
        local rev = revBase + index
        local entry = data:GetOrCreateMember(ownerKey)

        entry.owner = ownerKey
        entry.rev = rev
        entry.updatedAt = updatedAt
        entry.sourceType = sourceType
        entry.guildStatus = "active"
        entry.lastSeenInGuildAt = updatedAt
        entry.professions[profession] = {
            recipes = { [recipeKey] = true },
            count = 1,
            signature = tostring(recipeKey),
            blockRevision = rev,
            lastUpdatedAt = updatedAt,
            sourceType = sourceType,
            guildStatus = "active",
            lastSeenInGuildAt = updatedAt,
        }
        data:NormalizeMemberEntry(entry, ownerKey)
        data:MarkManifestDirty(data:BuildSyncBlockKey(ownerKey, profession), reason)
    end

    data:BuildManifestCacheNow(reason)
end

io.write("Manifest chunk reliability\n")

Test.it("uses receiver-side manifest progress timestamps for prune timeout and requests recovery after timeout", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local manifestId = "Peerone-Testrealm:100:1:3"

    addon.Sync:HandleManifestChunk({
        sender = peerKey,
        manifestId = manifestId,
        seq = 1,
        total = 3,
        builtAt = time() - 120,
        memberKey = peerKey,
        totals = { blocks = 3, recipes = 3 },
        blocks = {
            {
                blockKey = "Peerone-Testrealm::Alchemy",
                ownerCharacter = peerKey,
                professionKey = "Alchemy",
                revision = 10,
                lastUpdatedAt = 100,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "fp-1",
            },
        },
    })

    local state = addon.Sync.partialManifestReceive[peerKey] and addon.Sync.partialManifestReceive[peerKey][manifestId]
    Test.truthy(state, "partial manifest should be tracked after the first chunk")
    addon.Sync:PrunePartialManifestReceives()
    Test.truthy(addon.Sync.partialManifestReceive[peerKey] and addon.Sync.partialManifestReceive[peerKey][manifestId], "old sender builtAt alone should not prune a fresh partial manifest")

    wow.AdvanceTime(61)
    addon.Sync:PrunePartialManifestReceives()

    local diag = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestId, "receive")
    Test.falsy(addon.Sync.partialManifestReceive[peerKey], "stalled partial manifest should prune after receiver-side timeout")
    Test.eq(countCommKind(wow, "MREQ"), 1, "timed-out partial manifests should request a fresh manifest")
    Test.truthy(diag and diag.pruned, "diagnostics should remember that the partial manifest was pruned")
    Test.eq(diag and diag.pruneReason, "timeout", "prune reason should be recorded")
    Test.eq(diag and diag.receivedSeqCount, 1, "diagnostics should preserve received sequence count")
    Test.eq(diag and #(diag.missingSeqs or {}), 2, "diagnostics should preserve missing sequence information")
end)

Test.it("requeues failed MANI sends and only counts successful chunk sends", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"

    seedReplicaManifestBlocks(data, 30, {
        reason = "mani-send-failure",
        recipeBase = 310000,
    })

    addon.Sync:SendManifestToPeer(peerKey, "force")
    Test.eq(#addon.Sync.manifestChunkQueue, 2, "30 manifest blocks should queue two MANI chunks")

    local manifestId = addon.Sync.manifestChunkQueue[1].payload.manifestId
    local diag = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestId, "send")
    local originalSendDirectEnvelope = addon.Sync.SendDirectEnvelope
    addon.Sync.SendDirectEnvelope = function()
        return false
    end

    Test.falsy(addon.Sync:SendNextManifestChunk(), "failed MANI send should return false")
    Test.eq(#addon.Sync.manifestChunkQueue, 2, "failed MANI send should remain queued")
    Test.eq(addon.Sync.telemetry.manifestChunksSent or 0, 0, "failed MANI sends must not count as sent")
    Test.eq(addon.Sync.telemetry.manifestChunkSendFailures or 0, 1, "failed MANI send should increment failure telemetry")
    Test.eq(diag and diag.sendAttemptedChunks, 1, "send attempt diagnostics should increment")
    Test.eq(diag and diag.sendFailedChunks, 1, "failed send diagnostics should increment")
    Test.eq(diag and diag.queuedChunks, 2, "failed send should not drain the queued count")

    addon.Sync.SendDirectEnvelope = originalSendDirectEnvelope
    wow.AdvanceTime(0.13)

    Test.truthy(addon.Sync:SendNextManifestChunk(), "requeued MANI chunk should send once the transport accepts it")
    Test.eq(#addon.Sync.manifestChunkQueue, 1, "successful retry should drain one queued MANI chunk")
    Test.eq(addon.Sync.telemetry.manifestChunksSent or 0, 1, "successful retry should count as a sent MANI chunk")
    Test.eq(diag and diag.sendSucceededChunks, 1, "successful retry should update send diagnostics")
    Test.eq(diag and diag.queuedChunks, 1, "queued chunk count should shrink only on success")
    Test.eq(countCommKind(wow, "MANI"), 1, "exactly one MANI chunk should be emitted after the retry succeeds")
end)

Test.it("coalesces duplicate MANI batches for the same peer and manifestId", function()
    local addon, _wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"

    seedReplicaManifestBlocks(data, 50, {
        reason = "mani-coalesce",
        recipeBase = 320000,
    })

    local chunks = addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "mani-coalesce",
    })

    addon.Sync:SendManifestToPeer(peerKey, "force")
    addon.Sync:SendManifestToPeer(peerKey, "force")

    local manifestId = chunks[1].manifestId
    local diag = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestId, "send")
    Test.eq(#addon.Sync.manifestChunkQueue, #chunks, "duplicate sends should keep only one queued batch per peer and manifestId")
    Test.eq(addon.Sync.telemetry.manifestChunkBatchesCoalesced or 0, 1, "coalesced duplicate MANI batches should be counted")
    Test.eq(diag and diag.totalChunks, #chunks, "send diagnostics should track the batch size")
    Test.eq(diag and diag.queuedChunks, #chunks, "send diagnostics should reflect the coalesced queued chunk count")
end)

Test.it("records compare diagnostics after a manifest completes out of order", function()
    local addon, _wow, _data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local manifestId = "Peerone-Testrealm:200:2:2"

    addon.Sync:HandleManifestChunk({
        sender = peerKey,
        manifestId = manifestId,
        seq = 2,
        total = 2,
        builtAt = 200,
        memberKey = peerKey,
        totals = { blocks = 2, recipes = 2 },
        blocks = {
            {
                blockKey = "Peerone-Testrealm::Cooking",
                ownerCharacter = peerKey,
                professionKey = "Cooking",
                revision = 12,
                lastUpdatedAt = 201,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "fp-2",
            },
        },
    })

    local diag = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestId, "receive")
    Test.eq(diag and diag.receivedSeqCount, 1, "receive diagnostics should track partial sequence count")
    Test.eq(diag and #(diag.missingSeqs or {}), 1, "receive diagnostics should report missing sequences while incomplete")
    Test.eq(diag and diag.missingSeqs[1], 1, "the first sequence should be reported missing")

    addon.Sync:HandleManifestChunk({
        sender = peerKey,
        manifestId = manifestId,
        seq = 1,
        total = 2,
        builtAt = 200,
        memberKey = peerKey,
        totals = { blocks = 2, recipes = 2 },
        blocks = {
            {
                blockKey = "Peerone-Testrealm::Alchemy",
                ownerCharacter = peerKey,
                professionKey = "Alchemy",
                revision = 11,
                lastUpdatedAt = 200,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "fp-1",
            },
        },
    })

    diag = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestId, "receive")
    Test.truthy(diag and diag.completed, "completed manifests should be marked in diagnostics")
    Test.truthy(diag and diag.compareFired, "compare diagnostics should be flagged after manifest completion")
    Test.eq(diag and diag.receivedSeqCount, 2, "completed manifest should report all sequences")
    Test.eq(diag and #(diag.missingSeqs or {}), 0, "completed manifest should no longer report missing sequences")
end)

Test.it("completes a large MANI batch after requester wipe and produces catch-up candidates", function()
    local blockCount = 420
    local bus = CommBus.CreatePeers(2, {
        prefix = "Relipeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
    })
    local source = bus.nodes[1]
    local requester = bus.nodes[2]

    bus:Activate(source)
    seedReplicaManifestBlocks(source.addon.Data, blockCount, {
        prefix = "Wipedowner",
        realm = "TestRealm",
        recipeBase = 330000,
        reason = "large-post-wipe",
    })

    local chunks = source.addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "large-post-wipe",
    })
    local manifestId = chunks[1].manifestId

    Test.truthy(#chunks >= 17 and #chunks <= 22, "large manifest should span the expected number of MANI chunks")

    bus:Activate(requester)
    requester.addon.Data:WipeDatabase()

    bus:Activate(source)
    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local converged = bus:RunUntil(function()
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return diag
            and diag.completed
            and diag.compareFired
            and (requester.addon.Sync.telemetry.manifestCatchupCandidates or 0) >= blockCount
            and (requester.addon.Sync.telemetry.manifestCatchupQueued or 0) > 0
    end, runOpts({
        maxTicks = 1200,
    }))

    local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
    Test.truthy(converged, "large post-wipe MANI exchange should complete and drive catch-up planning")
    Test.truthy(diag and diag.completed, "large MANI diagnostics should report completion")
    Test.truthy(diag and diag.compareFired, "large MANI diagnostics should report compare execution")
    Test.eq(diag and diag.totalChunks, #chunks, "large MANI diagnostics should preserve chunk totals")
    Test.gte(bus.stats.sentKinds.MANI or 0, #chunks, "large MANI scenario should emit the expected chunk traffic")
    Test.gte(requester.addon.Sync.telemetry.manifestCatchupQueued or 0, 1, "manifest completion after wipe should queue follow-up catch-up work")
end)

io.write(string.format("Manifest chunk reliability: %d test(s) passed\n", Test.count))
