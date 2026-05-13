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

local function runOpts(overrides)
    local opts = {
        maxTicks = 9000,
        tickSeconds = 0.05,
        perfRuns = 2,
        inboundRuns = 2,
        timerRuns = 30,
        transportFlushThreshold = 32,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

local function seedLargeOwner(bus, node, recipeCountPerProfession)
    for index, profession in ipairs(PROFESSIONS) do
        bus:SeedSelfProfession(node, {
            profession = profession,
            recipeCount = recipeCountPerProfession,
            baseRecipe = 900000 + (index * 1000),
            rev = 200 + index,
            updatedAt = 4000 + index,
        })
    end
end

io.write("Transport backpressure\n")

Test.it("keeps outbound chunk pressure bounded under throttled transport", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Throttlepeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
    })
    local owner = bus.nodes[1]
    local receiver = bus.nodes[2]
    local window = owner.addon.Sync._private.constants.SNAPSHOT_SESSION_WINDOW or 8

    seedLargeOwner(bus, owner, 500)
    bus:SeedSelfProfession(receiver, {
        profession = "Cooking",
        recipeCount = 1,
        baseRecipe = 950000,
    })

    bus:BroadcastHelloPresence({ rev = 0, version = "transport-backpressure" })

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(receiver, owner.key, "Alchemy") == 500
            and current:CountRecipes(receiver, owner.key, "Tailoring") == 500
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts())

    Test.truthy(converged, "large snapshot should converge under throttled transport")
    Test.lte(bus.stats.maxOutboundChunkQueue or 0, window, "outbound chunk queue should stay within the session window")
    Test.lte(bus.stats.maxTransportQueue or 0, 96, "transport queue should remain bounded in the throttled scenario")

    local doneBySession = {}
    for _, event in ipairs(bus:FindEvents(function(row)
        return row.type == "SEND" and row.kind == "DONE"
    end)) do
        doneBySession[event.sessionId] = event.tick
    end

    for sessionId, doneTick in pairs(doneBySession) do
        local lateSnaps = bus:FindEvents(function(row)
            return row.type == "SEND"
                and row.kind == "SNAP"
                and row.sessionId == sessionId
                and row.tick > doneTick
        end)
        Test.eq(#lateSnaps, 0, "completed session should not send extra SNAP chunks after DONE")
    end
end)

Test.it("resume requeues only the missing chunk instead of resending the full session", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Resumebackpeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
    })
    local owner = bus.nodes[1]
    local receiver = bus.nodes[2]
    local droppedSeq2 = false

    bus:SeedSelfProfession(owner, {
        profession = "Alchemy",
        recipeCount = 350,
        baseRecipe = 960000,
    })
    bus:SeedSelfProfession(receiver, {
        profession = "Cooking",
        recipeCount = 1,
        baseRecipe = 970000,
    })

    bus:SetRouteHook(function(_bus, sender, target, _row, payload)
        if sender == owner and target == receiver and payload.kind == "SNAP" and payload.key == owner.key then
            if payload.seq == 2 and not droppedSeq2 then
                droppedSeq2 = true
                return "drop"
            end
        end
    end)

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(receiver, owner.key, "Alchemy") == 350
            and current:AllQueuesIdle()
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 3000,
        perfRuns = 4,
        inboundRuns = 4,
    }))

    Test.truthy(converged, "resume scenario should converge")
    Test.truthy(droppedSeq2, "fixture should drop one snapshot chunk once")

    local resumeTick
    local sessionId
    for _, event in ipairs(bus:FindEvents(function(row)
        return row.type == "SEND" and row.kind == "RESUME"
    end)) do
        resumeTick = event.tick
        sessionId = event.sessionId
        break
    end

    Test.truthy(resumeTick ~= nil, "receiver should send a RESUME request")

    local resumedSnaps = bus:FindEvents(function(row)
        return row.type == "SEND"
            and row.kind == "SNAP"
            and row.sessionId == sessionId
            and row.tick > resumeTick
    end)

    Test.truthy(#resumedSnaps >= 1, "sender should requeue at least one snapshot chunk after RESUME")
    for _, event in ipairs(resumedSnaps) do
        Test.eq(event.seq, 2, "RESUME should requeue only the missing seq")
    end
end)

io.write(string.format("Transport backpressure: %d test(s) passed\n", Test.count))
