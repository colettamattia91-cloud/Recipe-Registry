local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function runOpts(overrides)
    local opts = {
        maxTicks = 5000,
        tickSeconds = 0.25,
        perfRuns = 4,
        inboundRuns = 4,
        timerRuns = 40,
        transportFlushThreshold = 24,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function countPartialManifestOpen(sync, peerKey)
    local manifests = sync.partialManifestReceive and sync.partialManifestReceive[peerKey] or nil
    local count = 0
    for _ in pairs(manifests or {}) do
        count = count + 1
    end
    return count
end

local function seedLargeOwner(bus, node, recipeCount, baseRecipe)
    bus:SeedSelfProfession(node, {
        profession = "Alchemy",
        recipeCount = recipeCount,
        baseRecipe = baseRecipe,
        rev = 1200,
        updatedAt = 6400,
    })
end

local function seedLocalRequester(bus, node, recipeKey)
    bus:SeedSelfProfession(node, {
        profession = "Cooking",
        recipeCount = 1,
        baseRecipe = recipeKey,
        rev = 33,
        updatedAt = 3300,
    })
end

io.write("Reload recovery\n")

Test.it("does not keep zombie in-flight request after reload", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Reloadpeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local requester = bus.nodes[1]
    local owner = bus.nodes[2]

    seedLocalRequester(bus, requester, 401000)
    seedLargeOwner(bus, owner, 320, 402000)

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local requestStarted = bus:RunUntil(function(current)
        return current:NodeHasInFlightRequest(requester)
    end, runOpts({
        maxTicks = 300,
    }))

    Test.truthy(requestStarted, "request should be in-flight before reload")

    local saved = bus:SnapshotSavedVariables(requester)
    bus:ReloadNode(requester, {
        savedVariables = saved,
    })

    Test.falsy(bus:NodeHasZombieRequests(requester), "reload should clear zombie request state immediately")
    Test.eq(bus:CountRecipes(requester, requester.key, "Cooking"), 1, "local saved profession should survive reload")

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local recovered = bus:RunUntil(function(current)
        return current:CountRecipes(requester, owner.key, "Alchemy") == 320
            and current:AllQueuesIdleForNode(requester)
            and not current:NodeHasZombieRequests(requester)
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 2200,
    }))

    Test.truthy(recovered, "reloaded requester should recover without zombie requests")
end)

Test.it("reload with partial inbound snapshot discards runtime partial state and converges on a new request", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Reloadsnappeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local requester = bus.nodes[1]
    local owner = bus.nodes[2]
    local holdTailChunks = true
    local firstChunkSeen = false

    seedLocalRequester(bus, requester, 403000)
    seedLargeOwner(bus, owner, 350, 404000)

    bus:SetRouteHook(function(_bus, sender, target, _row, payload)
        if sender == owner and target == requester and payload.kind == "SNAP" and payload.key == owner.key then
            if payload.seq == 1 then
                firstChunkSeen = true
                return
            end
            if holdTailChunks then
                return "drop"
            end
        end
    end)

    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local partialStarted = bus:RunUntil(function()
        return firstChunkSeen
            and requester.addon.Sync.partialReceive[owner.key] ~= nil
            and bus:CountRecipes(requester, owner.key, "Alchemy") == 0
    end, runOpts({
        maxTicks = 300,
    }))

    Test.truthy(partialStarted, "requester should hold a partial snapshot before reload")

    local saved = bus:SnapshotSavedVariables(requester)
    bus:ReloadNode(requester, {
        savedVariables = saved,
    })

    Test.eq(countKeys(requester.addon.Sync.partialReceive), 0, "reload should clear partial snapshot runtime state")
    Test.eq(bus:CountRecipes(requester, owner.key, "Alchemy"), 0, "partial snapshot should not be applied across reload")

    holdTailChunks = false
    bus:Activate(owner)
    owner.addon.Sync:BroadcastHello()

    local converged = bus:RunUntil(function(current)
        return current:CountRecipes(requester, owner.key, "Alchemy") == 350
            and current:AllQueuesIdleForNode(requester)
            and not current:NodeHasZombieRequests(requester)
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 2400,
    }))

    Test.truthy(converged, "reloaded requester should converge from a clean snapshot state")
end)

Test.it("reload with partial manifest receive clears runtime state and allows a clean manifest compare afterwards", function()
    local bus = CommBus.CreatePeers(2, {
        prefix = "Reloadmanipeer",
        transportProfile = "throttled",
        payloadMode = "realistic-string",
        runtimeTickers = true,
    })
    local requester = bus.nodes[1]
    local source = bus.nodes[2]
    local deliveredOneChunk = false
    local blockCount = 385

    seedLocalRequester(bus, requester, 405000)
    bus:Activate(source)
    for index = 1, blockCount do
        local ownerKey = string.format("Reloadghost%03d-TestRealm", index)
        local recipeKey = 406000 + index
        local profession = (index % 2 == 0) and "Alchemy" or "Cooking"
        local entry = source.addon.Data:GetOrCreateMember(ownerKey)
        entry.owner = ownerKey
        entry.rev = 900 + index
        entry.updatedAt = 7000 + index
        entry.sourceType = "replica"
        entry.guildStatus = "active"
        entry.lastSeenInGuildAt = entry.updatedAt
        entry.professions[profession] = {
            recipes = { [recipeKey] = true },
            count = 1,
            signature = tostring(recipeKey),
            blockRevision = entry.rev,
            lastUpdatedAt = entry.updatedAt,
            sourceType = "replica",
            guildStatus = "active",
            lastSeenInGuildAt = entry.updatedAt,
        }
        source.addon.Data:NormalizeMemberEntry(entry, ownerKey)
        source.addon.Data:MarkManifestDirty(source.addon.Data:BuildSyncBlockKey(ownerKey, profession), "reload-manifest")
    end
    source.addon.Data:BuildManifestCacheNow("reload-manifest")

    local chunks = source.addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = "reload-manifest",
    })
    local manifestId = chunks[1].manifestId

    bus:SetRouteHook(function(_bus, sender, target, _row, payload)
        if sender == source and target == requester and payload.kind == "MANI" and payload.manifestId == manifestId then
            if not deliveredOneChunk then
                deliveredOneChunk = true
                return
            end
            return "drop"
        end
    end)

    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local partialManifestStarted = bus:RunUntil(function()
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return deliveredOneChunk
            and diag
            and diag.receivedSeqCount == 1
            and countPartialManifestOpen(requester.addon.Sync, source.key) == 1
    end, runOpts({
        maxTicks = 200,
    }))

    Test.truthy(partialManifestStarted, "requester should hold a partial manifest before reload")

    local saved = bus:SnapshotSavedVariables(requester)
    bus:ReloadNode(requester, {
        savedVariables = saved,
    })

    Test.eq(countPartialManifestOpen(requester.addon.Sync, source.key), 0, "reload should clear partial manifest runtime state")
    Test.falsy(bus:NodeHasZombieRequests(requester), "reload should not keep manifest zombie state")

    bus:SetRouteHook(nil)
    bus:Activate(source)
    source.addon.Sync:SendManifestToPeer(requester.key, "force")

    local recovered = bus:RunUntil(function(current)
        local diag = requester.addon.Sync:GetManifestBatchDiagnostics(source.key, manifestId, "receive")
        return diag
            and diag.completed
            and diag.compareFired
            and (requester.addon.Sync.telemetry.manifestCatchupQueued or 0) > 0
            and current:AllQueuesIdleForNode(requester)
            and not current:NodeHasZombieRequests(requester)
            and current:TransportIdle()
    end, runOpts({
        maxTicks = 2600,
    }))

    Test.truthy(recovered, "reloaded requester should complete manifest compare from a clean state")
end)

io.write(string.format("Reload recovery: %d test(s) passed\n", Test.count))
