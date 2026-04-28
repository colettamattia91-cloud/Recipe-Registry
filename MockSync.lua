local Addon = _G.RecipeRegistry
local MockSync = Addon:NewModule("MockSync")
Addon.MockSync = MockSync

local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local format = string.format

local MOCK_PEER_PREFIX = "__RRMockPeer"
local MOCK_OWNER_PREFIX = "__RRMockOwner"

local MOCK_PROFESSIONS = {
    "Alchemy", "Blacksmithing", "Cooking", "Enchanting",
    "Engineering", "Jewelcrafting", "Leatherworking", "Tailoring",
}

local SCENARIOS = {
    light = { peers = 2, professions = 2, recipesPerProfession = 30, chunkSize = 20, peerDelay = 0.12 },
    medium = { peers = 4, professions = 3, recipesPerProfession = 70, chunkSize = 24, peerDelay = 0.09 },
    heavy = { peers = 8, professions = 4, recipesPerProfession = 120, chunkSize = 28, peerDelay = 0.06 },
    burst = { peers = 12, professions = 4, recipesPerProfession = 160, chunkSize = 40, peerDelay = 0.02 },
    bootstrap = { peers = 1, professions = 6, recipesPerProfession = 220, chunkSize = 32, peerDelay = 0.04, sourceType = "bootstrap" },
    traffic = { mode = "traffic", peers = 3, ownersPerPeer = 2, professions = 3, recipesPerProfession = 80, chunkSize = 24, peerDelay = 0.08, requestDelay = 0.05, sourceType = "replica" },
    offline = { mode = "traffic", peers = 4, ownersPerPeer = 3, professions = 3, recipesPerProfession = 110, chunkSize = 24, peerDelay = 0.06, requestDelay = 0.05, sourceType = "replica" },
    trafficburst = { mode = "traffic", peers = 6, ownersPerPeer = 3, professions = 4, recipesPerProfession = 150, chunkSize = 32, peerDelay = 0.02, requestDelay = 0.02, sourceType = "replica" },
    roster = { mode = "roster", activeMembers = 6, missingMembers = 4, prunableMembers = 2, professions = 3, recipesPerProfession = 18 },
    rosterheavy = { mode = "roster", activeMembers = 12, missingMembers = 8, prunableMembers = 5, professions = 4, recipesPerProfession = 28 },
}

local function nowSeconds()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return time()
end

local function cloneTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function copyRecipeSlice(recipeKeys, startIndex, chunkSize)
    local slice = {}
    for offset = 0, (chunkSize - 1) do
        local recipeKey = recipeKeys[startIndex + offset]
        if not recipeKey then break end
        slice[#slice + 1] = recipeKey
    end
    return slice
end

function MockSync:OnInitialize()
    self:Reset()
end

function MockSync:Reset()
    self.active = false
    self.scenarioName = nil
    self.scenarioConfig = nil
    self.pendingPayloads = {}
    self.mockDatasets = {}
    self.rosterScenario = nil
    self._scenarioSerial = 0
    self.telemetry = {
        scenariosStarted = 0,
        scenariosCompleted = 0,
        payloadsQueued = 0,
        payloadsDelivered = 0,
        peersSimulated = 0,
        trafficAnnouncements = 0,
        trafficRequests = 0,
        trafficSnapshots = 0,
        rosterRunsStarted = 0,
        rosterRunsCompleted = 0,
    }
end

function MockSync:ResetTelemetry()
    self.telemetry = {
        scenariosStarted = 0,
        scenariosCompleted = 0,
        payloadsQueued = 0,
        payloadsDelivered = 0,
        peersSimulated = 0,
        trafficAnnouncements = 0,
        trafficRequests = 0,
        trafficSnapshots = 0,
        rosterRunsStarted = 0,
        rosterRunsCompleted = 0,
    }
end

function MockSync:GetScenarioConfig(name)
    local config = SCENARIOS[name]
    if not config then return nil end
    return cloneTable(config)
end

function MockSync:BuildPeerKey(index)
    local realm = (GetRealmName() or "MockRealm"):gsub("[%s%-]", "")
    return format("%s%02d-%s", MOCK_PEER_PREFIX, index, realm)
end

function MockSync:BuildOwnerKey(peerIndex, ownerIndex)
    local realm = (GetRealmName() or "MockRealm"):gsub("[%s%-]", "")
    return format("%s%02d%02d-%s", MOCK_OWNER_PREFIX, peerIndex, ownerIndex, realm)
end

function MockSync:BuildRosterKey(index)
    local realm = (GetRealmName() or "MockRealm"):gsub("[%s%-]", "")
    return format("%sRoster%02d-%s", MOCK_OWNER_PREFIX, index, realm)
end

function MockSync:BuildRecipeKeys(peerIndex, ownerIndex, professionIndex, recipeCount)
    local recipeKeys = {}
    local base = 800000 + (peerIndex * 100000) + (ownerIndex * 10000) + (professionIndex * 1000)
    for i = 1, recipeCount do
        recipeKeys[#recipeKeys + 1] = base + i
    end
    return recipeKeys
end

function MockSync:SeedMockMember(memberKey, professions, recipesPerProfession, opts)
    opts = opts or {}
    local entry = Addon.Data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.rev = opts.rev or (((self._scenarioSerial or 0) * 1000) + professions)
    entry.updatedAt = opts.updatedAt or time()
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.staleAt = opts.staleAt or 0
    entry.isMock = true
    entry.professions = {}

    for professionIndex = 1, professions do
        local professionKey = MOCK_PROFESSIONS[((professionIndex - 1) % #MOCK_PROFESSIONS) + 1]
        local recipeKeys = self:BuildRecipeKeys(90 + professionIndex, 40 + professions, professionIndex, recipesPerProfession)
        local recipes = {}
        for recipeIndex = 1, #recipeKeys do
            recipes[recipeKeys[recipeIndex]] = true
        end
        entry.professions[professionKey] = {
            recipes = recipes,
            skillRank = 300,
            skillMaxRank = 375,
            sourceType = entry.sourceType,
            guildStatus = entry.guildStatus,
            lastSeenInGuildAt = entry.lastSeenInGuildAt,
            blockRevision = entry.rev,
            lastUpdatedAt = entry.updatedAt,
        }
    end

    Addon.Data:NormalizeMemberEntry(entry, memberKey)
    return entry
end

function MockSync:StartRosterScenario(name, config)
    if not (Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.StartCleanup) then
        return false, "cleanup-unavailable"
    end

    self:Cleanup()
    self.active = true
    self.scenarioName = name
    self.scenarioConfig = config
    self.rosterScenario = {
        name = name,
        seeded = 0,
        expectedActive = config.activeMembers or 0,
        expectedStale = config.missingMembers or 0,
        expectedPruned = config.prunableMembers or 0,
        running = true,
        label = "mock-roster-" .. tostring(name),
    }
    self.telemetry.scenariosStarted = self.telemetry.scenariosStarted + 1
    self.telemetry.rosterRunsStarted = (self.telemetry.rosterRunsStarted or 0) + 1

    local now = time()
    local snapshot = {}
    local memberKeys = {}
    local nextIndex = 1

    local function seedMembers(count, opts)
        for _ = 1, count do
            local memberKey = self:BuildRosterKey(nextIndex)
            nextIndex = nextIndex + 1
            self:SeedMockMember(memberKey, config.professions or 2, config.recipesPerProfession or 12, opts)
            memberKeys[#memberKeys + 1] = memberKey
            self.rosterScenario.seeded = self.rosterScenario.seeded + 1
            if opts and opts.presentInRoster then
                snapshot[memberKey] = true
            end
        end
    end

    seedMembers(config.activeMembers or 0, {
        guildStatus = "active",
        presentInRoster = true,
        updatedAt = now,
        lastSeenInGuildAt = now,
    })
    seedMembers(config.missingMembers or 0, {
        guildStatus = "active",
        presentInRoster = false,
        updatedAt = now - 86400,
        lastSeenInGuildAt = now - 86400,
    })
    seedMembers(config.prunableMembers or 0, {
        guildStatus = "stale",
        presentInRoster = false,
        updatedAt = now - (35 * 24 * 60 * 60),
        lastSeenInGuildAt = now - (35 * 24 * 60 * 60),
        staleAt = now - (35 * 24 * 60 * 60),
    })

    Addon.Data:InvalidateRecipeCaches("presence")
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex()
    end

    local started, reason = Addon.GuildLifecycleMaintenance:StartCleanup({
        force = true,
        snapshot = snapshot,
        memberKeys = memberKeys,
        updateLastRunAt = false,
        label = self.rosterScenario.label,
        mock = true,
    })
    if not started then
        self.active = false
        self.rosterScenario.running = false
        return false, reason or "cleanup-start-failed"
    end

    Addon:RequestRefresh("mock-roster")
    return true
end

function MockSync:IsMockKey(memberKey)
    return type(memberKey) == "string"
        and (memberKey:find(MOCK_PEER_PREFIX, 1, true) == 1 or memberKey:find(MOCK_OWNER_PREFIX, 1, true) == 1)
end

function MockSync:IsLocalTrafficEnabled(sourceKey, memberKey)
    if not self.active then return false end
    if not (self.scenarioConfig and self.scenarioConfig.mode == "traffic") then return false end
    if sourceKey and not self.mockDatasets[sourceKey] then return false end
    if memberKey and not self:IsMockKey(memberKey) then return false end
    return true
end

function MockSync:QueuePayload(deliverAt, payload)
    self.pendingPayloads[#self.pendingPayloads + 1] = {
        deliverAt = deliverAt,
        payload = payload,
    }
    self.telemetry.payloadsQueued = self.telemetry.payloadsQueued + 1
end

function MockSync:BuildDirectPeerPayloads(peerIndex, config)
    local peerKey = self:BuildPeerKey(peerIndex)
    local payloads = {}
    local sessionId = format("mock:%s:%d", peerKey, self._scenarioSerial or 0)
    local rev = ((self._scenarioSerial or 0) * 1000) + peerIndex
    local updatedAt = time()
    local total = 0
    local perProfession = {}

    for professionIndex = 1, config.professions do
        local profession = MOCK_PROFESSIONS[((professionIndex - 1) % #MOCK_PROFESSIONS) + 1]
        local allRecipeKeys = self:BuildRecipeKeys(peerIndex, 1, professionIndex, config.recipesPerProfession)
        perProfession[#perProfession + 1] = {
            profession = profession,
            recipeKeys = allRecipeKeys,
        }
        total = total + math.max(1, math.ceil(#allRecipeKeys / config.chunkSize))
    end

    local seq = 0
    for _, row in ipairs(perProfession) do
        local index = 1
        while index <= #row.recipeKeys do
            seq = seq + 1
            payloads[#payloads + 1] = {
                kind = "SNAP",
                sender = peerKey,
                sessionId = sessionId,
                key = peerKey,
                rev = rev,
                updatedAt = updatedAt,
                sourceType = config.sourceType or "replica",
                isMock = true,
                profession = row.profession,
                skillRank = 300,
                skillMaxRank = 375,
                recipeKeys = copyRecipeSlice(row.recipeKeys, index, config.chunkSize),
                seq = seq,
                total = total,
            }
            index = index + config.chunkSize
        end
    end

    return peerKey, payloads, rev, updatedAt
end

function MockSync:BuildTrafficDataset(peerIndex, config)
    local peerKey = self:BuildPeerKey(peerIndex)
    local peerRevision = ((self._scenarioSerial or 0) * 1000) + peerIndex
    local builtAt = time()
    local owners = {}
    local manifestBlocks = {}
    local totals = { blocks = 0, recipes = 0 }

    for ownerIndex = 1, (config.ownersPerPeer or 1) do
        local ownerKey = self:BuildOwnerKey(peerIndex, ownerIndex)
        local ownerRevision = peerRevision + ownerIndex
        local professions = {}
        for professionIndex = 1, config.professions do
            local professionKey = MOCK_PROFESSIONS[((professionIndex - 1) % #MOCK_PROFESSIONS) + 1]
            local recipeKeys = self:BuildRecipeKeys(peerIndex, ownerIndex, professionIndex, config.recipesPerProfession)
            local signature = table.concat(recipeKeys, ":")
            professions[professionKey] = {
                profession = professionKey,
                recipeKeys = recipeKeys,
                skillRank = 300,
                skillMaxRank = 375,
                revision = ownerRevision,
                updatedAt = builtAt,
                sourceType = config.sourceType or "replica",
                count = #recipeKeys,
                signature = signature,
            }
            local blockKey = Addon.Data:BuildSyncBlockKey(ownerKey, professionKey)
            manifestBlocks[blockKey] = {
                blockKey = blockKey,
                ownerCharacter = ownerKey,
                professionKey = professionKey,
                revision = ownerRevision,
                lastUpdatedAt = builtAt,
                sourceType = config.sourceType or "replica",
                guildStatus = "active",
                lastSeenInGuildAt = builtAt,
                count = #recipeKeys,
                fingerprint = signature,
            }
            totals.blocks = totals.blocks + 1
            totals.recipes = totals.recipes + #recipeKeys
        end

        owners[ownerKey] = {
            memberKey = ownerKey,
            rev = ownerRevision,
            updatedAt = builtAt,
            sourceType = config.sourceType or "replica",
            professions = professions,
        }
    end

    return {
        peerKey = peerKey,
        peerRevision = peerRevision,
        updatedAt = builtAt,
        owners = owners,
        manifest = {
            builtAt = builtAt,
            memberKey = peerKey,
            totals = totals,
            blocks = manifestBlocks,
        },
    }
end

function MockSync:BuildManifestChunks(dataset)
    local blockKeys = {}
    for blockKey in pairs(dataset.manifest.blocks or {}) do
        blockKeys[#blockKeys + 1] = blockKey
    end
    sort(blockKeys)

    local manifestId = format("mockmani:%s:%d:%d", dataset.peerKey, self._scenarioSerial or 0, #blockKeys)
    local chunks = {}
    local chunkSize = 24
    for startIndex = 1, #blockKeys, chunkSize do
        local blocks = {}
        for offset = 0, (chunkSize - 1) do
            local blockKey = blockKeys[startIndex + offset]
            if not blockKey then break end
            blocks[#blocks + 1] = cloneTable(dataset.manifest.blocks[blockKey])
        end
        chunks[#chunks + 1] = {
            kind = "MANI",
            sender = dataset.peerKey,
            manifestId = manifestId,
            builtAt = dataset.manifest.builtAt,
            memberKey = dataset.peerKey,
            totals = dataset.manifest.totals,
            seq = #chunks + 1,
            total = math.max(1, math.ceil(#blockKeys / chunkSize)),
            blocks = blocks,
            isMock = true,
        }
    end

    if #chunks == 0 then
        chunks[1] = {
            kind = "MANI",
            sender = dataset.peerKey,
            manifestId = manifestId,
            builtAt = dataset.manifest.builtAt,
            memberKey = dataset.peerKey,
            totals = dataset.manifest.totals,
            seq = 1,
            total = 1,
            blocks = {},
            isMock = true,
        }
    end

    return chunks
end

function MockSync:QueueDirectScenarioPayloads(name, config)
    local scenarioStartedAt = nowSeconds()

    for peerIndex = 1, config.peers do
        local peerKey, payloads, rev, updatedAt = self:BuildDirectPeerPayloads(peerIndex, config)
        if Addon.Sync then
            Addon.Sync:TouchNode(peerKey, "mock")
            Addon.Sync:RecordRevisionHint(peerKey, rev, updatedAt, peerKey, { isMock = true })
        end
        for payloadIndex = 1, #payloads do
            self:QueuePayload(
                scenarioStartedAt + ((payloadIndex - 1) * config.peerDelay),
                payloads[payloadIndex]
            )
        end
    end
end

function MockSync:QueueTrafficScenarioPayloads(config)
    local scenarioStartedAt = nowSeconds()

    for peerIndex = 1, config.peers do
        local dataset = self:BuildTrafficDataset(peerIndex, config)
        self.mockDatasets[dataset.peerKey] = dataset
        if Addon.Sync then
            Addon.Sync:TouchNode(dataset.peerKey, "mock-traffic")
            Addon.Sync:RecordRevisionHint(dataset.peerKey, dataset.peerRevision, dataset.updatedAt, dataset.peerKey, { isMock = true })
        end

        self:QueuePayload(scenarioStartedAt + ((peerIndex - 1) * config.peerDelay), {
            kind = "HELLO",
            sender = dataset.peerKey,
            key = dataset.peerKey,
            rev = dataset.peerRevision,
            updatedAt = dataset.updatedAt,
            version = "mock-traffic",
            isMock = true,
        })

        local manifestChunks = self:BuildManifestChunks(dataset)
        for chunkIndex = 1, #manifestChunks do
            self:QueuePayload(
                scenarioStartedAt + ((peerIndex - 1) * config.peerDelay) + 0.02 + ((chunkIndex - 1) * 0.01),
                manifestChunks[chunkIndex]
            )
        end
    end
end

function MockSync:QueueScenarioPayloads(name)
    local config = self:GetScenarioConfig(name)
    if not config then return false, "unknown-scenario" end

    self.active = true
    self.scenarioName = name
    self.scenarioConfig = config
    self.pendingPayloads = {}
    self.mockDatasets = {}
    self._scenarioSerial = (self._scenarioSerial or 0) + 1
    self.telemetry.scenariosStarted = self.telemetry.scenariosStarted + 1
    self.telemetry.peersSimulated = config.peers

    if config.mode == "traffic" then
        self:QueueTrafficScenarioPayloads(config)
    else
        self:QueueDirectScenarioPayloads(name, config)
    end

    sort(self.pendingPayloads, function(a, b)
        return (a.deliverAt or 0) < (b.deliverAt or 0)
    end)
    return true
end

function MockSync:DeliverTrafficPayload(payload)
    if not Addon.Sync then return end
    if payload.kind == "HELLO" then
        self.telemetry.trafficAnnouncements = self.telemetry.trafficAnnouncements + 1
        Addon.Sync:HandleHello(payload)
        return
    end
    if payload.kind == "MANI" then
        self.telemetry.trafficAnnouncements = self.telemetry.trafficAnnouncements + 1
        Addon.Sync:HandleManifestChunk(payload)
        return
    end
    if payload.kind == "SNAP" then
        self.telemetry.trafficSnapshots = self.telemetry.trafficSnapshots + 1
        Addon.Sync:HandleSnapshotChunk(payload)
    end
end

function MockSync:DeliverNextPayload()
    if #self.pendingPayloads == 0 then
        self._workerScheduled = false
        if self.active and not (self.scenarioConfig and self.scenarioConfig.mode == "traffic") then
            self.active = false
            self.telemetry.scenariosCompleted = self.telemetry.scenariosCompleted + 1
            Addon:RequestRefresh("mock")
        end
        return false
    end

    local nextPayload = self.pendingPayloads[1]
    if (nextPayload.deliverAt or 0) > nowSeconds() then
        return true
    end

    table.remove(self.pendingPayloads, 1)
    self.telemetry.payloadsDelivered = self.telemetry.payloadsDelivered + 1

    if nextPayload.payload.kind == "SNAP" and not nextPayload.payload.sessionId then
        nextPayload.payload.sessionId = format("mock:snap:%s:%d", nextPayload.payload.key or "unknown", self._scenarioSerial or 0)
    end

    if self.scenarioConfig and self.scenarioConfig.mode == "traffic" then
        self:DeliverTrafficPayload(nextPayload.payload)
    elseif Addon.Sync then
        Addon.Sync:HandleSnapshotChunk(nextPayload.payload)
    end

    Addon:RequestRefresh("mock")
    return true
end

function MockSync:BuildOwnerSnapshotPayloads(peerKey, ownerKey)
    local dataset = self.mockDatasets[peerKey]
    local owner = dataset and dataset.owners and dataset.owners[ownerKey]
    if not owner then return nil end

    local payloads = {}
    local sessionId = format("mockreq:%s:%s:%d", peerKey, ownerKey, self._scenarioSerial or 0)
    local total = 0
    local professionNames = {}
    for professionKey in pairs(owner.professions or {}) do
        professionNames[#professionNames + 1] = professionKey
    end
    sort(professionNames)

    for _, professionKey in ipairs(professionNames) do
        local profession = owner.professions[professionKey]
        total = total + math.max(1, math.ceil(#(profession.recipeKeys or {}) / (self.scenarioConfig.chunkSize or 24)))
    end

    local seq = 0
    for _, professionKey in ipairs(professionNames) do
        local profession = owner.professions[professionKey]
        local index = 1
        repeat
            seq = seq + 1
            payloads[#payloads + 1] = {
                kind = "SNAP",
                sender = peerKey,
                sessionId = sessionId,
                key = ownerKey,
                rev = owner.rev,
                updatedAt = owner.updatedAt,
                sourceType = profession.sourceType or owner.sourceType or "replica",
                isMock = true,
                profession = professionKey,
                skillRank = profession.skillRank or 0,
                skillMaxRank = profession.skillMaxRank or 0,
                recipeKeys = copyRecipeSlice(profession.recipeKeys or {}, index, self.scenarioConfig.chunkSize or 24),
                seq = seq,
                total = total,
            }
            index = index + (self.scenarioConfig.chunkSize or 24)
        until index > #(profession.recipeKeys or {})
    end

    return payloads
end

function MockSync:HandleLocalRequest(request)
    local dataset = request and self.mockDatasets and self.mockDatasets[request.source]
    if not dataset then return false end
    local owner = dataset.owners and dataset.owners[request.memberKey]
    if not owner then return false end
    if (owner.rev or 0) <= (request.knownRev or 0) then
        return false
    end

    self.telemetry.trafficRequests = self.telemetry.trafficRequests + 1
    local payloads = self:BuildOwnerSnapshotPayloads(request.source, request.memberKey)
    if not payloads or #payloads == 0 then
        return false
    end

    local startAt = nowSeconds() + (self.scenarioConfig.requestDelay or 0.05)
    for payloadIndex = 1, #payloads do
        self:QueuePayload(startAt + ((payloadIndex - 1) * (self.scenarioConfig.peerDelay or 0.05)), payloads[payloadIndex])
    end
    sort(self.pendingPayloads, function(a, b)
        return (a.deliverAt or 0) < (b.deliverAt or 0)
    end)
    self:EnsureWorker()
    return true
end

function MockSync:EnsureWorker()
    if self._workerScheduled or not Addon.Performance then return end
    self._workerScheduled = true
    Addon.Performance:ScheduleJob("mock-sync-loop", function()
        return self:DeliverNextPayload()
    end, {
        category = "mock",
        label = "mock-sync-loop",
        budgetMs = 1,
    })
end

function MockSync:StartScenario(name)
    local config = self:GetScenarioConfig(name)
    if not config then
        return false, "unknown-scenario"
    end
    if config.mode == "roster" then
        return self:StartRosterScenario(name, config)
    end

    local ok, err = self:QueueScenarioPayloads(name)
    if not ok then
        return false, err
    end
    self:EnsureWorker()
    Addon:RequestRefresh("mock")
    return true
end

function MockSync:Stop()
    self.pendingPayloads = {}
    self.mockDatasets = {}
    self.active = false
    self.scenarioName = nil
    self.scenarioConfig = nil
    self.rosterScenario = nil
    self._workerScheduled = false
    Addon:RequestRefresh("mock")
end

function MockSync:Cleanup()
    self:Stop()
    local removedMembers = Addon.Data and Addon.Data.DeleteMockMembers and Addon.Data:DeleteMockMembers() or 0
    local removedRegistry, removedOnlineNodes, removedPending = 0, 0, 0
    if Addon.Sync and Addon.Sync.CleanupMockState then
        removedRegistry, removedOnlineNodes, removedPending = Addon.Sync:CleanupMockState()
    end
    if Addon.TrickleSync and Addon.TrickleSync.peerState then
        for peerKey in pairs(Addon.TrickleSync.peerState) do
            if self:IsMockKey(peerKey) then
                Addon.TrickleSync.peerState[peerKey] = nil
            end
        end
        for peerKey in pairs(Addon.TrickleSync.outboundQueue or {}) do
            if self:IsMockKey(peerKey) then
                Addon.TrickleSync.outboundQueue[peerKey] = nil
            end
        end
    end
    return removedMembers, removedRegistry, removedOnlineNodes, removedPending
end

function MockSync:GetDebugSnapshot()
    local lastCleanup = Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.GetLastRunInfo
        and Addon.GuildLifecycleMaintenance:GetLastRunInfo() or nil
    local rosterRunning = Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.IsCleanupRunning
        and Addon.GuildLifecycleMaintenance:IsCleanupRunning() or false
    if self.rosterScenario and not rosterRunning and lastCleanup and lastCleanup.label == self.rosterScenario.label and self.rosterScenario.running then
        self.rosterScenario.running = false
        self.active = false
        self.telemetry.scenariosCompleted = self.telemetry.scenariosCompleted + 1
        self.telemetry.rosterRunsCompleted = (self.telemetry.rosterRunsCompleted or 0) + 1
    end
    return {
        active = self.active,
        scenarioName = self.scenarioName,
        pendingPayloads = #self.pendingPayloads,
        datasets = countKeys(self.mockDatasets),
        telemetry = self.telemetry,
        scenarioCount = countKeys(SCENARIOS),
        localTraffic = self.scenarioConfig and self.scenarioConfig.mode == "traffic" or false,
        rosterScenario = self.rosterScenario,
        rosterRunning = rosterRunning,
        lastCleanup = lastCleanup,
    }
end

function MockSync:DumpStatus()
    local snapshot = self:GetDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    Addon:Print(format(
        "Mock active=%s scenario=%s traffic=%s pending=%d datasets=%d started=%d completed=%d queued=%d delivered=%d peers=%d announcements=%d requests=%d snapshots=%d",
        tostring(snapshot.active),
        tostring(snapshot.scenarioName or "none"),
        tostring(snapshot.localTraffic),
        snapshot.pendingPayloads or 0,
        snapshot.datasets or 0,
        telemetry.scenariosStarted or 0,
        telemetry.scenariosCompleted or 0,
        telemetry.payloadsQueued or 0,
        telemetry.payloadsDelivered or 0,
        telemetry.peersSimulated or 0,
        telemetry.trafficAnnouncements or 0,
        telemetry.trafficRequests or 0,
        telemetry.trafficSnapshots or 0
    ))
    if snapshot.rosterScenario then
        local roster = snapshot.rosterScenario
        local lastCleanup = snapshot.lastCleanup
        Addon:Print(format(
            "Mock roster running=%s seeded=%d expectedActive=%d expectedStale=%d expectedPruned=%d lastProcessed=%d lastKept=%d lastStale=%d lastPruned=%d",
            tostring(snapshot.rosterRunning),
            roster.seeded or 0,
            roster.expectedActive or 0,
            roster.expectedStale or 0,
            roster.expectedPruned or 0,
            lastCleanup and lastCleanup.processed or 0,
            lastCleanup and lastCleanup.keptActive or 0,
            lastCleanup and lastCleanup.markedStale or 0,
            lastCleanup and lastCleanup.pruned or 0
        ))
    end
end
