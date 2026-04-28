local Addon = _G.RecipeRegistry
local BootstrapSync = Addon:NewModule("BootstrapSync")
Addon.BootstrapSync = BootstrapSync

local pairs = pairs
local sort = table.sort
local tinsert = table.insert

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function normalizeSeedEntry(seedKey, metadata)
    if type(metadata) ~= "table" then return nil end
    local entry = {}
    for key, value in pairs(metadata) do
        entry[key] = value
    end
    entry.seedKey = seedKey or entry.seedKey
    entry.protocolVersion = entry.protocolVersion or Addon.WIRE_VERSION
    entry.canSeed = entry.canSeed == true
    entry.isBusy = entry.isBusy == true
    entry.datasetBlocks = tonumber(entry.datasetBlocks or 0) or 0
    entry.datasetRecipes = tonumber(entry.datasetRecipes or 0) or 0
    entry.lastUpdatedAt = tonumber(entry.lastUpdatedAt or 0) or 0
    entry.completeness = tonumber(entry.completeness or entry.datasetRecipes or 0) or 0
    entry.trustedSeed = entry.trustedSeed == true
    return entry
end

function BootstrapSync:OnInitialize()
    self.discovery = {
        startedAt = 0,
        candidates = {},
    }
    self.session = {
        activeSeed = nil,
        inProgress = false,
        completedAt = 0,
        requestedAt = 0,
    }
    self.serveState = {
        activeRequester = nil,
        pendingRequester = nil,
    }
end

function BootstrapSync:CanBootstrap()
    if not IsInGuild() then return false end
    if not Addon.Data or not Addon.Data.IsBootstrapNeeded then return false end
    if self.session.inProgress then return false end
    local completedAt = self.session.completedAt
    if Addon.Data and Addon.Data.GetGlobalMeta then
        completedAt = Addon.Data:GetGlobalMeta().bootstrapCompletedAt or completedAt
    end
    if completedAt and completedAt > 0 then return false end
    return Addon.Data:IsBootstrapNeeded()
end

function BootstrapSync:GetLocalSeedMetadata()
    local blockCount, recipeCount = Addon.Data:GetDatasetCompletenessEstimate()
    return {
        protocolVersion = Addon.WIRE_VERSION,
        canSeed = Addon.Data:IsBootstrapCandidate(),
        isBusy = self.serveState.activeRequester ~= nil,
        datasetBlocks = blockCount,
        datasetRecipes = recipeCount,
        completeness = recipeCount,
        lastUpdatedAt = Addon.Data:GetLocalSummary().updatedAt or 0,
        trustedSeed = false,
    }
end

function BootstrapSync:ObserveSeedMetadata(seedKey, metadata)
    local entry = normalizeSeedEntry(seedKey, metadata)
    if not entry then return end
    self.discovery.candidates[entry.seedKey] = entry
end

function BootstrapSync:StartSeedDiscovery()
    self.discovery.startedAt = time()
    self.discovery.candidates = {}

    -- Scaffolding note: protocol exchange lands in a later pass. For now the
    -- discovery cache is a local registry populated by ObserveSeedMetadata().
    if Addon.Sync and Addon.Sync.registry then
        for memberKey in pairs(Addon.Sync.registry) do
            if memberKey ~= Addon.Data:GetPlayerKey() then
                self.discovery.candidates[memberKey] = normalizeSeedEntry(memberKey, {
                    protocolVersion = Addon.WIRE_VERSION,
                    canSeed = true,
                    isBusy = false,
                    datasetBlocks = 0,
                    datasetRecipes = 0,
                    completeness = 0,
                    lastUpdatedAt = 0,
                })
            end
        end
    end

    return self.discovery.candidates
end

function BootstrapSync:SelectBestSeed()
    local ranked = {}
    for seedKey, metadata in pairs(self.discovery.candidates or {}) do
        ranked[#ranked + 1] = normalizeSeedEntry(seedKey, metadata)
    end

    sort(ranked, function(a, b)
        local aCompatible = a.protocolVersion == Addon.WIRE_VERSION and 1 or 0
        local bCompatible = b.protocolVersion == Addon.WIRE_VERSION and 1 or 0
        if aCompatible ~= bCompatible then return aCompatible > bCompatible end
        if a.isBusy ~= b.isBusy then return not a.isBusy end
        if a.canSeed ~= b.canSeed then return a.canSeed end
        if a.completeness ~= b.completeness then return a.completeness > b.completeness end
        if a.lastUpdatedAt ~= b.lastUpdatedAt then return a.lastUpdatedAt > b.lastUpdatedAt end
        if a.trustedSeed ~= b.trustedSeed then return a.trustedSeed end
        return tostring(a.seedKey) < tostring(b.seedKey)
    end)

    self.discovery.selectedSeed = ranked[1] and ranked[1].seedKey or nil
    return ranked[1]
end

function BootstrapSync:RequestBootstrap(seedKey)
    if not seedKey then return false end
    if not self:CanBootstrap() then return false end

    self.session.activeSeed = seedKey
    self.session.inProgress = true
    self.session.requestedAt = time()

    if Addon.Performance then
        Addon.Performance:ScheduleJob("bootstrap-request", function()
            -- Placeholder until the bootstrap wire protocol is added.
            return false
        end, {
            category = "bootstrap",
            label = "bootstrap-request:" .. tostring(seedKey),
        })
    end

    Addon:RequestRefresh("bootstrap")
    return true
end

function BootstrapSync:QueueBootstrapRequest(requester)
    if not requester then return false, "missing-requester" end
    if self.serveState.activeRequester and self.serveState.activeRequester ~= requester then
        if self.serveState.pendingRequester and self.serveState.pendingRequester ~= requester then
            if Addon.Sync and Addon.Sync.telemetry then
                Addon.Sync.telemetry.busySeedRejections = (Addon.Sync.telemetry.busySeedRejections or 0) + 1
            end
            return false, "busy"
        end
        self.serveState.pendingRequester = requester
        return false, "pending"
    end

    self.serveState.activeRequester = requester
    return true, "accepted"
end

function BootstrapSync:SendNextBootstrapChunk()
    if not self.serveState.activeRequester then return false end
    -- Chunk transport is intentionally deferred until the protocol step lands.
    return false
end

function BootstrapSync:ApplyBootstrapChunk(chunk)
    if type(chunk) ~= "table" then return false end

    if Addon.Performance then
        Addon.Performance:ScheduleJob("bootstrap-apply", function(state)
            state.done = true
            return false, state
        end, {
            category = "bootstrap",
            label = "bootstrap-apply",
            state = {
                chunk = chunk,
            },
        })
    end

    Addon:RequestRefresh("bootstrap")
    return true
end

function BootstrapSync:MarkBootstrapComplete()
    self.session.inProgress = false
    self.session.completedAt = time()
    self.session.activeSeed = nil
    if Addon.Data and Addon.Data.MarkBootstrapCompleted then
        Addon.Data:MarkBootstrapCompleted(self.session.completedAt)
    end
    Addon:RequestRefresh("bootstrap")
end

function BootstrapSync:GetUiState()
    return {
        canBootstrap = self:CanBootstrap(),
        inProgress = self.session.inProgress,
        completed = self.session.completedAt and self.session.completedAt > 0 or false,
        activeSeed = self.session.activeSeed,
        candidateCount = countKeys(self.discovery.candidates),
    }
end
