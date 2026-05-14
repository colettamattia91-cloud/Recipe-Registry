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

local function sentPayloadsByKind(wow, kind)
    local rows = {}
    for _, row in ipairs(wow.GetSentComm()) do
        local payload = row.message
        if type(payload) == "string" then
            local ok, decoded = LibStub("AceSerializer-3.0"):Deserialize(payload)
            if ok and type(decoded) == "table" then
                payload = decoded
            end
        end
        if type(payload) == "table" and payload.kind == kind then
            rows[#rows + 1] = payload
        end
    end
    return rows
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

local function seedReplicaManifestBlock(data, ownerKey, profession, recipeKey, opts)
    opts = opts or {}
    local updatedAt = opts.updatedAt or 9000
    local rev = opts.rev or 1200
    local reason = opts.reason or "manifest-single-seed"
    local sourceType = opts.sourceType or "replica"
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
    data:BuildManifestCacheNow(reason)
end

local function countPartialManifestOpen(sync, peerKey)
    if peerKey then
        local manifests = sync.partialManifestReceive and sync.partialManifestReceive[peerKey] or nil
        local count = 0
        for _ in pairs(manifests or {}) do
            count = count + 1
        end
        return count
    end

    local total = 0
    for _, manifests in pairs(sync.partialManifestReceive or {}) do
        for _ in pairs(manifests or {}) do
            total = total + 1
        end
    end
    return total
end

local function queuedManifestIdsForPeer(sync, peerKey)
    local seen = {}
    local ids = {}
    for _, queued in ipairs(sync.manifestChunkQueue or {}) do
        local payload = queued and queued.payload or nil
        local manifestId = payload and payload.manifestId or nil
        if queued and queued.peer == peerKey and manifestId and not seen[manifestId] then
            seen[manifestId] = true
            ids[#ids + 1] = manifestId
        end
    end
    table.sort(ids)
    return ids
end

io.write("Manifest chunk reliability\n")

Test.it("uses receiver-side manifest progress timestamps for soft timeout recovery before hard prune", function()
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
    local mreqs = sentPayloadsByKind(wow, "MREQ")
    Test.truthy(addon.Sync.partialManifestReceive[peerKey] and addon.Sync.partialManifestReceive[peerKey][manifestId], "first timeout should keep the partial manifest open for missing-seq recovery")
    Test.eq(countCommKind(wow, "MREQ"), 1, "timed-out partial manifests should emit one recovery request")
    Test.eq(mreqs[1] and mreqs[1].reason, "manifest-missing-seqs", "recovery request should use the missing-seqs reason")
    Test.eq(mreqs[1] and mreqs[1].manifestId, manifestId, "recovery request should include the manifestId")
    Test.eq(mreqs[1] and #(mreqs[1].missingSeqs or {}), 2, "recovery request should include the missing sequences")
    Test.eq(mreqs[1] and mreqs[1].missingSeqs[1], 2, "recovery request should ask for seq=2 first")
    Test.eq(addon.Sync.telemetry.manifestSoftTimeouts or 0, 1, "soft timeout telemetry should increment")
    Test.eq(addon.Sync.telemetry.manifestPartialTimeouts or 0, 1, "partial manifest timeout telemetry should increment")
    Test.eq(addon.Sync.telemetry.manifestRecoveryRequests or 0, 1, "manifest recovery telemetry should increment")
    Test.eq(addon.Sync.telemetry.manifestMissingSeqRequests or 0, 1, "missing seq request telemetry should increment")
    Test.eq(addon.Sync.telemetry.lastManifestPruneReason, nil, "soft timeout should not record a prune reason yet")
    Test.eq(addon.Sync.telemetry.lastManifestRecoveryPeer, peerKey, "last recovery peer telemetry should update")
    Test.eq(addon.Sync.telemetry.lastManifestRecoveryId, manifestId, "last recovery manifest telemetry should update")
    Test.falsy(diag and diag.pruned, "soft timeout should not mark the partial as pruned")
    Test.truthy(diag and diag.recoveryRequested, "diagnostics should remember that recovery was requested")
    Test.eq(diag and diag.receivedSeqCount, 1, "diagnostics should preserve received sequence count")
    Test.eq(diag and #(diag.missingSeqs or {}), 2, "diagnostics should preserve missing sequence information")

    wow.AdvanceTime(61)
    addon.Sync:PrunePartialManifestReceives()

    diag = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestId, "receive")
    Test.falsy(addon.Sync.partialManifestReceive[peerKey], "stalled partial manifest should hard-prune after recovery grace expires")
    Test.eq(addon.Sync.telemetry.manifestHardPrunes or 0, 1, "hard prune telemetry should increment")
    Test.eq(addon.Sync.telemetry.manifestPartialPrunes or 0, 1, "legacy partial prune telemetry should still increment on hard prune")
    Test.eq(addon.Sync.telemetry.lastManifestPruneReason, "timeout", "hard prune should record timeout as the prune reason")
    Test.truthy(diag and diag.pruned, "diagnostics should remember the eventual hard prune")
    Test.eq(diag and diag.pruneReason, "timeout", "hard prune reason should be recorded")
end)

Test.it("lets missing-seq manifest recovery bypass peer backoff and quarantine", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-Testrealm"
    local manifestId = "Peerone-Testrealm:101:1:3"

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = addon.ADDON_VERSION }
    addon.Sync.peerBackoffUntil[peerKey] = time() + 120
    addon.Sync.peerHealth[peerKey] = addon.Sync.peerHealth[peerKey] or {}
    addon.Sync.peerHealth[peerKey].snapshotQuarantineUntil = time() + 120

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
                revision = 11,
                lastUpdatedAt = 101,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "fp-1",
            },
        },
    })

    wow.AdvanceTime(61)
    addon.Sync:PrunePartialManifestReceives()

    local mreqs = sentPayloadsByKind(wow, "MREQ")
    Test.eq(#mreqs, 1, "soft timeout should still send a missing-seq recovery request while peer health is degraded")
    Test.eq(mreqs[1] and mreqs[1].reason, "manifest-missing-seqs", "recovery request should keep the targeted missing-seqs reason")
    Test.eq(addon.Sync.peerBackoffUntil[peerKey], nil, "targeted recovery should clear peer backoff so the reply path can resume")
    Test.eq(addon.Sync.peerHealth[peerKey] and addon.Sync.peerHealth[peerKey].snapshotQuarantineUntil or 0, 0, "targeted recovery should clear snapshot quarantine")
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
    Test.eq(addon.Sync.telemetry.manifestChunkSendRetries or 0, 1, "retry telemetry should count the resent MANI chunk")
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

Test.it("recovers a 12 chunk manifest by requesting and resending only the missing seq", function()
    local blockCount = 288
    local bus = CommBus.CreatePeers(2, {
        prefix = "Targetedpeer",
        transportProfile = "instant",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local source = bus.nodes[1]
    local requester = bus.nodes[2]
    local droppedSeq2 = false
    local recoveryRequest
    local resentSeq2 = 0

    bus:Activate(source)
    seedReplicaManifestBlocks(source.addon.Data, blockCount, {
        prefix = "Targetedowner",
        realm = "TestRealm",
        recipeBase = 342000,
        reason = "targeted-missing-seq",
    })

    local chunks = source.addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "targeted-missing-seq",
    })
    local manifestId = chunks[1].manifestId

    Test.eq(#chunks, 12, "288 block manifest should produce exactly 12 MANI chunks")

    bus:SetRouteHook(function(_bus, sender, target, _row, payload)
        if sender == requester and target == source and payload.kind == "MREQ" and payload.manifestId == manifestId then
            recoveryRequest = payload
            return
        end
        if sender == source and target == requester and payload.kind == "MANI" and payload.manifestId == manifestId then
            if payload.seq == 2 and not droppedSeq2 then
                droppedSeq2 = true
                return "drop"
            end
            if recoveryRequest and payload.seq == 2 then
                resentSeq2 = resentSeq2 + 1
            end
        end
    end)

    bus:Activate(source)
    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local recovered = bus:RunUntil(function(current)
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return recoveryRequest
            and resentSeq2 == 1
            and diag
            and diag.completed
            and diag.compareFired
            and diag.receivedSeqCount == #chunks
            and #(diag.missingSeqs or {}) == 0
            and (requester.addon.Sync.telemetry.manifestCatchupCandidates or 0) > 0
    end, runOpts({
        maxTicks = 1000,
        tickSeconds = 0.5,
    }))

    Test.truthy(recovered, "receiver should recover the single missing manifest seq and complete the batch")
    Test.truthy(recoveryRequest, "soft timeout should emit a targeted recovery request")
    Test.eq(recoveryRequest and recoveryRequest.reason, "manifest-missing-seqs", "recovery request should use the missing-seqs reason")
    Test.eq(recoveryRequest and recoveryRequest.manifestId, manifestId, "recovery request should target the same manifestId")
    Test.eq(recoveryRequest and #(recoveryRequest.missingSeqs or {}), 1, "recovery request should ask for only one missing seq")
    Test.eq(recoveryRequest and recoveryRequest.missingSeqs[1], 2, "recovery request should ask for seq=2")
    Test.eq(resentSeq2, 1, "sender should resend only the requested missing seq")
    Test.eq(requester.addon.Sync.telemetry.manifestSoftTimeouts or 0, 1, "soft timeout telemetry should increment once")
    Test.eq(requester.addon.Sync.telemetry.manifestMissingSeqRequests or 0, 1, "missing seq request telemetry should increment once")
    Test.eq(source.addon.Sync.telemetry.manifestMissingSeqChunksSent or 0, 1, "sender should count the targeted resend chunk")
    Test.eq(requester.addon.Sync.telemetry.manifestMissingSeqRecovered or 0, 1, "targeted recovery should count as recovered")
    Test.eq(requester.addon.Sync.telemetry.manifestRecoveryCompleted or 0, 1, "recovery completion telemetry should increment")
end)

Test.it("recovers large 17 chunk manifest after receiving only one chunk first", function()
    local blockCount = 385
    local bus = CommBus.CreatePeers(2, {
        prefix = "Ghostpeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local source = bus.nodes[1]
    local requester = bus.nodes[2]
    local initialChunkDelivered = false
    local initialDrops = 0
    local recoveryMreqs = 0
    local recoveryManifestChunks = 0

    bus:Activate(source)
    seedReplicaManifestBlocks(source.addon.Data, blockCount, {
        prefix = "Ghostowner",
        realm = "TestRealm",
        recipeBase = 340000,
        reason = "ghost-shape",
    })

    local chunks = source.addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "ghost-shape",
    })
    local manifestId = chunks[1].manifestId

    Test.eq(#chunks, 17, "385 block manifest should produce exactly 17 MANI chunks")

    bus:SetRouteHook(function(_bus, sender, target, row, payload)
        if sender == requester and target == source and payload.kind == "MREQ" then
            recoveryMreqs = recoveryMreqs + 1
            return
        end

        if sender == source and target == requester and payload.kind == "MANI" and payload.manifestId == manifestId then
            if not initialChunkDelivered then
                initialChunkDelivered = true
                local mutated = {}
                for key, value in pairs(payload) do
                    mutated[key] = value
                end
                mutated.builtAt = (payload.builtAt or time()) - 120
                row.message = LibStub("AceSerializer-3.0"):Serialize(mutated)
                payload.builtAt = mutated.builtAt
                return
            end
            if recoveryMreqs == 0 then
                initialDrops = initialDrops + 1
                return "drop"
            end
            recoveryManifestChunks = recoveryManifestChunks + 1
        end
    end)

    bus:Activate(source)
    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local heldOpen = bus:RunUntil(function()
        if not initialChunkDelivered then
            return false
        end
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return diag
            and diag.receivedSeqCount == 1
            and initialDrops >= (#chunks - 1)
            and countPartialManifestOpen(requester.addon.Sync, source.key) == 1
            and (requester.addon.Sync.telemetry.manifestRecoveryRequests or 0) == 0
    end, runOpts({
        maxTicks = 80,
        tickSeconds = 0.5,
    }))

    Test.truthy(heldOpen, "single-chunk partial should remain open before receiver-side timeout")
    Test.truthy(initialDrops >= 16, "all remaining chunks from the first batch should be held back")
    Test.eq(requester.addon.Sync.telemetry.manifestPartialTimeouts or 0, 0, "receiver should not timeout before its own progress clock expires")
    Test.eq(requester.addon.Sync.telemetry.lastManifestPruneReason, nil, "no prune reason should be recorded before timeout")

    local recovered = bus:RunUntil(function(current)
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return recoveryMreqs >= 1
            and recoveryManifestChunks >= (#chunks - 1)
            and diag
            and diag.completed
            and diag.compareFired
            and diag.receivedSeqCount == #chunks
            and #(diag.missingSeqs or {}) == 0
            and countPartialManifestOpen(requester.addon.Sync, source.key) == 0
            and (requester.addon.Sync.telemetry.manifestCatchupCandidates or 0) > 0
            and (requester.addon.Sync.telemetry.manifestCatchupQueued or 0) > 0
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 1000,
        tickSeconds = 0.5,
    }))

    local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
    Test.truthy(recovered, "incomplete large MANI should recover, complete, and generate catch-up work")
    Test.eq(requester.addon.Sync.telemetry.manifestPartialTimeouts or 0, 1, "receiver-side timeout should be counted once")
    Test.eq(requester.addon.Sync.telemetry.manifestRecoveryRequests or 0, 1, "recovery MREQ should be counted once")
    Test.eq(requester.addon.Sync.telemetry.manifestMissingSeqRequests or 0, 1, "large recovery should use one missing-seq request")
    Test.eq(requester.addon.Sync.telemetry.manifestPartialRecovered or 0, 1, "recovered manifest completion should be counted")
    Test.eq(requester.addon.Sync.telemetry.manifestReceiveCompleted or 0, 1, "manifest completion should be counted")
    Test.eq(requester.addon.Sync.telemetry.manifestCompareFired or 0, 1, "manifest compare should fire exactly once for the recovered manifest")
    Test.eq(requester.addon.Sync.telemetry.lastManifestPruneReason, nil, "soft recovery should complete without hard-pruning the partial")
    Test.eq(requester.addon.Sync.telemetry.lastManifestRecoveryPeer, source.key, "recovery telemetry should record the source peer")
    Test.eq(requester.addon.Sync.telemetry.lastManifestRecoveryId, manifestId, "recovery telemetry should record the manifestId")
    Test.eq(recoveryMreqs, 1, "recovery should emit only one targeted MREQ for the stalled manifest")
    Test.truthy(diag and diag.recoveryRequested, "batch diagnostics should remember that recovery was requested")
    Test.truthy(diag and diag.completed, "recovered manifest diagnostics should report completion")
    Test.truthy(diag and diag.compareFired, "recovered manifest diagnostics should report compare execution")
    Test.lte(bus.stats.sentKinds.MANI or 0, (#chunks * 2) + 1, "recovery should not loop into unbounded MANI re-announces")
end)

Test.it("late duplicate chunks for a completed manifestId do not reopen partial state or rerun compare", function()
    local blockCount = 288
    local bus = CommBus.CreatePeers(2, {
        prefix = "Completedpeer",
        transportProfile = "instant",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local source = bus.nodes[1]
    local requester = bus.nodes[2]

    bus:Activate(source)
    seedReplicaManifestBlocks(source.addon.Data, blockCount, {
        prefix = "Completedowner",
        realm = "TestRealm",
        recipeBase = 343000,
        reason = "completed-duplicate",
    })

    local chunks = source.addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "completed-duplicate",
    })
    local manifestId = chunks[1].manifestId

    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local completed = bus:RunUntil(function(current)
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return diag
            and diag.completed
            and diag.compareFired
            and countPartialManifestOpen(requester.addon.Sync, source.key) == 0
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 600,
        tickSeconds = 0.25,
    }))

    Test.truthy(completed, "baseline manifest should complete before duplicate chunks are injected")
    local compareBefore = requester.addon.Sync.telemetry.manifestCompareFired or 0
    local recoveryBefore = requester.addon.Sync.telemetry.manifestRecoveryRequests or 0
    local pruneBefore = requester.addon.Sync.telemetry.manifestHardPrunes or 0

    bus:Activate(requester)
    requester.addon.Sync:HandleManifestChunk({
        sender = source.key,
        manifestId = manifestId,
        manifestAttempt = 1,
        seq = 3,
        total = #chunks,
        builtAt = chunks[3].builtAt,
        memberKey = chunks[3].memberKey,
        totals = chunks[3].totals,
        blocks = chunks[3].blocks,
    })

    Test.eq(countPartialManifestOpen(requester.addon.Sync, source.key), 0, "duplicate chunks for a completed manifest should not reopen partial state")
    Test.eq(requester.addon.Sync.telemetry.manifestCompareFired or 0, compareBefore, "compare should not rerun for duplicate completed chunks")
    Test.eq(requester.addon.Sync.telemetry.manifestRecoveryRequests or 0, recoveryBefore, "duplicate completed chunks should not trigger recovery")
    Test.eq(requester.addon.Sync.telemetry.manifestHardPrunes or 0, pruneBefore, "duplicate completed chunks should not schedule later prunes")
    Test.eq(requester.addon.Sync.telemetry.manifestDuplicateCompletedChunksIgnored or 0, 1, "duplicate completed chunk telemetry should increment")
end)

Test.it("late chunks from a hard-pruned manifestId do not reopen a zombie partial", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Latepeer-Testrealm"
    local manifestId = "Latepeer-Testrealm:400:9:3"

    addon.Sync:HandleManifestChunk({
        sender = peerKey,
        manifestId = manifestId,
        manifestAttempt = 1,
        seq = 1,
        total = 3,
        builtAt = 400,
        memberKey = peerKey,
        totals = { blocks = 3, recipes = 3 },
        blocks = {
            {
                blockKey = "Latepeer-Testrealm::Alchemy",
                ownerCharacter = peerKey,
                professionKey = "Alchemy",
                revision = 10,
                lastUpdatedAt = 400,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "late-1",
            },
        },
    })

    wow.AdvanceTime(61)
    addon.Sync:PrunePartialManifestReceives()
    wow.AdvanceTime(61)
    addon.Sync:PrunePartialManifestReceives()

    Test.falsy(addon.Sync.partialManifestReceive[peerKey], "partial manifest should be fully hard-pruned before late chunks arrive")

    addon.Sync:HandleManifestChunk({
        sender = peerKey,
        manifestId = manifestId,
        manifestAttempt = 1,
        seq = 2,
        total = 3,
        builtAt = 400,
        memberKey = peerKey,
        totals = { blocks = 3, recipes = 3 },
        blocks = {
            {
                blockKey = "Latepeer-Testrealm::Cooking",
                ownerCharacter = peerKey,
                professionKey = "Cooking",
                revision = 11,
                lastUpdatedAt = 401,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "late-2",
            },
        },
    })

    Test.falsy(addon.Sync.partialManifestReceive[peerKey], "late chunk from the abandoned attempt should not reopen a zombie partial")
    Test.eq(addon.Sync.telemetry.manifestLateChunksIgnored or 0, 1, "late ignored telemetry should increment")
end)

Test.it("retries intermittent MANI send failures across specific large-manifest seq values", function()
    local blockCount = 385
    local bus = CommBus.CreatePeers(2, {
        prefix = "Retrypeer",
        transportProfile = "instant",
        payloadMode = "realistic-string",
    })
    local source = bus.nodes[1]
    local requester = bus.nodes[2]
    local failFirstSeqs = { [3] = true, [7] = true, [12] = true }
    local attemptCounts = {}

    bus:Activate(source)
    seedReplicaManifestBlocks(source.addon.Data, blockCount, {
        prefix = "Retryowner",
        realm = "TestRealm",
        recipeBase = 350000,
        reason = "mani-large-retry",
    })

    local chunks = source.addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "mani-large-retry",
    })
    local manifestId = chunks[1].manifestId
    local originalSendDirectEnvelope = source.addon.Sync.SendDirectEnvelope

    source.addon.Sync.SendDirectEnvelope = function(sync, kind, payload, targetKey, priority)
        if kind == "MANI" and targetKey == requester.key and payload and payload.manifestId == manifestId then
            local seq = payload.seq or 0
            attemptCounts[seq] = (attemptCounts[seq] or 0) + 1
            if failFirstSeqs[seq] and attemptCounts[seq] == 1 then
                return false
            end
        end
        return originalSendDirectEnvelope(sync, kind, payload, targetKey, priority)
    end

    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local failuresObserved = bus:RunUntil(function()
        local diag = source.addon.Sync:GetManifestBatchDiagnostics(requester.key, manifestId, "send")
        return (source.addon.Sync.telemetry.manifestChunkSendFailures or 0) == 3
            and diag
            and diag.sendFailedChunks == 3
            and diag.queuedChunks > 0
            and #source.addon.Sync.manifestChunkQueue > 0
    end, runOpts({
        maxTicks = 120,
        tickSeconds = 0.25,
    }))

    Test.truthy(failuresObserved, "failed seq values should remain queued after their first MANI send failure")

    local completed = bus:RunUntil(function(current)
        local sendDiag = source.addon.Sync:GetManifestBatchDiagnostics(requester.key, manifestId, "send")
        local recvDiag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return sendDiag
            and recvDiag
            and sendDiag.completed
            and recvDiag.completed
            and recvDiag.receivedSeqCount == #chunks
            and #(recvDiag.missingSeqs or {}) == 0
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 320,
        tickSeconds = 0.25,
    }))

    local sendDiag = source.addon.Sync:GetManifestBatchDiagnostics(requester.key, manifestId, "send")
    local recvDiag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
    Test.truthy(completed, "large manifest should complete after retrying the failed MANI seq values")
    Test.eq(source.addon.Sync.telemetry.manifestChunksSent or 0, #chunks, "manifestChunksSent should count successful large MANI sends only")
    Test.eq(source.addon.Sync.telemetry.manifestChunkSendFailures or 0, 3, "three MANI send failures should be recorded")
    Test.gte(source.addon.Sync.telemetry.manifestChunkSendRetries or 0, 3, "retry telemetry should reflect the retried MANI seq values")
    Test.eq(sendDiag and sendDiag.sendSucceededChunks, #chunks, "all MANI chunks should eventually send successfully")
    Test.eq(sendDiag and sendDiag.sendFailedChunks, 3, "send diagnostics should record the failed seq values")
    Test.eq(sendDiag and sendDiag.queuedChunks, 0, "all MANI chunks should drain after the retries")
    Test.eq(recvDiag and recvDiag.receivedSeqCount, #chunks, "receiver should assemble every MANI seq after the retries")
    Test.eq(recvDiag and #(recvDiag.missingSeqs or {}), 0, "receiver should not be missing any MANI seq after recovery")
    Test.eq(attemptCounts[3], 2, "seq 3 should be retried exactly once")
    Test.eq(attemptCounts[7], 2, "seq 7 should be retried exactly once")
    Test.eq(attemptCounts[12], 2, "seq 12 should be retried exactly once")
end)

Test.it("supersedes an older manifestId instead of interleaving multiple active MANI batches for the same peer", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-Testrealm"

    seedReplicaManifestBlocks(data, 72, {
        prefix = "Supersedeowner",
        recipeBase = 360000,
        reason = "mani-supersede-a",
    })

    local chunksA = addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "mani-supersede-a",
    })
    local manifestIdA = chunksA[1].manifestId

    addon.Sync:SendManifestToPeer(peerKey, "force")
    wow.AdvanceTime(0.13)
    addon.Sync:SendNextManifestChunk()
    Test.eq(countCommKind(wow, "MANI"), 1, "first manifest batch should begin sending before the next manifestId is queued")

    seedReplicaManifestBlock(data, "Supersedeextra-TestRealm", "Alchemy", 361000, {
        reason = "mani-supersede-b",
        updatedAt = 12345,
        rev = 2222,
    })

    local chunksB = addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "mani-supersede-b",
    })
    local manifestIdB = chunksB[1].manifestId

    Test.truthy(manifestIdA ~= manifestIdB, "dirty manifest rebuild should produce a new manifestId")

    addon.Sync:SendManifestToPeer(peerKey, "force")

    local queuedIds = queuedManifestIdsForPeer(addon.Sync, peerKey)
    local diagA = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestIdA, "send")
    local diagB = addon.Sync:GetManifestBatchDiagnostics(peerKey, manifestIdB, "send")
    Test.eq(#queuedIds, 1, "only one manifestId should remain active in the MANI queue for a peer")
    Test.eq(queuedIds[1], manifestIdB, "the newer manifestId should supersede the older queued batch")
    Test.eq(addon.Sync.telemetry.manifestSuperseded or 0, 1, "superseded manifest batches should be counted")
    Test.truthy(diagA and diagA.pruned, "older manifest batch diagnostics should record supersession")
    Test.eq(diagA and diagA.pruneReason, "superseded", "older manifest batch should be marked as superseded")
    Test.eq(diagB and diagB.totalChunks, #chunksB, "newer manifest batch diagnostics should remain active")
    Test.eq(diagB and diagB.queuedChunks, #chunksB, "newer manifest batch should own the remaining queued chunk budget")
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
