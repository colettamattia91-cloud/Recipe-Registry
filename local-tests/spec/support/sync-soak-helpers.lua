local Soak = {}

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

function Soak.runOpts(overrides)
    local opts = {
        maxTicks = 6000,
        tickSeconds = 0.25,
        perfRuns = 3,
        inboundRuns = 3,
        timerRuns = 40,
        transportFlushThreshold = 24,
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return opts
end

function Soak.seedEveryPeer(bus)
    for _, node in ipairs(bus.nodes) do
        bus:SeedSelfProfession(node, {
            profession = "Alchemy",
            recipeCount = 1,
            baseRecipe = 500000 + (node.index * 10),
            rev = 100 + node.index,
            updatedAt = 2000 + node.index,
        })
    end
end

function Soak.addLocalRecipe(node, recipeKey, reason)
    local data = node.addon.Data
    local memberKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(memberKey)
    entry.rev = (entry.rev or 0) + 1
    entry.updatedAt = (entry.updatedAt or 0) + 10
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions.Alchemy = entry.professions.Alchemy or {
        recipes = {},
        count = 0,
        signature = "",
        blockRevision = entry.rev,
        lastUpdatedAt = entry.updatedAt,
        sourceType = "owner",
        guildStatus = "active",
        lastSeenInGuildAt = entry.updatedAt,
    }

    local prof = entry.professions.Alchemy
    prof.recipes[recipeKey] = true
    local keys = {}
    for value in pairs(prof.recipes or {}) do
        keys[#keys + 1] = value
    end
    table.sort(keys)
    prof.count = #keys
    prof.signature = table.concat(keys, ":")
    prof.blockRevision = entry.rev
    prof.lastUpdatedAt = entry.updatedAt
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    prof.lastSeenInGuildAt = entry.updatedAt
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkManifestDirty(data:BuildSyncBlockKey(memberKey, "Alchemy"), reason)
    data:BuildManifestCacheNow(reason)
end

local function pickReplicaNode(bus, index, offset)
    local span = math.max(1, #bus.nodes - 1)
    return bus.nodes[2 + (((index - 1) + offset) % span)]
end

function Soak.seedConflictingOfflineReplicas(bus, opts)
    opts = opts or {}
    local staleOwnerKey = opts.staleOwnerKey or "Soakstale-TestRealm"
    local conflictCount = opts.conflictCount or math.min(10, math.max(4, math.floor(#bus.nodes / 3)))

    for index = 1, conflictCount do
        local ownerKey = string.format("Soakoffline%03d-TestRealm", index)
        local lowNode = pickReplicaNode(bus, index, 0)
        local highNode = pickReplicaNode(bus, index, math.floor(#bus.nodes / 2))
        if highNode == lowNode then
            highNode = pickReplicaNode(bus, index, math.floor(#bus.nodes / 2) + 1)
        end
        bus:SeedReplicaProfession(lowNode, ownerKey, "Alchemy", { 600000 + index }, {
            rev = 10 + index,
            updatedAt = 3000 + index,
            sourceType = "replica",
        })
        bus:SeedReplicaProfession(highNode, ownerKey, "Alchemy", { 600000 + index, 610000 + index }, {
            rev = 30 + index,
            updatedAt = 5000 + index,
            sourceType = "replica",
        })
    end

    local staleSeedNode = pickReplicaNode(bus, conflictCount + 1, 1)
    local richSeedNode = pickReplicaNode(bus, conflictCount + 1, math.floor(#bus.nodes / 3))
    if richSeedNode == staleSeedNode then
        richSeedNode = pickReplicaNode(bus, conflictCount + 1, math.floor(#bus.nodes / 3) + 1)
    end
    bus:SeedReplicaProfession(staleSeedNode, staleOwnerKey, "Alchemy", { 620001 }, {
        rev = 15,
        updatedAt = 3200,
        sourceType = "replica",
    })
    bus:SeedReplicaProfession(richSeedNode, staleOwnerKey, "Alchemy", { 620001, 620002 }, {
        rev = 40,
        updatedAt = 5400,
        sourceType = "replica",
    })

    local auditor = bus.nodes[1]
    bus:SeedReplicaProfession(auditor, staleOwnerKey, "Alchemy", { 620001 }, {
        rev = 15,
        updatedAt = 3200,
        sourceType = "replica",
    })
    bus:Activate(auditor)
    auditor.addon.Data:MarkMemberStale(staleOwnerKey, 9000)

    return {
        staleOwnerKey = staleOwnerKey,
        conflictCount = conflictCount,
    }
end

function Soak.buildScenario(peerCount, opts)
    opts = opts or {}
    local cycleCount = opts.cycleCount or ((peerCount >= 40) and 10 or 8)
    local offlineCount = opts.offlineCount or math.min(5, math.max(3, math.floor(peerCount / 6)))
    local nodes = {}
    for index = 1, peerCount do
        nodes[index] = index
    end

    local reloadTargets = {
        3,
        math.max(4, math.floor(peerCount / 3)),
        math.max(5, math.floor((peerCount * 2) / 3)),
    }
    local offlineTargets = {}
    for index = peerCount - offlineCount + 1, peerCount do
        offlineTargets[#offlineTargets + 1] = index
    end

    return {
        peerCount = peerCount,
        cycleCount = cycleCount,
        reloadTargets = reloadTargets,
        offlineTargets = offlineTargets,
        pauseCycles = opts.pauseCycles or { 3, cycleCount >= 7 and 7 or 6 },
        reloadCycles = opts.reloadCycles or { 4, 6, 8 },
    }
end

function Soak.isStable(bus, expectedOwners, prefix)
    return bus:AllNodesHaveOwners(expectedOwners, prefix)
        and bus:AllQueuesIdle()
        and bus:TransportIdle()
        and bus:CountInFlightRequests() == 0
        and bus:CountPartialManifests() == 0
        and bus:CountPartialSnapshots() == 0
        and bus:CountManifestCatchupQueued() == 0
        and bus:CountOutboundChunksQueued() == 0
end

function Soak.waitForStable(bus, expectedOwners, prefix, opts)
    return bus:RunUntil(function(current)
        return Soak.isStable(current, expectedOwners, prefix)
    end, Soak.runOpts(opts))
end

function Soak.mutatedCountsForScenario(bus, cycleCount)
    local expected = {}
    for cycle = 1, cycleCount do
        local node = bus.nodes[((cycle - 1) % #bus.nodes) + 1]
        expected[node.key] = 2
    end
    return expected
end

function Soak.allOnlineNodesSeeRecipeCounts(bus, expectedCounts, profession)
    for _, node in ipairs(bus.nodes) do
        if node.online then
            for ownerKey, expectedCount in pairs(expectedCounts or {}) do
                if bus:CountRecipes(node, ownerKey, profession or "Alchemy") ~= expectedCount then
                    return false
                end
            end
        end
    end
    return true
end

function Soak.chunksAfterDoneCount(bus)
    local doneAt = {}
    local extra = 0
    for _, event in ipairs(bus.events or {}) do
        local sessionId = tostring(event.sessionId or "")
        if sessionId ~= "" then
            local key = table.concat({
                tostring(event.sender or ""),
                sessionId,
            }, "\031")
            if event.type == "SEND" and event.kind == "DONE" then
                doneAt[key] = doneAt[key] or event.tick or 0
            elseif event.type == "SEND" and event.kind == "SNAP" and doneAt[key] and (event.tick or 0) > doneAt[key] then
                extra = extra + 1
            end
        end
    end
    return extra
end

function Soak.manifestLoopDetected(bus, opts)
    opts = opts or {}
    local maxMreqPerEdge = opts.maxMreqPerEdge or 4
    local seen = {}

    for _, event in ipairs(bus.events or {}) do
        if event.type == "SEND" and event.kind == "MREQ" then
            local key = table.concat({
                tostring(event.sender or ""),
                tostring(event.target or ""),
                tostring(event.memberKey or ""),
            }, "\031")
            seen[key] = (seen[key] or 0) + 1
            if seen[key] > maxMreqPerEdge then
                return true
            end
        end
    end
    return false
end

function Soak.retryStormDetected(bus, threshold)
    threshold = threshold or 12
    for _, node in ipairs(bus.nodes) do
        if node.online then
            bus:Activate(node)
            local tel = node.addon.Sync.telemetry or {}
            if (tel.requestRetries or 0) > threshold or (tel.manifestRecoveryRequests or 0) > threshold then
                return true
            end
        end
    end
    return false
end

function Soak.nodeQueueCounts(bus)
    return {
        inFlight = bus:CountInFlightRequests(),
        partialManifests = bus:CountPartialManifests(),
        partialSnapshots = bus:CountPartialSnapshots(),
        manifestCatchup = bus:CountManifestCatchupQueued(),
        outboundChunks = bus:CountOutboundChunksQueued(),
    }
end

function Soak.sumTelemetry(bus, field)
    local total = 0
    for _, node in ipairs(bus.nodes) do
        if node.online then
            bus:Activate(node)
            total = total + (((node.addon.Sync.telemetry or {})[field]) or 0)
        end
    end
    return total
end

function Soak.runScenario(bus, scenario)
    local reloadStep = 0
    local reloadTargets = {}
    local offlineTargets = {}

    for _, index in ipairs(scenario.reloadTargets or {}) do
        reloadTargets[#reloadTargets + 1] = bus.nodes[index]
    end
    for _, index in ipairs(scenario.offlineTargets or {}) do
        offlineTargets[#offlineTargets + 1] = bus.nodes[index]
    end

    for cycle = 1, scenario.cycleCount do
        local mutatingNode = bus.nodes[((cycle - 1) % scenario.peerCount) + 1]
        bus:Activate(mutatingNode)
        Soak.addLocalRecipe(mutatingNode, 700000 + cycle, "soak-cycle-" .. tostring(cycle))

        if cycle == 2 then
            for _, node in ipairs(offlineTargets) do
                bus:SetNodeOnline(node, false)
            end
        elseif cycle == 5 then
            for _, node in ipairs(offlineTargets) do
                bus:SetNodeOnline(node, true)
            end
        end

        for _, pauseCycle in ipairs(scenario.pauseCycles or {}) do
            if pauseCycle == cycle then
                bus:SetNodeInstance(bus.nodes[2], true, "party")
                bus:RunUntil(function()
                    return false
                end, Soak.runOpts({
                    maxTicks = 40,
                }))
                bus:SetNodeInstance(bus.nodes[2], false, "none")
                break
            end
        end

        for _, reloadCycle in ipairs(scenario.reloadCycles or {}) do
            if reloadCycle == cycle and reloadStep < #reloadTargets then
                reloadStep = reloadStep + 1
                local reloadNode = reloadTargets[reloadStep]
                local saved = bus:SnapshotSavedVariables(reloadNode)
                bus:ReloadNode(reloadNode, {
                    savedVariables = saved,
                })
                bus:Activate(reloadNode)
                reloadNode.addon.Sync:BroadcastHello()
                break
            end
        end

        bus:Activate(mutatingNode)
        mutatingNode.addon.Sync:BroadcastHello()
        if cycle == 5 then
            for _, node in ipairs(offlineTargets) do
                bus:Activate(node)
                node.addon.Sync:BroadcastHello()
            end
        end

        bus:RunUntil(function()
            return false
        end, Soak.runOpts({
            maxTicks = scenario.perCycleTicks or 36,
        }))
    end
end

function Soak.emitMutatedOwnerBurst(bus, cycleCount)
    for cycle = 1, cycleCount do
        local node = bus.nodes[((cycle - 1) % #bus.nodes) + 1]
        bus:Activate(node)
        node.addon.Sync:BroadcastHello()
    end
end

function Soak.describeState(bus)
    local queues = Soak.nodeQueueCounts(bus)
    return string.format(
        "work=%s inFlight=%d partialMani=%d partialSnap=%d catchup=%d outbound=%d",
        bus:DescribeWorkSummary(8),
        queues.inFlight,
        queues.partialManifests,
        queues.partialSnapshots,
        queues.manifestCatchup,
        queues.outboundChunks
    )
end

return Soak
