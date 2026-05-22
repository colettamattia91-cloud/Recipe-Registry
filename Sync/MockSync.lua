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
    light = { peers = 2, ownersPerPeer = 1, professions = 2, recipesPerProfession = 30, hardIsolation = true },
    medium = { peers = 4, ownersPerPeer = 1, professions = 3, recipesPerProfession = 70, hardIsolation = true },
    heavy = { peers = 8, ownersPerPeer = 1, professions = 4, recipesPerProfession = 120, hardIsolation = true },
    burst = { peers = 12, ownersPerPeer = 1, professions = 4, recipesPerProfession = 160, hardIsolation = true },
    bootstrap = { peers = 1, ownersPerPeer = 1, professions = 6, recipesPerProfession = 220, sourceType = "bootstrap", hardIsolation = true },
    traffic = { mode = "traffic", peers = 3, ownersPerPeer = 2, professions = 3, recipesPerProfession = 80, hardIsolation = true },
    offline = { mode = "traffic", peers = 4, ownersPerPeer = 3, professions = 3, recipesPerProfession = 110, hardIsolation = true },
    offlinewipe = { mode = "traffic", peers = 4, ownersPerPeer = 3, professions = 3, recipesPerProfession = 110, hardIsolation = true },
    trafficburst = { mode = "traffic", peers = 6, ownersPerPeer = 3, professions = 4, recipesPerProfession = 150, hardIsolation = true },
    roster = { mode = "roster", activeMembers = 6, missingMembers = 4, prunableMembers = 2, professions = 3, recipesPerProfession = 18, hardIsolation = true },
    rosterheavy = { mode = "roster", activeMembers = 12, missingMembers = 8, prunableMembers = 5, professions = 4, recipesPerProfession = 28, hardIsolation = true },
    rosterbad = { mode = "rosterbad", activeMembers = 10, professions = 2, recipesPerProfession = 12, hardIsolation = true },
    integrity = { mode = "integrity", professions = 2, recipesPerProfession = 16, hardIsolation = true },
}

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

local function makeRecipeSet(recipeKeys)
    local recipes = {}
    for index = 1, #recipeKeys do
        recipes[recipeKeys[index]] = true
    end
    return recipes
end

function MockSync:OnInitialize()
    self:Reset()
end

function MockSync:Reset()
    self.active = false
    self.hardIsolation = false
    self.scenarioName = nil
    self.scenarioConfig = nil
    self.mockDatasets = {}
    self.rosterScenario = nil
    self.integrityScenario = nil
    self._scenarioSerial = 0
    self.telemetry = {
        scenariosStarted = 0,
        scenariosCompleted = 0,
        peersSimulated = 0,
        membersSeeded = 0,
        blocksSeeded = 0,
        helloInjected = 0,
        summaryInjected = 0,
        rosterRunsStarted = 0,
        rosterRunsCompleted = 0,
        integrityRunsStarted = 0,
        integrityRunsCompleted = 0,
        integrityRunsFailed = 0,
        suppressedSends = 0,
    }
end

function MockSync:ResetTelemetry()
    self.telemetry = {
        scenariosStarted = 0,
        scenariosCompleted = 0,
        peersSimulated = 0,
        membersSeeded = 0,
        blocksSeeded = 0,
        helloInjected = 0,
        summaryInjected = 0,
        rosterRunsStarted = 0,
        rosterRunsCompleted = 0,
        integrityRunsStarted = 0,
        integrityRunsCompleted = 0,
        integrityRunsFailed = 0,
        suppressedSends = 0,
    }
end

function MockSync:GetScenarioConfig(name)
    local config = SCENARIOS[name]
    if not config then
        return nil
    end
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
    local updatedAt = opts.updatedAt or time()
    entry.owner = memberKey
    entry.updatedAt = updatedAt
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or updatedAt
    entry.staleAt = opts.staleAt or 0
    entry.isMock = true
    entry.professions = {}

    for professionIndex = 1, professions do
        local professionKey = MOCK_PROFESSIONS[((professionIndex - 1) % #MOCK_PROFESSIONS) + 1]
        local recipeKeys = self:BuildRecipeKeys(90 + professionIndex, 40 + professions, professionIndex, recipesPerProfession)
        entry.professions[professionKey] = {
            recipes = makeRecipeSet(recipeKeys),
            skillRank = 300,
            skillMaxRank = 375,
            sourceType = entry.sourceType,
            guildStatus = entry.guildStatus,
            lastSeenInGuildAt = entry.lastSeenInGuildAt,
            lastUpdatedAt = updatedAt,
        }
        self.telemetry.blocksSeeded = (self.telemetry.blocksSeeded or 0) + 1
    end

    Addon.Data:NormalizeMemberEntry(entry, memberKey)
    self.telemetry.membersSeeded = (self.telemetry.membersSeeded or 0) + 1
    return entry
end

function MockSync:IsMockKey(memberKey)
    return type(memberKey) == "string"
        and (memberKey:find(MOCK_PEER_PREFIX, 1, true) == 1 or memberKey:find(MOCK_OWNER_PREFIX, 1, true) == 1)
end

function MockSync:IsLocalTrafficEnabled(sourceKey, memberKey)
    if not self.active then
        return false
    end
    if not (self.scenarioConfig and self.scenarioConfig.mode == "traffic") then
        return false
    end
    if sourceKey and not self.mockDatasets[sourceKey] then
        return false
    end
    if memberKey and not self:IsMockKey(memberKey) then
        return false
    end
    return true
end

function MockSync:IsHardIsolationEnabled()
    return self.active == true and self.hardIsolation == true
end

function MockSync:RecordSuppressedSend()
    self.telemetry.suppressedSends = (self.telemetry.suppressedSends or 0) + 1
end

function MockSync:InjectTrafficDiscovery(peerKey, ownerCount, blockCount, contentCount)
    if not Addon.Sync then
        return
    end
    local fingerprint = format("mock:%s:%d:%d:%d", tostring(peerKey), ownerCount, blockCount, contentCount)
    local helloId = format("mock-hello:%s:%d", tostring(peerKey), self._scenarioSerial or 0)
    local caps = Addon.Sync.GetLocalProtocolCaps and Addon.Sync:GetLocalProtocolCaps() or nil
    local hello = {
        kind = "HELLO",
        sender = peerKey,
        key = peerKey,
        helloId = helloId,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        version = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = Addon.CAPABILITIES,
        caps = caps,
        syncModel = "index-diff-block-pull",
        indexStatus = "ready",
        activeOwnerCount = ownerCount,
        activeBlockCount = blockCount,
        activeContentCount = contentCount,
        globalFingerprint = fingerprint,
        isMock = true,
    }
    Addon.Sync:TouchNode(peerKey, Addon.ADDON_VERSION or Addon.DISPLAY_VERSION)
    if Addon.Sync.ObservePeerVersion then
        Addon.Sync:ObservePeerVersion(peerKey, hello)
    end
    Addon.Sync:HandleHello(hello)
    self.telemetry.helloInjected = (self.telemetry.helloInjected or 0) + 1

    Addon.Sync:HandleSummary({
        kind = "SUMMARY",
        sender = peerKey,
        helloId = helloId,
        activeOwnerCount = ownerCount,
        activeBlockCount = blockCount,
        activeContentCount = contentCount,
        globalFingerprint = fingerprint,
        isMock = true,
    })
    self.telemetry.summaryInjected = (self.telemetry.summaryInjected or 0) + 1
end

function MockSync:SeedScenario(name, config)
    self:Cleanup()
    self.active = true
    self.hardIsolation = config.hardIsolation == true
    self.scenarioName = name
    self.scenarioConfig = config
    self.mockDatasets = {}
    self._scenarioSerial = (self._scenarioSerial or 0) + 1
    self.telemetry.scenariosStarted = (self.telemetry.scenariosStarted or 0) + 1
    self.telemetry.peersSimulated = config.peers or 0

    local totalOwners = 0
    local totalBlocks = 0
    local totalContent = 0

    for peerIndex = 1, (config.peers or 0) do
        local peerKey = self:BuildPeerKey(peerIndex)
        self.mockDatasets[peerKey] = { peerKey = peerKey, owners = {} }
        for ownerIndex = 1, (config.ownersPerPeer or 1) do
            local ownerKey = self:BuildOwnerKey(peerIndex, ownerIndex)
            self:SeedMockMember(ownerKey, config.professions or 2, config.recipesPerProfession or 12, {
                sourceType = config.sourceType or "replica",
                updatedAt = time(),
                lastSeenInGuildAt = time(),
            })
            self.mockDatasets[peerKey].owners[ownerKey] = true
            totalOwners = totalOwners + 1
            totalBlocks = totalBlocks + (config.professions or 0)
            totalContent = totalContent + ((config.professions or 0) * (config.recipesPerProfession or 0))
        end
        if config.mode == "traffic" then
            self:InjectTrafficDiscovery(
                peerKey,
                config.ownersPerPeer or 1,
                (config.ownersPerPeer or 1) * (config.professions or 0),
                (config.ownersPerPeer or 1) * (config.professions or 0) * (config.recipesPerProfession or 0)
            )
        end
    end

    if Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty("mock-seed", nil, {
            full = true,
        })
    end
    if Addon.Sync and Addon.Sync.ScheduleHello then
        Addon.Sync:ScheduleHello("mock-seed", 0.2)
    end

    self.active = false
    self.telemetry.scenariosCompleted = (self.telemetry.scenariosCompleted or 0) + 1
    Addon:RequestRefresh("mock")
    return true, format("owners=%d blocks=%d content=%d", totalOwners, totalBlocks, totalContent)
end

function MockSync:StartRosterScenario(name, config)
    if not (Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.StartCleanup) then
        return false, "cleanup-unavailable"
    end

    self:Cleanup()
    self.active = true
    self.hardIsolation = config.hardIsolation == true
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
    self.telemetry.scenariosStarted = (self.telemetry.scenariosStarted or 0) + 1
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

function MockSync:StartRosterBadScenario(name, config)
    if not (Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.StartCleanup) then
        return false, "cleanup-unavailable"
    end

    self:Cleanup()
    self.active = true
    self.hardIsolation = config.hardIsolation == true
    self.scenarioName = name
    self.scenarioConfig = config
    self.rosterScenario = {
        name = name,
        seeded = 0,
        expectedActive = config.activeMembers or 0,
        expectedStale = 0,
        expectedPruned = 0,
        running = false,
        label = "mock-rosterbad-" .. tostring(name),
    }
    self.telemetry.scenariosStarted = (self.telemetry.scenariosStarted or 0) + 1
    self.telemetry.rosterRunsStarted = (self.telemetry.rosterRunsStarted or 0) + 1

    local memberKeys = {}
    for index = 1, (config.activeMembers or 0) do
        local memberKey = self:BuildRosterKey(index)
        self:SeedMockMember(memberKey, config.professions or 2, config.recipesPerProfession or 12, {
            guildStatus = "active",
            updatedAt = time(),
            lastSeenInGuildAt = time(),
        })
        memberKeys[#memberKeys + 1] = memberKey
        self.rosterScenario.seeded = self.rosterScenario.seeded + 1
    end

    local started, reason = Addon.GuildLifecycleMaintenance:StartCleanup({
        force = true,
        snapshot = {},
        memberKeys = memberKeys,
        updateLastRunAt = false,
        label = self.rosterScenario.label,
        mock = false,
    })
    if started then
        self.rosterScenario.running = true
        return true
    end

    self.active = false
    self.telemetry.scenariosCompleted = (self.telemetry.scenariosCompleted or 0) + 1
    self.telemetry.rosterRunsCompleted = (self.telemetry.rosterRunsCompleted or 0) + 1
    Addon:RequestRefresh("mock-rosterbad")
    return reason == "roster-empty" or reason == "roster-too-small", reason or "cleanup-start-failed"
end

function MockSync:StartIntegrityScenario(name, config)
    self:Cleanup()
    self.active = true
    self.hardIsolation = config.hardIsolation == true
    self.scenarioName = name
    self.scenarioConfig = config
    self.integrityScenario = {
        name = name,
        passed = false,
        reason = "not-run",
    }
    self.telemetry.scenariosStarted = (self.telemetry.scenariosStarted or 0) + 1
    self.telemetry.integrityRunsStarted = (self.telemetry.integrityRunsStarted or 0) + 1

    local memberKey = self:BuildOwnerKey(77, 1)
    local entry = self:SeedMockMember(memberKey, config.professions or 2, config.recipesPerProfession or 16, {
        sourceType = "replica",
        guildStatus = "active",
        updatedAt = time() - 60,
        lastSeenInGuildAt = time() - 60,
    })

    local professionNames = {}
    for professionName in pairs(entry.professions or {}) do
        professionNames[#professionNames + 1] = professionName
    end
    sort(professionNames)
    local primaryProfession = professionNames[1]
    local secondaryProfession = professionNames[2]
    if not primaryProfession or not secondaryProfession then
        self.integrityScenario.reason = "missing-professions"
        self.telemetry.integrityRunsFailed = (self.telemetry.integrityRunsFailed or 0) + 1
        self.active = false
        return false, "missing-professions"
    end

    local blockKey = Addon.Data:BuildSyncBlockKey(memberKey, primaryProfession)
    local snapshot = Addon.Data:BuildBlockSnapshot(blockKey, {
        snapshotKind = "mock-integrity",
    })
    local subset = {}
    for index = 1, math.max(1, math.floor(#(snapshot.recipeKeys or {}) / 2)) do
        subset[#subset + 1] = snapshot.recipeKeys[index]
    end
    snapshot.recipeKeys = subset

    local applied = Addon.Data:ApplyIncomingBlockAdditive(blockKey, {
        blockKey = blockKey,
        ownerCharacter = memberKey,
        professionKey = primaryProfession,
        recipeKeys = snapshot.recipeKeys,
        specialization = snapshot.specialization,
        skillRank = snapshot.skillRank,
        skillMaxRank = snapshot.skillMaxRank,
        metadata = snapshot.metadata,
    }, {
        sourceType = "replica",
    })

    local resolved = Addon.Data:GetMember(memberKey)
    local primaryCount = resolved and resolved.professions and resolved.professions[primaryProfession]
        and resolved.professions[primaryProfession].count or 0
    local secondaryExists = resolved and resolved.professions and resolved.professions[secondaryProfession] ~= nil
    local expectedPrimaryCount = entry.professions[primaryProfession].count or 0
    local passed = applied == true and primaryCount >= expectedPrimaryCount and secondaryExists

    self.integrityScenario = {
        name = name,
        passed = passed,
        reason = passed and "ok" or "integrity-check-failed",
        memberKey = memberKey,
        primaryProfession = primaryProfession,
        primaryCount = primaryCount,
        expectedPrimaryCount = expectedPrimaryCount,
        secondaryProfession = secondaryProfession,
        secondaryExists = secondaryExists,
    }

    if passed then
        self.telemetry.integrityRunsCompleted = (self.telemetry.integrityRunsCompleted or 0) + 1
        self.telemetry.scenariosCompleted = (self.telemetry.scenariosCompleted or 0) + 1
    else
        self.telemetry.integrityRunsFailed = (self.telemetry.integrityRunsFailed or 0) + 1
    end
    self.active = false
    Addon:RequestRefresh("mock-integrity")
    return passed, self.integrityScenario.reason
end

function MockSync:HandleLocalRequest(_request)
    return false
end

function MockSync:StartScenario(name)
    local config = self:GetScenarioConfig(name)
    if not config then
        return false, "unknown-scenario"
    end
    if config.mode == "roster" then
        return self:StartRosterScenario(name, config)
    end
    if config.mode == "rosterbad" then
        return self:StartRosterBadScenario(name, config)
    end
    if config.mode == "integrity" then
        return self:StartIntegrityScenario(name, config)
    end
    return self:SeedScenario(name, config)
end

function MockSync:Stop()
    self.active = false
    self.hardIsolation = false
    self.scenarioName = nil
    self.scenarioConfig = nil
    self.mockDatasets = {}
    self.rosterScenario = nil
    self.integrityScenario = nil
    Addon:RequestRefresh("mock")
end

function MockSync:Cleanup()
    self:Stop()
    local removedMembers = Addon.Data and Addon.Data.DeleteMockMembers and Addon.Data:DeleteMockMembers() or 0
    local removedRegistry, removedOnlineNodes, removedPending = 0, 0, 0
    if Addon.Sync and Addon.Sync.CleanupMockState then
        removedRegistry, removedOnlineNodes, removedPending = Addon.Sync:CleanupMockState()
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
        self.telemetry.scenariosCompleted = (self.telemetry.scenariosCompleted or 0) + 1
        self.telemetry.rosterRunsCompleted = (self.telemetry.rosterRunsCompleted or 0) + 1
    end
    return {
        active = self.active,
        scenarioName = self.scenarioName,
        datasets = countKeys(self.mockDatasets),
        telemetry = self.telemetry,
        scenarioCount = countKeys(SCENARIOS),
        localTraffic = self.scenarioConfig and self.scenarioConfig.mode == "traffic" or false,
        hardIsolation = self:IsHardIsolationEnabled(),
        rosterScenario = self.rosterScenario,
        integrityScenario = self.integrityScenario,
        rosterRunning = rosterRunning,
        lastCleanup = lastCleanup,
    }
end

function MockSync:DumpStatus()
    local snapshot = self:GetDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    Addon:SystemPrint(format(
        "Mock active=%s scenario=%s traffic=%s isolated=%s datasets=%d started=%d completed=%d peers=%d members=%d blocks=%d hello=%d summary=%d suppressed=%d",
        tostring(snapshot.active),
        tostring(snapshot.scenarioName or "none"),
        tostring(snapshot.localTraffic),
        tostring(snapshot.hardIsolation),
        snapshot.datasets or 0,
        telemetry.scenariosStarted or 0,
        telemetry.scenariosCompleted or 0,
        telemetry.peersSimulated or 0,
        telemetry.membersSeeded or 0,
        telemetry.blocksSeeded or 0,
        telemetry.helloInjected or 0,
        telemetry.summaryInjected or 0,
        telemetry.suppressedSends or 0
    ))
    if snapshot.rosterScenario then
        local roster = snapshot.rosterScenario
        local lastCleanup = snapshot.lastCleanup
        Addon:SystemPrint(format(
            "Mock roster running=%s seeded=%d expectedActive=%d expectedStale=%d expectedPruned=%d lastProcessed=%d lastKept=%d lastStale=%d lastPruned=%d aborted=%s reason=%s",
            tostring(snapshot.rosterRunning),
            roster.seeded or 0,
            roster.expectedActive or 0,
            roster.expectedStale or 0,
            roster.expectedPruned or 0,
            lastCleanup and lastCleanup.processed or 0,
            lastCleanup and lastCleanup.keptActive or 0,
            lastCleanup and lastCleanup.markedStale or 0,
            lastCleanup and lastCleanup.pruned or 0,
            tostring(lastCleanup and lastCleanup.aborted or false),
            tostring(lastCleanup and lastCleanup.abortReason or "none")
        ))
    end
    if snapshot.integrityScenario then
        local integrity = snapshot.integrityScenario
        Addon:SystemPrint(format(
            "Mock integrity passed=%s reason=%s member=%s primary=%s %d/%d secondary=%s exists=%s",
            tostring(integrity.passed),
            tostring(integrity.reason or "none"),
            tostring(integrity.memberKey or "none"),
            tostring(integrity.primaryProfession or "none"),
            integrity.primaryCount or 0,
            integrity.expectedPrimaryCount or 0,
            tostring(integrity.secondaryProfession or "none"),
            tostring(integrity.secondaryExists or false)
        ))
    end
end
