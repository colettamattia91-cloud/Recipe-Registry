local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Soak = dofile("local-tests/spec/support/sync-soak-helpers.lua")
local Test = dofile("local-tests/harness/test.lua")

local PEER_COUNT = 24
local PEER_PREFIX = "Soakpeer"
local RELEASE_BUDGETS = {
    maxOutboundChunkQueue = 8,
    maxManifestCatchupQueue = 48,
    maxTransportQueue = 600,
    maxTransportBytesQueued = 120000,
    maxManifestRecoveryRequests = 6,
    maxRequestRetries = 8,
    maxManifestSuperseded = 8,
    maxMreqSent = 128,
    maxManiSent = 1800,
}

io.write("Sync soak\n")

Test.it("reaches a real baseline, survives controlled churn, and settles cleanly", function()
    local bus = CommBus.CreatePeers(PEER_COUNT, {
        prefix = PEER_PREFIX,
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local manifestShape = Soak.seedConflictingOfflineReplicas(bus, {
        conflictCount = 8,
    })
    local scenario = Soak.buildScenario(PEER_COUNT, {
        cycleCount = 8,
        offlineCount = 4,
        reloadTargets = { 3, 8, 16 },
        reloadCycles = { 4, 7, 8 },
        pauseCycles = { 3, 6 },
    })

    Soak.seedEveryPeer(bus)
    bus:BroadcastHelloPresence({ rev = 0, version = "sync-soak-initial" })

    local baselineStable = Soak.waitForStable(bus, PEER_COUNT, PEER_PREFIX, {
        maxTicks = 4000,
    })
    Test.truthy(baselineStable, "baseline convergence should reach a truly idle state: " .. Soak.describeState(bus))

    local expectedCounts = Soak.mutatedCountsForScenario(bus, scenario.cycleCount)
    Soak.runScenario(bus, scenario)
    Soak.emitMutatedOwnerBurst(bus, scenario.cycleCount)

    local settled = Soak.waitForStable(bus, PEER_COUNT, PEER_PREFIX, {
        maxTicks = 2400,
    })

    local auditor = bus.nodes[1]
    bus:Activate(auditor)
    local staleEntry = auditor.addon.Data:GetMember(manifestShape.staleOwnerKey)

    Test.truthy(settled, "controlled churn should settle back to idle: " .. Soak.describeState(bus))
    Test.truthy(bus:AllNodesHaveOwners(PEER_COUNT, PEER_PREFIX), "all online peers should still agree on live guild owners after soak")
    Test.eq(bus:CountInFlightRequests(), 0, "no in-flight requests should remain after settle")
    Test.eq(bus:CountPartialManifests(), 0, "no partial MANI state should remain after settle")
    Test.eq(bus:CountPartialSnapshots(), 0, "no partial SNAP state should remain after settle")
    Test.eq(bus:CountManifestCatchupQueued(), 0, "manifest catch-up queue should drain fully")
    Test.eq(bus:CountOutboundChunksQueued(), 0, "outbound chunk queues should drain fully")
    Test.eq(Soak.chunksAfterDoneCount(bus), 0, "no SNAP chunks should be sent after DONE")
    Test.falsy(Soak.retryStormDetected(bus, RELEASE_BUDGETS.maxRequestRetries), "soak should not enter a retry storm")
    Test.falsy(Soak.manifestLoopDetected(bus, {
        maxMreqPerEdge = 4,
    }), "soak should not enter a HELLO/MANI/MREQ loop")
    Test.truthy(Soak.allOnlineNodesSeeRecipeCounts(bus, expectedCounts, "Alchemy"), "complete owner data should not be overwritten by partial replica data")
    Test.truthy(staleEntry ~= nil, "stale offline owner should still exist on the auditor node")
    Test.eq(staleEntry and staleEntry.guildStatus, "stale", "stale offline owner should not be reactivated by replica churn")
    Test.lte(bus.stats.maxOutboundChunkQueue or 0, RELEASE_BUDGETS.maxOutboundChunkQueue, "outbound chunk queue should stay within release budget")
    Test.lte(bus.stats.maxManifestCatchupQueue or 0, RELEASE_BUDGETS.maxManifestCatchupQueue, "manifest catch-up queue should stay within release budget")
    Test.lte(bus.stats.maxTransportQueue or 0, RELEASE_BUDGETS.maxTransportQueue, "transport queue should stay within release budget")
    Test.lte(bus.stats.maxTransportBytesQueued or 0, RELEASE_BUDGETS.maxTransportBytesQueued, "transport byte pressure should stay within release budget")
    Test.lte(Soak.sumTelemetry(bus, "manifestRecoveryRequests"), RELEASE_BUDGETS.maxManifestRecoveryRequests, "manifest recovery requests should stay within release budget")
    Test.lte(Soak.sumTelemetry(bus, "requestRetries"), RELEASE_BUDGETS.maxRequestRetries, "request retries should stay within release budget")
    Test.lte(Soak.sumTelemetry(bus, "manifestSuperseded"), RELEASE_BUDGETS.maxManifestSuperseded, "superseded manifest batches should stay bounded")
    Test.lte(bus.stats.sentKinds.MREQ or 0, RELEASE_BUDGETS.maxMreqSent, "targeted manifest refreshes should stay within release budget")
    Test.lte(bus.stats.sentKinds.MANI or 0, RELEASE_BUDGETS.maxManiSent, "manifest fan-out should stay within release budget")
end)

io.write(string.format("Sync soak: %d test(s) passed\n", Test.count))
