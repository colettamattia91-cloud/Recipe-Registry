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

local function ownerCountForIndexes(bus, indexes, prefix)
    for _, index in ipairs(indexes or {}) do
        local node = bus.nodes[index]
        if node and node.online then
            local count, stale, mock = bus:CountVisibleOwners(node, prefix)
            if count ~= #indexes or stale ~= 0 or mock ~= 0 then
                return false
            end
        end
    end
    return true
end

local function countBackoffPeers(bus)
    local total = 0
    for _, node in ipairs(bus.nodes or {}) do
        if node.online then
            bus:Activate(node)
            for _ in pairs(node.addon.Sync.peerBackoffUntil or {}) do
                total = total + 1
            end
        end
    end
    return total
end

local function cohortSeesRecipeCounts(bus, viewerIndexes, expectedCounts, profession)
    for _, viewerIndex in ipairs(viewerIndexes or {}) do
        local viewer = bus.nodes[viewerIndex]
        if viewer and viewer.online then
            for ownerKey, expectedCount in pairs(expectedCounts or {}) do
                if bus:CountRecipes(viewer, ownerKey, profession or "Alchemy") ~= expectedCount then
                    return false
                end
            end
        end
    end
    return true
end

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

Test.it("keeps mixed version and mixed channel peers quiet while compatible cohorts still settle", function()
    local peerCount = 16
    local peerPrefix = "Mixedsoakpeer"
    local releaseCohort = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15 }
    local devCohort = { 11, 12 }
    local noisyIndexes = { 11, 12, 13, 14, 15, 16 }
    local bus = CommBus.CreatePeers(peerCount, {
        prefix = peerPrefix,
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
        nodeOptionsFactory = function(index)
            if index == 11 or index == 12 then
                return {
                    addonMetadata = {
                        Version = "2.0.0",
                        ["X-Build-Channel"] = "dev",
                        ["X-Build-ID"] = "dev-" .. tostring(index),
                    },
                }
            end
            if index == 13 then
                return {
                    addonSetup = function(addon)
                        addon.ADDON_VERSION = "1.9.9"
                        addon.DISPLAY_VERSION = addon.ADDON_VERSION
                        addon.WIRE_VERSION = 2
                        addon.MIN_SUPPORTED_WIRE_VERSION = 2
                    end,
                }
            end
            if index == 14 then
                return {
                    addonSetup = function(addon)
                        addon.ADDON_VERSION = "2.1.0"
                        addon.DISPLAY_VERSION = addon.ADDON_VERSION
                        addon.WIRE_VERSION = 4
                        addon.MIN_SUPPORTED_WIRE_VERSION = 4
                    end,
                }
            end
            if index == 15 then
                return {
                    addonSetup = function(addon)
                        addon.CAPABILITIES = {
                            chunkWindow = true,
                            maniReliable = false,
                            snapCodec = true,
                            manifestShards = false,
                        }
                    end,
                }
            end
            if index == 16 then
                return {
                    addonSetup = function(addon)
                        addon.ADDON_VERSION = "1.9.8"
                        addon.DISPLAY_VERSION = addon.ADDON_VERSION
                        addon.BUILD_CHANNEL = nil
                        addon.WIRE_VERSION = 0
                        addon.MIN_SUPPORTED_WIRE_VERSION = 0
                        addon.CAPABILITIES = {}
                    end,
                }
            end
            return nil
        end,
    })

    Soak.seedEveryPeer(bus)
    bus:BroadcastHello()

    local baselineStable = bus:RunUntil(function(current)
        return ownerCountForIndexes(current, releaseCohort, peerPrefix)
            and ownerCountForIndexes(current, devCohort, peerPrefix)
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, Soak.runOpts({
        maxTicks = 2600,
    }))

    Test.truthy(baselineStable, "mixed baseline should settle without cross-channel noise: " .. Soak.describeState(bus))

    local mutated = { 1, 4, 7, 10 }
    for cycle, index in ipairs(mutated) do
        local node = bus.nodes[index]
        bus:Activate(node)
        Soak.addLocalRecipe(node, 710000 + cycle, "mixed-soak-" .. tostring(cycle))
        node.addon.Sync:BroadcastHello()

        if cycle == 2 then
            local reloadNode = bus.nodes[5]
            local saved = bus:SnapshotSavedVariables(reloadNode)
            bus:ReloadNode(reloadNode, {
                savedVariables = saved,
            })
            bus:Activate(reloadNode)
            reloadNode.addon.Sync:BroadcastHello()
        end

        if cycle == 3 then
            bus:SetNodeOnline(bus.nodes[10], false)
        elseif cycle == 4 then
            bus:SetNodeOnline(bus.nodes[10], true)
            bus:Activate(bus.nodes[10])
            bus.nodes[10].addon.Sync:BroadcastHello()
        end

        for _, noisyIndex in ipairs(noisyIndexes) do
            local noisyNode = bus.nodes[noisyIndex]
            if noisyNode and noisyNode.online then
                bus:Activate(noisyNode)
                noisyNode.addon.Sync:BroadcastHello()
            end
        end

        bus:RunUntil(function()
            return false
        end, Soak.runOpts({
            maxTicks = 60,
        }))
    end

    local expectedCounts = {}
    for _, index in ipairs(mutated) do
        expectedCounts[bus.nodes[index].key] = 2
    end

    local settled = bus:RunUntil(function(current)
        return ownerCountForIndexes(current, releaseCohort, peerPrefix)
            and ownerCountForIndexes(current, devCohort, peerPrefix)
            and cohortSeesRecipeCounts(current, releaseCohort, expectedCounts, "Alchemy")
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, Soak.runOpts({
        maxTicks = 3000,
    }))

    Test.truthy(settled, "mixed churn should settle without queue noise: " .. Soak.describeState(bus))
    Test.eq(bus:CountInFlightRequests(), 0, "mixed soak should finish with no in-flight requests")
    Test.eq(bus:CountPartialManifests(), 0, "mixed soak should finish with no partial MANI state")
    Test.eq(bus:CountPartialSnapshots(), 0, "mixed soak should finish with no partial SNAP state")
    Test.eq(bus:CountManifestCatchupQueued(), 0, "mixed soak should finish with no manifest catch-up queue")
    Test.eq(bus:CountOutboundChunksQueued(), 0, "mixed soak should finish with no outbound chunk queue")
    Test.eq(countBackoffPeers(bus), 0, "mixed soak should not leave peer backoff state behind")
    Test.eq(Soak.sumTelemetry(bus, "requestRetries"), 0, "mixed incompatibilities should not trigger retry storms")
    Test.eq(Soak.sumTelemetry(bus, "requestTimeoutInitial"), 0, "mixed incompatibilities should not trigger request timeouts")
    Test.eq(Soak.sumTelemetry(bus, "requestTimeoutProgress"), 0, "mixed incompatibilities should not trigger progress timeouts")
    Test.eq(Soak.sumTelemetry(bus, "manifestRecoveryRequests"), 0, "mixed incompatibilities should not trigger MANI recovery loops")
    Test.truthy(Soak.sumTelemetry(bus, "skippedMissingCapability") > 0, "missing capabilities should be skipped explicitly")
    bus:Activate(bus.nodes[1])
    Test.eq(bus.nodes[1].addon.Sync.peerVersions[bus.nodes[13].key].compatibility, "remote-older-wire", "older wire peer should stay diagnostic-only")
    Test.eq(bus.nodes[1].addon.Sync.peerVersions[bus.nodes[14].key].compatibility, "remote-newer-wire", "newer wire peer should stay diagnostic-only")
    Test.eq(bus.nodes[1].addon.Sync.peerVersions[bus.nodes[16].key].compatibility, "legacy", "missing-channel peer should stay diagnostic-only")
end)

io.write(string.format("Sync soak: %d test(s) passed\n", Test.count))
