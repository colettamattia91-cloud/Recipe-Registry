local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function runOpts(overrides)
    local opts = {
        maxTicks = 1200,
        tickSeconds = 0.05,
        perfRuns = 2,
        inboundRuns = 2,
        timerRuns = 40,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

io.write("Transport harness\n")

Test.it("preserves instant transport convergence for existing comm bus flows", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Instantpeer",
    })
    local owner = bus.nodes[1]
    local receiver = bus.nodes[2]

    bus:SeedSelfProfession(owner, {
        profession = "Alchemy",
        recipeCount = 40,
        baseRecipe = 510000,
    })
    bus:SeedSelfProfession(receiver, {
        profession = "Cooking",
        recipeCount = 1,
        baseRecipe = 520000,
    })

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(receiver, owner.key, "Alchemy") == 40
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts())

    Test.truthy(converged, "instant profile should preserve sync convergence")
    Test.eq(bus.transport.profileName, "instant", "default transport profile should stay instant")
    Test.truthy(bus:TransportIdle(), "transport queue should drain under instant profile")
    Test.gte(bus:CountEventsByType("SEND"), 1, "send events should be journaled")
    Test.gte(bus:CountEventsByType("DELIVER"), 1, "deliver events should be journaled")
    Test.gte(bus.transport.maxQueued, 1, "transport queue should observe at least one enqueued item")
    Test.gte(bus.stats.maxTransportQueue, 1, "transport stats should expose max queue depth")
    Test.gte(bus:MaxQueueDepth("transport"), 1, "queue depth helper should track transport depth")
end)

Test.it("supports realistic string payload mode without changing logical convergence", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Stringpeer",
        payloadMode = "realistic-string",
        transportProfile = "instant",
    })
    local owner = bus.nodes[1]
    local receiver = bus.nodes[2]

    bus:SeedSelfProfession(owner, {
        profession = "Alchemy",
        recipeCount = 30,
        baseRecipe = 530000,
    })
    bus:SeedSelfProfession(receiver, {
        profession = "Cooking",
        recipeCount = 1,
        baseRecipe = 540000,
    })

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(receiver, owner.key, "Alchemy") == 30
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts())

    bus:Activate(owner)
    local sent = owner.state.sentComm or {}

    Test.truthy(converged, "realistic string payloads should still converge")
    Test.truthy(#sent > 0, "owner should emit comm messages")
    Test.eq(type(sent[1].message), "string", "realistic payload mode should send strings")
    Test.gte(bus.transport.deliveredBytes, 1, "transport should accumulate delivered byte counts")
    Test.gte(bus.stats.sentKinds.HELLO or 0, 1, "HELLO should still be counted from decoded payloads")
    Test.gte(bus.stats.sentKinds.SNAP or 0, 1, "snapshot traffic should still be decoded and counted")
    Test.lte(bus.transport.maxQueued, 32, "instant realistic-string transport should stay bounded in a small scenario")
end)

io.write(string.format("Transport harness: %d test(s) passed\n", Test.count))
