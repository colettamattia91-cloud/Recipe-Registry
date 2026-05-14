local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Soak = dofile("local-tests/spec/support/sync-soak-helpers.lua")
local Test = dofile("local-tests/harness/test.lua")

local PEER_COUNT = 50
local PEER_PREFIX = "Soakpeer"
local HEAVY_BUDGETS = {
    maxOutboundChunkQueue = 64,
    maxManifestCatchupQueue = 96,
    maxTransportQueue = 2600,
    maxTransportBytesQueued = 500000,
    maxManifestRecoveryRequests = 10,
    maxRequestRetries = 16,
    maxManifestSuperseded = 16,
    maxMreqSent = 640,
    maxManiSent = 7600,
}

io.write("Sync soak heavy\n")

Test.it("holds baseline stability and returns idle under 50-peer churn", function()
    local bus = CommBus.CreatePeers(PEER_COUNT, {
        prefix = PEER_PREFIX,
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local manifestShape = Soak.seedConflictingOfflineReplicas(bus, {
        conflictCount = 10,
    })
    local scenario = Soak.buildScenario(PEER_COUNT, {
        cycleCount = 10,
        offlineCount = 5,
        reloadTargets = { 3, 17, 29 },
        reloadCycles = { 4, 6, 8 },
        pauseCycles = { 3, 7 },
    })

    Soak.seedEveryPeer(bus)
    bus:BroadcastHelloPresence({ rev = 0, version = "sync-soak-heavy-initial" })

    local baselineStable = Soak.waitForStable(bus, PEER_COUNT, PEER_PREFIX, {
        maxTicks = 8000,
    })
    Test.truthy(baselineStable, "heavy baseline should become truly idle before churn: " .. Soak.describeState(bus))

    local expectedCounts = Soak.mutatedCountsForScenario(bus, scenario.cycleCount)
    Soak.runScenario(bus, scenario)
    Soak.emitMutatedOwnerBurst(bus, scenario.cycleCount)

    local settled = Soak.waitForStable(bus, PEER_COUNT, PEER_PREFIX, {
        maxTicks = 4000,
    })

    local auditor = bus.nodes[1]
    bus:Activate(auditor)
    local staleEntry = auditor.addon.Data:GetMember(manifestShape.staleOwnerKey)

    Test.truthy(settled, "heavy churn should settle back to idle: " .. Soak.describeState(bus))
    Test.truthy(bus:AllNodesHaveOwners(PEER_COUNT, PEER_PREFIX), "all online peers should still agree on live guild owners after heavy soak")
    Test.eq(bus:CountInFlightRequests(), 0, "no in-flight requests should remain after heavy settle")
    Test.eq(bus:CountPartialManifests(), 0, "no partial MANI state should remain after heavy settle")
    Test.eq(bus:CountPartialSnapshots(), 0, "no partial SNAP state should remain after heavy settle")
    Test.eq(bus:CountManifestCatchupQueued(), 0, "heavy manifest catch-up queue should drain fully")
    Test.eq(bus:CountOutboundChunksQueued(), 0, "heavy outbound chunk queues should drain fully")
    Test.eq(Soak.chunksAfterDoneCount(bus), 0, "heavy soak should not send SNAP chunks after DONE")
    Test.falsy(Soak.retryStormDetected(bus, HEAVY_BUDGETS.maxRequestRetries), "heavy soak should not enter a retry storm")
    Test.falsy(Soak.manifestLoopDetected(bus, {
        maxMreqPerEdge = 12,
    }), "heavy soak should not enter a HELLO/MANI/MREQ loop")
    Test.truthy(Soak.allOnlineNodesSeeRecipeCounts(bus, expectedCounts, "Alchemy"), "heavy soak should preserve complete owner data after churn")
    Test.truthy(staleEntry ~= nil, "stale offline owner should still exist on the heavy auditor node")
    Test.eq(staleEntry and staleEntry.guildStatus, "stale", "heavy soak should not reactivate the stale owner")
    Test.lte(bus.stats.maxOutboundChunkQueue or 0, HEAVY_BUDGETS.maxOutboundChunkQueue, "heavy outbound chunk queue should stay within release budget")
    Test.lte(bus.stats.maxManifestCatchupQueue or 0, HEAVY_BUDGETS.maxManifestCatchupQueue, "heavy manifest catch-up queue should stay within release budget")
    Test.lte(bus.stats.maxTransportQueue or 0, HEAVY_BUDGETS.maxTransportQueue, "heavy transport queue should stay within release budget")
    Test.lte(bus.stats.maxTransportBytesQueued or 0, HEAVY_BUDGETS.maxTransportBytesQueued, "heavy transport byte pressure should stay within release budget")
    Test.lte(Soak.sumTelemetry(bus, "manifestRecoveryRequests"), HEAVY_BUDGETS.maxManifestRecoveryRequests, "heavy manifest recovery requests should stay within release budget")
    Test.lte(Soak.sumTelemetry(bus, "requestRetries"), HEAVY_BUDGETS.maxRequestRetries, "heavy request retries should stay within release budget")
    Test.lte(Soak.sumTelemetry(bus, "manifestSuperseded"), HEAVY_BUDGETS.maxManifestSuperseded, "heavy superseded manifest batches should stay bounded")
    Test.lte(bus.stats.sentKinds.MREQ or 0, HEAVY_BUDGETS.maxMreqSent, "heavy targeted manifest refreshes should stay within release budget")
    Test.lte(bus.stats.sentKinds.MANI or 0, HEAVY_BUDGETS.maxManiSent, "heavy manifest fan-out should stay within release budget")
end)

io.write(string.format("Sync soak heavy: %d test(s) passed\n", Test.count))
