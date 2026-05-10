local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local PEER_COUNT = 200
local PEER_PREFIX = "Buspeer"
local CHURN_COUNT = 100
local CHURN_PREFIX = "Churnpeer"

local function runOpts(overrides)
    local opts = {
        maxTicks = 4000,
        tickSeconds = 0.05,
        perfRuns = 3,
        inboundRuns = 3,
        timerRuns = 50,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

io.write("Manifest comm bus\n")

Test.it("converges two hundred peers through a coordinator-aware comm bus", function()
    local bus = CommBus.CreatePeers(PEER_COUNT, { prefix = PEER_PREFIX })
    bus:SeedAllSelfData({ recipeCount = 1 })
    bus:BroadcastHelloPresence({ rev = 0, version = "comm-bus-scale" })

    local converged = bus:RunUntil(function(current)
        return current:AllNodesAgreeOnCoordinator()
            and current:AllNodesHaveOwners(PEER_COUNT, PEER_PREFIX)
            and current:AllQueuesIdle()
    end, {
        maxTicks = 6000,
        tickSeconds = 0.05,
        perfRuns = 2,
        inboundRuns = 2,
        timerRuns = 50,
    })

    local expectedPairwise = PEER_COUNT * (PEER_COUNT - 1)
    Test.truthy(converged, "multi-node comm bus should converge")
    Test.truthy(bus:AllNodesAgreeOnCoordinator(), "all nodes should agree on one coordinator")
    Test.truthy(bus:AllNodesHaveOwners(PEER_COUNT, PEER_PREFIX), "all nodes should know every peer owner")
    Test.truthy(bus:AllQueuesIdle(), "all sync queues should drain")
    Test.eq(bus.stats.dropped, 0, "comm bus should route every message")
    Test.eq(bus.stats.sentKinds.HELLO or 0, PEER_COUNT, "one HELLO should be sent per peer")
    Test.eq(bus.stats.deliveredKinds.HELLO or 0, expectedPairwise, "guild HELLO should reach every other peer")
    Test.gte(bus.stats.sentKinds.MANI or 0, expectedPairwise, "peer manifests should cross the bus")
    Test.gte(bus.stats.sentKinds.REQ or 0, expectedPairwise, "real REQ messages should be produced")
    Test.gte(bus.stats.sentKinds.SNAP or 0, expectedPairwise, "real SNAP messages should be produced")
    Test.gte(bus.stats.sentKinds.DONE or 0, expectedPairwise, "real DONE messages should be produced")
    Test.gte(bus.stats.sentKinds.IDX or 0, 1, "coordinator should broadcast index updates")
    Test.gte(bus.stats.maxCatchupDeferred, 1, "catch-up work should defer under load")
    Test.gte(8, bus.stats.maxManifestOutstandingOwners, "manifest catch-up owners should respect the cap")
    Test.gte(32, bus.stats.maxManifestOutstandingBlocks, "manifest catch-up blocks should respect the cap")
    Test.gte(PEER_COUNT, bus.stats.maxOutstandingOwners, "overall request pressure should stay bounded per node")

    for _, node in ipairs(bus.nodes) do
        bus:Activate(node)
        Test.eq(#(node.addon.Sync.manifestCatchupQueue or {}), 0, "node catch-up queue should drain")
        Test.eq(Test.countKeys(node.addon.Sync.pendingRequests), 0, "node pending requests should drain")
        Test.falsy(node.addon.Sync.inFlight, "node in-flight request should finish")
        Test.eq(#(node.addon.Sync.inboundChunkQueue or {}), 0, "node inbound chunks should drain")
        Test.eq(#(node.addon.Sync.inboundFinalizeQueue or {}), 0, "node inbound finalize queue should drain")
    end
end)

Test.it("continues after the elected coordinator goes offline during a large sync", function()
    local bus = CommBus.CreatePeers(CHURN_COUNT, { prefix = CHURN_PREFIX })
    bus:SeedAllSelfData({ recipeCount = 1 })
    bus:BroadcastHelloPresence({ rev = 0, version = "comm-bus-churn" })

    local elected = bus:RunUntil(function(current)
        return current:AllNodesAgreeOnCoordinator()
    end, runOpts({ maxTicks = 100 }))
    Test.truthy(elected, "initial coordinator should be elected")

    local oldCoordinatorKey = bus:CoordinatorKey()
    local oldCoordinator = bus.nodeByKey[oldCoordinatorKey]
    Test.truthy(oldCoordinator, "coordinator node should exist")

    bus:SetNodeOnline(oldCoordinator, false)
    bus:BroadcastHelloPresence({ rev = 0, version = "comm-bus-churn-after-offline" })

    local activeOwnerKeys = bus:OnlineOwnerKeys(CHURN_PREFIX)
    local converged = bus:RunUntil(function(current)
        return current:CoordinatorKey() ~= oldCoordinatorKey
            and current:AllNodesAgreeOnCoordinator()
            and current:AllOnlineNodesHaveOwnerKeys(activeOwnerKeys)
            and current:AllQueuesIdle()
    end, runOpts({ maxTicks = 5000 }))

    Test.truthy(converged, "online peers should converge after coordinator churn")
    Test.ne(bus:CoordinatorKey(), oldCoordinatorKey, "new coordinator should replace the offline one")
    Test.truthy(bus:AllNodesAgreeOnCoordinator(), "online peers should agree on the new coordinator")
    Test.truthy(bus:AllOnlineNodesHaveOwnerKeys(activeOwnerKeys), "online peers should retain active owner convergence")
    Test.truthy(bus:AllQueuesIdle(), "queues should drain after coordinator churn")
    Test.gte(bus.stats.sentKinds.HELLO or 0, (CHURN_COUNT * 2) - 1, "peers should rebroadcast presence after churn")
    Test.gte(bus.stats.sentKinds.MANI or 0, 1, "manifest traffic should continue after churn")
end)

Test.it("chooses the richer newest replica for an offline owner under conflicting manifests", function()
    local bus = CommBus.CreatePeers(3, { prefix = "Conflictpeer" })
    local requester = bus.nodes[1]
    local partialReplica = bus.nodes[2]
    local richReplica = bus.nodes[3]
    local ownerKey = "Offlineowner-TestRealm"

    bus:SeedSelfProfession(requester, { profession = "Cooking", recipeCount = 1 })
    bus:SeedSelfProfession(partialReplica, { profession = "Cooking", recipeCount = 1 })
    bus:SeedSelfProfession(richReplica, { profession = "Cooking", recipeCount = 1 })
    bus:SeedReplicaProfession(partialReplica, ownerKey, "Alchemy", { 221001 }, {
        rev = 12,
        updatedAt = 1200,
        sourceType = "replica",
    })
    bus:SeedReplicaProfession(richReplica, ownerKey, "Alchemy", { 221001, 221002, 221003 }, {
        rev = 24,
        updatedAt = 2400,
        sourceType = "replica",
    })

    bus:BroadcastHelloPresence({ rev = 0, version = "comm-bus-conflict" })
    bus:Activate(partialReplica)
    partialReplica.addon.Sync:SendManifestToPeer(requester.key, "force")
    bus:Activate(richReplica)
    richReplica.addon.Sync:SendManifestToPeer(requester.key, "force")

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(requester, ownerKey, "Alchemy") == 3
            and current:AllQueuesIdle()
    end, runOpts({ maxTicks = 1500 }))

    bus:Activate(requester)
    local entry = requester.addon.Data:GetMember(ownerKey)
    Test.truthy(converged, "requester should converge on the richer offline replica")
    Test.truthy(entry, "offline owner should be applied")
    Test.eq(entry.rev, 24, "newest replica revision should win")
    Test.eq(bus:CountRecipes(requester, ownerKey, "Alchemy"), 3, "richer replica recipes should be retained")
    Test.gte(requester.addon.Sync.telemetry.replicaRequestsQueued or 0, 1, "offline replica request should be queued")
    Test.gte(requester.addon.Sync.telemetry.replicaOwnersApplied or 0, 1, "offline replica owner should be applied")
end)

Test.it("recovers a large snapshot with reordered chunks and one dropped chunk via RESUME", function()
    local bus = CommBus.CreatePeers(2, { prefix = "Largepeer" })
    local owner = bus.nodes[1]
    local receiver = bus.nodes[2]
    local droppedSeq2 = false
    local delayedSeq1 = false

    bus:SeedSelfProfession(owner, {
        profession = "Alchemy",
        recipeCount = 250,
        baseRecipe = 230000,
    })
    bus:SeedSelfProfession(receiver, {
        profession = "Cooking",
        recipeCount = 1,
        baseRecipe = 240000,
    })

    bus:SetRouteHook(function(_bus, sender, target, _row, payload)
        if sender == owner and target == receiver and payload.kind == "SNAP" and payload.key == owner.key then
            if payload.seq == 1 and not delayedSeq1 then
                delayedSeq1 = true
                return "delay", 2
            end
            if payload.seq == 2 and not droppedSeq2 then
                droppedSeq2 = true
                return "drop"
            end
        end
    end)

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(receiver, owner.key, "Alchemy") == 250
            and current:AllQueuesIdle()
    end, runOpts({
        maxTicks = 300,
        tickSeconds = 0.5,
        perfRuns = 4,
        inboundRuns = 4,
    }))

    Test.truthy(converged, "large snapshot should recover after reorder/drop")
    Test.truthy(delayedSeq1, "first snapshot chunk should be delayed")
    Test.truthy(droppedSeq2, "second snapshot chunk should be dropped once")
    Test.gte(bus.stats.delayed, 1, "bus should record delayed delivery")
    Test.eq(bus.stats.droppedKinds.SNAP or 0, 1, "exactly one SNAP chunk should be dropped")
    Test.gte(bus.stats.sentKinds.RESUME or 0, 1, "receiver should request missing chunks")
    Test.gte(bus.stats.sentKinds.SNAP or 0, 4, "source should resend the missing snapshot chunk")
    Test.eq(bus:CountRecipes(receiver, owner.key, "Alchemy"), 250, "all large snapshot recipes should apply")
    Test.truthy(bus:AllQueuesIdle(), "queues should drain after resume")
end)

Test.it("does not reactivate a locally stale owner from an in-flight replica snapshot", function()
    local bus = CommBus.CreatePeers(2, { prefix = "Stalepeer" })
    local requester = bus.nodes[1]
    local replica = bus.nodes[2]
    local ownerKey = "Exguildowner-TestRealm"
    local delayedSnapshot = false

    bus:SeedSelfProfession(requester, { profession = "Cooking", recipeCount = 1 })
    bus:SeedSelfProfession(replica, { profession = "Cooking", recipeCount = 1 })
    bus:SeedReplicaProfession(requester, ownerKey, "Alchemy", { 250001 }, {
        rev = 5,
        updatedAt = 500,
        sourceType = "replica",
    })
    bus:SeedReplicaProfession(replica, ownerKey, "Alchemy", { 250001, 250002 }, {
        rev = 10,
        updatedAt = 1000,
        sourceType = "replica",
    })

    bus:SetRouteHook(function(_bus, sender, target, _row, payload)
        if sender == replica and target == requester and payload.kind == "SNAP" and payload.key == ownerKey and not delayedSnapshot then
            delayedSnapshot = true
            return "delay", 8
        end
    end)

    bus:BroadcastHelloPresence({ rev = 0, version = "comm-bus-stale" })
    bus:Activate(replica)
    replica.addon.Sync:SendManifestToPeer(requester.key, "force")

    local requestStarted = bus:RunUntil(function()
        return delayedSnapshot
    end, runOpts({ maxTicks = 100 }))
    Test.truthy(requestStarted, "replica snapshot should be in flight before stale mark")

    bus:Activate(requester)
    requester.addon.Data:MarkMemberStale(ownerKey, 2000)

    local drained = bus:RunUntil(function(current)
        return current:AllQueuesIdle()
    end, runOpts({ maxTicks = 300 }))

    bus:Activate(requester)
    local entry = requester.addon.Data:GetMember(ownerKey)
    Test.truthy(drained, "stale race queues should drain")
    Test.truthy(entry, "stale owner entry should remain present")
    Test.eq(entry.guildStatus, "stale", "replica snapshot should not reactivate stale owner")
    Test.eq(entry.rev, 5, "stale owner revision should not be replaced by replica")
    Test.eq(bus:CountRecipes(requester, ownerKey, "Alchemy"), 1, "stale owner recipes should not be expanded by replica")
end)

io.write(string.format("Manifest comm bus: %d test(s) passed\n", Test.count))
