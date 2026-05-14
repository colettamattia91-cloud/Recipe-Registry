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

Test.it("keeps a heavier mixed peer pool quiet while compatible cohorts converge", function()
    local peerCount = 24
    local peerPrefix = "Heavymixedpeer"
    local releaseCohort = {}
    for index = 1, 16 do
        releaseCohort[#releaseCohort + 1] = index
    end
    releaseCohort[#releaseCohort + 1] = 21
    releaseCohort[#releaseCohort + 1] = 22
    local devCohort = { 17, 18 }
    local noisyIndexes = { 17, 18, 19, 20, 21, 22, 23, 24 }
    local bus = CommBus.CreatePeers(peerCount, {
        prefix = peerPrefix,
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
        nodeOptionsFactory = function(index)
            if index == 17 or index == 18 then
                return {
                    addonMetadata = {
                        Version = "2.0.0",
                        ["X-Build-Channel"] = "dev",
                        ["X-Build-ID"] = "dev-heavy-" .. tostring(index),
                    },
                }
            end
            if index == 19 then
                return {
                    addonSetup = function(addon)
                        addon.ADDON_VERSION = "1.9.9"
                        addon.DISPLAY_VERSION = addon.ADDON_VERSION
                        addon.WIRE_VERSION = 2
                        addon.MIN_SUPPORTED_WIRE_VERSION = 2
                    end,
                }
            end
            if index == 20 then
                return {
                    addonSetup = function(addon)
                        addon.ADDON_VERSION = "2.1.0"
                        addon.DISPLAY_VERSION = addon.ADDON_VERSION
                        addon.WIRE_VERSION = 4
                        addon.MIN_SUPPORTED_WIRE_VERSION = 4
                    end,
                }
            end
            if index == 21 or index == 22 then
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
            if index == 23 or index == 24 then
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
        maxTicks = 5000,
    }))

    Test.truthy(baselineStable, "heavy mixed baseline should settle: " .. Soak.describeState(bus))

    local mutated = { 1, 4, 7, 10, 13, 16 }
    for cycle, index in ipairs(mutated) do
        local node = bus.nodes[index]
        bus:Activate(node)
        Soak.addLocalRecipe(node, 720000 + cycle, "heavy-mixed-" .. tostring(cycle))
        node.addon.Sync:BroadcastHello()

        if cycle == 2 or cycle == 5 then
            local reloadNode = bus.nodes[cycle == 2 and 6 or 14]
            local saved = bus:SnapshotSavedVariables(reloadNode)
            bus:ReloadNode(reloadNode, {
                savedVariables = saved,
            })
            bus:Activate(reloadNode)
            reloadNode.addon.Sync:BroadcastHello()
        end

        if cycle == 3 then
            bus:SetNodeOnline(bus.nodes[16], false)
        elseif cycle == 4 then
            bus:SetNodeOnline(bus.nodes[16], true)
            bus:Activate(bus.nodes[16])
            bus.nodes[16].addon.Sync:BroadcastHello()
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
            maxTicks = 90,
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
        maxTicks = 5200,
    }))

    Test.truthy(settled, "heavy mixed churn should settle: " .. Soak.describeState(bus))
    Test.eq(bus:CountInFlightRequests(), 0, "heavy mixed soak should finish with no in-flight requests")
    Test.eq(bus:CountPartialManifests(), 0, "heavy mixed soak should finish with no partial MANI state")
    Test.eq(bus:CountPartialSnapshots(), 0, "heavy mixed soak should finish with no partial SNAP state")
    Test.eq(bus:CountManifestCatchupQueued(), 0, "heavy mixed soak should finish with no manifest catch-up queue")
    Test.eq(bus:CountOutboundChunksQueued(), 0, "heavy mixed soak should finish with no outbound chunk queue")
    Test.eq(countBackoffPeers(bus), 0, "heavy mixed soak should not leave backoff state behind")
    Test.lte(Soak.sumTelemetry(bus, "requestRetries"), 8, "heavy mixed incompatibilities should keep retries bounded")
    Test.lte(Soak.sumTelemetry(bus, "requestTimeoutInitial"), 40, "heavy mixed incompatibilities should keep initial timeouts bounded")
    Test.eq(Soak.sumTelemetry(bus, "requestTimeoutProgress"), 0, "heavy mixed incompatibilities should not trigger progress timeouts")
    Test.eq(Soak.sumTelemetry(bus, "manifestRecoveryRequests"), 0, "heavy mixed incompatibilities should not trigger MANI recovery loops")
    Test.truthy(Soak.sumTelemetry(bus, "skippedMissingCapability") > 0, "heavy mixed missing capabilities should be skipped explicitly")
    bus:Activate(bus.nodes[1])
    Test.eq(bus.nodes[1].addon.Sync.peerVersions[bus.nodes[19].key].compatibility, "remote-older-wire", "heavy older wire peer should stay diagnostic-only")
    Test.eq(bus.nodes[1].addon.Sync.peerVersions[bus.nodes[20].key].compatibility, "remote-newer-wire", "heavy newer wire peer should stay diagnostic-only")
    Test.eq(bus.nodes[1].addon.Sync.peerVersions[bus.nodes[23].key].compatibility, "legacy", "heavy missing-channel peer should stay diagnostic-only")
end)

io.write(string.format("Sync soak heavy: %d test(s) passed\n", Test.count))
