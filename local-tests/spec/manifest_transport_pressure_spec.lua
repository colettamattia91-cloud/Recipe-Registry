local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function runOpts(overrides)
    local opts = {
        maxTicks = 5000,
        tickSeconds = 0.05,
        perfRuns = 2,
        inboundRuns = 2,
        timerRuns = 40,
        transportFlushThreshold = 32,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

local function seedEveryPeer(bus, recipeBase)
    for _, node in ipairs(bus.nodes) do
        bus:SeedSelfProfession(node, {
            profession = "Alchemy",
            recipeCount = 1,
            baseRecipe = recipeBase + (node.index * 10),
            rev = 100 + node.index,
            updatedAt = 2000 + node.index,
        })
    end
end

io.write("Manifest transport pressure\n")

Test.it("avoids targeted MREQ storms during the first throttled hello burst", function()
    local peerCount = 60
    local bus = CommBus.CreatePeers(peerCount, {
        prefix = "Stormpeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
    })

    seedEveryPeer(bus, 980000)
    bus:BroadcastHelloPresence({ rev = 0, version = "manifest-storm" })

    local converged = bus:RunUntil(function(current)
        return current:AllQueuesIdle() and current:TransportIdle()
    end, runOpts())

    Test.truthy(converged, "first throttled hello burst should drain")
    Test.eq(bus.stats.sentKinds.MREQ or 0, 0, "first-contact hello burst should not produce targeted manifest refresh storms")
    Test.gte(bus.stats.sentKinds.MANI or 0, peerCount, "manifest replies should still be exchanged")
    Test.lte(bus.stats.maxManifestOutstandingOwners or 0, 8, "manifest outstanding owners should respect the cap")
    Test.lte(bus.stats.maxManifestOutstandingBlocks or 0, 32, "manifest outstanding blocks should respect the cap")
    Test.lte(bus.stats.maxManifestCatchupQueue or 0, 256, "manifest catch-up queue should stay bounded")
end)

Test.it("skips redundant manifest and refresh traffic after throttled convergence with unchanged data", function()
    local peerCount = 20
    local bus = CommBus.CreatePeers(peerCount, {
        prefix = "Quietpeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
    })

    seedEveryPeer(bus, 990000)
    bus:BroadcastHelloPresence({ rev = 0, version = "manifest-quiet-initial" })

    local converged = bus:RunUntil(function(current)
        return current:AllQueuesIdle() and current:TransportIdle()
    end, runOpts({
        maxTicks = 3500,
    }))
    Test.truthy(converged, "initial throttled convergence should complete")

    local maniBefore = bus.stats.sentKinds.MANI or 0
    local mreqBefore = bus.stats.sentKinds.MREQ or 0
    local reqBefore = bus.stats.sentKinds.REQ or 0

    bus:BroadcastHelloPresence({ rev = 0, version = "manifest-quiet-repeat" })
    local drained = bus:RunUntil(function(current)
        return current:AllQueuesIdle() and current:TransportIdle()
    end, runOpts({
        maxTicks = 1200,
    }))

    Test.truthy(drained, "repeat hello burst should drain")
    Test.eq((bus.stats.sentKinds.MANI or 0) - maniBefore, 0, "unchanged manifests should not be re-announced")
    Test.eq((bus.stats.sentKinds.MREQ or 0) - mreqBefore, 0, "repeat hellos after manifest receipt should not request targeted refreshes")
    Test.eq((bus.stats.sentKinds.REQ or 0) - reqBefore, 0, "repeat hellos with unchanged manifests should not queue sync requests")
end)

io.write(string.format("Manifest transport pressure: %d test(s) passed\n", Test.count))
